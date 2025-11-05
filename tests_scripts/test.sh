#!/bin/bash

set -e

INTEREST_CACHE=${1:-disabled}
LOG_LEVEL=${2:-info,alexgg=debug,parachain=debug}
OUTPUT=${3:-output}
RESULTS_FILE=${4:-""}
OUTPUT_DIR=${5:-"."}
TRIE_CACHE=${6:-enabled}  # "enabled" or "disabled"

TEST_DIR=test1
TSTAMP=$(date +%Y%m%d_%H%M%S)

# launch network
./network_start.sh  $TEST_DIR

sleep 2
COLLATOR_LOG=${TEST_DIR}/collator.log
TOP_OUTPUT="${OUTPUT_DIR}/top_${OUTPUT}.log"
# launch collator
INTEREST_CACHE=$INTEREST_CACHE ./node_launch.sh $TEST_DIR collator $LOG_LEVEL $TOP_OUTPUT $TRIE_CACHE

# give some time for collator to sync
sleep 60

# Only wait for cache warmup if trie cache is enabled
if [ "$TRIE_CACHE" == "enabled" ]; then
    ./warmup_cache_wait.sh
fi

# submit_transactions

# Record timestamps for filtering logs (more reliable than writing markers to active log files)
TX_START_TIME=$(date +%s)
TX_START_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "TX_START: $TX_START_TIMESTAMP (epoch: $TX_START_TIME)"

RUST_LOG=info,zombienet_orchestrator=debug \
ZOMBIE_PROVIDER=native \
# cargo test --release -p polkadot-zombienet-sdk-tests --features zombie-metadata,zombie-ci txs_per_block_test_2 -- --no-capture
cargo test --release -p polkadot-zombienet-sdk-tests --features zombie-metadata,zombie-ci weights_test_2 -- --no-capture
# cargo nextest run --release -p polkadot-zombienet-sdk-tests --features zombie-metadata,zombie-ci --no-capture txs_per_block_test_2

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

# Use Python script for metric analysis (replaces complex AWK logic)
# This script parses logs, calculates metrics, and outputs both summary and CSV data
echo "Running metric analysis..."

# Get the directory where test.sh is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run Python analysis - it will output summary and optionally append to CSV
CSV_ARGS=""
if [ -n "$RESULTS_FILE" ]; then
    CSV_ARGS="--csv-file $RESULTS_FILE --trie-cache $TRIE_CACHE --interest-cache $INTEREST_CACHE --log-level $LOG_LEVEL"
fi

python3 "${SCRIPT_DIR}/analyze_metrics.py" \
    --collator-log "$COLLATOR_LOG" \
    --top-log "$TOP_OUTPUT" \
    --start-time "$TX_START_TIMESTAMP" \
    --end-time "$TX_END_TIMESTAMP" \
    --output "$SUMMARY_OUTPUT" \
    $CSV_ARGS

echo ""
echo "========================================"
echo "Full logs available:"
echo "  TOP: $TOP_OUTPUT"
echo "  Collator: $COLLATOR_LOG"
echo "  Summary: $SUMMARY_OUTPUT"
echo "  Timestamps: $TIMESTAMP_FILE"
if [ -n "$RESULTS_FILE" ]; then
    echo "  Results CSV: $RESULTS_FILE"
fi
echo "========================================"
