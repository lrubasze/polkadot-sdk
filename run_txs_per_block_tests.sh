#!/bin/bash

# Script to run txs_per_block_test with different configurations
# and collect log files for analysis
#
# Tests 12 combinations (4 cache configs × 3 log levels):
# - INTEREST_CACHE: disabled, default, min_info, min_trace
# - COLLATOR_LOG: info, info_debug, info_trace

set -e

# Configuration arrays
PARACHAIN_CMD="polkadot-parachain"

# Interest cache configurations
INTEREST_CACHE_CONFIGS=(
    "disabled"   # explicitly disabled
    "default"    # enabled with defaults
    "min_verbosity=info,lru_cache_size=1024"
    "min_verbosity=trace,lru_cache_size=1024"
)

CACHE_TYPE_NAMES=(
    "disabled"
    "default"
    "min_info"
    "min_trace"
)

COLLATOR_LOGS=(
    "-linfo"
    "-linfo,parachain=debug,aura=debug"
    "-linfo,parachain=debug,aura=debug,alexggh=debug"
    "-linfo,parachain=debug,aura=debug,alexggh=trace"
    "-linfo,alexggh=debug"
    "-linfo,alexggh=trace"
    "-linfo,alexggh=debug,abcdefg=trace"
)

LOG_NAMES=(
    "info"
    "info_para_debug"
    "info_para_debug_al_debug"
    "info_para_debug_al_trace"
    "info_al_debug"
    "info_al_trace"
    "info_al_debug_abc_trace"
)

# Generate timestamp for this run
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Create output directory
OUTPUT_DIR="_test"
mkdir -p "$OUTPUT_DIR"

TMP_DIR=/var/folders/sc/c9stf8y96798j41wbx8hp42w0000gn/T

# Function to find the latest zombienet directory
find_zombie_latest() {
    local zombie_dir=$(ls -dt $TMP_DIR/zombie-* | head -1)
    echo "$zombie_dir"
}

# Function to run test with given configuration
run_test() {
    local interest_cache_config=$1
    local collator_log=$2
    local log_name=$3
    local cache_type=$4

    echo "========================================"
    echo "Running test with:"
    echo "  PARACHAIN_CMD: $PARACHAIN_CMD"
    echo "  INTEREST_CACHE: $interest_cache_config"
    echo "  COLLATOR_LOG: $collator_log"
    echo "========================================"

    # BIN_DIR=/Users/lukasz/work/paritytech/polkadot-sdk/bin
    RELEASE_DIR=/Users/lukasz/work/paritytech/polkadot-sdk/target/release

    # Run the test with INTEREST_CACHE always set
    INTEREST_CACHE="$interest_cache_config" \
    PARACHAIN_CMD="$PARACHAIN_CMD" \
    COLLATOR_LOG="$collator_log" \
    PATH=$RELEASE_DIR:$PATH \
    RUST_LOG=info,zombienet_orchestrator=info \
    ZOMBIE_PROVIDER=native \
    cargo nextest run --release \
        -p polkadot-zombienet-sdk-tests \
        --features zombie-metadata,zombie-ci \
        --no-capture \
        txs_per_block_test

    # Find the latest zombie directory
    local zombie_dir=$(find_zombie_latest)

    if [ -n "$zombie_dir" ]; then
        # Find collator.log in the zombie directory
        local collator_log_file=$(find "$zombie_dir" -name "collator.log" | head -1)

        if [ -n "$collator_log_file" ]; then
            local output_file="$OUTPUT_DIR/txs_per_block_${TIMESTAMP}_${cache_type}_${log_name}.log"
            cp "$collator_log_file" "$output_file"
            echo "✓ Log file copied to: $output_file"
        else
            echo "✗ Warning: collator.log not found in $zombie_dir"
        fi
    else
        echo "✗ Warning: No zombienet directory found"
    fi

    echo ""
}

# Main execution
echo "Starting txs_per_block test suite"
echo "Run timestamp: $TIMESTAMP"
echo "Output directory: $OUTPUT_DIR"
echo ""

total_tests=$((${#INTEREST_CACHE_CONFIGS[@]} * ${#COLLATOR_LOGS[@]}))
current_test=0

# Loop through all combinations
for i in "${!INTEREST_CACHE_CONFIGS[@]}"; do
    interest_cache_config="${INTEREST_CACHE_CONFIGS[$i]}"
    cache_type="${CACHE_TYPE_NAMES[$i]}"

    for j in "${!COLLATOR_LOGS[@]}"; do
        collator_log="${COLLATOR_LOGS[$j]}"
        log_name="${LOG_NAMES[$j]}"

        current_test=$((current_test + 1))

        echo "Progress: Test $current_test of $total_tests"
        run_test "$interest_cache_config" "$collator_log" "$log_name" "$cache_type"

        # Optional: Add a small delay between tests
        sleep 2
    done
done

echo "========================================"
echo "All tests completed!"
echo "Run timestamp: $TIMESTAMP"
echo "Log files are in: $OUTPUT_DIR"
echo "========================================"
ls -lh "$OUTPUT_DIR" | grep "$TIMESTAMP"
