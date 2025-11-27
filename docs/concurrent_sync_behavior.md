# Concurrent Block Import During Sync

**Author:** Analysis based on user observation
**Date:** 2025-11-27
**Critical Finding:** Live blocks are imported DURING warp/gap sync

---

## Executive Summary

During warp sync, state sync, and gap sync, nodes **concurrently** receive and import live blocks that are being broadcast on the network. This means:

- ✅ Historical sync (warp/gap sync) downloading old blocks
- ✅ Live block import (NetworkBroadcast) importing new blocks being produced NOW
- ⚠️ **Both happen simultaneously**

This has **major implications** for the Sync Strategy Module design.

---

## Evidence from Code

### PolkadotSyncingStrategy Routes Block Announcements

**File:** `substrate/client/network/sync/src/strategy/polkadot.rs:124-140`

```rust
fn on_validated_block_announce(
    &mut self,
    is_best: bool,
    peer_id: PeerId,
    announce: &BlockAnnounce<B::Header>,
) -> Option<(B::Hash, NumberFor<B>)> {
    let new_best = if let Some(ref mut warp) = self.warp {
        warp.on_validated_block_announce(is_best, peer_id, announce)  // ← Warp sync handles announcements!
    } else if let Some(ref mut state) = self.state {
        state.on_validated_block_announce(is_best, peer_id, announce) // ← State sync too!
    } else if let Some(ref mut chain_sync) = self.chain_sync {
        chain_sync.on_validated_block_announce(is_best, peer_id, announce) // ← Gap sync too!
    } else {
        error!(target: LOG_TARGET, "No syncing strategy is active.");
        debug_assert!(false);
        Some((announce.header.hash(), *announce.header.number()))
    };
    // ...
}
```

**Key Insight:** Every sync strategy (warp, state, chain_sync) handles block announcements, meaning they all process live blocks concurrently with their historical sync.

---

## What Actually Happens

### Scenario: Node During Warp Sync

```
Time: T0
├── Warp Sync: Downloading proof for block #1,000,000
│   └── Origin: BlockOrigin::WarpSync
│
└── Network Broadcast: Block #1,000,500 announced
    ├── Received from peers
    ├── Validated
    └── Imported with Origin: BlockOrigin::NetworkBroadcast

Time: T1
├── Warp Sync: Completed, transitioning to State Sync
│   └── Origin: BlockOrigin::WarpSync
│
└── Network Broadcast: Block #1,000,501 announced
    └── Imported with Origin: BlockOrigin::NetworkBroadcast

Time: T2
├── State Sync: Downloading state for block #1,000,000
│   └── Origin: ? (likely NetworkInitialSync)
│
└── Network Broadcast: Block #1,000,502 announced
    └── Imported with Origin: BlockOrigin::NetworkBroadcast

Time: T3
├── Gap Sync: Filling blocks #1 → #999,999
│   └── Origin: BlockOrigin::GapSync
│
└── Network Broadcast: Block #1,000,503 announced
    └── Imported with Origin: BlockOrigin::NetworkBroadcast
```

---

## Implications for Design

### 1. Sync State is Not Purely Linear

**Previously thought:**
```
WarpSync → StateSync → GapSync → Live
```

**Actually:**
```
WarpSync + Live Blocks → StateSync + Live Blocks → GapSync + Live Blocks → Live
```

The state is **composite**, not atomic.

### 2. Two Concurrent Block Sources

At any given time during fast sync:

| Source | Origin | Purpose | Verification |
|--------|--------|---------|--------------|
| Historical Sync | `WarpSync`, `GapSync` | Fill historical gaps | Minimal (already finalized) |
| Live Network | `NetworkBroadcast` | Stay current with chain tip | Full verification |

### 3. Import Queue Receives Mixed Origins

The import queue receives blocks with different origins **concurrently**:

```rust
// Import queue during gap sync
IncomingBlock { origin: BlockOrigin::GapSync, number: 500 }        // Historical
IncomingBlock { origin: BlockOrigin::NetworkBroadcast, number: 1_000_500 }  // Live
IncomingBlock { origin: BlockOrigin::GapSync, number: 501 }        // Historical
IncomingBlock { origin: BlockOrigin::NetworkBroadcast, number: 1_000_501 }  // Live
```

### 4. Best Block Advances Ahead of Gap Fill

