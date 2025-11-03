#!/bin/bash
# Monitor node performance metrics for interest-cache evaluation

NODE_PID=$1
DURATION=${2:-60}  # seconds
PROMETHEUS_PORT=${3:-9615}

if [ -z "$NODE_PID" ]; then
    echo "Usage: $0 <node_pid> [duration_seconds] [prometheus_port]"
    echo "Example: $0 12345 60 9615"
    exit 1
fi

echo "Monitoring node (PID: $NODE_PID) for ${DURATION} seconds..."
echo "Prometheus endpoint: http://localhost:${PROMETHEUS_PORT}/metrics"
echo ""

# Create output file
OUTPUT="node_metrics_$(date +%Y%m%d_%H%M%S).log"

echo "=== Node Performance Metrics ===" | tee -a $OUTPUT
echo "Started at: $(date)" | tee -a $OUTPUT
echo "" | tee -a $OUTPUT

# Function to get CPU usage
get_cpu_usage() {
    ps -p $NODE_PID -o %cpu --no-headers 2>/dev/null || echo "0"
}

# Function to get memory usage
get_memory_usage() {
    ps -p $NODE_PID -o rss --no-headers 2>/dev/null || echo "0"
}

# Function to get Prometheus metric
get_prometheus_metric() {
    local metric=$1
    curl -s http://localhost:${PROMETHEUS_PORT}/metrics 2>/dev/null | \
        grep "^${metric}" | head -1 | awk '{print $2}'
}

# Collect initial metrics
echo "Initial Metrics:" | tee -a $OUTPUT
echo "---------------" | tee -a $OUTPUT

INITIAL_CPU=$(get_prometheus_metric "process_cpu_seconds_total")
INITIAL_TIME=$(date +%s)

echo "CPU seconds: $INITIAL_CPU" | tee -a $OUTPUT
echo "Memory (RSS): $(get_memory_usage) KB" | tee -a $OUTPUT
echo "Block height: $(get_prometheus_metric "substrate_block_height{status=\"best\"}")" | tee -a $OUTPUT
echo "" | tee -a $OUTPUT

# Monitor over time
echo "Sampling every 5 seconds..." | tee -a $OUTPUT
echo "" | tee -a $OUTPUT

SAMPLES=$((DURATION / 5))
for i in $(seq 1 $SAMPLES); do
    CPU=$(get_cpu_usage)
    MEM=$(get_memory_usage)
    BLOCK=$(get_prometheus_metric "substrate_block_height{status=\"best\"}")

    echo "[$i/$SAMPLES] CPU: ${CPU}% | MEM: ${MEM} KB | Block: ${BLOCK}" | tee -a $OUTPUT

    sleep 5
done

# Collect final metrics
echo "" | tee -a $OUTPUT
echo "Final Metrics:" | tee -a $OUTPUT
echo "-------------" | tee -a $OUTPUT

FINAL_CPU=$(get_prometheus_metric "process_cpu_seconds_total")
FINAL_TIME=$(date +%s)
FINAL_BLOCK=$(get_prometheus_metric "substrate_block_height{status=\"best\"}")

echo "CPU seconds: $FINAL_CPU" | tee -a $OUTPUT
echo "Memory (RSS): $(get_memory_usage) KB" | tee -a $OUTPUT
echo "Block height: $FINAL_BLOCK" | tee -a $OUTPUT
echo "" | tee -a $OUTPUT

# Calculate averages
ELAPSED=$((FINAL_TIME - INITIAL_TIME))
CPU_USED=$(echo "$FINAL_CPU - $INITIAL_CPU" | bc 2>/dev/null || echo "N/A")
AVG_CPU=$(echo "scale=2; ($CPU_USED / $ELAPSED) * 100" | bc 2>/dev/null || echo "N/A")

echo "Summary:" | tee -a $OUTPUT
echo "--------" | tee -a $OUTPUT
echo "Elapsed time: ${ELAPSED}s" | tee -a $OUTPUT
echo "CPU used: ${CPU_USED}s" | tee -a $OUTPUT
echo "Average CPU: ${AVG_CPU}%" | tee -a $OUTPUT
echo "" | tee -a $OUTPUT

# Key metrics from Prometheus
echo "Key Prometheus Metrics:" | tee -a $OUTPUT
echo "----------------------" | tee -a $OUTPUT

echo "Block processing time: $(get_prometheus_metric "substrate_block_processing_time_sum")" | tee -a $OUTPUT
echo "Transaction pool size: $(get_prometheus_metric "substrate_sub_txpool_validations_scheduled")" | tee -a $OUTPUT
echo "Peer count: $(get_prometheus_metric "substrate_sub_libp2p_peers_count")" | tee -a $OUTPUT
echo "" | tee -a $OUTPUT

echo "Completed at: $(date)" | tee -a $OUTPUT
echo "Results saved to: $OUTPUT"
