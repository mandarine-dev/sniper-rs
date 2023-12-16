use std::sync::Arc;

use ethers::abi::{Abi, Address};
use ethers::prelude::*;
use ethers::providers::{Middleware, Provider, Ws};
use eyre::Result;

#[tokio::main]
async fn main() -> Result<()> {
    let provider = Provider::<Ws>::connect("ws://135.181.50.148:9650/ext/bc/C/ws").await?;
    let provider2 = Arc::new(provider.clone());

    let contract_abi = include_str!("../abi/erc20.json");
    let contract_abi: Abi = serde_json::from_str(contract_abi)?; // Parsez l'ABI
    let contract_address = "0xA5FF6a6467CF02301780E7Aad381dA92604F5946".parse::<Address>()?;

    // Créez une instance du contrat
    let contract = Contract::new(contract_address, contract_abi, provider2);

    let symbol: String = contract.method("symbol", ())?.call().await?;

    let mut stream = provider.subscribe_blocks().await?;

    while let Some(block) = stream.next().await {
        println!(
            "Scanning {} (block: {})",
            symbol,
            block.number.unwrap_or_default()
        );
    }

    Ok(())
}
