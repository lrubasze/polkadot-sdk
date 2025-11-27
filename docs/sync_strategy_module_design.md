# Sync Strategy Module Design Document

**Author:** Claude (with lrubasze)
**Date:** 2025-11-27
**Status:** Draft
**Related PR:** #10373 (Block import improvements)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Problem Statement](#problem-statement)
3. [Goals and Non-Goals](#goals-and-non-goals)
4. [Background](#background)
5. [Architecture](#architecture)
6. [Detailed Design](#detailed-design)
7. [API Specification](#api-specification)
8. [Implementation Plan](#implementation-plan)
9. [Testing Strategy](#testing-strategy)
10. [Migration Path](#migration-path)
11. [Performance Considerations](#performance-considerations)
12. [Security Considerations](#security-considerations)
13. [Future Work](#future-work)
14. [Alternatives Considered](#alternatives-considered)
15. [Open Questions](#open-questions)

---

## Executive Summary

This document proposes a new **Sync Strategy Module** that centralizes the logic for determining how blocks from different synchronization sources should be verified and processed during import.

Currently, sync-related decision-making is scattered across consensus modules (BABE, GRANDPA), the database layer, and the import queue. This creates code duplication and tight coupling. The proposed module provides a single source of truth for sync strategy decisions, making the codebase more maintainable and extensible.

**Key Benefits:**
- Eliminates code duplication across consensus modules
- Provides clear API for sync-related decisions
- Makes it easier to add new sync modes
- Improves testability and observability
- Reduces coupling between components

---

## Problem Statement

### Current Issues

1. **Code Duplication:**
   - Each consensus module (BABE, GRANDPA) independently checks `BlockOrigin::WarpSync`
   - Similar verification-skipping logic is duplicated in multiple places
   - Gap management logic is intertwined with block import

2. **Tight Coupling:**
   - Consensus modules need to understand sync internals (warp sync, gap sync)
   - Database layer makes decisions about verification levels
   - No clear separation of concerns

3. **Poor Discoverability:**
   - Hard to find all places that handle a specific sync mode
   - Behavior for a given `BlockOrigin` is scattered across codebase
   - No central documentation of sync policies

4. **Difficult to Extend:**
   - Adding a new sync mode requires changes in multiple modules
   - Easy to miss edge cases
   - No clear pattern to follow

### Example of Current Duplication

**In BABE (`substrate/client/consensus/babe/src/lib.rs:1256`):**
```rust
if block.origin == BlockOrigin::WarpSync {
    return Ok(());
}
```

**In GRANDPA (`substrate/client/consensus/grandpa/src/import.rs:282`):**
```rust
if block.origin == BlockOrigin::WarpSync {
    return Ok(PendingSetChanges {
        just_in_case: None,
        applied_changes: AppliedChanges::None,
        ...
    });
}
```

Both modules duplicate the same decision logic.

---

## Goals and Non-Goals

### Goals

1. **Centralize Sync Logic:** Create single source of truth for sync-related decisions
2. **Improve Maintainability:** Reduce code duplication and coupling
3. **Enhance Testability:** Make sync behavior easily testable in isolation
4. **Better Observability:** Provide clear sync state tracking and metrics
5. **Simplify Extensions:** Make adding new sync modes straightforward
6. **Clear Documentation:** API serves as living documentation of sync policies

### Non-Goals

1. **Not a Complete Rewrite:** Work with existing sync infrastructure
2. **Not Changing Consensus:** Don't modify consensus algorithms themselves
3. **Not Network Protocol Changes:** No changes to wire protocols
4. **Not Performance Optimization:** Focus is on architecture, not speed (though better architecture may enable future optimizations)

---

## Background

### Current Block Origins

Substrate defines several `BlockOrigin` types (from `sp-consensus`):

```rust
pub enum BlockOrigin {
    Genesis,              // Genesis block
    NetworkInitialSync,   // Initial sync
    NetworkBroadcast,     // Live broadcast
    ConsensusBroadcast,   // Validated by consensus
    Own,                  // Locally authored
    File,                 // Imported from file
    WarpSync,            // From warp sync proof (PR #10373)
    GapSync,             // Gap filling (PR #10373)
}
```

### Sync Phases

Polkadot SDK supports multiple sync strategies:

1. **Initial Sync:** Download all blocks from genesis
2. **Warp Sync:** Jump to finalized state using cryptographic proofs
3. **Gap Sync:** Fill missing blocks after warp sync
4. **Live Sync:** Process blocks as they arrive

Each phase has different verification requirements and performance characteristics.

### Related Work

- **PR #9678:** Initial warp sync improvements
- **PR #10373:** Block import improvements, introduced `WarpSync` and `GapSync` origins
- **Gap Management:** Recent refactoring of gap update logic (this PR)

---

## Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     Network Sync Layer                      │
│          (Downloads blocks, determines origin)              │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              Sync Strategy Coordinator                      │
│  ┌────────────────────────────────────────────────────┐    │
│  │  • Import strategy determination                   │    │
│  │  • Verification level policies                     │    │
│  │  • Epoch/authority tracking rules                  │    │
│  │  • Gap management policies                         │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────┬──────────────────────┬────────────────────────┘
              │                      │
              ▼                      ▼
┌─────────────────────┐  ┌──────────────────────────┐
│  Consensus Modules  │  │   Database Layer         │
│  • BABE             │  │   • Block storage        │
│  • GRANDPA          │  │   • Gap management       │
│  • Aura, etc.       │  │   • State management     │
└─────────────────────┘  └──────────────────────────┘
```

### Component Responsibilities

#### 1. Sync Strategy Coordinator
- **Pure logic:** No state, just decision functions
- **Input:** `BlockOrigin`, block metadata
- **Output:** Policy decisions (verification level, tracking flags, etc.)
- **Location:** `substrate/client/db/src/sync_strategy/coordinator.rs`

#### 2. Sync State Manager
- **Stateful:** Tracks current sync phase
- **Manages:** State transitions (warp → gap → live)
- **Provides:** Context-aware decisions based on current state
- **Location:** `substrate/client/db/src/sync_strategy/state_manager.rs`

#### 3. Sync Policy
- **Configuration:** Defines policies for each sync phase
- **Examples:** Batch commit sizes, notification policies, gap limits
- **Location:** `substrate/client/db/src/sync_strategy/policy.rs`

---

## Detailed Design

### Core Types

#### ImportStrategy Enum

```rust
/// The strategy to use when importing a block
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImportStrategy {
    /// Block from warp sync - minimal verification, no epoch tracking
    WarpSynced {
        /// Is this the target block of warp sync?
        is_target: bool,
    },

    /// Block filling a gap - standard verification
    GapFill {
        /// Position within the gap
        gap_position: GapPosition,
    },

    /// Block from initial sync - standard verification, gap management
    InitialSync,

    /// Live synced block - full verification
    LiveSync,

    /// Locally produced block - authored verification
    Local,

    /// Genesis block - no verification
    Genesis,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GapPosition {
    Start,
    Middle,
    End,
}
```

#### VerificationLevel Enum

```rust
/// Level of verification to perform on a block
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum VerificationLevel {
    /// No verification needed (genesis)
    None,

    /// Already verified externally (warp sync proof)
    /// Only verify proof signature, skip consensus checks
    CryptographicProofOnly,

    /// Trusted source (imported file)
    /// Basic sanity checks only
    Trusted,

    /// Standard verification (basic consensus checks)
    /// - Header validity
    /// - Justifications
    /// - State transitions
    Standard,

    /// Full verification including equivocation checks
    /// - All Standard checks
    /// - Equivocation detection
    /// - VRF verification
    /// - Authority set checks
    Full,

    /// Authored by us - verify own work
    /// - All Full checks
    /// - Additional authorship validation
    Author,
}

impl VerificationLevel {
    /// Does this level include equivocation checks?
    pub fn includes_equivocation_checks(&self) -> bool {
        matches!(self, Self::Full | Self::Author)
    }

    /// Does this level require VRF verification?
    pub fn requires_vrf_verification(&self) -> bool {
        matches!(self, Self::Full | Self::Author)
    }
}
```

#### SyncState Enum

```rust
/// Current synchronization state of the node
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncState {
    /// Performing warp sync
    WarpSyncing {
        /// Target block number
        target: u64,
        /// Current progress
        current: u64,
    },

    /// Filling gaps after warp sync
    GapFilling {
        /// Gap range being filled
        gap_start: u64,
        gap_end: u64,
        /// Current position
        current: u64,
    },

    /// Initial sync (no warp)
    InitialSyncing {
        /// Best known block
        target: u64,
        /// Current block
        current: u64,
    },

    /// Fully synced, processing live blocks
    Live,
}

impl SyncState {
    /// Get current progress as percentage (0-100)
    pub fn progress_percent(&self) -> Option<u8> {
        match self {
            Self::WarpSyncing { target, current } => {
                Some(((current * 100) / target).min(100) as u8)
            }
            Self::GapFilling { gap_start, gap_end, current } => {
                let total = gap_end - gap_start;
                let done = current - gap_start;
                Some(((done * 100) / total).min(100) as u8)
            }
            Self::InitialSyncing { target, current } => {
                Some(((current * 100) / target).min(100) as u8)
            }
            Self::Live => None,
        }
    }

    /// Is this a "fast sync" mode where we can skip expensive ops?
    pub fn is_fast_sync(&self) -> bool {
        matches!(self, Self::WarpSyncing { .. } | Self::GapFilling { .. })
    }
}
```

---

## API Specification

### Sync Strategy Coordinator

```rust
/// Centralized coordinator for sync strategy decisions
pub struct SyncStrategyCoordinator;

impl SyncStrategyCoordinator {
    /// Determine import strategy for a block based on its origin
    ///
    /// # Example
    /// ```
    /// let strategy = SyncStrategyCoordinator::import_strategy_for_origin(
    ///     BlockOrigin::WarpSync
    /// );
    /// assert!(matches!(strategy, ImportStrategy::WarpSynced { .. }));
    /// ```
    pub fn import_strategy_for_origin(origin: BlockOrigin) -> ImportStrategy {
        match origin {
            BlockOrigin::WarpSync => ImportStrategy::WarpSynced { is_target: false },
            BlockOrigin::GapSync => ImportStrategy::GapFill {
                gap_position: GapPosition::Middle
            },
            BlockOrigin::NetworkInitialSync => ImportStrategy::InitialSync,
            BlockOrigin::NetworkBroadcast |
            BlockOrigin::ConsensusBroadcast => ImportStrategy::LiveSync,
            BlockOrigin::Own => ImportStrategy::Local,
            BlockOrigin::File => ImportStrategy::Local,
            BlockOrigin::Genesis => ImportStrategy::Genesis,
        }
    }

    /// Get verification level required for this block
    ///
    /// # Example
    /// ```
    /// let level = SyncStrategyCoordinator::verification_level(BlockOrigin::WarpSync);
    /// assert_eq!(level, VerificationLevel::CryptographicProofOnly);
    /// ```
    pub fn verification_level(origin: BlockOrigin) -> VerificationLevel {
        match origin {
            BlockOrigin::WarpSync => VerificationLevel::CryptographicProofOnly,
            BlockOrigin::GapSync => VerificationLevel::Standard,
            BlockOrigin::NetworkInitialSync => VerificationLevel::Standard,
            BlockOrigin::NetworkBroadcast => VerificationLevel::Full,
            BlockOrigin::ConsensusBroadcast => VerificationLevel::Full,
            BlockOrigin::Own => VerificationLevel::Author,
            BlockOrigin::File => VerificationLevel::Trusted,
            BlockOrigin::Genesis => VerificationLevel::None,
        }
    }

    /// Should full consensus verification be performed?
    pub fn requires_full_verification(origin: BlockOrigin) -> bool {
        Self::verification_level(origin) >= VerificationLevel::Standard
    }

    /// Should epoch changes be tracked during import?
    ///
    /// For warp sync blocks, epoch changes will be reconstructed from
    /// finalized state after sync completes.
    pub fn should_track_epoch_changes(origin: BlockOrigin) -> bool {
        origin != BlockOrigin::WarpSync
    }

    /// Should authority set changes be tracked?
    pub fn should_track_authority_changes(origin: BlockOrigin) -> bool {
        origin != BlockOrigin::WarpSync
    }

    /// Should equivocation checks be performed?
    pub fn should_check_equivocations(origin: BlockOrigin) -> bool {
        Self::verification_level(origin).includes_equivocation_checks()
    }

    /// Should we create or update block gaps for this block?
    pub fn should_manage_gaps(origin: BlockOrigin) -> bool {
        matches!(
            origin,
            BlockOrigin::WarpSync |
            BlockOrigin::GapSync |
            BlockOrigin::NetworkInitialSync
        )
    }

    /// Can state be missing for this block during import?
    pub fn allows_missing_state(origin: BlockOrigin) -> bool {
        matches!(
            origin,
            BlockOrigin::WarpSync | BlockOrigin::GapSync
        )
    }
}
```

### Sync State Manager

```rust
/// Manages synchronization state and transitions
pub struct SyncStateManager<Block: BlockT> {
    current_state: SyncState,
    gap_info: Option<BlockGap<NumberFor<Block>>>,
    metrics: Arc<SyncMetrics>,
}

impl<Block: BlockT> SyncStateManager<Block> {
    /// Create a new sync state manager
    pub fn new() -> Self {
        Self {
            current_state: SyncState::Live,
            gap_info: None,
            metrics: Arc::new(SyncMetrics::default()),
        }
    }

    /// Create with initial warp sync state
    pub fn new_warp_sync(target: NumberFor<Block>) -> Self {
        Self {
            current_state: SyncState::WarpSyncing {
                target: target.saturated_into(),
                current: 0,
            },
            gap_info: None,
            metrics: Arc::new(SyncMetrics::default()),
        }
    }

    /// Update state based on imported block
    ///
    /// Returns transition information if state changed
    pub fn on_block_imported(
        &mut self,
        origin: BlockOrigin,
        number: NumberFor<Block>,
        has_gap: bool,
    ) -> Option<SyncStateTransition> {
        let old_state = self.current_state;
        let block_num: u64 = number.saturated_into();

        // Update current position in state
        match &mut self.current_state {
            SyncState::WarpSyncing { current, .. } => {
                *current = block_num;
            }
            SyncState::GapFilling { current, .. } => {
                *current = block_num;
            }
            SyncState::InitialSyncing { current, .. } => {
                *current = block_num;
            }
            SyncState::Live => {}
        }

        // State transition logic
        let new_state = match (self.current_state, origin, has_gap) {
            // Warp sync completed, transition to gap filling
            (SyncState::WarpSyncing { target, .. }, BlockOrigin::WarpSync, true)
                if block_num >= target => {
                if let Some(gap) = &self.gap_info {
                    SyncState::GapFilling {
                        gap_start: gap.start.saturated_into(),
                        gap_end: gap.end.saturated_into(),
                        current: gap.start.saturated_into(),
                    }
                } else {
                    SyncState::Live
                }
            }

            // Gap filling completed
            (SyncState::GapFilling { .. }, _, false) => SyncState::Live,

            // Initial sync completed
            (SyncState::InitialSyncing { target, current }, _, false)
                if current >= target => SyncState::Live,

            // Continue current state
            (state, _, _) => state,
        };

        if new_state != old_state {
            self.current_state = new_state;
            self.metrics.record_transition(&old_state, &new_state);

            Some(SyncStateTransition {
                from: old_state,
                to: new_state,
                triggered_by: origin,
            })
        } else {
            None
        }
    }

    /// Update gap information
    pub fn update_gap(&mut self, gap: Option<BlockGap<NumberFor<Block>>>) {
        self.gap_info = gap;
    }

    /// Get current sync state
    pub fn current_state(&self) -> &SyncState {
        &self.current_state
    }

    /// Should we skip expensive operations based on current state?
    pub fn can_skip_expensive_ops(&self) -> bool {
        self.current_state.is_fast_sync()
    }

    /// Get appropriate block origin for downloaded blocks in current state
    pub fn origin_for_downloaded_block(&self) -> BlockOrigin {
        match self.current_state {
            SyncState::WarpSyncing { .. } => BlockOrigin::WarpSync,
            SyncState::GapFilling { .. } => BlockOrigin::GapSync,
            SyncState::InitialSyncing { .. } => BlockOrigin::NetworkInitialSync,
            SyncState::Live => BlockOrigin::NetworkBroadcast,
        }
    }

    /// Get metrics snapshot
    pub fn metrics(&self) -> SyncMetrics {
        self.metrics.snapshot(&self.current_state)
    }
}
```

### Sync State Transition

```rust
/// Represents a transition between sync states
#[derive(Debug, Clone)]
pub struct SyncStateTransition {
    pub from: SyncState,
    pub to: SyncState,
    pub triggered_by: BlockOrigin,
    pub timestamp: Instant,
}

impl SyncStateTransition {
    /// Did we complete a major sync phase?
    pub fn completed_phase(&self) -> bool {
        matches!(
            (&self.from, &self.to),
            (SyncState::WarpSyncing { .. }, SyncState::GapFilling { .. }) |
            (SyncState::GapFilling { .. }, SyncState::Live) |
            (SyncState::InitialSyncing { .. }, SyncState::Live)
        )
    }

    /// Get human-readable description
    pub fn description(&self) -> String {
        match (&self.from, &self.to) {
            (SyncState::WarpSyncing { .. }, SyncState::GapFilling { .. }) => {
                "Warp sync completed, starting gap fill".to_string()
            }
            (SyncState::GapFilling { .. }, SyncState::Live) => {
                "Gap fill completed, node fully synced".to_string()
            }
            (SyncState::InitialSyncing { .. }, SyncState::Live) => {
                "Initial sync completed, node fully synced".to_string()
            }
            _ => format!("{:?} -> {:?}", self.from, self.to),
        }
    }
}
```

### Sync Policy

```rust
/// Policy decisions for different sync phases
pub struct SyncPolicy;

impl SyncPolicy {
    /// Should we batch-commit blocks during this phase?
    pub fn should_batch_commits(state: &SyncState) -> bool {
        matches!(
            state,
            SyncState::WarpSyncing { .. } |
            SyncState::InitialSyncing { .. } |
            SyncState::GapFilling { .. }
        )
    }

    /// Get optimal batch size for commits
    pub fn batch_commit_size(state: &SyncState) -> usize {
        match state {
            SyncState::WarpSyncing { .. } => 1000,
            SyncState::GapFilling { .. } => 500,
            SyncState::InitialSyncing { .. } => 100,
            SyncState::Live => 1,
        }
    }

    /// Should we emit notifications for imported blocks?
    pub fn should_notify_on_import(state: &SyncState) -> bool {
        matches!(state, SyncState::Live)
    }

    /// Maximum acceptable gap size
    pub fn max_acceptable_gap_size(state: &SyncState) -> Option<u64> {
        match state {
            SyncState::WarpSyncing { .. } => Some(1_000_000),
            SyncState::GapFilling { .. } => Some(100_000),
            SyncState::InitialSyncing { .. } => Some(10_000),
            SyncState::Live => Some(10),
        }
    }

    /// Should we prune state during this phase?
    pub fn should_prune_state(state: &SyncState) -> bool {
        matches!(state, SyncState::Live)
    }

    /// Should we warm up caches?
    pub fn should_warm_caches(state: &SyncState) -> bool {
        matches!(state, SyncState::Live)
    }
}
```

---

## Implementation Plan

### Phase 1: Core Infrastructure (Week 1)

**Goal:** Create basic module structure and types

- [ ] Create `substrate/client/db/src/sync_strategy/` directory
- [ ] Implement core types:
  - [ ] `ImportStrategy` enum
  - [ ] `VerificationLevel` enum
  - [ ] `SyncState` enum
  - [ ] `SyncStateTransition` struct
- [ ] Implement `SyncStrategyCoordinator` (stateless functions)
- [ ] Add comprehensive unit tests
- [ ] Documentation and examples

**Deliverable:** Working coordinator with full test coverage

### Phase 2: State Management (Week 2)

**Goal:** Add stateful sync state tracking

- [ ] Implement `SyncStateManager`
- [ ] Add state transition logic
- [ ] Implement `SyncPolicy`
- [ ] Add integration tests for state transitions
- [ ] Add metrics collection

**Deliverable:** State manager with transition tracking

### Phase 3: Integration - Consensus (Week 3)

**Goal:** Refactor consensus modules to use new API

- [ ] Refactor BABE to use `SyncStrategyCoordinator`
  - [ ] Replace origin checks with API calls
  - [ ] Update epoch change tracking
  - [ ] Update equivocation checks
- [ ] Refactor GRANDPA similarly
- [ ] Update tests
- [ ] Verify no behavior changes

**Deliverable:** BABE and GRANDPA using new API

### Phase 4: Integration - Database (Week 4)

**Goal:** Integrate with block import and gap management

- [ ] Update `try_commit_operation` to use `SyncStateManager`
- [ ] Integrate with gap management helpers
- [ ] Use verification level for skip decisions
- [ ] Add metrics emission
- [ ] Update tests

**Deliverable:** Database layer using sync strategy module

### Phase 5: Polish and Documentation (Week 5)

**Goal:** Complete documentation and examples

- [ ] Update module-level documentation
- [ ] Create usage guide
- [ ] Add more examples
- [ ] Performance testing
- [ ] Security review
- [ ] Update PR #10373 prdoc

**Deliverable:** Production-ready module

---

## Testing Strategy

### Unit Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn warp_sync_blocks_skip_full_verification() {
        assert!(!SyncStrategyCoordinator::requires_full_verification(
            BlockOrigin::WarpSync
        ));
        assert_eq!(
            SyncStrategyCoordinator::verification_level(BlockOrigin::WarpSync),
            VerificationLevel::CryptographicProofOnly
        );
    }

    #[test]
    fn gap_sync_requires_standard_verification() {
        assert_eq!(
            SyncStrategyCoordinator::verification_level(BlockOrigin::GapSync),
            VerificationLevel::Standard
        );
    }

    #[test]
    fn live_blocks_require_full_verification() {
        assert_eq!(
            SyncStrategyCoordinator::verification_level(BlockOrigin::NetworkBroadcast),
            VerificationLevel::Full
        );
    }

    #[test]
    fn state_transitions_warp_to_gap() {
        let mut manager = SyncStateManager::<Block>::new_warp_sync(1000);

        let transition = manager.on_block_imported(
            BlockOrigin::WarpSync,
            1000,
            true, // has gap
        );

        assert!(transition.is_some());
        let t = transition.unwrap();
        assert!(matches!(t.from, SyncState::WarpSyncing { .. }));
        assert!(matches!(t.to, SyncState::GapFilling { .. }));
        assert!(t.completed_phase());
    }

    #[test]
    fn state_transitions_gap_to_live() {
        let mut manager = SyncStateManager::<Block>::new();
        manager.current_state = SyncState::GapFilling {
            gap_start: 100,
            gap_end: 1000,
            current: 999,
        };

        let transition = manager.on_block_imported(
            BlockOrigin::GapSync,
            1000,
            false, // no gap
        );

        assert!(transition.is_some());
        let t = transition.unwrap();
        assert!(matches!(t.to, SyncState::Live));
        assert!(t.completed_phase());
    }
}
```

### Integration Tests

```rust
#[test]
fn babe_uses_sync_strategy_for_verification() {
    // Test that BABE correctly queries sync strategy
    // and skips verification for warp sync blocks
}

#[test]
fn gap_management_integrates_with_state_manager() {
    // Test that gap updates trigger state transitions
}

#[test]
fn metrics_tracked_across_sync_phases() {
    // Test that metrics are correctly updated
}
```

### Property-Based Tests

```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn verification_level_ordering_is_consistent(origin: BlockOrigin) {
        let level = SyncStrategyCoordinator::verification_level(origin);

        // Invariant: Author verification is always highest
        if origin == BlockOrigin::Own {
            assert_eq!(level, VerificationLevel::Author);
        }

        // Invariant: Genesis never requires verification
        if origin == BlockOrigin::Genesis {
            assert_eq!(level, VerificationLevel::None);
        }
    }

    #[test]
    fn state_transitions_are_monotonic(
        initial_state: SyncState,
        blocks: Vec<(BlockOrigin, u64, bool)>
    ) {
        // Property: Once we reach Live state, we never go back
        let mut manager = /* ... */;

        for (origin, num, has_gap) in blocks {
            manager.on_block_imported(origin, num, has_gap);

            if matches!(manager.current_state(), SyncState::Live) {
                // Verify we stay in Live state
            }
        }
    }
}
```

---

## Migration Path

### Backwards Compatibility

The module is **fully backwards compatible**:

1. **No API changes** to existing `BlockOrigin`
2. **No changes** to network protocols
3. **Optional adoption** - can be used incrementally
4. **Behavioral equivalence** - produces same results as current code

### Migration Steps

#### Step 1: Add Module (No Behavior Changes)

```rust
// Add module alongside existing code
mod sync_strategy;

// No changes to existing functionality yet
```

#### Step 2: Gradual Adoption

```rust
// BABE - migrate one module at a time
// Old code:
if block.origin == BlockOrigin::WarpSync {
    return Ok(());
}

// New code (optional at first):
if !SyncStrategyCoordinator::should_track_epoch_changes(block.origin) {
    return Ok(());
}
```

#### Step 3: Complete Migration

Once all modules use the new API:

```rust
// Remove old scattered checks
// All sync decisions go through SyncStrategyCoordinator
```

#### Step 4: Deprecation (Optional)

If we want to prevent future direct origin checks:

```rust
#[deprecated(note = "Use SyncStrategyCoordinator instead")]
pub enum BlockOrigin { ... }
```

### Rollback Plan

If issues arise:
1. Module is self-contained - can be removed
2. Original code paths remain unchanged
3. No database schema changes
4. Simple revert of code changes

---

## Performance Considerations

### Expected Impact

**Positive:**
- **Better batching:** State manager enables smarter batch commit decisions
- **Skip unnecessary work:** Clear policies for when to skip expensive operations
- **Cache awareness:** Can avoid warming caches during fast sync

**Neutral:**
- **Function call overhead:** Minimal (simple enum matches)
- **State tracking:** Small memory footprint (~100 bytes)
- **No hot path changes:** Just organizing existing checks

**Potential Concerns:**
- **None identified** - Module is mostly decision logic with minimal overhead

### Benchmarks

Should measure:
1. **Block import throughput** (before/after migration)
2. **Warp sync duration** (should be same or better)
3. **Memory usage** (SyncStateManager overhead)
4. **CPU overhead** (function call overhead)

Target: **<1% performance difference** in all metrics

---

## Security Considerations

### Security Properties

#### Invariant Preservation

The module **must preserve** these security invariants:

1. **Warp sync blocks verified:** Only blocks with valid cryptographic proofs get `WarpSync` origin
2. **Live blocks fully verified:** `NetworkBroadcast` blocks always get full verification
3. **No verification bypass:** Cannot skip verification unless explicitly safe
4. **Epoch tracking:** Authority sets correctly reconstructed after sync

#### Attack Vectors

**1. Origin Manipulation**

*Risk:* Malicious code sets wrong `BlockOrigin` to skip verification

*Mitigation:*
- Origin set by trusted sync layer only
- Module is pure logic, no origin assignment
- Comprehensive tests verify correct behavior

**2. State Transition Exploitation**

*Risk:* Force premature transition to `Live` state to skip checks

*Mitigation:*
- State transitions require specific conditions (gap completion, etc.)
- Transitions logged and observable
- Tests verify transition correctness

**3. Policy Bypass**

*Risk:* Code bypasses `SyncStrategyCoordinator` and makes direct decisions

*Mitigation:*
- Code review catches direct origin checks
- Linting rules can enforce API usage
- Optional: Deprecate direct access to origin

### Security Review Checklist

- [ ] All verification levels preserve security properties
- [ ] State transitions cannot be exploited
- [ ] Warp sync proof validation occurs before origin assignment
- [ ] No verification bypass paths
- [ ] Metrics don't leak sensitive information
- [ ] Tests cover adversarial scenarios

---

## Future Work

### Potential Extensions

#### 1. Snapshot Sync

Add support for snapshot-based sync:

```rust
pub enum BlockOrigin {
    // ... existing variants
    SnapshotSync, // From state snapshot
}

// Coordinator handles new mode automatically
impl SyncStrategyCoordinator {
    pub fn verification_level(origin: BlockOrigin) -> VerificationLevel {
        match origin {
            BlockOrigin::SnapshotSync => VerificationLevel::Trusted,
            // ... existing cases
        }
    }
}
```

#### 2. Adaptive Policies

Make policies adaptive based on observed performance:

```rust
pub struct AdaptiveSyncPolicy {
    baseline_policy: SyncPolicy,
    performance_stats: PerformanceStats,
}

impl AdaptiveSyncPolicy {
    pub fn batch_commit_size(&self, state: &SyncState) -> usize {
        let baseline = SyncPolicy::batch_commit_size(state);

        // Adjust based on observed commit latency
        if self.performance_stats.commit_latency_high() {
            baseline / 2
        } else {
            baseline
        }
    }
}
```

#### 3. Pluggable Verification

Allow custom verification strategies:

```rust
pub trait VerificationStrategy {
    fn verify_block(&self, block: &Block, level: VerificationLevel) -> Result<()>;
}

pub struct StandardVerification;
pub struct OptimizedVerification;
pub struct ParallelVerification;
```

#### 4. Sync Orchestration

Coordinate multiple sync strategies:

```rust
pub struct SyncOrchestrator {
    strategies: Vec<Box<dyn SyncStrategy>>,
    state_manager: SyncStateManager,
}

impl SyncOrchestrator {
    pub fn optimal_strategy(&self) -> &dyn SyncStrategy {
        // Choose warp, initial, or snap sync based on network conditions
    }
}
```

#### 5. Enhanced Metrics

More detailed observability:

```rust
pub struct DetailedSyncMetrics {
    blocks_per_second: Gauge,
    verification_time_histogram: Histogram,
    state_transition_counter: Counter,
    sync_lag_gauge: Gauge,
    // Per-origin metrics
    per_origin_stats: HashMap<BlockOrigin, OriginStats>,
}
```

### Research Questions

1. **Can we predict optimal sync strategy?** Machine learning to choose warp vs. initial sync
2. **Parallel verification during gap fill?** Verify multiple blocks concurrently
3. **Incremental state verification?** Verify state in chunks during warp sync
4. **Cross-chain sync coordination?** Coordinate sync across parachains

---

## Alternatives Considered

### Alternative 1: Keep Current Approach

**Pros:**
- No code changes needed
- Works today

**Cons:**
- Code duplication continues
- Hard to extend
- Poor discoverability
- Testing is difficult

**Decision:** Rejected - technical debt is growing

### Alternative 2: Trait-Based Approach

```rust
pub trait BlockVerificationStrategy {
    fn requires_verification(&self) -> bool;
    fn verification_level(&self) -> VerificationLevel;
}

impl BlockVerificationStrategy for BlockOrigin {
    // ... implementation
}
```

**Pros:**
- More OOP-style
- Extensible via traits

**Cons:**
- More complex than needed
- Harder to test
- Trait overhead

**Decision:** Rejected - simpler approach preferred

### Alternative 3: Config-Based

```rust
// TOML config file
[sync_strategy]
warp_sync_verification = "proof_only"
gap_sync_verification = "standard"
# ...
```

**Pros:**
- Runtime configurable
- No code changes for policy updates

**Cons:**
- Adds configuration complexity
- Harder to reason about
- Security risk (wrong config = vulnerability)

**Decision:** Rejected - policy should be in code for security

### Alternative 4: Macro-Based

```rust
verify_block!(block, {
    WarpSync => skip_verification(),
    GapSync => standard_verification(),
    _ => full_verification(),
});
```

**Pros:**
- Concise at call sites

**Cons:**
- Magic behavior
- Hard to debug
- Poor IDE support

**Decision:** Rejected - explicit is better

---

## Open Questions

### Q1: Should policies be configurable?

**Question:** Should node operators be able to tune sync policies?

**Options:**
- **A:** Hardcoded policies (proposed)
- **B:** Runtime configurable via config file
- **C:** CLI flags for common settings

**Recommendation:** Start with (A), add (C) later if needed

**Rationale:** Policies affect security, should be code-reviewed

---

### Q2: How to handle custom consensus engines?

**Question:** How do custom consensus engines (non-BABE/GRANDPA) integrate?

**Options:**
- **A:** They call `SyncStrategyCoordinator` like BABE/GRANDPA
- **B:** Provide trait they must implement
- **C:** Document pattern, no enforcement

**Recommendation:** (A) with documentation examples

**Rationale:** Consistent API across all consensus

---

### Q3: Metrics granularity?

**Question:** How detailed should metrics be?

**Options:**
- **A:** Basic (current state, transition count)
- **B:** Detailed (per-origin stats, histograms)
- **C:** Pluggable (let users choose)

**Recommendation:** Start with (A), expand to (B) in Phase 5

**Rationale:** Can always add more metrics later

---

### Q4: State persistence?

**Question:** Should sync state persist across restarts?

**Options:**
- **A:** No persistence (reconstruct on startup)
- **B:** Persist to database
- **C:** Persist to separate file

**Recommendation:** (A) initially

**Rationale:** State can be reconstructed from blockchain state. Can add persistence later if needed.

---

## Conclusion

The Sync Strategy Module provides a clean, testable, and extensible architecture for managing block synchronization logic. By centralizing sync-related decisions, we:

1. **Eliminate duplication** across consensus modules
2. **Improve maintainability** with clear API boundaries
3. **Enable observability** through state tracking and metrics
4. **Simplify extensions** for new sync modes

The module is fully backwards compatible and can be adopted incrementally, making it a low-risk improvement with significant long-term benefits.

---

## Appendix A: Complete Example

### Before (Current Code)

```rust
// In BABE
if block.origin == BlockOrigin::WarpSync {
    return Ok(());
}
// ... 30 lines of verification ...

// In GRANDPA
if block.origin == BlockOrigin::WarpSync {
    return Ok(PendingSetChanges { /* ... */ });
}
// ... 25 lines of verification ...

// In Database
if operation.origin == BlockOrigin::WarpSync {
    // Skip some processing
}
// ... scattered throughout ...
```

### After (With Sync Strategy Module)

```rust
// In BABE
use sc_client_db::sync_strategy::SyncStrategyCoordinator;

if !SyncStrategyCoordinator::should_track_epoch_changes(block.origin) {
    return Ok(());
}

if !SyncStrategyCoordinator::should_check_equivocations(block.origin) {
    // Skip equivocation checks
}

// In GRANDPA
if !SyncStrategyCoordinator::should_track_authority_changes(block.origin) {
    return Ok(PendingSetChanges::default());
}

// In Database
let strategy = SyncStrategyCoordinator::import_strategy_for_origin(operation.origin);

match strategy {
    ImportStrategy::WarpSynced { .. } => {
        // Handle warp sync
    }
    ImportStrategy::GapFill { .. } => {
        // Handle gap fill
    }
    _ => {
        // Standard import
    }
}

// With state manager
if state_manager.can_skip_expensive_ops() {
    // Skip cache warming, etc.
}
```

---

## Appendix B: Metrics Schema

```rust
/// Prometheus metrics exposed by sync strategy module
pub struct SyncMetrics {
    /// Current sync state (gauge)
    sync_state: Gauge,

    /// State transition counter (counter)
    state_transitions_total: CounterVec,

    /// Blocks imported by origin (counter)
    blocks_imported_total: CounterVec,

    /// Verification skips by origin (counter)
    verification_skips_total: CounterVec,

    /// Current sync progress (gauge, 0-100)
    sync_progress_percent: Gauge,

    /// Time spent in each state (histogram)
    state_duration_seconds: HistogramVec,
}

// Usage
state_transitions_total.with_label_values(&["warp", "gap"]).inc();
blocks_imported_total.with_label_values(&["warp_sync"]).inc();
```

---

## Appendix C: References

- **PR #9678:** Warp sync improvements
- **PR #10373:** Block import improvements
- **sp-consensus:** `BlockOrigin` definition
- **sc-client-db:** Database backend implementation
- **BABE specification:** https://spec.polkadot.network/
- **GRANDPA specification:** https://spec.polkadot.network/

---

**End of Design Document**
