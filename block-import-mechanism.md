# Block Import Mechanism

Two-phase pipeline for block verification and persistence.

---

## Architecture

```
Network → ImportQueue → Verifier → BlockImport → Database
            ↓              ↓           ↓
         Buffering    Consensus    Persistence
                       Checks
```

**Phases**:
1. **Verification**: Consensus-specific validation
2. **Import**: Database persistence + state computation

---

## Core Components

### 1. BlockImport Trait

**Location**: `substrate/client/consensus/common/src/block_import.rs:306-317`

```rust
#[async_trait::async_trait]
pub trait BlockImport<B: BlockT> {
    type Error: std::error::Error + Send + 'static;

    async fn check_block(&self, block: BlockCheckParams<B>)
        -> Result<ImportResult, Self::Error>;

    async fn import_block(&self, block: BlockImportParams<B>)
        -> Result<ImportResult, Self::Error>;
}
```

### 2. ImportQueue

**Location**: `substrate/client/consensus/common/src/import_queue.rs:125-142`

**Role**: Orchestrates verification and import

**Default**: `BasicQueue` (sequential, background worker)
- Location: `basic_queue.rs:44`
- Yields after each block for responsiveness
- Channel capacity: 100,000 items

### 3. Verifier Trait

**Location**: `import_queue.rs:99-104`

```rust
#[async_trait::async_trait]
pub trait Verifier<B: BlockT>: Send + Sync {
    async fn verify(&self, block: BlockImportParams<B>)
        -> Result<BlockImportParams<B>, String>;
}
```

**Implementations**:
- **AuraVerifier**: Slot numbers, seal signatures
- **BabeVerifier**: VRF proofs, epoch data
- **GRANDPA**: Wraps others, adds finality tracking

### 4. BlockImportParams

**Location**: `block_import.rs:170-221`

```rust
pub struct BlockImportParams<Block: BlockT> {
    pub origin: BlockOrigin,                      // Network/File/Own
    pub header: Block::Header,                    // Pre-runtime (no post-digests)
    pub post_digests: Vec<DigestItem>,            // Post-runtime (seals)
    pub body: Option<Vec<Block::Extrinsic>>,
    pub justifications: Option<Justifications>,
    pub state_action: StateAction<Block>,
    pub finalized: bool,
    pub intermediates: HashMap<...>,              // Consensus metadata
    pub fork_choice: Option<ForkChoiceStrategy>,
    pub import_existing: bool,
    pub create_gap: bool,
}
```

### 5. StateAction

**Location**: `block_import.rs:145-154`

```rust
pub enum StateAction<Block: BlockT> {
    Execute,                          // Execute block body
    ExecuteIfPossible,                // Execute if parent state available
    ApplyChanges(StorageChanges),     // Use precomputed state
    Skip,                             // Header-only (no execution)
}
```

**Usage**:
- `Execute`: Normal blocks
- `ApplyChanges`: After warp/state sync
- `Skip`: Gap sync blocks

### 6. ImportResult

**Location**: `block_import.rs:30-43`

```rust
pub enum ImportResult {
    Imported(ImportedAux),    // Success
    AlreadyInChain,           // Duplicate
    KnownBad,                 // Block/parent bad
    UnknownParent,            // Parent missing
    MissingState,             // Parent state unavailable
}
```

---

## Import Pipeline

```
┌──────────────────────────────────────────────────────┐
│ 1. Block Arrives from Network                       │
└────────────────────┬─────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────┐
│ 2. ImportQueue::import_blocks()                     │
│    → Send to background worker via channel           │
└────────────────────┬─────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────┐
│ 3. Background Worker: block_import_process()        │
│    → Loop: await blocks from channel                │
└────────────────────┬─────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────┐
│ 4. Sequential Import: import_many_blocks()          │
│    For each block:                                   │
│      ├─ Phase 1: verify_single_block_metered()     │
│      ├─ Phase 2: import_single_block_metered()     │
│      └─ Yield: futures::pending!()                  │
└────────────────────┬─────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────┐
│ 5. Results: BufferedLink::blocks_processed()        │
│    → Report to sync engine                          │
└──────────────────────────────────────────────────────┘
```

### Step-by-Step Flow

**Location**: `basic_queue.rs:223-449`

