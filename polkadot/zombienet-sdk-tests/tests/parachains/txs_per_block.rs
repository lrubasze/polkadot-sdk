// Copyright (C) Parity Technologies (UK) Ltd.
// SPDX-License-Identifier: Apache-2.0

#[zombienet_sdk::subxt::subxt(
	runtime_metadata_path = "metadata-files/asset-hub-westend-local.scale"
)]
mod ahw {}

use anyhow::anyhow;
use dashmap::DashMap;
use futures::{stream::FuturesUnordered, StreamExt};
use rand::Rng;
use sp_core::H256;
use std::{
	str::FromStr,
	sync::{
		atomic::{AtomicU64, Ordering},
		Arc,
	},
	time::Instant,
};
use zombienet_sdk::{
	subxt::{self, config::polkadot::PolkadotExtrinsicParamsBuilder, OnlineClient, PolkadotConfig},
	subxt_signer::{
		sr25519::{dev, Keypair},
		SecretUri,
	},
	LocalFileSystem, Network, NetworkConfigBuilder, NetworkNode,
};

const KEYS_COUNT: usize = 2000;
const CHUNK_SIZE: usize = 500;
const TXS_PER_BLOCK: usize = 1000; // Target number of transactions per block
const NUM_BLOCKS: u32 = 10; // Number of blocks to test
const TRANSFER_AMOUNT: u128 = 1000000; // Small amount for transfers

#[tokio::test(flavor = "multi_thread")]
async fn txs_per_block_test() -> Result<(), anyhow::Error> {
	let _ = env_logger::try_init_from_env(
		env_logger::Env::default().filter_or(env_logger::DEFAULT_FILTER_ENV, "info"),
	);

	let network = setup_network().await?;
	let collator = network.get_node("collator")?;
	let para_client: OnlineClient<PolkadotConfig> = collator.wait_client().await?;

	log::info!("Network is ready, waiting for warm-up to finish");
	let _ = wait_warmup_finish(&collator).await;

	log::info!("Warm-up finished, starting test setup");
	let alice = dev::alice();
	let keys = create_keys(KEYS_COUNT);

	// Setup accounts - fund them with enough balance
	setup_accounts(&para_client, &alice, &keys).await?;
	log::info!("Accounts ready with {} keys", KEYS_COUNT);

	// Initialize nonce tracker for all keys
	let nonce_tracker = Arc::new(DashMap::new());
	for (i, key) in keys.iter().enumerate() {
		let account_id = key.public_key().to_account_id();
		let nonce = para_client.tx().account_nonce(&account_id).await?;
		nonce_tracker.insert(i, AtomicU64::new(nonce));
	}

	// Wrap keys in Arc for sharing
	let keys = Arc::new(keys);

	log::info!(
		"Starting per-block test: {} transactions per block for {} blocks",
		TXS_PER_BLOCK,
		NUM_BLOCKS
	);
	let start_time = Instant::now();

	// Subscribe to finalized blocks to know when to submit next batch
	let mut blocks_sub = para_client.blocks().subscribe_finalized().await?;

	let mut total_txs_submitted = 0u64;
	let mut blocks_processed = 0u32;

	// Wait for first block
	let _initial_block = blocks_sub.next().await.transpose()?.expect("Block stream ended");

	while blocks_processed < NUM_BLOCKS {
		log::info!("Preparing batch {} for next block", blocks_processed + 1);

		// Create batch of transactions for this block
		let mut batch_txs = Vec::with_capacity(TXS_PER_BLOCK);

		for i in 0..TXS_PER_BLOCK {
			let sender_idx = i % KEYS_COUNT;
			let sender_key = &keys[sender_idx];

			// Get next recipient (round-robin)
			let recipient_idx = (sender_idx + 1) % KEYS_COUNT;
			let recipient_key = &keys[recipient_idx];
			let recipient_account = recipient_key.public_key().into();

			// Get and increment nonce
			let sender_nonce = if let Some(nonce_ref) = nonce_tracker.get(&sender_idx) {
				nonce_ref.fetch_add(1, Ordering::SeqCst)
			} else {
				0
			};

			// Create transfer transaction
			let call =
				ahw::tx().balances().transfer_keep_alive(recipient_account, TRANSFER_AMOUNT);
			let params = tx_params(sender_nonce);

			match para_client.tx().create_signed(&call, sender_key, params).await {
				Ok(tx) => batch_txs.push(tx),
				Err(e) => {
					log::warn!("Failed to create transaction: {:?}", e);
					continue;
				},
			}
		}

		let batch_size = batch_txs.len();
		log::info!("Submitting batch of {} transactions", batch_size);

		// Submit all transactions at once
		match submit_txs_fire_and_forget(batch_txs).await {
			Ok(count) => {
				total_txs_submitted += count;
				log::info!("Successfully submitted {} transactions", count);
			},
			Err(e) => {
				log::warn!("Failed to submit batch: {:?}", e);
			},
		}

		// Wait for next finalized block
		match blocks_sub.next().await {
			Some(Ok(block)) => {
				blocks_processed += 1;
				log::info!(
					"Block {} finalized: {:?}, total txs submitted so far: {}",
					blocks_processed,
					block.hash(),
					total_txs_submitted
				);
			},
			Some(Err(e)) => {
				log::error!("Error receiving block: {:?}", e);
				break;
			},
			None => {
				log::error!("Block stream ended unexpectedly");
				break;
			},
		}
	}

	let elapsed = start_time.elapsed();
	let avg_txs_per_block = if blocks_processed > 0 {
		total_txs_submitted as f64 / blocks_processed as f64
	} else {
		0.0
	};
	let tps = total_txs_submitted as f64 / elapsed.as_secs_f64();

	log::info!("=== Per-Block Test Results ===");
	log::info!("Duration: {:.2} seconds", elapsed.as_secs_f64());
	log::info!("Blocks processed: {}", blocks_processed);
	log::info!("Total transactions submitted: {}", total_txs_submitted);
	log::info!("Average transactions per block: {:.2}", avg_txs_per_block);
	log::info!("Average throughput: {:.2} TPS", tps);
	log::info!("Target transactions per block: {}", TXS_PER_BLOCK);
	log::info!("================================");

	Ok(())
}

