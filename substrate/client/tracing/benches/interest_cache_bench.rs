// This file is part of Substrate.
//
// Copyright (C) Parity Technologies (UK) Ltd.
// SPDX-License-Identifier: GPL-3.0-or-later WITH Classpath-exception-2.0

//! Benchmark to compare different interest cache configurations.

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use log::{Level, LevelFilter};
use std::sync::Once;

static INIT_LOGGER: Once = Once::new();

/// Initialize logger with specific interest cache configuration
fn init_logger_with_cache(cache_size: usize, min_verbosity: Level) {
	INIT_LOGGER.call_once(|| {
		#[cfg(all(feature = "interest-cache", feature = "std"))]
		{
			use tracing_log::InterestCacheConfig;
			let config = InterestCacheConfig::default()
				.with_lru_cache_size(cache_size)
				.with_min_verbosity(min_verbosity);

			tracing_log::LogTracer::builder()
				.with_max_level(LevelFilter::Info)
				.with_interest_cache(config)
				.init()
				.ok();
		}

		#[cfg(not(all(feature = "interest-cache", feature = "std")))]
		{
			tracing_log::LogTracer::builder()
				.with_max_level(LevelFilter::Info)
				.init()
				.ok();
		}

		// Initialize a basic tracing subscriber
		let subscriber = tracing_subscriber::fmt()
			.with_max_level(tracing::Level::INFO)
			.with_writer(std::io::sink)
			.finish();
		let _ = tracing::subscriber::set_global_default(subscriber);
	});
}

/// Simulates realistic logging patterns with many filtered-out logs
fn bench_realistic_logging(c: &mut Criterion) {
	let mut group = c.benchmark_group("interest_cache_realistic");

	// Test different cache sizes
	for cache_size in [0, 128, 512, 1024, 2048, 4096] {
		init_logger_with_cache(cache_size, Level::Debug);

		group.bench_with_input(
			BenchmarkId::new("cache_size", cache_size),
			&cache_size,
			|b, _| {
				b.iter(|| {
					// Simulate realistic Polkadot SDK logging pattern
					// Most debug/trace logs are disabled in production
					for i in 0..100 {
						log::trace!(target: "substrate", "trace message {}", i);
						log::debug!(target: "runtime", "debug message {}", i);
						log::debug!(target: "sync", "sync debug {}", i);
						log::trace!(target: "consensus", "consensus trace {}", i);
						log::debug!(target: "network", "network debug {}", i);

						// Occasional info logs that will be shown
						if i % 10 == 0 {
							log::info!(target: "substrate", "info message {}", i);
						}
					}
					black_box(());
				})
			},
		);
	}

	group.finish();
}

/// Benchmark with high target diversity (stress test for cache)
fn bench_diverse_targets(c: &mut Criterion) {
	let mut group = c.benchmark_group("interest_cache_diverse_targets");

	for cache_size in [128, 512, 1024, 2048] {
		init_logger_with_cache(cache_size, Level::Debug);

		group.bench_with_input(
			BenchmarkId::new("cache_size", cache_size),
			&cache_size,
			|b, _| {
				b.iter(|| {
					// Generate many unique targets to test cache eviction
					for i in 0..200 {
						let target = format!("module_{}", i % 50); // 50 unique targets
						log::debug!(target: &target, "message {}", i);
						log::trace!(target: &target, "trace {}", i);
					}
					black_box(());
				})
			},
		);
	}

	group.finish();
}

/// Benchmark multi-threaded logging (cache is per-thread)
fn bench_multithreaded_logging(c: &mut Criterion) {
	let mut group = c.benchmark_group("interest_cache_multithreaded");
	group.sample_size(10); // Fewer samples for slower multi-threaded test

	for cache_size in [0, 512, 1024, 2048] {
		init_logger_with_cache(cache_size, Level::Debug);

		group.bench_with_input(
			BenchmarkId::new("cache_size", cache_size),
			&cache_size,
			|b, _| {
				b.iter(|| {
					let handles: Vec<_> = (0..8)
						.map(|thread_id| {
							std::thread::spawn(move || {
								for i in 0..100 {
									log::debug!(target: "substrate", "thread {} msg {}", thread_id, i);
									log::trace!(target: "runtime", "thread {} trace {}", thread_id, i);
								}
							})
						})
						.collect();

					for handle in handles {
						handle.join().unwrap();
					}
					black_box(());
				})
			},
		);
	}

	group.finish();
}

/// Benchmark to show overhead of cache vs no cache
fn bench_cache_overhead(c: &mut Criterion) {
	let mut group = c.benchmark_group("interest_cache_overhead");

	// Scenario where cache doesn't help much (all logs enabled)
	init_logger_with_cache(1024, Level::Debug);

	group.bench_function("info_logs_always_enabled", |b| {
		b.iter(|| {
			for i in 0..1000 {
				log::info!(target: "substrate", "info {}", i);
			}
			black_box(());
		})
	});

	// Scenario where cache helps a lot (all logs disabled)
	group.bench_function("debug_logs_always_disabled", |b| {
		b.iter(|| {
			for i in 0..1000 {
				log::debug!(target: "substrate", "debug {}", i);
			}
			black_box(());
		})
	});

	group.finish();
}

criterion_group!(
	benches,
	bench_realistic_logging,
	bench_diverse_targets,
	bench_multithreaded_logging,
	bench_cache_overhead
);
criterion_main!(benches);