```rust
// Background worker
async fn block_import_process(...) {
    loop {
        let ImportBlocks(origin, blocks) = receiver.next().await;
        let result = import_many_blocks(
            block_import, origin, blocks, verifier, metrics
        ).await;
        sender.blocks_processed(result.imported, result.count, result.results);
    }
}

// Sequential processing
async fn import_many_blocks(...) {
    for block in blocks {
        // Phase 1: Verify
        let verified = verify_single_block_metered(...).await?;

        // Phase 2: Import
        let result = match verified {
            Verified(params) => import_single_block_metered(params).await,
            Imported(status) => Ok(status),
        };

        // Yield to other tasks (critical!)
        futures::pending!();
    }
}
```

**Why sequential?** Block N+1 depends on state of block N.

**Why yield?** Keeps node responsive (network, RPC).

---

## Verification Phase

**Consensus-specific checks**:
- Block structure validation
- Seal/signature verification
- Authority permissions
- Equivocation detection
- Weight/difficulty checks

**Example (Aura verifier)**:
```rust
async fn verify(&self, params: BlockImportParams) -> Result<...> {
    // Extract slot from pre-digest
    let slot = find_pre_digest(&params.header)?;

    // Check slot validity
    if slot > current_slot() { return Err("Future block"); }

    // Get authorities
    let authorities = self.authorities_at(&params.header.parent_hash())?;

    // Calculate expected author
    let author_idx = *slot % authorities.len();

    // Verify seal
    verify_seal(&params.header, &authorities[author_idx])?;

    // Set fork choice
    params.fork_choice = Some(ForkChoiceStrategy::LongestChain);

    Ok(params)
}
```

---

## Import Phase

**Database operations**:
1. Check parent exists
2. Execute block or apply state
3. Write header + body
4. Apply state changes
5. Store justifications
6. Update best block (if fork choice says so)
7. Commit transaction

**Pseudocode**:
```rust
async fn import_block(&self, params: BlockImportParams) -> Result<ImportResult> {
    // 1. Check parent
    if !parent_exists(params.header.parent_hash()) {
        return Ok(ImportResult::UnknownParent);
    }

    // 2. Compute state
    let state = match params.state_action {
        Execute => execute_block(&params)?,
        ApplyChanges(changes) => changes,
        Skip => None,
    };

    // 3. Write to DB
    let mut tx = db.transaction();
    tx.set_header(params.hash(), params.header);
    if let Some(body) = params.body {
        tx.set_body(params.hash(), body);
    }
    if let Some(state) = state {
        tx.apply_state(state);
    }

    // 4. Update best
    let is_new_best = match params.fork_choice {
        Some(LongestChain) => params.number > best_number(),
        Some(Custom(is_best)) => is_best,
        None => return Err("Fork choice not set"),
    };

    if is_new_best {
        tx.set_best_block(params.hash());
    }

    // 5. Commit
    db.commit(tx)?;

    Ok(ImportResult::Imported(ImportedAux { is_new_best, ... }))
}
```

---

## Special Features

### 1. Consensus Pipeline Stacking

Multiple `BlockImport` layers:

```
Network Block
    ↓
┌──────────────────┐
│ BabeBlockImport  │ ← BABE validation
└────────┬─────────┘
         ↓
┌──────────────────┐
│GrandpaBlockImport│ ← Finality tracking
└────────┬─────────┘
         ↓
┌──────────────────┐
│     Client       │ ← Database write
└──────────────────┘
```

Each layer:
1. Processes its data
2. Adds/removes `intermediates`
3. Passes to next layer

### 2. Intermediates (Layer Communication)

**Location**: `block_import.rs:202`

```rust
pub intermediates: HashMap<Cow<'static, [u8]>, Box<dyn Any + Send>>
```

**Usage**:
```rust
// Layer 1: Write
params.insert_intermediate(b"babe_epoch", epoch_data);

// Layer 2: Read
let epoch = params.get_intermediate::<EpochData>(b"babe_epoch")?;

// Final layer: Verify consumed
if !params.intermediates.is_empty() {
    return Err("Unhandled intermediates");
}
```

### 3. Justification Import

**Location**: `block_import.rs:351-367`

Separate trait for finality proofs:

```rust
#[async_trait::async_trait]
pub trait JustificationImport<B: BlockT> {
    async fn on_start(&mut self) -> Vec<(B::Hash, NumberFor<B>)>;

    async fn import_justification(
        &mut self,
        hash: B::Hash,
        number: NumberFor<B>,
        justification: Justification,
    ) -> Result<(), Self::Error>;
}
```

