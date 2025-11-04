#!/bin/bash

set -e

INTEREST_CACHE=${1:-disabled}
LOG_LEVEL=${2:-info,alexgg=debug,parachain=debug}
OUTPUT=${3:-output}

TEST_DIR=test1
TSTAMP=$(date +%Y%m%d_%H%M%S)

# launch network
./network_start.sh  $TEST_DIR

sleep 2
COLLATOR_LOG=${TEST_DIR}/collator.log
TOP_OUTPUT="top_${OUTPUT}.log"
# launch collator
INTEREST_CACHE=$INTEREST_CACHE ./node_launch.sh $TEST_DIR collator $LOG_LEVEL $TOP_OUTPUT

# give some time for collator to sync
sleep 60

# submit_transactions
RUST_LOG=info,zombienet_orchestrator=debug
ZOMBIE_PROVIDER=native

echo "tx_start" > $TOP_OUTPUT
echo "tx_start" >> $COLLATOR_LOG
cargo nextest run --release -p polkadot-zombienet-sdk-tests --features zombie-metadata,zombie-ci --no-capture txs_per_block_test_2
echo "tx_done" >> $TOP_OUTPUT
echo "tx_done" >> $COLLATOR_LOG

pkill -9 polkadot polkadot-parachain top

COLLATOR_LOG="collator_${OUTPUT}.log"

cp $TEST_DIR/collator.log  $COLLATOR_LOG

# Create summary output file
SUMMARY_OUTPUT="summary_${OUTPUT}.log"

# process COLLATOR_LOG and TOP_OUTPUT
{
echo ""
echo "========================================"
echo "  Performance Analysis Results"
echo "========================================"
echo ""

# Process CPU metrics from TOP_OUTPUT
echo "--- CPU Usage Analysis ---"
awk '/tx_start/,/tx_done/ {
    if ($2 ~ /^[0-9]+\.?[0-9]*$/) {
        cpu = $2
        sum += cpu
        count++
        if (cpu > max || max == "") max = cpu
        if (cpu < min || min == "") min = cpu
    }
}
END {
    if (count > 0) {
        printf "Samples: %d\n", count
        printf "Avg CPU: %.2f%%\n", sum/count
        printf "Min CPU: %.2f%%\n", min
        printf "Max CPU: %.2f%%\n", max
    } else {
        print "No CPU data found"
    }
}' $TOP_OUTPUT

echo ""
echo "--- Block Preparation Metrics ---"

# Extract block metrics between markers
awk '/tx_start/,/tx_done/' $COLLATOR_LOG | \
grep "Prepared block for propo" | \
sed -E 's/.*at ([0-9]+).*\(([0-9]+) ms\).*extrinsics \(([0-9]+)\).*/\1 \2 \3/' | \
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
}'

echo ""
echo "========================================"
echo "Full logs available:"
echo "  TOP: $TOP_OUTPUT"
echo "  Collator: $COLLATOR_LOG"
echo "  Summary: $SUMMARY_OUTPUT"
echo "========================================"
} | tee "$SUMMARY_OUTPUT"
