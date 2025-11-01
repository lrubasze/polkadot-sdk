# Interest Cache Optimization Guide

This guide explains how to determine the optimal interest cache configuration for `tracing-log`.

## Understanding Cache Effectiveness

The interest cache works best when:
- ✅ Many log statements are **disabled** (e.g., debug/trace in production)
- ✅ Same targets are logged repeatedly
- ✅ High-frequency logging from few modules

The cache provides little benefit when:
- ❌ Most logs are **enabled** (cache checks still happen)
- ❌ Many unique targets (causes cache eviction)
- ❌ Low-frequency logging

## Method 1: Criterion Benchmarks (Recommended)

### Setup

1. Enable the interest-cache feature:
```toml
# In substrate/client/tracing/Cargo.toml
[dependencies]
tracing-log = { workspace = true, features = ["interest-cache"] }
```

2. Run the benchmarks:
```bash
cd substrate/client/tracing
cargo bench --bench interest_cache_bench --features interest-cache
```

### Interpreting Results

Look for the configuration with the **lowest time**:

```
interest_cache_realistic/cache_size/0     time: [245.32 µs ...]  # No cache
interest_cache_realistic/cache_size/128   time: [198.45 µs ...]  # 19% faster
interest_cache_realistic/cache_size/1024  time: [187.23 µs ...]  # 24% faster ✓ Best
interest_cache_realistic/cache_size/2048  time: [188.91 µs ...]  # Similar, more memory
```

**Key metrics:**
- **20-30% improvement**: Cache is working well
- **<10% improvement**: Cache not helping much (most logs enabled?)
- **Diminishing returns**: If 1024 and 2048 are similar, use 1024

### Compare Configurations

```bash
# Install critcmp for easy comparison
cargo install critcmp

# Run benchmarks with different baselines
cargo bench --bench interest_cache_bench -- --save-baseline nocache
# (modify config to use cache)
cargo bench --bench interest_cache_bench -- --save-baseline withcache

# Compare
critcmp nocache withcache
```

## Method 2: CPU Profiling (Real-World Performance)

### Using `perf` (Linux)

```bash
# Build with debug symbols
CARGO_PROFILE_RELEASE_DEBUG=true cargo build --release -p polkadot

# Profile without cache
perf record -g -F 999 ./target/release/polkadot --dev --tmp &
POLKADOT_PID=$!
sleep 60
kill $POLKADOT_PID

perf report > profile_nocache.txt

# Profile with cache (modify code first)
perf record -g -F 999 ./target/release/polkadot --dev --tmp &
POLKADOT_PID=$!
sleep 60
kill $POLKADOT_PID

perf report > profile_withcache.txt
```

### What to Look For

Search the perf report for:
- `tracing_log::LogTracer::log` - time spent in logging
- `tracing_core::Dispatch::enabled` - time spent checking filters
- Lock contention symbols

**Good signs:**
- Time in `enabled()` decreases by 20-50%
- Overall CPU usage drops by 5-15%

### Using `flamegraph`

```bash
cargo install flamegraph

# Without cache
cargo flamegraph --root -p polkadot -- --dev --tmp
# Save as flamegraph_nocache.svg

# With cache (after modifying code)
cargo flamegraph --root -p polkadot -- --dev --tmp
# Save as flamegraph_withcache.svg

# Compare the width of tracing-related functions
```

## Method 3: Instrumented Testing

Add temporary instrumentation to measure cache effectiveness:

```rust
use std::sync::atomic::{AtomicUsize, Ordering};

static FILTER_CALLS: AtomicUsize = AtomicUsize::new(0);
static CACHE_HITS: AtomicUsize = AtomicUsize::new(0);

// Before testing
FILTER_CALLS.store(0, Ordering::SeqCst);
CACHE_HITS.store(0, Ordering::SeqCst);

// Run your workload
run_test_workload();

// After testing
let total = FILTER_CALLS.load(Ordering::SeqCst);
let hits = CACHE_HITS.load(Ordering::SeqCst);
let hit_rate = (hits as f64 / total as f64) * 100.0;

println!("Cache hit rate: {:.2}%", hit_rate);
```

**Optimal hit rates:**
- 90-99%: Excellent cache performance
- 70-89%: Good cache performance
- 50-69%: Marginal benefit
- <50%: Cache too small or too much diversity

## Method 4: Memory Profiling

Check memory overhead of different cache sizes:

```bash
# Install heaptrack
sudo apt-get install heaptrack

# Profile memory usage
heaptrack ./target/release/polkadot --dev --tmp
# Let it run for a while, then Ctrl+C

# Analyze
heaptrack_gui heaptrack.polkadot.*.gz
```

**Per-thread memory usage:**
- 128 entries: ~1 KB per thread
- 1024 entries: ~8 KB per thread
- 2048 entries: ~16 KB per thread
- 4096 entries: ~32 KB per thread

With 100 threads:
- 1024 cache: ~800 KB total (negligible)
- 4096 cache: ~3.2 MB total (still small)

## Method 5: A/B Testing in Production

Deploy with different configurations and compare metrics:

### Metrics to Track

1. **CPU Usage**: Lower is better
   - Monitor: `process_cpu_seconds_total` (Prometheus)

2. **Block Processing Time**: Should stay same or improve
   - Monitor: `substrate_block_processing_time`

3. **Memory Usage**: Should increase slightly
   - Monitor: `process_resident_memory_bytes`

### Configuration Matrix

| Config | Cache Size | Min Verbosity | Use Case |
|--------|------------|---------------|----------|
| A      | 0          | Debug         | Baseline (no cache) |
| B      | 512        | Debug         | Conservative |
| C      | 1024       | Debug         | Recommended default |
| D      | 2048       | Trace         | High diversity/verbosity |
| E      | 4096       | Debug         | Maximum performance |

Run each for 24 hours, compare metrics.

## Recommended Starting Point

For Polkadot SDK:

```rust
use tracing_log::InterestCacheConfig;
use log::Level;

// Start with this configuration
let config = InterestCacheConfig::default()
    .with_lru_cache_size(1024)      // Good balance
    .with_min_verbosity(Level::Debug); // Cache debug & trace

LogTracer::builder()
    .with_max_level(max_level)
    .with_interest_cache(config)
    .init()?;
```

**Then tune based on:**
- If profiling shows <70% hit rate → increase to 2048
- If many unique targets (50+) → increase to 2048-4096
- If memory constrained → decrease to 512
- If CPU shows no improvement → check if logs are mostly enabled

## Decision Tree

```
Start with 1024 cache size
         ↓
Run benchmarks
         ↓
    ┌────┴────┐
    │ >20%    │ <10%
    │ faster  │ faster
    ↓         ↓
Good!    Are most logs
         enabled? (INFO level)
              ↓
         Yes → Cache won't help much
         No → Try larger cache (2048)
              or check target diversity
```

## Quick Validation Test

Run this to quickly test if cache helps:

```bash
# Without cache
time cargo test --package sc-tracing \
    parallel_logs_from_multiple_threads_are_properly_gathered \
    --release -- --nocapture

# With cache (after enabling)
time cargo test --package sc-tracing \
    parallel_logs_from_multiple_threads_are_properly_gathered \
    --release -- --nocapture

# Compare execution times
```

If cache version is 15-30% faster, it's working well!
