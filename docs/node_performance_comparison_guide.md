# Node Performance Comparison Guide

Guide for comparing node performance with and without interest-cache enabled.

## Quick Start

### 1. Baseline Test (Without interest-cache)

```bash
# Build without interest-cache
git checkout <commit-before-interest-cache>
cargo build --release -p polkadot

# Run node
./target/release/polkadot --dev --tmp --prometheus-port 9615 &
NODE_PID=$!

# Monitor for 5 minutes
./scripts/monitor_node_performance.sh $NODE_PID 300 9615

# Stop node
kill $NODE_PID
```

Save results as `baseline_metrics.log`

### 2. Test With interest-cache

```bash
# Build with interest-cache
git checkout <commit-with-interest-cache>
cargo build --release -p polkadot

# Run node
./target/release/polkadot --dev --tmp --prometheus-port 9615 &
NODE_PID=$!

# Monitor for 5 minutes
./scripts/monitor_node_performance.sh $NODE_PID 300 9615

# Stop node
kill $NODE_PID
```

Save results as `with_cache_metrics.log`

## Key Metrics to Compare

### 🔴 Critical Metrics (Must Not Regress)

| Metric | Baseline | With Cache | Status | Notes |
|--------|----------|------------|--------|-------|
| Block processing time | X ms | Y ms | ✅/❌ | Should stay same or improve |
| Finality lag | X blocks | Y blocks | ✅/❌ | Should not increase |
| Transaction throughput | X tx/s | Y tx/s | ✅/❌ | Should maintain |

### 🟡 Performance Metrics (Expected to Improve)

| Metric | Baseline | With Cache | Improvement | Notes |
|--------|----------|------------|-------------|-------|
| Average CPU % | X % | Y % | Z % | Target: 5-15% reduction |
| CPU seconds/minute | X s | Y s | Z s | Lower is better |
| Stderr write time | X ms | Y ms | Z ms | Should decrease |

### 🟢 Resource Metrics (Expected Small Increase)

| Metric | Baseline | With Cache | Change | Notes |
|--------|----------|------------|--------|-------|
| Memory (RSS) | X MB | Y MB | +Z MB | Expected: <10 MB |
| Thread count | X | Y | +Z | Should stay same |

## Detailed Monitoring Scenarios

### Scenario 1: Idle Node

**Purpose:** Measure baseline overhead

```bash
./target/release/polkadot --dev --tmp &
NODE_PID=$!
sleep 60  # Let it settle
./scripts/monitor_node_performance.sh $NODE_PID 300
```

**Expected improvement:** Minimal (5-10% CPU reduction)

### Scenario 2: Block Production

**Purpose:** Measure under normal load

```bash
./target/release/polkadot --dev --tmp &
NODE_PID=$!
./scripts/monitor_node_performance.sh $NODE_PID 300
```

**Expected improvement:** Moderate (10-20% CPU reduction)

### Scenario 3: Transaction Spam

**Purpose:** Measure under heavy logging

```bash
# Terminal 1: Start node
./target/release/polkadot --dev --tmp &
NODE_PID=$!

# Terminal 2: Send transactions
for i in {1..1000}; do
    # Submit transactions via RPC
    curl -H "Content-Type: application/json" \
         -d '{"id":1, "jsonrpc":"2.0", "method": "author_submitExtrinsic", "params":[...]}' \
         http://localhost:9944/
done

# Terminal 3: Monitor
./scripts/monitor_node_performance.sh $NODE_PID 300
```

**Expected improvement:** Significant (15-30% CPU reduction)

### Scenario 4: Syncing (Most Realistic)

**Purpose:** Measure during chain sync

```bash
# Start from scratch, sync 1000 blocks
rm -rf /tmp/polkadot-dev
./target/release/polkadot \
    --chain rococo-dev \
    --base-path /tmp/polkadot-dev \
    --prometheus-port 9615 &
NODE_PID=$!

./scripts/monitor_node_performance.sh $NODE_PID 600  # 10 minutes
```

**Expected improvement:** Significant (20-30% CPU reduction during heavy sync)

## Using Prometheus Queries

### Connect to Prometheus

```bash
# If running locally
http://localhost:9615/metrics

# Example queries
```

### Key Queries

#### CPU Usage Rate
```promql
# CPU usage percentage over 5 minutes
rate(process_cpu_seconds_total[5m]) * 100
```

#### Block Processing Performance
```promql
# Average block processing time (ms)
rate(substrate_block_processing_time_sum[5m]) /
rate(substrate_block_processing_time_count[5m]) * 1000
```

#### Memory Growth
```promql
# Memory usage in MB
process_resident_memory_bytes / 1024 / 1024
```

#### Transaction Pool Efficiency
```promql
# Validation rate
rate(substrate_sub_txpool_validations_finished[5m])
```

## Using Grafana Dashboard

### Import Dashboard