async fn wait_warmup_finish(collator: &NetworkNode) -> Result<(), anyhow::Error> {
	while collator.reports("substrate_tasks_ended_total{kind=\"blocking\",reason=\"finished\",task_group=\"default\",task_name=\"warm-up-trie-cache\",chain=\"asset-hub-westend-local\"}").await? < 0.5 {
		std::thread::sleep(std::time::Duration::from_secs(10));
	}
	Ok(())
}

async fn setup_network() -> Result<Network<LocalFileSystem>, anyhow::Error> {
	let images = zombienet_sdk::environment::get_images_from_env();
	let config = NetworkConfigBuilder::new()
		.with_relaychain(|r| {
			r.with_chain("westend-local")
				.with_default_command("polkadot")
				.with_default_image(images.polkadot.as_str())
				.with_default_args(vec![("-lparachain=debug").into()])
				.with_validator(|node| node.with_name("validator-0"))
				.with_validator(|node| node.with_name("validator-1"))
		})
		.with_parachain(|p| {
			p.with_id(2000)
				.with_default_command("polkadot-parachain")
				.with_default_image(
					std::env::var("COL_IMAGE")
						.unwrap_or("docker.io/paritypr/colander:latest".to_string())
						.as_str(),
				)
				.with_chain("asset-hub-westend-local")
				.with_collator(|n| {
					n.with_name("collator").validator(true).with_args(vec![
						("--warm-up-trie-cache").into(),
						("-linfo").into(),
						("--pool-type=fork-aware").into(),
						("--trie-cache-size=32212254720").into(),
						("--rpc-max-subscriptions-per-connection=327680").into(),
						("--rpc-max-connections=102400".into()),
						("--pool-limit=819200").into(),
						("--pool-kbytes=2048000").into(),
					])
				})
		})
		.build()
		.map_err(|e| {
			let errs = e.into_iter().map(|e| e.to_string()).collect::<Vec<_>>().join(" ");
			anyhow!("config errs: {errs}")
		})?;
	let spawn_fn = zombienet_sdk::environment::get_spawn_fn();
	let network = spawn_fn(config).await?;

	Ok(network)
}

