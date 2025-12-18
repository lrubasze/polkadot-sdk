# Block Import Mechanism

The block import mechanism is a sophisticated pipeline that handles verification and persistence of blocks received from the network.

## Core Architecture

The block import system follows a **two-phase architecture**:
1. **Verification Phase** - Consensus-specific validation
2. **Import Phase** - Persistence to the database

## Key Components

### 1. BlockImport Trait

**Location**: `substrate/client/consensus/common/src/block_import.rs:306-317`

The fundamental trait that all block importers must implement:

```rust
#[async_trait::async_trait]
pub trait BlockImport<B: BlockT> {
    type Error: std::error::Error + Send + 'static;

    /// Check block preconditions
    async fn check_block(&self, block: BlockCheckParams<B>) -> Result<ImportResult, Self::Error>;

    /// Import a block
    async fn import_block(&self, block: BlockImportParams<B>) -> Result<ImportResult, Self::Error>;
}
```

### 2. ImportQueue

**Location**: `substrate/client/consensus/common/src/import_queue.rs:125-142`

The orchestrator that manages the entire import process. The queue:
- Receives blocks from the network
- Coordinates verification and import
- Reports results back to the sync engine
- Handles both blocks and justifications

**Default Implementation**: `BasicQueue`
- **Location**: `substrate/client/consensus/common/src/import_queue/basic_queue.rs:44`
- Imports blocks **sequentially** in a background task
- Yields after each block for responsiveness
- Uses unbounded channels for communication

### 3. Verifier Trait

**Location**: `substrate/client/consensus/common/src/import_queue.rs:99-104`

Consensus-specific verification logic:

```rust
#[async_trait::async_trait]
pub trait Verifier<B: BlockT>: Send + Sync {
    /// Verify the given block data and return the BlockImportParams
    async fn verify(&self, block: BlockImportParams<B>)
        -> Result<BlockImportParams<B>, String>;
}
```

Each consensus engine provides its own verifier:
- **Aura**: `AuraVerifier` - validates slot numbers and seals
- **BABE**: `BabeVerifier` - validates VRF proofs and slot claims
- **GRANDPA**: Wraps other verifiers to add finality checks

### 4. BlockImportParams

**Location**: `substrate/client/consensus/common/src/block_import.rs:170-221`

The complete data package for importing a block:

```rust
pub struct BlockImportParams<Block: BlockT> {
    pub origin: BlockOrigin,           // Where block came from (network/file/own)
    pub header: Block::Header,         // Pre-runtime header (no post-digests)
    pub justifications: Option<Justifications>,  // Finality proofs
    pub post_digests: Vec<DigestItem>, // Post-runtime digests (seals, signatures)
    pub body: Option<Vec<Block::Extrinsic>>,
    pub state_action: StateAction<Block>,  // How to compute new state
    pub finalized: bool,               // Instant finality flag
    pub intermediates: HashMap<...>,   // Consensus metadata
    pub fork_choice: Option<ForkChoiceStrategy>,
    // ... more fields
}
```

### 5. StateAction

**Location**: `substrate/client/consensus/common/src/block_import.rs:145-154`

Controls how the new state is computed:

```rust
pub enum StateAction<Block: BlockT> {
    ApplyChanges(StorageChanges<Block>),  // Use precomputed state
    Execute,                               // Must execute block body
    ExecuteIfPossible,                     // Execute if parent state available
    Skip,                                  // Don't execute (header-only sync)
}
```

### 6. ImportResult

**Location**: `substrate/client/consensus/common/src/block_import.rs:30-43`

The outcome of an import attempt:

```rust
pub enum ImportResult {
    Imported(ImportedAux),    // Successfully imported
    AlreadyInChain,           // Duplicate block
    KnownBad,                 // Block or parent is bad
    UnknownParent,            // Parent not in chain
    MissingState,             // Parent state unavailable
}
```

## The Import Pipeline Flow

### Step 1: Blocks Enter the Queue

When the sync engine receives blocks from the network:

```rust
// substrate/client/consensus/common/src/import_queue/basic_queue.rs:127-143
fn import_blocks(&mut self, origin: BlockOrigin, blocks: Vec<IncomingBlock<B>>) {
    self.block_import_sender.unbounded_send(
        worker_messages::ImportBlocks(origin, blocks)
    );
}
```

### Step 2: Background Worker Processes Blocks

The `block_import_process` runs in a background task:

**Location**: `basic_queue.rs:223-248`

```rust
async fn block_import_process<B: BlockT>(
    mut block_import: BoxBlockImport<B>,
    verifier: impl Verifier<B>,
    result_sender: BufferedLinkSender<B>,
    mut block_import_receiver: TracingUnboundedReceiver<...>,
) {
    loop {
        let ImportBlocks(origin, blocks) = block_import_receiver.next().await;
        let res = import_many_blocks(&mut block_import, origin, blocks, &verifier, ...).await;
        result_sender.blocks_processed(res.imported, res.block_count, res.results);
    }
}
```

### Step 3: Sequential Import

`import_many_blocks` processes blocks sequentially:

**Location**: `basic_queue.rs:386-449`

