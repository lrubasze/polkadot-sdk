#!/bin/bash

# Script to run txs_per_block_test with different configurations
# and collect log files for analysis
#
# Tests combinations of:
# - TRIE_CACHE: enabled, disabled
# - INTEREST_CACHE: disabled, default, various min_verbosity configs
# - COLLATOR_LOG: info, info_para_debug, info_al_debug, etc.

set -e

# Interest cache configurations
INTEREST_CACHE_CONFIGS=(
    "disabled"   # explicitly disabled
    "min_verbosity=debug,lru_cache_size=512"
    "default"    # enabled with defaults
    "min_verbosity=debug,lru_cache_size=2048"
    "min_verbosity=info,lru_cache_size=512"
    "min_verbosity=info,lru_cache_size=1024"
    "min_verbosity=info,lru_cache_size=2048"
    "min_verbosity=trace,lru_cache_size=512"
    "min_verbosity=trace,lru_cache_size=1024"
    "min_verbosity=trace,lru_cache_size=2048"
)

CACHE_TYPE_NAMES=(
    "disabled"
    "min_debug_cache=512"
    "default"
    "min_debug_cache=2048"
    "min_info_debug_cache=512"
    "min_info_debug_cache=1024"
    "min_info_debug_cache=2048"
    "min_trace_debug_cache=512"
    "min_trace_debug_cache=1024"
    "min_trace_debug_cache=2048"
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

# Trie cache configurations
TRIE_CACHE_CONFIGS=(
    "enabled"
    "disabled"
)

TRIE_CACHE_NAMES=(
    "tc_on"
    "tc_off"
)

# Generate timestamp for this run
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Create output directory for this run
OUTPUT_DIR="run_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"
echo "Created output directory: $OUTPUT_DIR"

# Create global results CSV file (in current directory, not in OUTPUT_DIR)
RESULTS_FILE="results_${TIMESTAMP}.csv"
echo "trie_cache;interest_cache;log_level;blocks_analyzed;proposal_min_ms;proposal_max_ms;proposal_avg_ms;avg_extrinsics;cpu_min_pct;cpu_max_pct;cpu_avg_pct" > "$RESULTS_FILE"
echo "Created global results file: $RESULTS_FILE"

# Function to run test with given configuration
run_test() {
    local trie_cache_config=$1
    local interest_cache_config=$2
    local collator_log=$3
    local log_name=$4
    local cache_type=$5
    local trie_cache_name=$6

    # Strip the -l prefix from collator_log to get log_level
    local log_level="${collator_log#-l}"

    # Construct OUTPUT name: TIMESTAMP_TRIE_CACHE_NAME_CACHE_TYPE_LOG_NAME
    local output_name="${TIMESTAMP}_${trie_cache_name}_${cache_type}_${log_name}"

    echo "========================================"
    echo "Running test with:"
    echo "  TRIE_CACHE: $trie_cache_config"
    echo "  INTEREST_CACHE: $interest_cache_config"
    echo "  LOG_LEVEL: $log_level"
    echo "  OUTPUT: $output_name"
    echo "  OUTPUT_DIR: $OUTPUT_DIR"
    echo "========================================"

    # Call test.sh with parameters (including global results file, output directory, and trie cache config)
    ./test.sh "$interest_cache_config" "$log_level" "$output_name" "$RESULTS_FILE" "$OUTPUT_DIR" "$trie_cache_config"

    echo ""
}

# Main execution
echo "Starting txs_per_block test suite"
echo "Run timestamp: $TIMESTAMP"
echo ""

total_tests=$((${#TRIE_CACHE_CONFIGS[@]} * ${#INTEREST_CACHE_CONFIGS[@]} * ${#COLLATOR_LOGS[@]}))
current_test=0

# Loop through all combinations
for k in "${!TRIE_CACHE_CONFIGS[@]}"; do
    trie_cache_config="${TRIE_CACHE_CONFIGS[$k]}"
    trie_cache_name="${TRIE_CACHE_NAMES[$k]}"

    for i in "${!INTEREST_CACHE_CONFIGS[@]}"; do
        interest_cache_config="${INTEREST_CACHE_CONFIGS[$i]}"
        cache_type="${CACHE_TYPE_NAMES[$i]}"

        for j in "${!COLLATOR_LOGS[@]}"; do
            collator_log="${COLLATOR_LOGS[$j]}"
            log_name="${LOG_NAMES[$j]}"

            current_test=$((current_test + 1))

            echo "Progress: Test $current_test of $total_tests"
            run_test "$trie_cache_config" "$interest_cache_config" "$collator_log" "$log_name" "$cache_type" "$trie_cache_name"

            # Optional: Add a small delay between tests
            sleep 2
        done
    done
done

echo "========================================"
echo "All tests completed!"
echo "Run timestamp: $TIMESTAMP"
echo "========================================"
echo ""
echo "Global results file: $RESULTS_FILE"
echo "Output directory: $OUTPUT_DIR"
echo ""
echo "Generated files in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"/*.log "$OUTPUT_DIR"/*.txt 2>/dev/null | awk '{print $9, $5}' || echo "No files found"
echo ""
echo "View consolidated results:"
echo "  cat $RESULTS_FILE"
echo "  column -t -s, $RESULTS_FILE"
