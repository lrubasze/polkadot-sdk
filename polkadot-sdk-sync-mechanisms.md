# Polkadot SDK Synchronization Mechanisms

Technical reference for warp sync and gap sync in Substrate.

---

## Overview

```
Full Sync Path:
WarpSync → StateSync → ChainSync → GapSync (background)
   ↓          ↓           ↓            ↓
  3 min    5 min      ongoing      hours (bg)
```

See [block-import-mechanism.md](./block-import-mechanism.md) for block import details.

---

## Warp Sync

Fast initial sync using GRANDPA finality proofs instead of verifying every header.

### Core Concept

**Traditional sync**: Verify every block (10M blocks = 10M verifications)
**Warp sync**: Verify only authority set changes (~100 blocks)

```
Genesis → Authority Change₁ → Authority Change₂ → ... → Current
  (0)         (100k)              (500k)                 (2M)
```

### Data Structures

**Location**: `substrate/client/consensus/grandpa/src/warp_proof.rs`

```rust
pub struct WarpSyncFragment<Block: BlockT> {
    pub header: Block::Header,                      // Finalized authority change block
    pub justification: GrandpaJustification<Block>, // 2/3+ signatures
}

pub struct WarpSyncProof<Block: BlockT> {
    proofs: Vec<WarpSyncFragment<Block>>,
    is_finished: bool,
}

pub enum VerificationResult<Block: BlockT> {
    Partial(SetId, AuthorityList, Block::Hash),    // Need more proofs
    Complete(SetId, AuthorityList, Block::Header), // Reached target
}
```

### Phase State Machine

**Location**: `substrate/client/network/sync/src/strategy/warp.rs:165-179`

```
┌─────────────────┐
│ WaitingForPeers │ (min 3 peers)
└────────┬────────┘
         ↓
┌─────────────────┐
│   WarpProof     │ Download & verify authority set changes
│                 │ Max proof size: 8 MB
└────────┬────────┘
         ↓
┌─────────────────┐
│  TargetBlock    │ Download target header + body
└────────┬────────┘
         ↓
┌─────────────────┐
│    Complete     │
└─────────────────┘
```

### Proof Generation

**Location**: `warp_proof.rs:82-197`

1. Start from requested block
2. Iterate through `AuthoritySetChanges`
3. For each change:
   - Get last block finalized by that set
   - Get GRANDPA justification
4. Stop at 8 MB or current authorities

### Verification Flow

**Location**: `warp_proof.rs:199-246`

```
For each fragment:
  1. Verify justification against current authority set
  2. Extract next authority set from block digest
  3. Increment set_id
  4. Repeat until all verified
```

### Security

- GRANDPA justifications signed by 2/3+ validators
- Each authority set signs off on next set
- Unbroken chain of trust from genesis

### Protocol

- **Network**: `/{genesis_hash}/sync/warp`
- **Request**: `WarpProofRequest { begin: Hash }`
- **Response**: Scale-encoded `WarpSyncProof` (max 8 MB)

### Constants

| Parameter | Value | Location |
|-----------|-------|----------|
| MIN_PEERS_TO_START | 3 | warp.rs:48 |
| MAX_PROOF_SIZE | 8 MB | warp_proof.rs:58 |

### Key Files

- `substrate/client/network/sync/src/strategy/warp.rs` - State machine
- `substrate/client/consensus/grandpa/src/warp_proof.rs` - Proof generation/verification
- `substrate/client/network/sync/src/warp_request_handler.rs` - Request handler

---

## Gap Sync

Background process filling missing blocks after warp/fast sync.

### Gap Types

**Location**: `substrate/primitives/blockchain/src/backend.rs:545-564`

```rust
pub enum BlockGapType {
    MissingHeaderAndBody,  // Warp sync result
    MissingBody,           // Fast sync result
}

pub struct BlockGap<N> {
    pub start: N,    // First missing block (inclusive)
    pub end: N,      // Last missing block (inclusive)
    pub gap_type: BlockGapType,
}
```

### State Tracking

**Location**: `substrate/client/network/sync/src/strategy/chain_sync.rs:203-207`

```rust
struct GapSync<B: BlockT> {
    blocks: BlockCollection<B>,           // Downloaded blocks
    best_queued_number: NumberFor<B>,     // Highest imported
    target: NumberFor<B>,                 // Gap end
}

enum PeerSyncState<B: BlockT> {
    DownloadingGap(NumberFor<B>),  // Peer downloading gap blocks
    // ...
}
```

### Gap Creation

**Location**: `substrate/client/db/src/lib.rs:1760-1784`

**Warp sync gap**:
```rust
if number > best_num + 1 && parent_header_missing {
    BlockGap {
        start: best_num + 1,
        end: number - 1,
        gap_type: MissingHeaderAndBody,
    }
}
```

**Fast sync gap**:
```rust
if number == best_num + 1 && parent_header_exists && body_missing {
    BlockGap {
        start: number,
        end: number,
        gap_type: MissingBody,
    }
}
```

### Download Strategy

**Location**: `chain_sync.rs:2204-2234`

**Direction**: Descending (newest → oldest)

```
Target (999,999) → ... → Start (1)
      ↓
   Recent blocks more useful
```

