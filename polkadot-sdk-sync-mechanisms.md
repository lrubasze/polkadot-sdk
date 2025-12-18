# Polkadot SDK Synchronization Mechanisms

A comprehensive guide to understanding warp sync, block import, and gap sync in the Polkadot SDK.

---

## Table of Contents

1. [Warp Sync](#warp-sync)
2. [Gap Sync](#gap-sync)

**Note**: For detailed information about the Block Import Mechanism, see [block-import-mechanism.md](./block-import-mechanism.md)

---

# Warp Sync

Warp sync is a fast blockchain synchronization method that allows new nodes to catch up to the current state by downloading only cryptographic proofs of authority set changes, rather than verifying every block header.

## Core Concept

Instead of downloading and verifying every block from genesis, warp sync downloads **GRANDPA finality proofs** that prove the handoff between validator sets. This dramatically reduces sync time from hours to minutes.

## Key Components

### 1. WarpSyncFragment

**Location**: `substrate/client/consensus/grandpa/src/warp_proof.rs:62`

Each fragment proves one authority set transition:

```rust
pub struct WarpSyncFragment<Block: BlockT> {
    pub header: Block::Header,           // Block that finalized an authority set change
    pub justification: GrandpaJustification<Block>,  // Proof of finality
}
```

### 2. WarpSyncProof

**Location**: `substrate/client/consensus/grandpa/src/warp_proof.rs:73`

A collection of fragments representing the chain of authority set changes:

```rust
pub struct WarpSyncProof<Block: BlockT> {
    proofs: Vec<WarpSyncFragment<Block>>,
    is_finished: bool,  // Whether we've reached current authorities
}
```

## The Warp Sync Process

### Phase 1: Waiting for Peers

**Location**: `substrate/client/network/sync/src/strategy/warp.rs:48`

- Requires **minimum 3 peers** to start (`MIN_PEERS_TO_START_WARP_SYNC`)
- Ensures network reliability and prevents single-peer attacks

### Phase 2: Downloading Warp Proofs

**Location**: `substrate/client/network/sync/src/strategy/warp.rs:116-117`

The state machine progresses through:

```rust
enum Phase<B: BlockT> {
    WaitingForPeers { warp_sync_provider: Arc<dyn WarpSyncProvider<B>> },
    WarpProof {
        set_id: SetId,              // Current authority set ID
        authorities: AuthorityList,  // Current validator set
        last_hash: B::Hash,         // Last verified block
        warp_sync_provider: Arc<dyn WarpSyncProvider<B>>,
    },
    TargetBlock(B::Header),
    Complete,
}
```

**How proof generation works** (`substrate/client/consensus/grandpa/src/warp_proof.rs:82-197`):

1. Start from the requested block
2. Iterate through all authority set changes
3. For each change, collect:
   - The **header** of the last block finalized by that set
   - The **GRANDPA justification** proving finality
4. Stop when:
   - Max proof size reached (8 MB - `warp_proof.rs:58`)
   - Current authority set reached

### Phase 3: Verification

**Location**: `substrate/client/consensus/grandpa/src/warp_proof.rs:199-246`

For each fragment:

1. **Verify the GRANDPA justification** against current authority set
2. **Extract next authority set** from the block's digest
3. **Advance to next set_id**
4. **Repeat** until all fragments processed

The verification returns:

```rust
pub enum VerificationResult<Block: BlockT> {
    Partial(SetId, AuthorityList, Block::Hash),    // Need more proofs
    Complete(SetId, AuthorityList, Block::Header), // Reached target!
}
```

### Phase 4: Downloading Target Block

**Location**: `substrate/client/network/sync/src/strategy/warp.rs:118`

After verifying the authority chain, download:
- Target block header
- Target block body
- Target justifications

### Phase 5: State Download

The `PolkadotSyncingStrategy` transitions to `StateStrategy` to download the state snapshot at the target block.

## Why Warp Sync is Fast

**Traditional sync:** Verify every block header from genesis to current
- Genesis → Block 1 → Block 2 → ... → Block 10,000,000 ✓

**Warp sync:** Verify only authority set changes
- Genesis → Set change #1 (block 100,000) → Set change #2 (block 500,000) → Set change #3 (block 2,000,000) → Current ✓

If authority sets change every 100,000 blocks and you have 10 million blocks, you only verify **~100 blocks** instead of 10 million!

## Security Model

Warp sync is cryptographically secure because:

1. **GRANDPA finality proofs** are signed by 2/3+ of the authority set
2. Each authority set **signs off** on the next authority set via the block digest
3. The **chain of authority handoffs** creates an unbroken chain of trust from genesis
4. Any invalid proof fails verification

## Protocol Details

**Network protocol:** `/{genesis_hash}/sync/warp`

**Request format:**
```rust
pub struct WarpProofRequest<B: BlockT> {
    pub begin: B::Hash,  // Start collecting proofs from this block
}
```

**Response:** Scale-encoded `WarpSyncProof` (max 8 MB)

## Integration with Sync Strategy

The full sync pipeline:

```
1. WarpSync (if enabled)
   ↓
2. StateStrategy (download state snapshot)
   ↓
3. ChainSync (download remaining blocks + keep-up sync)
```

If warp sync fails, it falls back gracefully to full `ChainSync`.

## Example: Authority Set Changes

Imagine a chain with these authority set changes:

```
Block 0 (Genesis): Set 0 [Alice, Bob, Charlie]
Block 100,000: Set 1 [Dave, Eve, Frank]  ← Fragment 1
Block 500,000: Set 2 [Grace, Henry, Ivan] ← Fragment 2
Block 2,000,000: Set 3 [Jack, Kate, Leo] ← Fragment 3 (current)
```

**Warp sync downloads:**
- Fragment 1: Header(100,000) + Justification(signed by Set 0)
- Fragment 2: Header(500,000) + Justification(signed by Set 1)
- Fragment 3: Header(2,000,000) + Justification(signed by Set 2)

**Total: 3 blocks instead of 2,000,000!**

## Key Files

- `substrate/client/network/sync/src/strategy/warp.rs:1-1659` - Main state machine
- `substrate/client/consensus/grandpa/src/warp_proof.rs:1-400` - Proof generation/verification
- `substrate/client/network/sync/src/warp_request_handler.rs` - Network request handler
- `substrate/client/network/sync/src/strategy/polkadot.rs` - Strategy orchestration

---

# Gap Sync

Gap sync is a background synchronization mechanism that fills in missing blocks after warp sync or fast sync operations.

## What is Gap Sync?

A **gap** is a range of consecutive missing blocks in the blockchain database that results from:
- **Warp Sync**: Skips from genesis to a recent finalized block, leaving headers AND bodies missing
- **Fast Sync**: Downloads headers but skips bodies for older blocks

Gap sync runs **in the background** after these fast sync methods complete, progressively downloading the missing historical blocks.

## Gap Data Structures

### 1. BlockGap Definition

**Location**: `substrate/primitives/blockchain/src/backend.rs:557-564`

```rust
pub enum BlockGapType {
    MissingHeaderAndBody,  // Result of warp sync
    MissingBody,           // Result of fast sync
}

pub struct BlockGap<N> {
    pub start: N,    // First missing block (inclusive)
    pub end: N,      // Last missing block (inclusive)
    pub gap_type: BlockGapType,
}
```

### 2. GapSync State

**Location**: `substrate/client/network/sync/src/strategy/chain_sync.rs:203-207`

```rust
struct GapSync<B: BlockT> {
    blocks: BlockCollection<B>,           // Downloaded gap blocks awaiting import
    best_queued_number: NumberFor<B>,     // Highest imported gap block
    target: NumberFor<B>,                 // Gap end - when to stop
}
```

Stored in `ChainSync` (chain_sync.rs:341):
```rust
gap_sync: Option<GapSync<B>>  // None when no gap exists
```

### 3. Peer State

**Location**: `chain_sync.rs:283`

```rust
enum PeerSyncState<B: BlockT> {
    DownloadingGap(NumberFor<B>),  // Peer downloading gap blocks
    // ... other states
}
```

## How Gaps Are Created

Gaps are detected and created during block import in the database layer.

**Location**: `substrate/client/db/src/lib.rs:1760-1784`

### Scenario 1: Warp Sync Creates a Gap

```rust
if operation.create_gap {
    if number > best_num + One::one() &&
       self.blockchain.header(parent_hash)?.is_none() {
        // Block is disconnected from chain tip
        let gap = BlockGap {
            start: best_num + One::one(),
            end: number - One::one(),
            gap_type: BlockGapType::MissingHeaderAndBody,
        };
        insert_new_gap(&mut transaction, gap, &mut block_gap);
    }
}
```

**Example**: After warp sync jumps from genesis to block 1,000,000:
```
Genesis (0) ... [GAP: blocks 1-999,999] ... Warp Target (1,000,000)
```

### Scenario 2: Fast Sync Creates a Body-Only Gap

```rust
else if number == best_num + One::one() &&
         self.blockchain.header(parent_hash)?.is_some() &&
         !existing_body {
    let gap = BlockGap {
        start: number,
        end: number,
        gap_type: BlockGapType::MissingBody,
    };
    insert_new_gap(&mut transaction, gap, &mut block_gap);
}
```

**When `create_gap` is set:**
- During warp sync state import
- When importing disconnected blocks
- Default: `true` (substrate/client/db/src/lib.rs:2131)

## Gap Sync Initialization

When ChainSync starts or restarts, it checks for gaps.

**Location**: `chain_sync.rs:1707-1714`

```rust
fn reset_sync_start_point(&mut self) -> Result<(), ClientError> {
    let info = self.client.info();

    if let Some(BlockGap { start, end, .. }) = info.block_gap {
        debug!(target: LOG_TARGET, "Starting gap sync #{start} - #{end}");
        self.gap_sync = Some(GapSync {
            best_queued_number: start - One::one(),
            target: end,
            blocks: BlockCollection::new(),
        });
    }
    Ok(())
}
```

## Gap Sync Download Strategy

### Request Generation

**Location**: `chain_sync.rs:2204-2234`

Gap blocks are requested via `peer_gap_block_request`:

```rust
fn peer_gap_block_request<B: BlockT>(
    id: &PeerId,
    peer: &PeerSync<B>,
    blocks: &mut BlockCollection<B>,
    attrs: BlockAttributes,
    target: NumberFor<B>,           // Gap end
    common_number: NumberFor<B>,    // best_queued_number
    max_blocks_per_request: u32,
) -> Option<(Range<NumberFor<B>>, BlockRequest<B>)> {
    // Calculate needed block range
    let range = blocks.needed_blocks(
        *id,
        max_blocks_per_request,
        std::cmp::min(peer.best_number, target),
        common_number,
        1,                    // Only 1 peer downloads gap at a time
        MAX_DOWNLOAD_AHEAD,   // 2048 blocks ahead max
    )?;

    // Request in DESCENDING order (newest to oldest)
    let last = range.end.saturating_sub(One::one());
    let request = BlockRequest::<B> {
        from: FromBlock::Number(last),
        direction: Direction::Descending,  // Important!
        max: Some((range.end - range.start).saturated_into::<u32>()),
        // ...
    };
    Some((range, request))
}
```

**Key characteristics:**
- **Direction**: `Descending` (downloads from newest to oldest)
- **Max parallel peers**: `1` (conservative to avoid overload)
- **Max lookahead**: `2048 blocks` (MAX_DOWNLOAD_AHEAD)
- **Priority**: Lower than new block sync, higher than ancestor search

### Request Priority

**Location**: `chain_sync.rs:1858-1920`

Gap requests are generated after other sync operations:

```
Request Generation Order:
1. Ancestor search requests (find common blocks)
2. New block downloads (DownloadingNew - tip sync)
3. Fork sync requests (DownloadingStale - alternative chains)
4. Gap sync requests (DownloadingGap - background history fill) ← HERE
```

Code (simplified):
```rust
// Line 1897-1907
if let Some((range, req)) = gap_sync.as_mut().and_then(|sync| {
    peer_gap_block_request(
        &id, peer, &mut sync.blocks, attrs,
        sync.target, sync.best_queued_number, max_blocks_per_request,
    )
}) {
    peer.state = PeerSyncState::DownloadingGap(range.start);
    trace!(target: LOG_TARGET, "New gap block request for {}", id);
    Some((id, req))
}
```

## Processing Gap Blocks

When gap blocks arrive:

**Location**: `chain_sync.rs:1169-1214`

```rust
PeerSyncState::DownloadingGap(_) => {
    peer.state = PeerSyncState::Available;

    if let Some(gap_sync) = &mut self.gap_sync {
        gap_sync.blocks.clear_peer_download(peer_id);

        // Validate and insert blocks
        if let Some(start_block) = validate_blocks::<B>(&blocks, peer_id, Some(request))? {
            gap_sync.blocks.insert(start_block, blocks, *peer_id);
        }

        // Get ready blocks for import
        let blocks: Vec<_> = gap_sync.blocks
            .ready_blocks(gap_sync.best_queued_number + One::one())
            .into_iter()
            .map(|block_data| {
                IncomingBlock {
                    hash: block_data.block.hash,
                    header: block_data.block.header,
                    body: block_data.block.body,
                    justifications: ...,
                    origin: block_data.origin,

                    // CRITICAL FLAGS FOR GAP BLOCKS:
                    allow_missing_state: true,   // Skip state checks
                    skip_execution: true,        // Don't execute transactions
                    import_existing: self.import_existing,

                    state: None,
                }
            })
            .collect();

        debug!(target: LOG_TARGET, "Drained {} gap blocks from {}",
               blocks.len(), gap_sync.best_queued_number);

        blocks
    }
}
```

**Critical import flags:**
- `allow_missing_state: true` - Allows import without parent state
- `skip_execution: true` - Doesn't execute block bodies (history only)
- These flags tell the import queue to store blocks without full validation

## Gap Completion

After each successful import:

**Location**: `chain_sync.rs:723-731`

```rust
let gap_sync_complete =
    self.gap_sync.as_ref().map_or(false, |s| s.target == number);

if gap_sync_complete {
    info!(target: LOG_TARGET, "Block history download is complete.");
    self.gap_sync = None;  // Clear gap sync state
}
```

When `best_queued_number` reaches `target`, gap sync is complete!

## Interaction with Database

### Gap Storage

Gaps are persisted in the database:
- **Column**: `COLUMN_META`
- **Key**: `BLOCK_GAP`
- **Value**: Encoded `BlockGap<N>`

### Gap Updates

As gap blocks are imported:
1. Database detects the gap is shrinking
2. Updates `block_gap` metadata
3. Eventually clears the gap when filled

## Complete Gap Sync Flow

### Phase 1: Gap Detection (After Warp Sync)
```
Warp Sync completes at block 1,000,000
    ↓
Database detects gap: blocks 1-999,999
    ↓
Stores BlockGap { start: 1, end: 999,999, type: MissingHeaderAndBody }
```

### Phase 2: Gap Sync Initialization
```
ChainSync.reset_sync_start_point() called
    ↓
Reads info.block_gap from database
    ↓
Creates GapSync { best_queued_number: 0, target: 999,999, blocks: ... }
```

### Phase 3: Progressive Download
```
Request blocks 999,999 → 999,900 (descending)
    ↓
Receive blocks
    ↓
Import blocks (with skip_execution=true, allow_missing_state=true)
    ↓
Update best_queued_number to 999,999
    ↓
Request blocks 999,899 → 999,800
    ↓
... (repeat)
```

### Phase 4: Completion
```
best_queued_number reaches target (999,999)
    ↓
Gap sync complete!
    ↓
gap_sync = None
    ↓
Database clears block_gap metadata
```

## Why Descending Order?

Gap blocks are downloaded **newest to oldest** because:
1. **Recent blocks are more useful** for validators joining the network
2. **State availability** - newer blocks have state more likely cached
3. **Interruption tolerance** - if interrupted, you have the most recent history
4. **Progressive benefit** - node becomes more useful as download progresses

## Constraints and Limits

| Parameter | Value | Location |
|-----------|-------|----------|
| Max parallel peers | 1 | chain_sync.rs:2218 |
| Max download ahead | 2048 blocks | MAX_DOWNLOAD_AHEAD |
| Max blocks per request | Configurable (typically 128) | |
| Skip execution | Yes (always) | chain_sync.rs:1199 |
| Allow missing state | Yes (always) | chain_sync.rs:1197 |

## Visual Summary

```
Initial State After Warp Sync:
[Block 0] ... [GAP: 1-999,999] ... [Block 1,000,000] ← Best

Gap Sync Active (downloads in descending order):
[Block 0] ... [GAP: 1-999,799] [Downloaded: 999,800-999,999] [Block 1,000,000]
                                              ↑
                                    best_queued_number = 999,999

Gap Sync Complete:
[Block 0] [Block 1] [Block 2] ... [Block 999,999] [Block 1,000,000]
                                           ↑
                                  gap_sync = None
```

## Key Takeaways

1. **Non-blocking**: Gap sync runs in the background while the node stays synchronized with the chain tip
2. **Resource-efficient**: Uses only 1 peer, skips execution, allows missing state
3. **Persistent**: Gap metadata survives restarts
4. **Descending order**: Downloads newest blocks first for maximum utility
5. **Automatic**: Triggered automatically when `block_gap` is detected
6. **Lower priority**: Normal syncing takes precedence over gap filling

Gap sync elegantly solves the problem of "how do I use warp sync to get running quickly, but still have full block history eventually?"

## Key Files

- `substrate/primitives/blockchain/src/backend.rs:557-564` - BlockGap definition
- `substrate/client/network/sync/src/strategy/chain_sync.rs` - Core gap sync logic
- `substrate/client/db/src/lib.rs:1760-1784` - Gap detection and storage
- `substrate/client/network/sync/src/blocks.rs` - BlockCollection for gap blocks

---

## Summary: The Complete Sync Picture

1. **Warp Sync** (fast initial sync)
   - Downloads only authority set change proofs
   - Reaches current state in minutes
   - Creates a gap in block history

2. **State Download** (after warp sync)
   - Downloads the full state at the target block
   - Enables the node to become operational

3. **Chain Sync** (keep-up sync)
   - Downloads new blocks as they're produced
   - Keeps the node synchronized with the network tip

4. **Gap Sync** (background history fill)
   - Runs in parallel with chain sync
   - Progressively downloads missing historical blocks
   - Low priority, resource-efficient

5. **Block Import** (the engine) - See [block-import-mechanism.md](./block-import-mechanism.md)
   - Two-phase verification and import pipeline
   - Handles all types of blocks (normal, gap, state sync)
   - Provides flexible state computation strategies

Together, these mechanisms enable Polkadot nodes to quickly join the network while eventually acquiring full block history, all without disrupting live synchronization.
