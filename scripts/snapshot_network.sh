#!/bin/bash
# snapshot_network.sh - Create and restore Polkadot/Parachain network snapshots

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOTS_DIR="${SNAPSHOTS_DIR:-$HOME/.polkadot-snapshots}"
DEFAULT_BASE_PATH="${HOME}/.local/share/polkadot"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
    create <name>           Create a new snapshot
    restore <name>          Restore from a snapshot
    list                    List all snapshots
    delete <name>           Delete a snapshot
    info <name>             Show snapshot information

Options:
    --base-path <path>      Node base path (default: ~/.local/share/polkadot)
    --chain <chain>         Chain name (default: dev)
    --compression <type>    Compression: none, gzip, zstd (default: gzip)

    Parachain Options:
    --parachain             Enable parachain mode (snapshot both relay + para)
    --relay-chain <chain>   Relay chain name (e.g., rococo_local_testnet)
    --para-id <id>          Parachain ID (e.g., 2000)
    --para-chain <chain>    Parachain chain name (default: local_testnet)

Examples:
    # Create snapshot (relay chain or dev)
    $0 create my-snapshot --chain dev

    # Create parachain snapshot (both relay + parachain)
    $0 create para-snapshot --parachain \\
        --relay-chain rococo_local_testnet \\
        --para-id 2000 \\
        --para-chain local_testnet

    # Restore snapshot
    $0 restore my-snapshot --base-path /tmp/polkadot-test

    # List snapshots
    $0 list

    # Show snapshot info
    $0 info para-snapshot
EOF
    exit 1
}

# Parse arguments
COMMAND=${1:-}
SNAPSHOT_NAME=${2:-}
BASE_PATH="$DEFAULT_BASE_PATH"
CHAIN="dev"
COMPRESSION="gzip"
PARACHAIN_MODE=false
RELAY_CHAIN=""
PARA_ID=""
PARA_CHAIN="local_testnet"

shift 2 2>/dev/null || true

while [[ $# -gt 0 ]]; do
    case $1 in
        --base-path)
            BASE_PATH="$2"
            shift 2
            ;;
        --chain)
            CHAIN="$2"
            shift 2
            ;;
        --compression)
            COMPRESSION="$2"
            shift 2
            ;;
        --parachain)
            PARACHAIN_MODE=true
            shift
            ;;
        --relay-chain)
            RELAY_CHAIN="$2"
            shift 2
            ;;
        --para-id)
            PARA_ID="$2"
            shift 2
            ;;
        --para-chain)
            PARA_CHAIN="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Ensure snapshots directory exists
mkdir -p "$SNAPSHOTS_DIR"