**Request generation**:
```rust
fn peer_gap_block_request(...) {
    let range = blocks.needed_blocks(
        peer_id,
        max_blocks_per_request,
        min(peer.best_number, target),
        best_queued_number,
        1,                    // Only 1 peer
        MAX_DOWNLOAD_AHEAD,   // 2048 blocks
    );

    BlockRequest {
        from: FromBlock::Number(range.end - 1),
        direction: Direction::Descending,
        // ...
    }
}
```

### Request Priority

**Location**: `chain_sync.rs:1858-1920`

```
Priority (high to low):
1. Ancestor search
2. New block downloads (tip sync)
3. Fork sync
4. Gap sync ← Background, lowest priority
```

### Block Processing

**Location**: `chain_sync.rs:1169-1214`

```rust
PeerSyncState::DownloadingGap(_) => {
    // Get ready blocks
    gap_sync.blocks.ready_blocks(best_queued_number + 1)
        .map(|block| IncomingBlock {
            header: block.header,
            body: block.body,
            allow_missing_state: true,   // Critical
            skip_execution: true,        // Critical
            // ...
        })
}
```

**Import flags**:
- `allow_missing_state: true` - No parent state needed
- `skip_execution: true` - Don't execute transactions
- Result: Headers + bodies stored, no state computed

### Gap Completion

**Location**: `chain_sync.rs:723-731`

```rust
if gap_sync.target == imported_block_number {
    info!("Block history download is complete.");
    gap_sync = None;
}
```

### Flow Diagram

```
┌─────────────────────────────────────────────────────────┐
│ After Warp Sync                                         │
├─────────────────────────────────────────────────────────┤
│ [Genesis] ... [GAP: 1-999,999] ... [Block 1,000,000]  │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ Gap Sync Init                                           │
├─────────────────────────────────────────────────────────┤
│ GapSync {                                               │
│   best_queued_number: 0,                               │
│   target: 999,999,                                      │
│   blocks: BlockCollection::new()                        │
│ }                                                       │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ Download (Descending Order)                             │
├─────────────────────────────────────────────────────────┤
│ Request: 999,999 → 999,900                             │
│ Import with skip_execution=true                         │
│ Update best_queued_number = 999,999                    │
│ Request: 999,899 → 999,800                             │
│ ... (repeat)                                            │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ Complete                                                │
├─────────────────────────────────────────────────────────┤
│ [Genesis][1][2]...[999,999][1,000,000]                │
│ gap_sync = None                                         │
└─────────────────────────────────────────────────────────┘
```

### Why Descending Order?

1. Recent blocks more useful for joining validators
2. Better state cache hit rate
3. Interruption-tolerant (have newest history first)
4. Progressive utility improvement

### Storage

- **Column**: `COLUMN_META`
- **Key**: `BLOCK_GAP`
- **Value**: Scale-encoded `BlockGap<N>`
- **Persistence**: Survives node restarts

### Constraints

| Parameter | Value | Location |
|-----------|-------|----------|
| Max parallel peers | 1 | chain_sync.rs:2218 |
| Max download ahead | 2048 blocks | MAX_DOWNLOAD_AHEAD |
| Skip execution | Always | chain_sync.rs:1199 |
| Allow missing state | Always | chain_sync.rs:1197 |

### Downloaded Data

**MissingHeaderAndBody** (warp sync):
- ✓ Headers
- ✓ Bodies
- ✗ State (skip_execution=true)

**MissingBody** (fast sync):
- ✗ Headers (already have)
- ✓ Bodies
- ✗ State (skip_execution=true)

### Key Files

- `substrate/primitives/blockchain/src/backend.rs:557-564` - BlockGap definition
- `substrate/client/network/sync/src/strategy/chain_sync.rs` - Core logic
- `substrate/client/db/src/lib.rs:1760-1784` - Gap detection/storage
- `substrate/client/network/sync/src/blocks.rs` - BlockCollection

---

## Sync Strategy Overview

```
┌──────────────────────────────────────────────────────────┐
│                  Sync Strategies                         │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  1. WarpSync (if enabled)                               │
│     ├─ Download authority set change proofs             │
│     ├─ Verify GRANDPA justifications                    │
│     └─ Result: Target header + Creates gap              │
│                     ↓                                    │
│  2. StateStrategy                                        │
│     ├─ Download state snapshot at target               │
│     └─ Result: Node operational                         │
│                     ↓                                    │
│  3. ChainSync (always final)                            │
│     ├─ Download new blocks                              │
│     └─ Keep-up sync                                     │
│                     ↓                                    │
│  4. GapSync (parallel background)                       │
│     ├─ Fill historical blocks                           │
│     ├─ Low priority                                     │
│     └─ Descending order                                 │
│                                                          │
└──────────────────────────────────────────────────────────┘

Timeline:
WarpSync:    [████] 3 min
StateSync:        [██████] 5 min
ChainSync:               [████████████████] ongoing
GapSync:                 [░░░░░░░░░░░░░░░░] hours (background)
```

**Block Import**: See [block-import-mechanism.md](./block-import-mechanism.md)
- Two-phase: Verification → Import
- Handles all block types (normal, gap, state sync)
- Sequential processing with yielding