fn create_keys(n: usize) -> Vec<Keypair> {
	let mut rng = rand::thread_rng();
	let seed: u32 = rng.gen();
	(0..n)
		.map(|i| {
			let uri = SecretUri::from_str(&format!("//key{}_perblock{}", seed, i)).unwrap();
			Keypair::from_uri(&uri).unwrap()
		})
		.collect()
}

fn tx_params<T: subxt::Config>(
	nonce: u64,
) -> <subxt::config::DefaultExtrinsicParams<T> as subxt::config::ExtrinsicParams<T>>::Params {
	PolkadotExtrinsicParamsBuilder::<T>::new().nonce(nonce).build()
}

async fn setup_accounts(
	client: &OnlineClient<PolkadotConfig>,
	caller: &Keypair,
	keys: &[Keypair],
) -> Result<(), anyhow::Error> {
	let caller_account_id = caller.public_key().to_account_id();
	let mut caller_nonce = client.tx().account_nonce(&caller_account_id).await?;

	// Transfer initial balance to all accounts
	log::info!("Funding {} accounts...", keys.len());
	for chunk in keys.chunks(CHUNK_SIZE) {
		let mut transfers = Vec::new();
		for key in chunk.iter() {
			let key_account = key.public_key().into();
			// Fund with enough balance for many transactions
			let initial_balance = 1000000000000000u128; // 1000 units
			let call = ahw::tx().balances().transfer_keep_alive(key_account, initial_balance);
			let params = tx_params(caller_nonce);
			caller_nonce += 1;
			let tx = client.tx().create_signed(&call, caller, params).await?;
			transfers.push(tx);
		}
		submit_txs(transfers).await?;
	}

	log::info!("Account funding completed");
	Ok(())
}

async fn submit_txs(
	txs: Vec<subxt::tx::SubmittableTransaction<PolkadotConfig, OnlineClient<PolkadotConfig>>>,
) -> Result<std::collections::HashSet<H256>, anyhow::Error> {
	let futs = txs.iter().map(|tx| tx.submit_and_watch()).collect::<FuturesUnordered<_>>();
	let res = futs.collect::<Vec<_>>().await;
	let res: Result<Vec<_>, _> = res.into_iter().collect();
	let res = res.expect("All the transactions submitted successfully");
	let mut statuses = futures::stream::select_all(res);
	let mut finalized_blocks = std::collections::HashSet::new();
	while let Some(a) = statuses.next().await {
		match a {
			Ok(st) => match st {
				subxt::tx::TxStatus::Validated => log::trace!("VALIDATED"),
				subxt::tx::TxStatus::Broadcasted => log::trace!("BROADCASTED"),
				subxt::tx::TxStatus::NoLongerInBestBlock => log::warn!("NO LONGER IN BEST BLOCK"),
				subxt::tx::TxStatus::InBestBlock(_) => log::trace!("IN BEST BLOCK"),
				subxt::tx::TxStatus::InFinalizedBlock(block) => {
					log::trace!("IN FINALIZED BLOCK");
					finalized_blocks.insert(block.block_hash());
				},
				subxt::tx::TxStatus::Error { message } => log::warn!("ERROR: {message}"),
				subxt::tx::TxStatus::Invalid { message } => log::trace!("INVALID: {message}"),
				subxt::tx::TxStatus::Dropped { message } => log::trace!("DROPPED: {message}"),
			},
			Err(e) => {
				log::warn!("Error status {:?}", e);
			},
		}
	}
	Ok(finalized_blocks)
}

/// Submit transactions without waiting for finalization (fire and forget)
/// This is faster for throughput testing
async fn submit_txs_fire_and_forget(
	txs: Vec<subxt::tx::SubmittableTransaction<PolkadotConfig, OnlineClient<PolkadotConfig>>>,
) -> Result<u64, anyhow::Error> {
	let count = txs.len() as u64;
	let futs = txs.iter().map(|tx| tx.submit()).collect::<FuturesUnordered<_>>();
	let results = futs.collect::<Vec<_>>().await;

	let mut success_count = 0u64;
	for result in results {
		match result {
			Ok(_) => success_count += 1,
			Err(e) => log::debug!("Transaction submission failed: {:?}", e),
		}
	}

	log::debug!("Submitted batch: {}/{} successful", success_count, count);
	Ok(success_count)
}
