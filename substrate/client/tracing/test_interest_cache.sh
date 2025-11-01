#!/bin/bash
# Script to test different interest cache configurations

set -e

echo "================================================"
echo "Testing Interest Cache Configurations"
echo "================================================"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to run benchmark with specific configuration
run_benchmark() {
    local cache_size=$1
    local description=$2

    echo -e "\n${BLUE}Testing: $description (cache_size=$cache_size)${NC}"

    # Note: You would need to modify Cargo.toml to enable interest-cache feature
    cargo bench --package sc-tracing \
        --bench interest_cache_bench \
        --features interest-cache \
        -- --save-baseline "cache_${cache_size}" \
        2>&1 | grep -E "(time:|Benchmarking)"
}

# Test different configurations
echo -e "\n${GREEN}1. Testing without cache (baseline)${NC}"
run_benchmark 0 "No cache (baseline)"

echo -e "\n${GREEN}2. Testing small cache${NC}"
run_benchmark 128 "Small cache"

echo -e "\n${GREEN}3. Testing medium cache (default)${NC}"
run_benchmark 1024 "Medium cache (default)"

echo -e "\n${GREEN}4. Testing large cache${NC}"
run_benchmark 2048 "Large cache"

echo -e "\n${GREEN}5. Testing very large cache${NC}"
run_benchmark 4096 "Very large cache"

echo -e "\n${BLUE}================================================${NC}"
echo -e "${GREEN}Benchmark complete!${NC}"
echo ""
echo "To compare results:"
echo "  cargo bench --package sc-tracing --bench interest_cache_bench -- --baseline cache_1024"
echo ""
echo "To see detailed comparison:"
echo "  critcmp cache_0 cache_1024 cache_2048"
