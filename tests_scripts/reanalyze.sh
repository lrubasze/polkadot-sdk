#!/bin/bash

# Script to re-analyze existing test results using updated analyze_metrics.py
# This allows you to apply new analysis logic to already collected data
# without re-running the expensive tests.
#
# Usage: ./reanalyze.sh <run_directory>
# Example: ./reanalyze.sh run_20251104_181503

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <run_directory>"
    echo ""
    echo "Example: $0 run_20251104_181503"
    echo ""
    echo "This will re-analyze all logs in the directory and create:"
    echo "  - Summary files inside run directory: summary_reanalysis_*.log"
    echo "  - Results CSV in current directory: results_<timestamp>_reanalysis.csv"
    exit 1
fi

RUN_DIR=$1

if [ ! -d "$RUN_DIR" ]; then
    echo "Error: Directory '$RUN_DIR' not found"
    exit 1
fi

# Get absolute path to run directory
RUN_DIR=$(cd "$RUN_DIR" && pwd)

# Extract original timestamp from directory name
# Expected format: run_YYYYMMDD_HHMMSS or run_YYYYMMDD_HHMMSS_suffix
DIR_BASENAME=$(basename "$RUN_DIR")
# Remove "run_" prefix
TIMESTAMP=${DIR_BASENAME#run_}

echo "========================================"
echo "Re-analyzing test results"
echo "Source directory: $RUN_DIR"
echo "Original timestamp: $TIMESTAMP"
echo "========================================"
echo ""

# ============================================================================
# Configuration arrays - MUST MATCH run_test.sh exactly
# ============================================================================

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
    "-linfo,alexggh=debug"
    "-linfo,alexggh=trace"
    # "-linfo,alexggh=debug,abcdefg=trace"
)

LOG_NAMES=(
    "info"
    "info_para_debug"
    # "info_para_debug_al_debug"
    # "info_para_debug_al_trace"
    "info_al_debug"
    "info_al_trace"
    # "info_al_debug_abc_trace"
)

# ============================================================================
# End of configuration arrays
# ============================================================================

# Create new results CSV file in current directory (not inside RUN_DIR)
RESULTS_FILE="results_${TIMESTAMP}_reanalysis.csv"
echo "interest_cache;log_level;blocks_analyzed;proposal_min_ms;proposal_max_ms;proposal_avg_ms;avg_extrinsics;cpu_min_pct;cpu_max_pct;cpu_avg_pct" > "$RESULTS_FILE"
echo "Created results file: $RESULTS_FILE"
echo ""

# Get the directory where this script is located (for analyze_metrics.py)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to reanalyze a single test configuration
reanalyze_test() {
    local interest_cache_config=$1
    local collator_log_arg=$2
    local log_name=$3
    local cache_type=$4

    # Strip the -l prefix from collator_log to get log_level
    local log_level="${collator_log_arg#-l}"

    # Construct OUTPUT name: TIMESTAMP_CACHE_TYPE_LOG_NAME (same as run_test.sh)
    local output_name="${TIMESTAMP}_${cache_type}_${log_name}"

    # Construct file paths
    local collator_log="${RUN_DIR}/collator_${output_name}.log"
    local top_log="${RUN_DIR}/top_${output_name}.log"
    local timestamp_file="${RUN_DIR}/timestamps_${output_name}.txt"
    local summary_output="${RUN_DIR}/summary_reanalysis_${output_name}.log"

    # Check if required files exist
    if [ ! -f "$collator_log" ]; then
        echo "  ⚠ Skipped: Collator log not found"
        return 1
    fi

    if [ ! -f "$top_log" ]; then
        echo "  ⚠ Skipped: Top log not found"
        return 1
    fi

    if [ ! -f "$timestamp_file" ]; then
        echo "  ⚠ Skipped: Timestamp file not found"
        return 1
    fi

    # Read timestamps from file
    source "$timestamp_file"

    if [ -z "$TX_START_TIMESTAMP" ] || [ -z "$TX_END_TIMESTAMP" ]; then
        echo "  ⚠ Skipped: Invalid timestamps"
        return 1
    fi

    # Run Python analysis
    if python3 "${SCRIPT_DIR}/analyze_metrics.py" \
        --collator-log "$collator_log" \
        --top-log "$top_log" \
        --start-time "$TX_START_TIMESTAMP" \
        --end-time "$TX_END_TIMESTAMP" \
        --output "$summary_output" \
        --csv-file "$RESULTS_FILE" \
        --interest-cache "$interest_cache_config" \
        --log-level "$log_level" 2>&1 | grep -v "^Parsing\|^Writing\|^Appending\|^Analysis complete"; then

        echo "  ✓ Reanalyzed successfully"
        return 0
    else
        echo "  ✗ Analysis failed"
        return 1
    fi
}

# Counter for processed tests
total_tests=$((${#INTEREST_CACHE_CONFIGS[@]} * ${#COLLATOR_LOGS[@]}))
current_test=0
processed=0
failed=0
skipped=0

# Loop through all combinations in the same order as run_test.sh
for i in "${!INTEREST_CACHE_CONFIGS[@]}"; do
    interest_cache_config="${INTEREST_CACHE_CONFIGS[$i]}"
    cache_type="${CACHE_TYPE_NAMES[$i]}"

    for j in "${!COLLATOR_LOGS[@]}"; do
        collator_log="${COLLATOR_LOGS[$j]}"
        log_name="${LOG_NAMES[$j]}"

        current_test=$((current_test + 1))

        echo "[$current_test/$total_tests] INTEREST_CACHE=$cache_type, LOG=$log_name"

        if reanalyze_test "$interest_cache_config" "$collator_log" "$log_name" "$cache_type"; then
            ((processed++))
        else
            if [ -f "${RUN_DIR}/collator_${TIMESTAMP}_${cache_type}_${log_name}.log" ]; then
                ((failed++))
            else
                ((skipped++))
            fi
        fi
    done
done

echo ""
echo "========================================"
echo "Re-analysis complete!"
echo "========================================"
echo ""
echo "Total configurations: $total_tests"
echo "  Successfully processed: $processed"
if [ $failed -gt 0 ]; then
    echo "  Failed: $failed"
fi
if [ $skipped -gt 0 ]; then
    echo "  Skipped (files not found): $skipped"
fi
echo ""
echo "Results file: $RESULTS_FILE"
echo ""
echo "Summary files created:"
ls -lh "$RUN_DIR"/summary_reanalysis_*.log 2>/dev/null | awk '{print "  " $9, "(" $5 ")"}' || echo "  None"
echo ""
echo "View results:"
echo "  cat $RESULTS_FILE"
echo "  column -t -s';' $RESULTS_FILE"
echo ""
