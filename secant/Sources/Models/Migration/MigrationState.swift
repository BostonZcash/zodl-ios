//
//  MigrationState.swift
//  zodl
//
//  The app's own migration lifecycle state, and the ONE place that derives it from the SDK's
//  signals.
//
//  The SDK used to own a 5-case `MigrationState` and hand it over whole. It retired that enum
//  (2026-07-30, `michal/migration-parity-fixes`) in favour of surfacing the upstream engine's own
//  state machine — `MigrationAdvanceStep` — plus composable reads. That is the right boundary: the
//  engine answers "what should happen next", which is a different question from "what should the
//  user be told", and only the app can answer the second.
//
//  So the enum lives here now, unchanged in shape, and `derive(...)` below implements the SDK
//  handoff's state-recognition recipe verbatim, in ONE place. The alternative — switching over
//  `MigrationAdvanceStep` at each of the ~40 call sites that consume a state today — would have
//  scattered the recipe across the banner, the re-entry router, the screens and the notification
//  arming, with no single place left to correct when the mapping changes again.
//
//  Naming: the SDK deleted its `MigrationState`, so there is no collision today. If it ever
//  reintroduces one, this same-module type shadows it inside the app and the two would have to be
//  reconciled deliberately — see the migration board's A21 row for why that shadowing is a trap
//  worth knowing about rather than relying on.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// Why a migration cannot proceed on its own and needs the user.
enum MigrationAttentionReason: Equatable, Sendable {
    /// The funding notes a pre-signed transfer spends were spent elsewhere, so the plan no longer
    /// matches the balance. Recovery is a re-plan.
    case invalidTransfer
    /// A transfer passed its expiry height unmined. Its pre-signed artifact is dead (the signature
    /// commits to the expiry), so it must be rebuilt with a fresh anchor and expiry.
    case transferExpired
}

/// Where the account's migration is, as the UI talks about it.
///
/// PER-RUN, not per-account: `.complete` means the stored run finished (or was cancelled), NOT that
/// the account has nothing left to migrate. A large balance takes several successive runs, and
/// funds received later re-create a migratable balance — "is there more?" is answered by an empty
/// `proposeMigrationTransfers`, never by this.
enum MigrationState: Equatable, Sendable {
    /// No run is stored: none was started, or a previous one was cancelled.
    case notStarted
    /// The run is committed and its preparation (note-split) transactions are not all mined yet.
    case splitPendingConfirmation
    /// Preparation is mined and the run's transfers are executing.
    case inProgress(MigrationProgress)
    /// Something needs the user before the run can continue.
    case requiresAttention(MigrationAttentionReason)
    /// Every transaction of the stored run is mined (M1: a terminal run that stopped short —
    /// the engine reports those as complete too — derives `.requiresAttention`, never this).
    case complete
}

extension MigrationState {
    /// The SDK handoff's state-recognition recipe, in one place.
    ///
    /// | this state | the signals that produce it |
    /// |---|---|
    /// | `.notStarted` | no advance step AND no progress |
    /// | `.splitPendingConfirmation` | statuses exist and the preparation phase is not complete |
    /// | `.inProgress` | `.prove` / `.broadcast` / `.waiting`, with `progress` for the N-of-M |
    /// | `.requiresAttention(.invalidTransfer)` | the engine's own `.requiresAttention(id:)`, or `hasInvalid` |
    /// | `.requiresAttention(.transferExpired)` | `.rebuild(id:)` |
    /// | `.complete` | `.complete` — but ONLY when every `.transfer` status is mined (or none
    ///   exist); a terminal run with an unmined transfer TERMINATED UNFINISHED and derives
    ///   `.requiresAttention(.invalidTransfer)` instead (M1: the engine folds failed runs into
    ///   the `.complete` step) |
    ///
    /// TWO INVALIDATION SIGNALS, and they answer different questions.
    ///
    /// The engine's own `.requiresAttention(id:)` (SDK addendum §2) names a SPECIFIC transaction
    /// marked dead by an observed event — a funding note spent outside the migration, or a terminal
    /// broadcast rejection. Upstream surfaces it FIRST, ahead of every actionable step, and this
    /// honours that ordering rather than re-deriving it.
    ///
    /// `hasInvalidTransfers` answers the coarser run-level question — "spendable Orchard remains
    /// but no scheduled transfer covers it" — which the engine cannot express as a step because it
    /// is about the plan's COVERAGE, not about any one transaction. It is still checked before the
    /// advance step, because a run whose plan no longer covers the balance can keep reporting a
    /// perfectly live `.waiting`.
    ///
    /// Both land on the same state: the banner is a run-level statement either way, and the per-row
    /// identity now comes from each row's own `.invalid` status (SDK addendum §3), which is where
    /// per-row facts belong.
    ///
    /// The preparation check sits below the terminal cases so a complete run is never re-reported
    /// as still splitting.
    ///
    /// - Parameters:
    ///   - advanceStep: `nil` when no run is stored.
    ///   - progress: `nil` for terminal runs (complete AND cancelled) — so it cannot stand alone as
    ///     the "is there a run" signal.
    ///   - statuses: the run's per-transaction rows; `[]` when no run is stored.
    ///   - hasInvalidTransfers: the app's own invalidation read.
    static func derive(
        advanceStep: MigrationAdvanceStep?,
        progress: MigrationProgress?,
        statuses: [MigrationTransactionStatus],
        hasInvalidTransfers: Bool
    ) -> MigrationState {
        guard let advanceStep else {
            // No run stored. `progress` can still be non-nil for the immediate send-max sweep,
            // which is a live migration the user should see as in progress even though the engine
            // tracks no run for it.
            if let progress {
                return .inProgress(progress)
            }
            return .notStarted
        }

        if hasInvalidTransfers {
            return .requiresAttention(.invalidTransfer)
        }

        switch advanceStep {
        case .requiresAttention:
            return .requiresAttention(.invalidTransfer)
        case .complete:
            // M1 (E2E harness F#2, A/B-sealed 2026-08-04): the advance step's `.complete` is the
            // step machine's "nothing left to drive", and the engine folds FAILED runs into it
            // (upstream `next_step` reports Complete for every terminal run). A genuinely complete
            // run has every transfer mined; a failed one stopped short — reporting it `.complete`
            // painted the green "Migration complete" banner over a run that moved nothing. The
            // statuses already in hand distinguish the two: any `.transfer` row not `.mined` means
            // the run TERMINATED UNFINISHED, which routes to the attention lane (the same blocker
            // UI where replan / "Migrate anyway" live). Empty statuses stay `.complete` — a
            // finished-and-cleared run reads no differently than before.
            let hasUnminedTransfer = statuses.contains { status in
                guard case MigrationTransactionStatus.Kind.transfer = status.kind else { return false }
                if case MigrationTransactionStatus.State.mined = status.state { return false }
                return true
            }
            return hasUnminedTransfer ? .requiresAttention(.invalidTransfer) : .complete
        case .rebuild:
            return .requiresAttention(.transferExpired)
        case .prove, .broadcast, .waiting:
            if !statuses.isEmpty && !statuses.isPreparationPhaseComplete {
                return .splitPendingConfirmation
            }
            if let progress {
                return .inProgress(progress)
            }
            // A live step with no progress row: treat as in progress with an empty count rather
            // than as not-started, which would hide a run that is demonstrably running.
            return .inProgress(
                MigrationProgress(
                    completedTransfers: 0,
                    totalTransfers: 0,
                    remainingOrchard: .zero,
                    nextTransferReadyAtHeight: nil
                )
            )
        }
    }
}
