#!/bin/bash

# Script to run txs_per_block_test with different configurations
# and collect log files for analysis
#
# Tests 12 combinations (4 cache configs × 3 log levels):
# - INTEREST_CACHE: disabled, default, min_info, min_trace
# - COLLATOR_LOG: info, info_debug, info_trace

set -e

# Interest cache configurations
INTEREST_CACHE_CONFIGS=(
    "disabled"   # explicitly disabled
    "default"    # enabled with defaults
    # "min_verbosity=info,lru_cache_size=1024"
    # "min_verbosity=trace,lru_cache_size=1024"
)

CACHE_TYPE_NAMES=(
    "disabled"
    "default"
    # "min_info"
    # "min_trace"
)

COLLATOR_LOGS=(
    "-linfo"
    "-linfo,parachain=debug,aura=debug"
    # "-linfo,parachain=debug,aura=debug,alexggh=debug"
    # "-linfo,parachain=debug,aura=debug,alexggh=trace"
    # "-linfo,alexggh=debug"
    # "-linfo,alexggh=trace"
    # "-linfo,alexggh=debug,abcdefg=trace"
)

LOG_NAMES=(
    "info"
    "info_para_debug"
    # "info_para_debug_al_debug"
    # "info_para_debug_al_trace"
    # "info_al_debug"
    # "info_al_trace"
    # "info_al_debug_abc_trace"
)

# Generate timestamp for this run
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Create global results CSV file
RESULTS_FILE="results_${TIMESTAMP}.csv"
echo "interest_cache,log_level,proposal_min_ms,proposal_max_ms,proposal_avg_ms,cpu_min_pct,cpu_max_pct,cpu_avg_pct" > "$RESULTS_FILE"
echo "Created global results file: $RESULTS_FILE"

# Function to run test with given configuration
run_test() {
    local interest_cache_config=$1
    local collator_log=$2
    local log_name=$3
    local cache_type=$4

    # Strip the -l prefix from collator_log to get log_level
    local log_level="${collator_log#-l}"

    # Construct OUTPUT name: TIMESTAMP_CACHE_TYPE_LOG_NAME
    local output_name="${TIMESTAMP}_${cache_type}_${log_name}"

    echo "========================================"
    echo "Running test with:"
    echo "  INTEREST_CACHE: $interest_cache_config"
    echo "  LOG_LEVEL: $log_level"
    echo "  OUTPUT: $output_name"
    echo "========================================"

    # Call test.sh with parameters (including global results file)
    ./test.sh "$interest_cache_config" "$log_level" "$output_name" "$RESULTS_FILE"

    echo ""
}

# Main execution
echo "Starting txs_per_block test suite"
echo "Run timestamp: $TIMESTAMP"
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
echo "========================================"
echo ""
echo "Global results file: $RESULTS_FILE"
echo ""
echo "Generated files (summary, top, collator logs):"
ls -lh *${TIMESTAMP}*.log 2>/dev/null || echo "No log files found with timestamp $TIMESTAMP"
echo ""
echo "View consolidated results:"
echo "  cat $RESULTS_FILE"
echo "  column -t -s, $RESULTS_FILE"
