use serde::{Deserialize, Serialize};
use zela_std::{CustomProcedure, RpcError, rpc_client::RpcClient, zela_custom_procedure};

pub struct Geo;

#[derive(Deserialize, Debug)]
pub struct Input {
    first_number: i32,
    second_number: i32,
}

#[derive(Serialize)]
pub struct Output {
    pub slot: u64,
}

impl CustomProcedure for Geo {
    type Params = Input;
    type ErrorData = ();
    type SuccessData = Output;

    async fn run(params: Self::Params) -> Result<Self::SuccessData, RpcError<Self::ErrorData>> {
        log::debug!("params: {params:?}");

        let client = RpcClient::new();
        let slot = client.get_slot().await?;

        Ok(Output {
            slot,
        })
    }

    const LOG_MAX_LEVEL: log::LevelFilter = log::LevelFilter::Debug;
}

zela_custom_procedure!(Geo);
