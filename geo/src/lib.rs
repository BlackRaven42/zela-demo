use serde::{Deserialize, Serialize};
use zela_std::{CustomProcedure, RpcError, rpc_client::RpcClient, zela_custom_procedure};

pub struct Geo;

#[derive(Deserialize, Debug)]
pub struct Input {}

#[derive(Serialize)]
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
            .find_map(|(identity, slots)| slots.into_iter().any(|s| s == slot_index).then_some(identity))
            .ok_or_else(|| RpcError {
                code: 500,
                message: format!("leader not found in schedule for slot {slot} (slot_index={slot_index})"),
                data: None,
            })?;

        let leader_geo = {
            let nodes = client.get_cluster_nodes().await?;
            let endpoint = nodes
                .into_iter()
                .find(|node| node.pubkey == leader)
                .and_then(|node| node.gossip.or(node.tpu).or(node.rpc).or(node.tvu));

            match endpoint {
                Some(addr) => {
                    let ip = addr.ip();
                    if ip.is_loopback() || ip.is_unspecified() {
                        "UNKNOWN".to_string()
                    } else {
                        format!("near endpoint IP {ip} (coarse)")
                    }
                }
                None => "UNKNOWN".to_string(),
            }
        };

        let closest_region = Region::Frankfurt;

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