# Auto-detect parachain setup from base path
detect_parachain_setup() {
    local base_path=$1
    local chains_dir="${base_path}/chains"

    if [[ ! -d "$chains_dir" ]]; then
        return 1
    fi

    # Look for common relay chain directories
    for relay in rococo_local_testnet westend_local_testnet kusama polkadot rococo westend; do
        if [[ -d "${chains_dir}/${relay}" ]]; then
            # Look for parachain directories
            for para_dir in "${chains_dir}"/*/; do
                local dirname=$(basename "$para_dir")
                # Check if it looks like a parachain (contains para ID or typical names)
                if [[ "$dirname" =~ ^(parachain-[0-9]+|local_testnet|para_[0-9]+)$ ]]; then
                    echo "DETECTED:relay=${relay}:para=${dirname}"
                    return 0
                fi
            done
        fi
    done

    return 1
}

create_snapshot() {
    local name=$1
    local snapshot_dir="${SNAPSHOTS_DIR}/${name}"

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Snapshot name required${NC}"
        usage
    fi

    if [[ -d "$snapshot_dir" ]]; then
        echo -e "${RED}Error: Snapshot '$name' already exists${NC}"
        exit 1
    fi

    # Create snapshot directory
    mkdir -p "$snapshot_dir"

    if [[ "$PARACHAIN_MODE" == true ]]; then
        create_parachain_snapshot "$name" "$snapshot_dir"
    else
        create_simple_snapshot "$name" "$snapshot_dir"
    fi
}

create_simple_snapshot() {
    local name=$1
    local snapshot_dir=$2
    local source="${BASE_PATH}/chains/${CHAIN}"

    if [[ ! -d "$source" ]]; then
        echo -e "${RED}Error: Source directory not found: $source${NC}"

        # Try auto-detection
        echo -e "${YELLOW}Attempting to auto-detect parachain setup...${NC}"
        local detected=$(detect_parachain_setup "$BASE_PATH")
        if [[ $? -eq 0 ]]; then
            echo -e "${YELLOW}Detected parachain setup: $detected${NC}"
            echo -e "${YELLOW}Use --parachain mode for proper snapshot${NC}"
        fi
        exit 1
    fi

    echo -e "${BLUE}Creating snapshot '$name'...${NC}"
    echo "Source: $source"

    # Save metadata
    cat > "$snapshot_dir/metadata.json" <<EOF
{
  "name": "$name",
  "type": "simple",
  "chain": "$CHAIN",
  "created": "$(date -Iseconds)",
  "base_path": "$BASE_PATH",
  "source": "$source",
  "compression": "$COMPRESSION"
}
EOF

    # Create snapshot based on compression type
    snapshot_directory "$source" "$snapshot_dir/data" "$CHAIN"

    # Calculate size
    local size=$(du -sh "$snapshot_dir" | cut -f1)
    echo "{\"size\": \"$size\"}" > "$snapshot_dir/stats.json"

    echo -e "${GREEN}✓ Snapshot created: $name ($size)${NC}"
    echo "Location: $snapshot_dir"
}

create_parachain_snapshot() {
    local name=$1
    local snapshot_dir=$2

    if [[ -z "$RELAY_CHAIN" ]] || [[ -z "$PARA_ID" ]]; then
        echo -e "${RED}Error: Parachain mode requires --relay-chain and --para-id${NC}"
        exit 1
    fi

    local relay_source="${BASE_PATH}/chains/${RELAY_CHAIN}"
    local para_source="${BASE_PATH}/chains/parachain-${PARA_ID}"

    # Try alternative parachain directory names
    if [[ ! -d "$para_source" ]]; then
        para_source="${BASE_PATH}/chains/${PARA_CHAIN}"
    fi
    if [[ ! -d "$para_source" ]]; then
        para_source="${BASE_PATH}/chains/para_${PARA_ID}"
    fi

    # Validate sources exist
    if [[ ! -d "$relay_source" ]]; then
        echo -e "${RED}Error: Relay chain not found: $relay_source${NC}"
        exit 1
    fi

    if [[ ! -d "$para_source" ]]; then
        echo -e "${RED}Error: Parachain not found: $para_source${NC}"
        echo -e "${YELLOW}Tried:${NC}"
        echo "  - ${BASE_PATH}/chains/parachain-${PARA_ID}"
        echo "  - ${BASE_PATH}/chains/${PARA_CHAIN}"
        echo "  - ${BASE_PATH}/chains/para_${PARA_ID}"
        exit 1
    fi

    echo -e "${BLUE}Creating parachain snapshot '$name'...${NC}"
    echo "Relay chain: $relay_source"
    echo "Parachain:   $para_source"

    # Save metadata
    cat > "$snapshot_dir/metadata.json" <<EOF
{
  "name": "$name",
  "type": "parachain",
  "relay_chain": "$RELAY_CHAIN",
  "para_id": "$PARA_ID",
  "para_chain": "$(basename $para_source)",
  "created": "$(date -Iseconds)",
  "base_path": "$BASE_PATH",
  "compression": "$COMPRESSION"
}
EOF

    # Create relay chain snapshot
    echo -e "${BLUE}[1/2] Snapshotting relay chain...${NC}"
    mkdir -p "$snapshot_dir/relay"
    snapshot_directory "$relay_source" "$snapshot_dir/relay/data" "$RELAY_CHAIN"

    # Create parachain snapshot
    echo -e "${BLUE}[2/2] Snapshotting parachain...${NC}"
    mkdir -p "$snapshot_dir/para"
    snapshot_directory "$para_source" "$snapshot_dir/para/data" "$(basename $para_source)"

    # Also snapshot keystore if it exists
    if [[ -d "${BASE_PATH}/keystore" ]]; then
        echo -e "${BLUE}Snapshotting keystore...${NC}"
        cp -a "${BASE_PATH}/keystore" "$snapshot_dir/keystore"
    fi

    # Calculate sizes
    local relay_size=$(du -sh "$snapshot_dir/relay" | cut -f1)
    local para_size=$(du -sh "$snapshot_dir/para" | cut -f1)
    local total_size=$(du -sh "$snapshot_dir" | cut -f1)

    cat > "$snapshot_dir/stats.json" <<EOF
{
  "relay_size": "$relay_size",
  "para_size": "$para_size",
  "total_size": "$total_size"
}
EOF

    echo -e "${GREEN}✓ Parachain snapshot created: $name${NC}"
    echo "  Relay chain: $relay_size"
    echo "  Parachain:   $para_size"
    echo "  Total:       $total_size"
    echo "Location: $snapshot_dir"
}

snapshot_directory() {
    local source=$1
    local target=$2
    local name=$3

    case $COMPRESSION in
        none)
            echo "  Copying files (no compression)..."
            cp -a "$source" "$target"
            ;;
        gzip)
            echo "  Creating compressed archive (gzip)..."
            tar czf "${target}.tar.gz" -C "$(dirname $source)" "$(basename $source)"
            ;;
        zstd)
            echo "  Creating compressed archive (zstd)..."
            tar -I zstd -cf "${target}.tar.zst" -C "$(dirname $source)" "$(basename $source)"
            ;;
        *)
            echo -e "${RED}Unknown compression: $COMPRESSION${NC}"
            exit 1
            ;;
    esac
}

restore_snapshot() {
    local name=$1
    local snapshot_dir="${SNAPSHOTS_DIR}/${name}"

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Snapshot name required${NC}"
        usage
    fi

    if [[ ! -d "$snapshot_dir" ]]; then
        echo -e "${RED}Error: Snapshot '$name' not found${NC}"
        exit 1
    fi

    # Read metadata to determine snapshot type
    local snapshot_type=$(jq -r '.type' "$snapshot_dir/metadata.json" 2>/dev/null || echo "simple")

    if [[ "$snapshot_type" == "parachain" ]]; then
        restore_parachain_snapshot "$name" "$snapshot_dir"
    else
        restore_simple_snapshot "$name" "$snapshot_dir"
    fi
}

restore_simple_snapshot() {
    local name=$1
    local snapshot_dir=$2
    local target="${BASE_PATH}/chains/${CHAIN}"

    if [[ -d "$target" ]]; then
        echo -e "${RED}Warning: Target directory exists: $target${NC}"
        read -p "Delete and restore? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
        rm -rf "$target"
    fi

    echo -e "${BLUE}Restoring snapshot '$name'...${NC}"

    # Read metadata
    local compression=$(jq -r '.compression' "$snapshot_dir/metadata.json" 2>/dev/null || echo "gzip")
    local stored_chain=$(jq -r '.chain' "$snapshot_dir/metadata.json" 2>/dev/null || echo "$CHAIN")

    # Create parent directory
    mkdir -p "$BASE_PATH/chains"

    # Restore based on compression type
    restore_directory "$snapshot_dir/data" "$BASE_PATH/chains" "$stored_chain" "$compression"

    echo -e "${GREEN}✓ Snapshot restored${NC}"
    echo "Target: $target"
    echo ""
    echo "To launch node:"
    echo "  ./target/release/polkadot --chain $CHAIN --base-path $BASE_PATH"
}

restore_parachain_snapshot() {
    local name=$1
    local snapshot_dir=$2

    # Read metadata
    local relay_chain=$(jq -r '.relay_chain' "$snapshot_dir/metadata.json")
    local para_id=$(jq -r '.para_id' "$snapshot_dir/metadata.json")
    local para_chain=$(jq -r '.para_chain' "$snapshot_dir/metadata.json")
    local compression=$(jq -r '.compression' "$snapshot_dir/metadata.json" 2>/dev/null || echo "gzip")

    local relay_target="${BASE_PATH}/chains/${relay_chain}"
    local para_target="${BASE_PATH}/chains/${para_chain}"

    echo -e "${BLUE}Restoring parachain snapshot '$name'...${NC}"
    echo "Relay chain: $relay_chain"
    echo "Parachain:   $para_chain (ID: $para_id)"

    # Check for existing directories
    if [[ -d "$relay_target" ]] || [[ -d "$para_target" ]]; then
        echo -e "${RED}Warning: Target directories exist${NC}"
        [[ -d "$relay_target" ]] && echo "  - $relay_target"
        [[ -d "$para_target" ]] && echo "  - $para_target"
        read -p "Delete and restore? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
        rm -rf "$relay_target" "$para_target"
    fi

    # Create parent directory
    mkdir -p "$BASE_PATH/chains"

    # Restore relay chain
    echo -e "${BLUE}[1/2] Restoring relay chain...${NC}"
    restore_directory "$snapshot_dir/relay/data" "$BASE_PATH/chains" "$relay_chain" "$compression"

    # Restore parachain
    echo -e "${BLUE}[2/2] Restoring parachain...${NC}"
    restore_directory "$snapshot_dir/para/data" "$BASE_PATH/chains" "$para_chain" "$compression"

    # Restore keystore if it exists
    if [[ -d "$snapshot_dir/keystore" ]]; then
        echo -e "${BLUE}Restoring keystore...${NC}"
        cp -a "$snapshot_dir/keystore" "${BASE_PATH}/keystore"
    fi

    echo -e "${GREEN}✓ Parachain snapshot restored${NC}"
    echo "Relay chain: $relay_target"
    echo "Parachain:   $para_target"
    echo ""
    echo "To launch collator:"
    echo "  ./target/release/polkadot-parachain \\"
    echo "    --collator \\"
    echo "    --base-path $BASE_PATH \\"
    echo "    --chain <para-spec> \\"
    echo "    -- \\"
    echo "    --chain <relay-spec>"
}

restore_directory() {
    local source=$1
    local target_parent=$2
    local chain_name=$3
    local compression=$4

    case $compression in
        none)
            echo "  Copying files..."
            cp -a "$source" "$target_parent/$chain_name"
            ;;
        gzip)
            echo "  Extracting (gzip)..."
            tar xzf "${source}.tar.gz" -C "$target_parent"
            ;;
        zstd)
            echo "  Extracting (zstd)..."
            tar -I zstd -xf "${source}.tar.zst" -C "$target_parent"
            ;;
    esac
}

list_snapshots() {
    echo -e "${BLUE}Available snapshots:${NC}"
    echo ""

    if [[ ! -d "$SNAPSHOTS_DIR" ]] || [[ -z "$(ls -A $SNAPSHOTS_DIR 2>/dev/null)" ]]; then
        echo "No snapshots found."
        return
    fi

    printf "%-20s %-10s %-20s %-20s %-10s\n" "NAME" "TYPE" "CHAIN/RELAY" "CREATED" "SIZE"
    printf "%-20s %-10s %-20s %-20s %-10s\n" "----" "----" "-----------" "-------" "----"

    for snapshot in "$SNAPSHOTS_DIR"/*; do
        if [[ -d "$snapshot" ]]; then
            local name=$(basename "$snapshot")
            local type=$(jq -r '.type' "$snapshot/metadata.json" 2>/dev/null || echo "simple")
            local created=$(jq -r '.created' "$snapshot/metadata.json" 2>/dev/null | cut -d'T' -f1 || echo "unknown")

            if [[ "$type" == "parachain" ]]; then
                local relay=$(jq -r '.relay_chain' "$snapshot/metadata.json" 2>/dev/null || echo "unknown")
                local para_id=$(jq -r '.para_id' "$snapshot/metadata.json" 2>/dev/null || echo "?")
                local size=$(jq -r '.total_size' "$snapshot/stats.json" 2>/dev/null || echo "?")
                local chain_info="${relay}+para${para_id}"
            else
                local chain=$(jq -r '.chain' "$snapshot/metadata.json" 2>/dev/null || echo "unknown")
                local size=$(jq -r '.size' "$snapshot/stats.json" 2>/dev/null || echo "?")
                local chain_info="$chain"
            fi

            printf "%-20s %-10s %-20s %-20s %-10s\n" "$name" "$type" "$chain_info" "$created" "$size"
        fi
    done
}

delete_snapshot() {
    local name=$1
    local snapshot_dir="${SNAPSHOTS_DIR}/${name}"

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Snapshot name required${NC}"
        usage
    fi

    if [[ ! -d "$snapshot_dir" ]]; then
        echo -e "${RED}Error: Snapshot '$name' not found${NC}"
        exit 1
    fi

    echo -e "${RED}Delete snapshot '$name'?${NC}"
    read -p "This cannot be undone [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi

    rm -rf "$snapshot_dir"
    echo -e "${GREEN}✓ Snapshot deleted: $name${NC}"
}

show_info() {
    local name=$1
    local snapshot_dir="${SNAPSHOTS_DIR}/${name}"

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Snapshot name required${NC}"
        usage
    fi

    if [[ ! -d "$snapshot_dir" ]]; then
        echo -e "${RED}Error: Snapshot '$name' not found${NC}"
        exit 1
    fi

    echo -e "${BLUE}Snapshot: $name${NC}"
    echo ""

    if [[ -f "$snapshot_dir/metadata.json" ]]; then
        echo "Metadata:"
        cat "$snapshot_dir/metadata.json" | jq .
    fi

    if [[ -f "$snapshot_dir/stats.json" ]]; then
        echo ""
        echo "Statistics:"
        cat "$snapshot_dir/stats.json" | jq .
    fi

    echo ""
    echo "Location: $snapshot_dir"

    # Show directory structure
    echo ""
    echo "Contents:"
    tree -L 2 "$snapshot_dir" 2>/dev/null || ls -lh "$snapshot_dir"
}

# Main
case $COMMAND in
    create)
        create_snapshot "$SNAPSHOT_NAME"
        ;;
    restore)
        restore_snapshot "$SNAPSHOT_NAME"
        ;;
    list)
        list_snapshots
        ;;
    delete)
        delete_snapshot "$SNAPSHOT_NAME"
        ;;
    info)
        show_info "$SNAPSHOT_NAME"
        ;;
    *)
        usage
        ;;
esac
