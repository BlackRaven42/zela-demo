use std::{
    collections::HashMap,
    sync::{
        OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};

use serde::{Deserialize, Serialize};
use zela_std::{CustomProcedure, RpcError, rpc_client::RpcClient, zela_custom_procedure};

pub struct Geo;

#[derive(Deserialize, Debug)]
pub struct Input {}

#[derive(Serialize, Deserialize, Clone, Copy, Debug)]
pub enum Region {
    Frankfurt,
    Dubai,
    NewYork,
    Tokyo,
}

#[derive(Serialize)]
pub struct Output {
    pub slot: u64,
    pub leader: String,
    pub leader_geo: String,
    pub closest_region: Region,
}

// Once this threshold is exceeded, the procedure warns the operator that it's time to rebuild the ip-geo map.
const UNKNOWN_IP_WARN_THRESHOLD: u64 = 10;
const UNKNOWN_GEO: &str = "UNKNOWN";

// Note: atomic is just a precaution in case procedure can run concurrently.
static UNKNOWN_IP_MISS_COUNT: AtomicU64 = AtomicU64::new(0);

// Note: this is a compile-time check - which prevents us from submitting a procedure without the map!
const LEADER_GEO_MAP_RAW: &str = include_str!("../data/ip-geo-map.json");

// Note: OnceLock is needed to only load & parse once.
static LEADER_GEO_BY_IP: OnceLock<HashMap<String, IpGeoInfo>> = OnceLock::new();

#[derive(Deserialize, Clone)]
struct IpGeoInfo {
    geo: String,
    closest_region: Region,
}

// Note: it is safe to use unwrap here, since we test the parseability of the map in the test below.
fn leader_geo_by_ip() -> &'static HashMap<String, IpGeoInfo> {
    LEADER_GEO_BY_IP.get_or_init(|| {
        serde_json::from_str::<HashMap<String, IpGeoInfo>>(LEADER_GEO_MAP_RAW).unwrap()
    })
}

impl CustomProcedure for Geo {
    type Params = Input;
    type ErrorData = ();
    type SuccessData = Output;

    async fn run(_: Self::Params) -> Result<Self::SuccessData, RpcError<Self::ErrorData>> {
        let client = RpcClient::new();
        let slot = client.get_slot().await?;
        let epoch_info = client.get_epoch_info().await?;

        let schedule = client
            .get_leader_schedule(Some(slot))
            .await?
            .ok_or_else(|| RpcError {
                code: 500,
                message: format!("leader schedule is unavailable for slot {slot}"),
                data: None,
            })?;

        let slot_index = epoch_info.slot_index as usize;
        let leader = schedule
            .into_iter()
            .find_map(|(identity, slots)| {
                slots
                    .into_iter()
                    .any(|s| s == slot_index)
                    .then_some(identity)
            })
            .ok_or_else(|| RpcError {
                code: 500,
                message: format!(
                    "leader not found in schedule for slot {slot} (slot_index={slot_index})"
                ),
                data: None,
            })?;

        let fallback = (UNKNOWN_GEO.to_string(), Region::Tokyo);

        let (leader_geo, closest_region) = {
            let nodes = client.get_cluster_nodes().await?;
            let endpoint = nodes
                .into_iter()
                .find(|node| node.pubkey == leader)
                .and_then(|node| node.gossip.or(node.tpu).or(node.rpc).or(node.tvu));

            match endpoint {
                Some(addr) => {
                    let ip = addr.ip();
                    if ip.is_loopback() || ip.is_unspecified() {
                        // Likely won't ever happen, but just in case.
                        fallback.clone()
                    } else {
                        let ip_s = ip.to_string();
                        match leader_geo_by_ip().get(&ip_s) {
                            Some(info) => (info.geo.clone(), info.closest_region),
                            None => {
                                let region = region_for_unknown_ip(&ip_s);
                                UNKNOWN_IP_MISS_COUNT.fetch_add(1, Ordering::Relaxed);
                                (UNKNOWN_GEO.to_string(), region)
                            }
                        }
                    }
                }
                None => fallback.clone(),
            }
        };
        warn_unknown_ip_threshold_if_needed();

        Ok(Output {
            slot,
            leader,
            leader_geo,
            closest_region,
        })
    }

    const LOG_MAX_LEVEL: log::LevelFilter = log::LevelFilter::Debug;
}

zela_custom_procedure!(Geo);

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

// Assuming we have similar (by computing power/throughput) nodes in all regions, we aim
// to balance the load between them by applying this randomish-yet-deterministic choice.
// The logic can (and should) be changed depending on e.g. cost/capacity, or statistical
// monitoring of nodes' performance.
fn region_for_unknown_ip(ip: &str) -> Region {
    match fnv1a64(ip.as_bytes()) % 4 {
        0 => Region::Frankfurt,
        1 => Region::Dubai,
        2 => Region::NewYork,
        _ => Region::Tokyo,
    }
}

// Just a nice (annoying!) way to inform operator that it's been a long time since the last leader IPs dump!
fn warn_unknown_ip_threshold_if_needed() {
    let count = UNKNOWN_IP_MISS_COUNT.load(Ordering::Relaxed);
    if count > UNKNOWN_IP_WARN_THRESHOLD {
        log::warn!("Unknown-IP fallbacks so far: {count} (threshold: {UNKNOWN_IP_WARN_THRESHOLD})");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leader_geo_map_parsing_logic_works() {
        let map = leader_geo_by_ip();
        assert!(!map.is_empty());
        assert!(map.keys().all(|ip| !ip.trim().is_empty()));
        assert!(map.values().all(|v| !v.geo.trim().is_empty()));
    }
}