1. Open Grafana (usually http://localhost:3000)
2. Import dashboard: https://grafana.com/grafana/dashboards/13840
3. Select Prometheus datasource

### Key Panels to Watch

- **CPU Usage**: Should show reduction
- **Block Processing Time**: Should stay stable or improve
- **Memory Usage**: Should show slight increase (<10MB)
- **Network I/O**: Should stay stable

## Manual Comparison

### Compare CPU Usage

```bash
# From monitoring logs
grep "Average CPU" baseline_metrics.log
# Output: Average CPU: 45.23%

grep "Average CPU" with_cache_metrics.log
# Output: Average CPU: 38.15%

# Calculate improvement
echo "scale=2; (45.23 - 38.15) / 45.23 * 100" | bc
# Output: 15.65% improvement ✅
```

### Compare Memory

```bash
# Get memory values
BASELINE_MEM=$(grep "Final.*Memory" baseline_metrics.log | awk '{print $3}')
CACHE_MEM=$(grep "Final.*Memory" with_cache_metrics.log | awk '{print $3}')

# Calculate increase
echo "scale=2; ($CACHE_MEM - $BASELINE_MEM) / 1024" | bc
# Output: 0.85 MB increase ✅ (acceptable)
```

### Compare Block Processing

```bash
# From Prometheus
curl -s http://localhost:9615/metrics | \
    grep substrate_block_processing_time_sum

# Compare the values over time
```

## Success Criteria

### ✅ Changes are Good if:

1. **CPU Usage**: Reduced by 10-30%
2. **Memory**: Increased by <10 MB
3. **Block Processing**: No regression (within 5%)
4. **Finality**: No increased lag
5. **Stability**: No crashes or panics

### ❌ Rollback if:

1. **Block Processing**: >10% slower
2. **Memory**: >50 MB increase
3. **Crashes**: Any new panics or crashes
4. **Consensus**: Finality lag increases
5. **No Improvement**: <5% CPU reduction (not worth complexity)

## Automated Comparison Script

```bash
#!/bin/bash
# compare_performance.sh

BASELINE_LOG=$1
CACHE_LOG=$2

if [ -z "$BASELINE_LOG" ] || [ -z "$CACHE_LOG" ]; then
    echo "Usage: $0 <baseline_log> <cache_log>"
    exit 1
fi

echo "Performance Comparison"
echo "====================="
echo ""

# Extract and compare CPU
BASELINE_CPU=$(grep "Average CPU" $BASELINE_LOG | awk '{print $3}' | tr -d '%')
CACHE_CPU=$(grep "Average CPU" $CACHE_LOG | awk '{print $3}' | tr -d '%')
CPU_IMPROVEMENT=$(echo "scale=2; ($BASELINE_CPU - $CACHE_CPU) / $BASELINE_CPU * 100" | bc)

echo "CPU Usage:"
echo "  Baseline: ${BASELINE_CPU}%"
echo "  With Cache: ${CACHE_CPU}%"
echo "  Improvement: ${CPU_IMPROVEMENT}%"
echo ""

# Extract and compare Memory
BASELINE_MEM=$(grep "Final.*Memory" $BASELINE_LOG | awk '{print $3}')
CACHE_MEM=$(grep "Final.*Memory" $CACHE_LOG | awk '{print $3}')
MEM_INCREASE=$(echo "scale=2; ($CACHE_MEM - $BASELINE_MEM) / 1024" | bc)

echo "Memory Usage:"
echo "  Baseline: ${BASELINE_MEM} KB"
echo "  With Cache: ${CACHE_MEM} KB"
echo "  Increase: ${MEM_INCREASE} MB"
echo ""

# Verdict
echo "Verdict:"
if (( $(echo "$CPU_IMPROVEMENT > 10" | bc -l) )) && \
   (( $(echo "$MEM_INCREASE < 10" | bc -l) )); then
    echo "  ✅ Performance improved significantly with acceptable memory increase"
elif (( $(echo "$CPU_IMPROVEMENT > 5" | bc -l) )) && \
     (( $(echo "$MEM_INCREASE < 20" | bc -l) )); then
    echo "  🟡 Moderate improvement, consider testing under heavier load"
else
    echo "  ❌ Insufficient improvement or too much memory overhead"
fi
```

## Production Deployment Checklist

Before deploying to production:

- [ ] Benchmark shows >10% CPU improvement
- [ ] Memory increase <10 MB per node
- [ ] No regression in block processing time
- [ ] Tested under heavy load (syncing, tx spam)
- [ ] Ran for 24+ hours without issues
- [ ] Peer connectivity remains stable
- [ ] Consensus participation normal
- [ ] Log output quality unchanged

## Troubleshooting

### High Memory Usage

If memory increases >10 MB:
- Check cache size configuration
- Monitor per-thread overhead
- Consider reducing `lru_cache_size`

### No Performance Improvement

If CPU usage doesn't improve:
- Check log level (must have debug/trace logs)
- Verify interest-cache is enabled
- Profile to see where CPU time is spent
- Increase cache size if hit rate is low

### Increased Block Time

If block processing slows down:
- Check for lock contention
- Profile with `perf` or `flamegraph`
- Consider disabling cache
- Report as bug

## Next Steps

After confirming improvement:

1. Document the optimal configuration
2. Update default settings if warranted
3. Submit PR with benchmarks
4. Monitor production deployment
5. Iterate on cache size if needed
