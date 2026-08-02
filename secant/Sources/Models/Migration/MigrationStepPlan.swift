//
//  MigrationStepPlan.swift
//  zodl
//
//  THE RULE: one app-open = ask the engine for the next step = discharge exactly that step = done.
//
//  The migration is a SEQUENTIAL process. It is not parallel, it is not a race, and nothing about
//  it is asynchronous beyond "the next step may need a wake-up". The engine owns the whole decision
//  — `Synchronizer.migrationAdvanceStep` is a verbatim conduit of upstream's `next_step` — and the
//  app's only job is to do what it says and then stop.
//
//  Until this type existed the app did NOT follow that model. It read `migrationAdvanceStep` in
//  exactly one place (`MigrationVisit.decide`), branched on `.broadcast` alone, and threw the other
//  five answers away. Two of them — `.rebuild` and `.requiresAttention` — had NO automatic
//  discharge anywhere in the app: their only callers (`refreshStaleMigrationTransfers`,
//  `restartCurrentMigrationStep`) sit behind buttons on screens the user has to find. A run whose
//  next step was `.rebuild` therefore sat still forever, no matter how many times the app was
//  opened, while the banner and the re-entry route — deriving from app-side block-height math
//  instead of from the step — offered "Send now" and "Reschedule", which the engine refuses. That
//  is the send-now/reschedule loop with nothing behind it.
//
//  So: this file makes the discharge of every step a COMPILE-TIME obligation. `action(for:phase:)`
//  switches exhaustively over `MigrationAdvanceStep` with no `default:` — a new engine step breaks
//  the build rather than silently becoming another deadlock.
//
//  THE TWO PHASES. One app-open has exactly two moments at which the engine can be obeyed, and
//  which step may be discharged at which moment is fixed by ZIP 318's session separation, not by
//  convenience:
//
//   - `.beforeSync` — decided BEFORE the wire is touched, because the correlation a broadcast-only
//     session exists to prevent is created the moment sync CONNECTS, not when it finishes. This is
//     the only phase that may broadcast.
//   - `.afterSync` — the sync-complete edge. The wallet is at the tip, so every settled anchor is
//     witnessable: this is the only phase that may prove. Having just synced, it must never
//     broadcast.
//
//  A step whose discharge belongs to the other phase yields `.nothing(.wrongPhase)`, which is a
//  first-class answer meaning "this open is a sync session; let it sync and I will be asked again
//  at the edge" — NOT "nothing to do".
//
//  See `docs/slipstream/migration/MIGRATION_STACK_MAP.md` §5 for the full-stack picture this
//  implements, and `MigrationStepDriver` for the executor.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// WHEN in one app-open the driver is running. See the file header for why the split is a privacy
/// property rather than an implementation detail.
enum MigrationOpenPhase: Equatable, Sendable {
    /// Before any network activity — the ZIP 318 session-kind decision. The only phase that may
    /// broadcast.
    case beforeSync
    /// The sync-complete edge, wallet at the tip. The only phase that may prove, and the one phase
    /// that must never broadcast.
    case afterSync
}

/// What the app must DO to discharge one engine step at one phase — the whole vocabulary, and
/// deliberately small. Every case has exactly one executor in `MigrationStepDriver`.
enum MigrationStepAction: Equatable, Sendable {
    /// Submit the named transaction and END the session (no sync). `.beforeSync` only.
    case broadcast(id: UInt32)
    /// Run the prove sweep. `.afterSync` only — proving needs the commitment tree at the tip.
    case prove(id: UInt32)
    /// Rebuild the expired transfer in place. `.afterSync` only: the rebuilt rows are re-anchored
    /// against the current tip, so a stale tip would rebuild them straight back into staleness.
    case rebuild(id: UInt32)
    /// The engine wants more scanned data before it will adjudicate. Sync and ask again — this IS
    /// the documented first discharge of `.requiresAttention`, and it costs the user nothing.
    case resync(id: UInt32)
    /// Attention SURVIVED a full sync: the obstruction is not transient and the run needs a
    /// decision only the user can take. Surface it; never sit on it.
    case escalateAttention(id: UInt32)
    /// Nothing is actionable. Register the wake-ups and end the session honestly.
    case armWakeups
    /// The stored run is terminal. Stop polling it.
    case finish
    /// No work at this phase — see `MigrationStepHold` for which kind of "no".
    case nothing(MigrationStepHold)
}

