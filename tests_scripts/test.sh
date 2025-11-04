#!/bin/bash

set -e

INTEREST_CACHE=${1:-disabled}
LOG_LEVEL=${2:-info,alexgg=debug,parachain=debug}
OUTPUT=${3:-output}
RESULTS_FILE=${4:-""}
OUTPUT_DIR=${5:-"."}

TEST_DIR=test1
TSTAMP=$(date +%Y%m%d_%H%M%S)

# launch network
./network_start.sh  $TEST_DIR

sleep 2
COLLATOR_LOG=${TEST_DIR}/collator.log
TOP_OUTPUT="${OUTPUT_DIR}/top_${OUTPUT}.log"
# launch collator
INTEREST_CACHE=$INTEREST_CACHE ./node_launch.sh $TEST_DIR collator $LOG_LEVEL $TOP_OUTPUT

# give some time for collator to sync
sleep 60

# submit_transactions

# Record timestamps for filtering logs (more reliable than writing markers to active log files)
TX_START_TIME=$(date +%s)
TX_START_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "TX_START: $TX_START_TIMESTAMP (epoch: $TX_START_TIME)"

RUST_LOG=info,zombienet_orchestrator=debug \
ZOMBIE_PROVIDER=native \
cargo nextest run --release -p polkadot-zombienet-sdk-tests --features zombie-metadata,zombie-ci --no-capture txs_per_block_test_2

TX_END_TIME=$(date +%s)
TX_END_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "TX_DONE: $TX_END_TIMESTAMP (epoch: $TX_END_TIME)"

# Save timestamps to a marker file for later use
TIMESTAMP_FILE="${OUTPUT_DIR}/timestamps_${OUTPUT}.txt"
cat > "$TIMESTAMP_FILE" <<EOF
TX_START_TIME="$TX_START_TIME"
TX_START_TIMESTAMP="$TX_START_TIMESTAMP"
TX_END_TIME="$TX_END_TIME"
TX_END_TIMESTAMP="$TX_END_TIMESTAMP"
EOF
echo "Timestamps saved to: $TIMESTAMP_FILE"

pkill -9 polkadot polkadot-parachain top

COLLATOR_LOG="${OUTPUT_DIR}/collator_${OUTPUT}.log"

cp $TEST_DIR/collator.log  $COLLATOR_LOG

# Create summary output file
SUMMARY_OUTPUT="${OUTPUT_DIR}/summary_${OUTPUT}.log"

# Load timestamps
source "$TIMESTAMP_FILE"