**Critical Behavior:**
- Gap sync is filling blocks #1 → #999,999
- Live blocks are being imported at #1,000,500+
- **Best block is at #1,000,500+ even though gap still exists**

This is intentional and correct - the node is staying in sync with the network while filling historical data in the background.

---

## Impact on Sync Strategy Module

### Updated SyncState Design

The `SyncState` enum needs to reflect this concurrent behavior:

**Option A: Composite State (Recommended)**
```rust
pub enum SyncState {
    /// Performing warp sync (+ live blocks)
    WarpSyncing {
        target: u64,
        current: u64,
        live_best: Option<u64>,  // ← Track live block progress too
    },

    /// Filling gaps (+ live blocks)
    GapFilling {
        gap_start: u64,
        gap_end: u64,
        current: u64,
        live_best: Option<u64>,  // ← Track live block progress
    },

    /// Fully synced
    Live,
}
```

**Option B: Separate Live Tracking**
```rust
pub struct SyncStateManager {
    historical_state: HistoricalSyncState,
    live_best: NumberFor<Block>,  // ← Separate tracker
}

pub enum HistoricalSyncState {
    WarpSyncing { .. },
    StateSyncing { .. },
    GapFilling { .. },
    Complete,
}
```

### Updated Import Strategy

The `import_strategy_for_origin` needs to acknowledge concurrent imports:

```rust
impl SyncStrategyCoordinator {
    pub fn import_strategy_for_origin(
        origin: BlockOrigin,
        sync_state: &SyncState,
    ) -> ImportStrategy {
        match (origin, sync_state) {
            // Live block during gap sync
            (BlockOrigin::NetworkBroadcast, SyncState::GapFilling { .. }) => {
                ImportStrategy::LiveDuringSync {
                    background_sync: BackgroundSyncType::GapFilling,
                }
            }

            // Live block during warp sync
            (BlockOrigin::NetworkBroadcast, SyncState::WarpSyncing { .. }) => {
                ImportStrategy::LiveDuringSync {
                    background_sync: BackgroundSyncType::WarpSync,
                }
            }

            // Regular live block
            (BlockOrigin::NetworkBroadcast, SyncState::Live) => {
                ImportStrategy::LiveSync
            }

            // Historical blocks
            (BlockOrigin::WarpSync, _) => ImportStrategy::WarpSynced,
            (BlockOrigin::GapSync, _) => ImportStrategy::GapFill,

            // ...
        }
    }
}
```

### Verification Policies Need Updating

**Live blocks during sync should still get full verification:**

```rust
impl SyncStrategyCoordinator {
    pub fn verification_level(origin: BlockOrigin) -> VerificationLevel {
        match origin {
            // Live blocks ALWAYS get full verification
            // Even during warp/gap sync!
            BlockOrigin::NetworkBroadcast => VerificationLevel::Full,

            // Historical blocks can use lighter verification
            BlockOrigin::WarpSync => VerificationLevel::CryptographicProofOnly,
            BlockOrigin::GapSync => VerificationLevel::Standard,

            // ...
        }
    }
}
```

---

## Performance Implications

### Positive

1. **Node stays current**: While filling historical data, node can follow chain tip
2. **Better UX**: Node can participate in consensus/validation while syncing
3. **Resilience**: If gap sync stalls, node still processes new blocks

### Concerns

1. **Resource contention**: Two concurrent sync processes compete for resources
2. **Import queue pressure**: Mixed block origins in import queue
3. **Complexity**: State management is more complex

### Mitigation Strategies

```rust
impl SyncPolicy {
    /// Should we throttle live block imports during heavy sync?
    pub fn should_throttle_live_imports(state: &SyncState) -> bool {
        match state {
            // Don't throttle - always process live blocks
            SyncState::Live => false,

            // Maybe throttle during heavy historical sync
            SyncState::GapFilling { .. } if gap_is_large() => true,

            // Don't throttle otherwise
            _ => false,
        }
    }

    /// Priority for block import
    pub fn import_priority(origin: BlockOrigin, state: &SyncState) -> Priority {
        match (origin, state) {
            // Live blocks always high priority
            (BlockOrigin::NetworkBroadcast, _) => Priority::High,

            // Historical blocks lower priority
            (BlockOrigin::GapSync, _) => Priority::Low,
            (BlockOrigin::WarpSync, _) => Priority::Medium,

            // ...
        }
    }
}
```

---

## Testing Requirements

### Unit Tests

