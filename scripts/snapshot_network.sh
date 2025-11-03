#!/bin/bash
# snapshot_network.sh - Create and restore Polkadot network snapshots

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOTS_DIR="${SNAPSHOTS_DIR:-$HOME/.polkadot-snapshots}"
DEFAULT_BASE_PATH="${HOME}/.local/share/polkadot"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
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

Examples:
    # Create snapshot
    $0 create my-snapshot --chain dev

    # Restore snapshot
    $0 restore my-snapshot --base-path /tmp/polkadot-test

    # List snapshots
    $0 list
EOF
    exit 1
}

# Parse arguments
COMMAND=${1:-}
SNAPSHOT_NAME=${2:-}
BASE_PATH="$DEFAULT_BASE_PATH"
CHAIN="dev"
COMPRESSION="gzip"

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
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Ensure snapshots directory exists
mkdir -p "$SNAPSHOTS_DIR"

create_snapshot() {
    local name=$1
    local source="${BASE_PATH}/chains/${CHAIN}"
    local snapshot_dir="${SNAPSHOTS_DIR}/${name}"

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Snapshot name required${NC}"
        usage
    fi

    if [[ -d "$snapshot_dir" ]]; then
        echo -e "${RED}Error: Snapshot '$name' already exists${NC}"
        exit 1
    fi

    if [[ ! -d "$source" ]]; then
        echo -e "${RED}Error: Source directory not found: $source${NC}"
        exit 1
    fi

    echo -e "${BLUE}Creating snapshot '$name'...${NC}"
    echo "Source: $source"

    # Create snapshot directory
    mkdir -p "$snapshot_dir"

    # Save metadata
    cat > "$snapshot_dir/metadata.json" <<EOF
{
  "name": "$name",
  "chain": "$CHAIN",
  "created": "$(date -Iseconds)",
  "base_path": "$BASE_PATH",
  "source": "$source",
  "compression": "$COMPRESSION"
}
EOF

    # Create snapshot based on compression type
    case $COMPRESSION in
        none)
            echo "Copying files (no compression)..."
            cp -a "$source" "$snapshot_dir/data"
            ;;
        gzip)
            echo "Creating compressed snapshot (gzip)..."
            tar czf "$snapshot_dir/data.tar.gz" -C "$BASE_PATH/chains" "$CHAIN"
            ;;
        zstd)
            echo "Creating compressed snapshot (zstd)..."
            tar -I zstd -cf "$snapshot_dir/data.tar.zst" -C "$BASE_PATH/chains" "$CHAIN"
            ;;
        *)
            echo -e "${RED}Unknown compression: $COMPRESSION${NC}"
            exit 1
            ;;
    esac

    # Calculate size
    local size=$(du -sh "$snapshot_dir" | cut -f1)
    echo "{\"size\": \"$size\"}" > "$snapshot_dir/stats.json"

    echo -e "${GREEN}✓ Snapshot created: $name ($size)${NC}"
    echo "Location: $snapshot_dir"
}

restore_snapshot() {
    local name=$1
    local snapshot_dir="${SNAPSHOTS_DIR}/${name}"
    local target="${BASE_PATH}/chains/${CHAIN}"

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Snapshot name required${NC}"
        usage
    fi

    if [[ ! -d "$snapshot_dir" ]]; then
        echo -e "${RED}Error: Snapshot '$name' not found${NC}"
        exit 1
    fi

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

    # Create parent directory
    mkdir -p "$BASE_PATH/chains"

    # Restore based on compression type
    case $compression in
        none)
            echo "Copying files..."
            cp -a "$snapshot_dir/data" "$target"
            ;;
        gzip)
            echo "Extracting (gzip)..."
            tar xzf "$snapshot_dir/data.tar.gz" -C "$BASE_PATH/chains"
            ;;
        zstd)
            echo "Extracting (zstd)..."
            tar -I zstd -xf "$snapshot_dir/data.tar.zst" -C "$BASE_PATH/chains"
            ;;
    esac

    echo -e "${GREEN}✓ Snapshot restored${NC}"
    echo "Target: $target"
    echo ""
    echo "To launch node:"
    echo "  ./target/release/polkadot --chain $CHAIN --base-path $BASE_PATH"
}

list_snapshots() {
    echo -e "${BLUE}Available snapshots:${NC}"
    echo ""

    if [[ ! -d "$SNAPSHOTS_DIR" ]] || [[ -z "$(ls -A $SNAPSHOTS_DIR 2>/dev/null)" ]]; then
        echo "No snapshots found."
        return
    fi

    printf "%-20s %-15s %-20s %-10s\n" "NAME" "CHAIN" "CREATED" "SIZE"
    printf "%-20s %-15s %-20s %-10s\n" "----" "-----" "-------" "----"

    for snapshot in "$SNAPSHOTS_DIR"/*; do
        if [[ -d "$snapshot" ]]; then
            local name=$(basename "$snapshot")
            local chain=$(jq -r '.chain' "$snapshot/metadata.json" 2>/dev/null || echo "unknown")
            local created=$(jq -r '.created' "$snapshot/metadata.json" 2>/dev/null | cut -d'T' -f1 || echo "unknown")
            local size=$(jq -r '.size' "$snapshot/stats.json" 2>/dev/null || echo "?")

            printf "%-20s %-15s %-20s %-10s\n" "$name" "$chain" "$created" "$size"
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
        cat "$snapshot_dir/metadata.json" | jq .
    fi

    if [[ -f "$snapshot_dir/stats.json" ]]; then
        echo ""
        echo "Statistics:"
        cat "$snapshot_dir/stats.json" | jq .
    fi

    echo ""
    echo "Location: $snapshot_dir"
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
