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
//  THE THIRD PHASE. `.tick` (MOB-1466) is not a moment inside an app-open at all — it is a
//  recurring 30s wake-up Root runs for as long as the app stays OPEN in the FOREGROUND with a
//  `.privateScheduled` run active, added because `.beforeSync` was, until now, the ONLY broadcast
//  opportunity that existed: a wallet left sitting on the migration progress screen (or anywhere
//  else) for the ten-plus minutes between transfer windows advanced nothing on its own, no matter
//  how long it stayed frontmost, because nothing short of a fresh app-open ever asked the engine
//  again.
//
//  A tick is safe to broadcast from for the exact reason a `.beforeSync` open is: NEITHER runs a
//  sync first. The manager's broadcast lane (`MigrationManagerImpl.broadcastOneTransfer`) stops
//  sync before it ever touches the wire (`stopSyncBeforeMigrationBroadcast`), and the privacy
//  buffer (`sendGate`) that separates a sync from a send does not care WHY the app is asking,
//  only whether one happened recently — so a
//  tick reproduces an app-open's network shape one-for-one rather than inventing a new correlation
//  the buffer was never built to prevent. That is why the tick column below sends `.broadcast`
//  straight to the SAME action `.beforeSync` produces, not a variant of it: as far as the wire is
//  concerned, the two are indistinguishable.
//
//  Everything else stays exactly where it already was. `.prove`/`.rebuild`/`.requiresAttention` are
//  all anchored to a sync boundary this recurring wake-up never crosses on its own — proving needs
//  the post-sync tip, rebuilding re-anchors against it, and attention's cheap first half IS a sync
//  — so a tick can only ever defer them (`.wrongPhase`) to the open or edge that actually owns them.
//  `.waiting`/`.complete`/`nil` were never phase-dependent in the first place and stay that way.
//
//  See `docs/slipstream/migration/MIGRATION_STACK_MAP.md` §5 for the full-stack picture this
//  implements, and `MigrationStepDriver` for the executor — including the single-flight latch, the
//  mode belt, and the privacy-buffer fast path that keep an idle tick cheap and an `.immediate` run
//  untouched by it.
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
    /// MOB-1466: a recurring foreground wake-up, not a moment inside an app-open — see the file
    /// header's "THE THIRD PHASE" note. A second broadcast opportunity, on the same terms as
    /// `.beforeSync` (no sync of its own); everything else defers to the open/edge that owns it.
    case tick
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
            switch phase {
            case MigrationOpenPhase.beforeSync:
                // ZIP 318: a proven transfer is delivered in a session that does not sync.
                return MigrationStepAction.broadcast(id: id)
            case MigrationOpenPhase.afterSync:
                // This session has ALREADY synced, so broadcasting here would create exactly the
                // adjacency the separation exists to prevent — it waits for the next open.
                return MigrationStepAction.nothing(MigrationStepHold.wrongPhase)
            case MigrationOpenPhase.tick:
                // THE TICK COLUMN's one substantive answer — see the file header's "THE THIRD
                // PHASE" note. A tick runs no sync of its own, same as `.beforeSync`, so the same
                // action is correct: the driver's broadcast lane cannot tell the two apart, and
                // neither should this table.
                return MigrationStepAction.broadcast(id: id)
            }

        case let MigrationAdvanceStep.prove(id, _):
            // The kind (`.transfer` vs `.preparation`) changes what happens AFTER the proof — a
            // preparation may also broadcast at the same wake-up, a transfer waits for its own
            // session — and that is the broadcast lane's business, decided by the engine's next
            // answer. It does not change whether we prove now, which is the only question here.
            switch phase {
            case MigrationOpenPhase.afterSync:
                return MigrationStepAction.prove(id: id)
            case MigrationOpenPhase.beforeSync, MigrationOpenPhase.tick:
                // A tick crosses no sync boundary of its own, so it is exactly as wrong a moment
                // to prove as `.beforeSync` already is — the post-sync edge still owns this step.
                return MigrationStepAction.nothing(MigrationStepHold.wrongPhase)
            }

        case let MigrationAdvanceStep.rebuild(id):
            switch phase {
            case MigrationOpenPhase.afterSync:
                return MigrationStepAction.rebuild(id: id)
            case MigrationOpenPhase.beforeSync, MigrationOpenPhase.tick:
                // Same reasoning as `.prove` above: a rebuild re-anchors against the CURRENT tip,
                // and a tick has not synced to move that tip since the last time it was read.
                return MigrationStepAction.nothing(MigrationStepHold.wrongPhase)
            }

        case let MigrationAdvanceStep.requiresAttention(id):
            switch phase {
            case MigrationOpenPhase.beforeSync:
                // The SDK's own discharge, in two beats: SYNC and re-ask, because the engine
                // adjudicates against scanned data and the obstruction is often transient; only if
                // it survives that sync does the user get involved. Doing the cheap automatic half
                // first is what keeps an attention state from becoming a support ticket.
                return MigrationStepAction.resync(id: id)
            case MigrationOpenPhase.afterSync:
                return MigrationStepAction.escalateAttention(id: id)
            case MigrationOpenPhase.tick:
                // A tick cannot run the cheap sync-and-re-ask half (it has no sync of its own) and
                // must not escalate to the user off the back of a 30s timer either — both remain
                // the opens'/edge's business, exactly as `.prove`/`.rebuild` do above.
                return MigrationStepAction.nothing(MigrationStepHold.wrongPhase)
            }

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
