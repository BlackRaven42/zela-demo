use std::{collections::HashMap, sync::OnceLock};

use serde::{Deserialize, Serialize};
use zela_std::{CustomProcedure, RpcError, rpc_client::RpcClient, zela_custom_procedure};

pub struct Geo;

#[derive(Deserialize, Debug)]
pub struct Input {}

#[derive(Serialize, Deserialize, Clone, Copy)]
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

const UNKNOWN_GEO: &str = "UNKNOWN";
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
    LEADER_GEO_BY_IP.get_or_init(|| serde_json::from_str::<HashMap<String, IpGeoInfo>>(LEADER_GEO_MAP_RAW).unwrap())
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
                        fallback.clone()
                    } else {
                        let ip_s = ip.to_string();
                        match leader_geo_by_ip().get(&ip_s) {
                            Some(info) => (info.geo.clone(), info.closest_region),
                            None => fallback.clone(),
                        }
                    }
                }
                None => fallback.clone(),
            }
        };

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