/// WHY an action is `.nothing`. The distinction matters because one of these is healthy and the
/// other means the app was asked something it has no run to answer for.
enum MigrationStepHold: Equatable, Sendable {
    /// The step's discharge belongs to the OTHER phase of this same app-open. The session proceeds
    /// normally (it syncs) and the driver is asked again at the edge.
    case wrongPhase
    /// No run is stored for this account — `migrationAdvanceStep` returned `nil`. Nothing to
    /// advance and nothing to poll.
    case noRun
}

/// A step the app cannot discharge on its own, recorded so the banner and the re-entry route can
/// offer the ONE action that will actually move the run.
///
/// This type exists because the alternative — the app silently doing nothing while the engine waits
/// — is the deadlock. If we cannot act, we must say precisely what is needed.
enum MigrationStepBlocker: Equatable, Sendable {
    /// `.rebuild` on a Keystone account: the rebuilt rows come back unsigned and need the signing
    /// ceremony. Only the user can run it.
    case rebuildNeedsSignature(id: UInt32)
    /// `.requiresAttention` survived a full sync: a funding note left the wallet, or a broadcast was
    /// rejected outright. Amounts change, so a new plan needs the user's consent.
    case attentionNeedsNewPlan(id: UInt32)
    /// The engine reports rows as ready-to-prove and the sweep proves none of them, repeatedly.
    /// Staying in the app does not help, so the app must stop asking the user to.
    case provingStalled
}

enum MigrationStepPlan {
    /// The single decision table: engine step × phase -> what to do.
    ///
    /// EXHAUSTIVE BY CONSTRUCTION. There is no `default:` here and there must never be one: the
    /// whole point of this function is that a step the app forgets to discharge cannot compile.
    ///
    /// - Parameters:
    ///   - step: the engine's answer, or `nil` when no run is stored.
    ///   - phase: which moment of the app-open this is.
    static func action(for step: MigrationAdvanceStep?, phase: MigrationOpenPhase) -> MigrationStepAction {
        guard let step else { return MigrationStepAction.nothing(MigrationStepHold.noRun) }

        switch step {
        case let MigrationAdvanceStep.broadcast(id):
            // ZIP 318: a proven transfer is delivered in a session that does not sync. At the
            // post-sync edge this session has ALREADY synced, so broadcasting here would create
            // exactly the adjacency the separation exists to prevent — it waits for the next open.
            return phase == MigrationOpenPhase.beforeSync
                ? MigrationStepAction.broadcast(id: id)
                : MigrationStepAction.nothing(MigrationStepHold.wrongPhase)

        case let MigrationAdvanceStep.prove(id, _):
            // The kind (`.transfer` vs `.preparation`) changes what happens AFTER the proof — a
            // preparation may also broadcast at the same wake-up, a transfer waits for its own
            // session — and that is the broadcast lane's business, decided by the engine's next
            // answer. It does not change whether we prove now, which is the only question here.
            return phase == MigrationOpenPhase.afterSync
                ? MigrationStepAction.prove(id: id)
                : MigrationStepAction.nothing(MigrationStepHold.wrongPhase)

        case let MigrationAdvanceStep.rebuild(id):
            return phase == MigrationOpenPhase.afterSync
                ? MigrationStepAction.rebuild(id: id)
                : MigrationStepAction.nothing(MigrationStepHold.wrongPhase)

        case let MigrationAdvanceStep.requiresAttention(id):
            // The SDK's own discharge, in two beats: SYNC and re-ask, because the engine adjudicates
            // against scanned data and the obstruction is often transient; only if it survives that
            // sync does the user get involved. Doing the cheap automatic half first is what keeps
            // an attention state from becoming a support ticket.
            return phase == MigrationOpenPhase.beforeSync
                ? MigrationStepAction.resync(id: id)
                : MigrationStepAction.escalateAttention(id: id)

        case MigrationAdvanceStep.waiting:
            return MigrationStepAction.armWakeups

        case MigrationAdvanceStep.complete:
            return MigrationStepAction.finish
        }
    }

    /// Whether this open is a BROADCAST session — the wallet-wide ZIP 318 decision, taken from the
    /// same steps the driver is about to discharge rather than from a second, independent read.
    ///
    /// Wallet-wide, not per-account, and deliberately so: sync is a single wallet-level activity, so
    /// if ANY account is mid-broadcast the whole wallet stays off the wire. A Zodl wallet and a
    /// Keystone wallet run independent plans but share one network identity.
    static func isBroadcastSession(steps: [MigrationAdvanceStep?]) -> Bool {
        steps.contains { step in
            if case MigrationAdvanceStep.broadcast? = step { return true }
            return false
        }
    }
}