# process COLLATOR_LOG and TOP_OUTPUT
{
echo ""
echo "========================================"
echo "  Performance Analysis Results"
echo "  Time Range: $TX_START_TIMESTAMP to $TX_END_TIMESTAMP"
echo "========================================"
echo ""

# Process CPU metrics from TOP_OUTPUT
echo "--- CPU Usage Analysis ---"
echo "Filtering by timestamp range: $TX_START_TIMESTAMP to $TX_END_TIMESTAMP"

# TOP output format: YYYY-MM-DD HH:MM:SS PID CPU MEM
# After timestamp filtering, CPU is in column 4
CPU_ANALYSIS=$(awk -v start_ts="$TX_START_TIMESTAMP" -v end_ts="$TX_END_TIMESTAMP" '
{
    # Extract timestamp from first two columns (YYYY-MM-DD HH:MM:SS)
    if (NF >= 5 && match($1, /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/)) {
        log_ts = $1 " " $2
        if (log_ts >= start_ts && log_ts <= end_ts) {
            cpu = $4
            if (cpu ~ /^[0-9]+\.?[0-9]*$/) {
                sum += cpu
                count++
                if (cpu > max || max == "") max = cpu
                if (cpu < min || min == "") min = cpu
            }
        }
    }
}
END {
    if (count > 0) {
        printf "Samples: %d\n", count
        printf "Avg CPU: %.2f%%\n", sum/count
        printf "Min CPU: %.2f%%\n", min
        printf "Max CPU: %.2f%%\n", max
    } else {
        print "No CPU data found in time range"
    }
}' $TOP_OUTPUT)

echo "$CPU_ANALYSIS"

# Extract CPU values for CSV (remove % sign)
CPU_MIN=$(echo "$CPU_ANALYSIS" | grep "Min CPU:" | awk '{print $3}' | tr -d '%')
CPU_MAX=$(echo "$CPU_ANALYSIS" | grep "Max CPU:" | awk '{print $3}' | tr -d '%')
CPU_AVG=$(echo "$CPU_ANALYSIS" | grep "Avg CPU:" | awk '{print $3}' | tr -d '%')

echo ""
echo "--- Block Preparation Metrics ---"
echo "Filtering by timestamp range: $TX_START_TIMESTAMP to $TX_END_TIMESTAMP"

# Extract block metrics using timestamp filtering
BLOCK_ANALYSIS=$(awk -v start_ts="$TX_START_TIMESTAMP" -v end_ts="$TX_END_TIMESTAMP" '
{
    # Extract timestamp from log line (format: YYYY-MM-DD HH:MM:SS)
    if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        log_ts = substr($0, RSTART, RLENGTH)
        if (log_ts >= start_ts && log_ts <= end_ts) {
            print $0
        }
    }
}' $COLLATOR_LOG | \
grep "Prepared block for propo" | \
sed -E 's/.*at ([0-9]+) \(([0-9]+) ms\).*extrinsics_count: ([0-9]+).*/\1 \2 \3/' | \
awk '{
    sum_duration += $2
    sum_extrinsics += $3
    min_duration = (min_duration == "" || $2 < min_duration) ? $2 : min_duration
    max_duration = (max_duration == "" || $2 > max_duration) ? $2 : max_duration
    count++
    blocks[count] = $1 "," $2 "," $3
}
END {
    if (count > 0) {
        print "Block,Duration(ms),Extrinsics"
        for (i=1; i<=count; i++) print blocks[i]
        print ""
        printf "Total blocks: %d\n", count
        printf "Avg duration: %.2f ms\n", sum_duration/count
        printf "Min duration: %d ms\n", min_duration
        printf "Max duration: %d ms\n", max_duration
        printf "Avg extrinsics: %.2f\n", sum_extrinsics/count
    } else {
        print "No block preparation data found"
    }
}')

echo "$BLOCK_ANALYSIS"

# Extract block proposal values for CSV (remove "ms" suffix)
PROPOSAL_MIN=$(echo "$BLOCK_ANALYSIS" | grep "Min duration:" | awk '{print $3}')
PROPOSAL_MAX=$(echo "$BLOCK_ANALYSIS" | grep "Max duration:" | awk '{print $3}')
PROPOSAL_AVG=$(echo "$BLOCK_ANALYSIS" | grep "Avg duration:" | awk '{print $3}')

echo ""
echo "========================================"
echo "Full logs available:"
echo "  TOP: $TOP_OUTPUT"
echo "  Collator: $COLLATOR_LOG"
echo "  Summary: $SUMMARY_OUTPUT"
echo "  Timestamps: $TIMESTAMP_FILE"
echo "========================================"
} | tee "$SUMMARY_OUTPUT"

# Append results to global CSV file if specified
if [ -n "$RESULTS_FILE" ]; then
    # Format: interest_cache,log_level,proposal_min_ms,proposal_max_ms,proposal_avg_ms,cpu_min_pct,cpu_max_pct,cpu_avg_pct
    echo "$INTEREST_CACHE,$LOG_LEVEL,$PROPOSAL_MIN,$PROPOSAL_MAX,$PROPOSAL_AVG,$CPU_MIN,$CPU_MAX,$CPU_AVG" >> "$RESULTS_FILE"
    echo "Results appended to: $RESULTS_FILE"
fi