**Implementation**: GRANDPA (finalizes blocks)

---

## Error Handling

**Location**: `import_queue.rs:189-219`

```rust
pub enum BlockImportError {
    IncompleteHeader(Option<PeerId>),
    VerificationFailed(Option<PeerId>, String),
    BadBlock(Option<PeerId>),
    MissingState,
    UnknownParent,
    Cancelled,
    Other(ConsensusError),
}
```

**Actions**:
| Error | Action |
|-------|--------|
| `UnknownParent` | Queue block, request parent |
| `VerificationFailed` | Reject block, penalize peer |
| `BadBlock` | Blacklist block, ban peer |
| `MissingState` | Trigger state sync |
| `Cancelled` | Parent failed, abort sequence |

**Sequential halt**:
```rust
if has_error {
    // Cancel remaining blocks in batch
    Err(BlockImportError::Cancelled)
}
```

---

## Special Import Scenarios

### 1. State Sync

```rust
IncomingBlock {
    state: Some(ImportedState { block: hash, state: kvs }),
    allow_missing_state: true,
    skip_execution: true,
    // ...
}
```

State applied directly, no execution.

### 2. Gap Sync

```rust
IncomingBlock {
    allow_missing_state: true,
    skip_execution: true,
    // ...
}
```

Headers + bodies stored, no state computation.

### 3. Header-Only

```rust
BlockImportParams {
    body: None,
    state_action: StateAction::Skip,
    // ...
}
```

Only header verified and stored.

---

## Fork Choice

**Location**: `block_import.rs:95-102`

```rust
pub enum ForkChoiceStrategy {
    LongestChain,        // Nakamoto consensus
    Custom(bool),        // Custom rule (true = make best)
}
```

Set by verifier, used by importer to update best block.

---

## Performance

**Design choices**:
1. **Sequential processing**: Required for state consistency
2. **Yielding**: `futures::pending!()` after each block
3. **Bounded channels**: 100k capacity prevents memory exhaustion
4. **Background worker**: Dedicated task for import
5. **Metrics**: Track import time, throughput

**Throughput**: Limited by:
- Block execution time
- Database write speed
- State computation

---

## Complete Flow Diagram

```
┌─────────────────────────────────────────────────────────┐
│                Block Import Pipeline                     │
└─────────────────────────────────────────────────────────┘

Network Blocks
      │
      ▼
┌───────────────────┐
│  Import Queue     │
│  (BasicQueue)     │ ← Buffers blocks
│                   │ ← Spawns background worker
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ block_import_     │
│ process()         │ ← Loop: await blocks
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ import_many_      │
│ blocks()          │ ← Sequential processing
└─────────┬─────────┘
          │
          ├──────────────────────┐
          ▼                      ▼
┌───────────────────┐  ┌───────────────────┐
│   VERIFICATION    │  │      IMPORT       │
│   (Verifier)      │  │  (BlockImport)    │
│                   │  │                   │
│ • Consensus seal  │  │ • Execute block   │
│ • Authority check │  │ • Apply state     │
│ • Equivocation    │  │ • Write to DB     │
│ • Fork choice     │  │ • Update best     │
└─────────┬─────────┘  └─────────┬─────────┘
          │                      │
          └──────────┬───────────┘
                     ▼
          ┌───────────────────┐
          │   ImportResult    │
          └─────────┬─────────┘
                    ▼
          ┌───────────────────┐
          │  Link::blocks_    │
          │  processed()      │ ← Report to sync engine
          └───────────────────┘
```

---

## Key Files

| File | Purpose |
|------|---------|
| `substrate/client/consensus/common/src/block_import.rs` | Core traits |
| `substrate/client/consensus/common/src/import_queue.rs` | Queue infrastructure |
| `substrate/client/consensus/common/src/import_queue/basic_queue.rs` | Default impl |
| `substrate/client/consensus/common/src/import_queue/buffered_link.rs` | Result channel |
| `substrate/client/service/src/client/block_import.rs` | DB importer |
| `substrate/client/consensus/grandpa/src/import.rs` | GRANDPA wrapper |
| `substrate/client/consensus/aura/src/import_queue.rs` | Aura verifier |