```rust
#[test]
fn live_blocks_imported_during_warp_sync() {
    let mut manager = SyncStateManager::new_warp_sync(1000);

    // Import warp sync block
    manager.on_block_imported(BlockOrigin::WarpSync, 1000, true);

    // Import live block concurrently
    manager.on_block_imported(BlockOrigin::NetworkBroadcast, 1500, false);

    // Verify both were processed correctly
    assert_eq!(manager.warp_sync_progress(), 1000);
    assert_eq!(manager.live_best(), 1500);
}

#[test]
fn live_blocks_imported_during_gap_sync() {
    let mut manager = SyncStateManager::new();
    manager.current_state = SyncState::GapFilling {
        gap_start: 1,
        gap_end: 1000,
        current: 500,
    };

    // Import gap block
    manager.on_block_imported(BlockOrigin::GapSync, 500, true);

    // Import live block concurrently
    manager.on_block_imported(BlockOrigin::NetworkBroadcast, 2000, false);

    // Verify both were processed
    assert_eq!(manager.gap_sync_progress(), 500);
    assert_eq!(manager.live_best(), 2000);
}
```

### Integration Tests

1. **Concurrent Import Test:**
   - Start warp sync
   - Inject live block announcements
   - Verify both import correctly with appropriate origins

2. **State Transition Test:**
   - Verify state transitions work correctly with concurrent live blocks
   - Ensure live blocks don't interfere with sync phase transitions

3. **Resource Contention Test:**
   - Heavy gap sync + rapid live blocks
   - Verify no deadlocks or resource exhaustion

---

## Updated Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    Syncing Engine                       │
└────────┬──────────────────────────────────┬─────────────┘
         │                                  │
         ▼                                  ▼
┌──────────────────┐              ┌───────────────────────┐
│  Block Announce  │              │   Historical Sync     │
│    Handler       │              │   (Warp/State/Gap)    │
└────────┬─────────┘              └──────────┬────────────┘
         │                                   │
         │ NetworkBroadcast                  │ WarpSync/GapSync
         │                                   │
         └────────────┬──────────────────────┘
                      │
                      ▼
              ┌───────────────┐
              │ Import Queue  │
              │  (Mixed       │
              │   Origins)    │
              └───────┬───────┘
                      │
                      ▼
              ┌───────────────┐
              │  Consensus    │
              │  Modules      │
              │  (Verify)     │
              └───────┬───────┘
                      │
                      ▼
              ┌───────────────┐
              │   Database    │
              │   (Import)    │
              └───────────────┘

Legend:
→ NetworkBroadcast: Live blocks from network
→ WarpSync/GapSync: Historical blocks from sync strategies
⚡ Both flow concurrently through the same import queue
```

---

## Recommendations

### High Priority

1. **Update SyncState enum** to track both historical and live progress
2. **Test concurrent imports** extensively
3. **Document the behavior** clearly in code comments
4. **Adjust verification policies** to ensure live blocks always get full verification

### Medium Priority

5. **Add metrics** for concurrent import tracking:
   - `live_blocks_during_sync_total`
   - `concurrent_import_queue_depth`
   - `import_queue_origin_distribution`

6. **Consider priority queuing** in import queue
7. **Resource management** policies for concurrent sync

### Low Priority

8. **Performance optimization** for concurrent imports
9. **Backpressure mechanisms** if import queue fills
10. **Advanced scheduling** algorithms

---

## Open Questions

1. **Q:** What happens if live blocks build on top of warp target but gap isn't filled yet?
   - **A:** Node likely accepts them - they're validated independently

2. **Q:** Can live blocks cause issues with gap management?
   - **A:** Need to verify gap update logic handles concurrent live imports

3. **Q:** Should live blocks be prioritized over historical blocks?
   - **A:** Probably yes - staying current is more important than historical data

4. **Q:** What's the maximum acceptable lag between live best and gap sync progress?
   - **A:** Depends on use case - needs configuration

---

## Conclusion

The concurrent import of live blocks during historical sync is a **critical architectural feature** that:

- ✅ Keeps nodes current while syncing
- ✅ Improves user experience
- ⚠️ Adds complexity to state management
- ⚠️ Requires careful resource management

The Sync Strategy Module design **must** account for this concurrent behavior to be accurate and useful.

---

**Next Steps:**
1. Update design document with concurrent import behavior
2. Add tests for concurrent scenarios
3. Update review observations with this finding
4. Consider if PR #10373 handles this correctly
