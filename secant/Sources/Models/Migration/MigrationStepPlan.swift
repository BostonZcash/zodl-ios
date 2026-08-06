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
//     broadcast a TRANSFER. A note-PREPARATION is the documented exception (AUD-3, 2026-08-05):
//     ZIP 318 scopes the sync/broadcast separation to Phase 2 transfers ("a preparation
//     transaction is a fully shielded send-to-self"), and the engine's own contract is "a
//     preparation is broadcast as soon as it is proved" — so a prep proved at this edge is
//     delivered at this edge (`isPreparationBroadcast` below).
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
//  Everything else stays anchored to a sync boundary — with ONE exception. `.rebuild` and
//  `.requiresAttention` a tick can only ever defer (`.wrongPhase`): rebuilding re-anchors
//  against the post-sync tip and attention's cheap first half IS a sync. `.prove` a tick DOES
//  discharge, unconditionally (FIND-5, 2026-08-05 — the marathon-session starvation). The tick
//  prove began 2026-08-02 gated on the wallet reading `.upToDate`, on the theory that "the
//  post-sync edge owns proving" was a proxy for "the commitment tree is current". The field then
//  produced a session where that gate starved proving for 50+ minutes: broadcast churn and the
//  sync gate's own ready-broadcast hold kept `syncStatus` off `.upToDate` essentially forever,
//  so ticks deferred every prove while no edge was coming, and the whole run's throughput
//  collapsed to one prove sweep per app-REOPEN — in the very session whose banner said "Keep
//  Zodl open". The gate was conservatism, not correctness: the engine's `.prove` answer is
//  evaluated on the SCANNED frame (an anchor it names is settled in data the wallet has), and
//  the SDK documents the sweep as safe on any schedule, including mid-sync. So the tick obeys
//  the engine, full stop. `.waiting`/`.complete`/`nil` were never phase-dependent in the first
//  place and stay that way.
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
    /// Run the prove sweep. `.afterSync` and `.tick` (FIND-5) — proving needs the commitment tree
    /// at the tip. `isPreparation` carries the step's own kind into the discharge: a proved
    /// note-PREPARATION also broadcasts in the SAME pass (D2 — nuttycom: "no second call needed,
    /// inspect the kind attribute of `Prove { id, kind }` and if it matches Preparation then
    /// prove and broadcast"), while a transfer's broadcast waits for its own session.
    case prove(id: UInt32, isPreparation: Bool)
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
    ///   - isPreparationBroadcast: AUD-3 — whether a `.broadcast` step's id names a note-
    ///     PREPARATION (the driver derives it from `migrationTransactionStatuses`). Consulted by
    ///     exactly one cell, the `.broadcast` row's `.afterSync` column: ZIP 318's sync/broadcast
    ///     separation is scoped to TRANSFERS ("a preparation transaction is a fully shielded
    ///     send-to-self"), and the engine's own contract is "a preparation is broadcast as soon
    ///     as it is proved" — at the very edge that proved it. The default `false` keeps the
    ///     conservative transfer treatment.
    ///
    /// (An `isWalletAtTip` parameter lived here 2026-08-02 → 2026-08-05, consulted by the
    /// `.prove` row's `.tick` column. FIND-5 removed it — see the file header's "with ONE
    /// exception" note for the marathon-session starvation it caused.)
    static func action(
        for step: MigrationAdvanceStep?,
        phase: MigrationOpenPhase,
        isPreparationBroadcast: Bool = false
    ) -> MigrationStepAction {
        guard let step else { return MigrationStepAction.nothing(MigrationStepHold.noRun) }

        switch step {
        case let MigrationAdvanceStep.broadcast(id):
            switch phase {
            case MigrationOpenPhase.beforeSync:
                // ZIP 318: a proven transfer is delivered in a session that does not sync.
                return MigrationStepAction.broadcast(id: id)
            case MigrationOpenPhase.afterSync:
                // A TRANSFER must wait for the next open: this session has ALREADY synced, and
                // broadcasting a pool-crossing here would create exactly the adjacency the
                // separation exists to prevent. A PREPARATION is the documented exception
                // (AUD-3): ZIP 318 exempts it from the separation, and deferring it here is what
                // used to cost every prep a whole extra human open — proved at this edge, it
                // goes out at this edge.
                return isPreparationBroadcast
                    ? MigrationStepAction.broadcast(id: id)
                    : MigrationStepAction.nothing(MigrationStepHold.wrongPhase)
            case MigrationOpenPhase.tick:
                // THE TICK COLUMN's one substantive answer — see the file header's "THE THIRD
                // PHASE" note. A tick runs no sync of its own, same as `.beforeSync`, so the same
                // action is correct: the driver's broadcast lane cannot tell the two apart, and
                // neither should this table.
                return MigrationStepAction.broadcast(id: id)
            }

        case let MigrationAdvanceStep.prove(transactions):
            // The engine offers the WHOLE provable set (#2939) — earliest-ready first, never empty
            // (SDK contract; `transactions[0]` below leans on it, and a breached contract must
            // crash here rather than read as "no run"). The action still carries ONE id: the HEAD,
            // exactly the entry the old single-id step named. The discharge's sweep proves every
            // ready row in one pass regardless; the head's id/kind only route what happens AFTER
            // the proof — a preparation broadcasts at the SAME wake-up, a transfer waits for its
            // own session. D2 (nuttycom, 2026-08-05): "there should be no second call needed —
            // inspect the kind attribute of `Prove { id, kind }`, and if it matches Preparation
            // then prove and broadcast." The step itself is the sanction; nothing re-asks the
            // engine. (A preparation elsewhere in the batch behind a transfer head still gets
            // PROVED by the whole-queue sweep; its broadcast follows at the edge whose step names
            // it — nothing new to handle.)
            switch phase {
            case MigrationOpenPhase.afterSync:
                return MigrationStepAction.prove(id: transactions[0].id, isPreparation: transactions[0].kind.isPreparation)
            case MigrationOpenPhase.tick:
                // A tick proves UNCONDITIONALLY (FIND-5, 2026-08-05). Two prior versions of this
                // cell each starved a real session: full deferral (pre-2026-08-02) starved
                // follow-mode, where no sync edge ever re-fires; the at-tip gate that replaced it
                // starved the marathon session, where broadcast churn and the sync gate's own
                // ready-broadcast hold keep `syncStatus` off `.upToDate` for the whole sitting —
                // the field saw proving collapse to one sweep per app-REOPEN, under a banner
                // asking the user to keep the app open. The gate guarded nothing: the engine
                // answers `.prove` on the SCANNED frame (the anchor it names is settled in data
                // the wallet has), and the sweep is documented safe on any schedule, including
                // mid-sync. Proving is local computation, so ZIP 318's broadcast-session
                // separation is untouched. The one tick-side refinement lives in the driver: a
                // sweep already adjudicated STALLED is not re-run every 30s.
                return MigrationStepAction.prove(id: transactions[0].id, isPreparation: transactions[0].kind.isPreparation)
            case MigrationOpenPhase.beforeSync:
                // The open's own edge is moments away and must stay free to broadcast instead —
                // deferring here is unchanged even at the tip.
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

extension MigrationTransactionStatus.Kind {
    /// A note-PREPARATION ("split") — wallet plumbing on the engine's own schedule, ZIP-318-exempt
    /// ("a fully shielded send-to-self") and broadcast as soon as it is proved (D2).
    var isPreparation: Bool {
        if case MigrationTransactionStatus.Kind.preparation = self { return true }
        return false
    }
}