```rust
async fn import_many_blocks(...) -> ImportManyBlocksResult<B> {
    for block in blocks {
        // Phase 1: Verify
        let verification_result = verify_single_block_metered(
            import_handle, blocks_origin, block, verifier, metrics
        ).await;

        // Phase 2: Import
        match verification_result {
            Ok(Verified(params)) => {
                import_single_block_metered(import_handle, params, metrics).await
            },
            Ok(Imported(status)) => Ok(status),  // Already imported during verification
            Err(e) => Err(e),
        }

        // Yield to other futures
        futures::pending!();
    }
}
```

**Key behavior**: After each block, the function yields control to ensure responsiveness.

### Step 4: Verification

The verifier performs consensus-specific checks:
- **Block structure validation**
- **Consensus seal verification** (signatures, VRF proofs)
- **Block difficulty/weight checks**
- **Equivocation detection**
- **Authority permissions**

### Step 5: Import to Database

The `BlockImport` implementation persists the block:
- **Write block header and body** to storage
- **Apply state changes** (execute or use precomputed)
- **Update best block** if fork choice indicates
- **Store justifications** for finality
- **Update aux data** (consensus metadata)

### Step 6: Results Communicated

Results flow back through `BufferedLink`:

**Location**: `substrate/client/consensus/common/src/import_queue.rs:147-154`

```rust
pub trait Link<B: BlockT>: Send + Sync {
    fn blocks_processed(
        &self,
        imported: usize,
        count: usize,
        results: Vec<(BlockImportResult<B>, B::Hash)>,
    );

    fn justification_imported(&self, who: RuntimeOrigin, hash: &B::Hash, ...);
    fn request_justification(&self, hash: &B::Hash, number: NumberFor<B>);
}
```

The sync engine receives these results and updates its state accordingly.

## Justification Import

Separate from block import, **justifications** (finality proofs) can be imported:

**Location**: `substrate/client/consensus/common/src/block_import.rs:351-367`

```rust
#[async_trait::async_trait]
pub trait JustificationImport<B: BlockT> {
    /// Called when import queue starts
    async fn on_start(&mut self) -> Vec<(B::Hash, NumberFor<B>)>;

    /// Import a justification and finalize the block
    async fn import_justification(
        &mut self,
        hash: B::Hash,
        number: NumberFor<B>,
        justification: Justification,
    ) -> Result<(), Self::Error>;
}
```

GRANDPA implements this to finalize blocks when justifications are received.

## Special Import Scenarios

### 1. State Sync (MissingState)

When syncing from a snapshot:
```rust
IncomingBlock {
    allow_missing_state: true,
    skip_execution: true,
    state: Some(ImportedState { block: hash, state: key_value_pairs }),
    ...
}
```

The importer applies the state directly without execution.

### 2. Header-Only Sync

```rust
BlockImportParams {
    body: None,
    state_action: StateAction::Skip,
    ...
}
```

Only the header is verified and stored.

### 3. Gap Syncing

When a block's parent is missing:
```rust
BlockCheckParams {
    allow_missing_parent: true,
    ...
}
```

The block is stored but not set as best until the gap is filled.

## Consensus Pipeline Stacking

Multiple `BlockImport` implementations can be **chained**:

```
Client (final importer - writes to DB)
  ↑
GrandpaBlockImport (adds finality tracking)
  ↑
BabeBlockImport (validates BABE-specific data)
  ↑
Network blocks arrive
```

Each layer:
1. Processes `intermediates` relevant to it
2. Removes processed intermediates
3. Passes params to next layer

The final importer (Client) rejects blocks with unhandled intermediates.

## Fork Choice Strategy

After verification, the verifier sets the fork choice:

```rust
pub enum ForkChoiceStrategy {
    LongestChain,        // Nakamoto-style
    Custom(bool),        // Custom rule (true = make best)
}
```

The importer uses this to decide whether to update the best block.

## Error Handling

When an import fails:
- **UnknownParent**: Block queued until parent arrives
- **KnownBad**: Block and peer reputation penalized
- **MissingState**: State sync triggered or block queued
- **VerificationFailed**: Block rejected, peer reputation reduced

Failed blocks halt sequential processing:
```rust
if has_error {
    Err(BlockImportError::Cancelled)  // Cancel remaining blocks
}
```

## Performance Considerations

1. **Sequential Processing**: Blocks imported one-by-one to maintain consistency
2. **Yielding**: `futures::pending!()` after each block ensures other tasks run
3. **Bounded Buffers**: 100,000 item queues prevent memory exhaustion
4. **Metrics**: Prometheus metrics track import times and throughput

## Key Files

- `substrate/client/consensus/common/src/block_import.rs` - Core traits and types
- `substrate/client/consensus/common/src/import_queue.rs` - Queue infrastructure
- `substrate/client/consensus/common/src/import_queue/basic_queue.rs` - Default queue implementation
- `substrate/client/consensus/common/src/import_queue/buffered_link.rs` - Result communication
- `substrate/client/service/src/client/block_import.rs` - Final database importer
- `substrate/client/consensus/grandpa/src/import.rs` - GRANDPA finality wrapper
- `substrate/client/consensus/aura/src/import_queue.rs` - Aura verifier
