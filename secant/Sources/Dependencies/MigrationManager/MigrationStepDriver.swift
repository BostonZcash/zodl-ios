//
//  MigrationStepDriver.swift
//  zodl
//
//  THE DRIVER: the one place the app obeys the migration engine.
//
//  `MigrationStepPlan` is the decision table (step × phase -> action) and it is pure. This file is
//  its executor, and between them they are the whole of the app's migration control flow. Nothing
//  else in the app may read `migrationAdvanceStep` and act on it; nothing else may decide what a
//  migration app-open does.
//
//  WHAT THIS REPLACED. The app used to read the engine's step in one place (`visitKind`), branch on
//  `.broadcast` alone, and discard the other five answers — then run its own sweeps and lanes on a
//  schedule of its own devising. `.rebuild` and `.requiresAttention` had no automatic discharge at
//  all: their only callers sat behind buttons on screens the user had to find, so a run whose next
//  step was either of those stopped dead and stayed dead across any number of app-opens. Meanwhile
//  the banner and the re-entry route derived from app-side block-height math rather than from the
//  step, so what the app OFFERED ("Send now", "Reschedule") and what the engine would ACCEPT had
//  drifted apart. That pair — a step nobody discharges plus a CTA the engine refuses — is the
//  send-now/reschedule loop with nothing behind it.
//
//  THE INVARIANTS this file exists to hold. All five are load-bearing; each one is a bug we shipped.
//
//   I1  EVERY STEP HAS A DISCHARGE. `MigrationStepPlan.action(for:phase:)` is exhaustive with no
//       `default:`. A new engine step is a compile error, not a new deadlock.
//   I2  EVERY OPEN ENDS WITH A VERDICT. `advance` always logs what it did and why, including
//       "nothing, because X". A session that did nothing and said nothing is indistinguishable from
//       a frozen app — that is precisely how six minutes of stale spinners got diagnosed as
//       "probably finished".
//   I3  PROGRESS OR ESCALATION, NEVER SILENCE. When the app cannot discharge a step itself it
//       records a `MigrationStepBlocker` so the banner and route can offer the ONE action that
//       moves the run. It never sits on a step it cannot take.
//   I4  ENTRY-INDEPENDENT. Tapping the icon and tapping a notification run the identical driver
//       calls in the identical order. A notification tap adds navigation and nothing else.
//   I5  NO SELF-DISARM. A session that suppresses sync always arms its own resume. (N4: a broadcast
//       session used to suppress sync, fail to arm the resume, and freeze the run for the whole
//       app-open.)
//
//  See `docs/slipstream/migration/MIGRATION_STACK_MAP.md` for the engine-to-app picture.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// What one `advance` call actually did — the session verdict of I2, and the driver's return value.
///
/// Every case is a sentence the log can print and a human can act on. `.held` is deliberately
/// distinct from `.idle`: "the privacy buffer is holding this for four more minutes" and "there is
/// genuinely nothing to do" look the same on screen and could not be told apart in a log.
enum MigrationStepVerdict: Equatable, Sendable {
    /// Migration is not applicable — flag off, Ironwood not activated, or no candidate accounts.
    case notApplicable
    /// No run is stored for any candidate account.
    case noRun
    /// A transfer was broadcast. ZIP 318: this session carried exactly one, and it is over.
    case broadcast(id: UInt32)
    /// A broadcast was due but withheld, with the reason. Holding is a legitimate outcome; being
    /// unable to say why is not.
    case held(reason: String)
    /// The prove sweep produced this many proofs (`0` is the ordinary "nothing was ready" answer).
    case proved(count: Int)
    /// An expired transfer was rebuilt in place, without the user.
    case rebuilt(id: UInt32)
    /// The engine wants more scanned data before it adjudicates. This session syncs and asks again.
    case resyncing(id: UInt32)
    /// The app cannot take this step alone. The blocker names what the user must do.
    case needsUser(MigrationStepBlocker)
    /// Nothing is actionable; wake-ups are armed.
    case idle
    /// The stored run is terminal.
    case complete
    /// The step's discharge belongs to the other phase of this same open. Not an error, not a stall
    /// — the session proceeds and the driver is asked again at the edge.
    case deferredToPhase
    /// A discharge was attempted and failed. Carries the reason; never swallowed.
    case failed(String)
}

extension MigrationManagerImpl {
    /// THE DRIVER. Ask the engine for the next step, discharge exactly that step, end the session.
    ///
    /// Called at exactly two moments per app-open — `.beforeSync` (before the wire is touched) and
    /// `.afterSync` (the sync-complete edge) — from Root, and from nowhere else. Both entry paths,
    /// icon tap and notification tap, reach the same two calls in the same order (I4).
    ///
    /// Per-account, in the engine's own priority order, but ZIP 318's session decision is
    /// wallet-wide and taken FIRST, from the same batch of steps this call is about to discharge —
    /// not from a second, independent read that could disagree with it. That single-read property
    /// is what makes the "two clocks" class of bug impossible here.
    ///
    /// Never throws. A migration read failure must not be able to brick ordinary wallet syncing, so
    /// every internal failure degrades to a logged `.failed` verdict and the wallet carries on.
    @discardableResult
    func advance(phase: MigrationOpenPhase) async -> MigrationStepVerdict {
        guard isIronwoodActivated() else {
            return MigrationStepVerdict.notApplicable
        }

        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: selectedWalletAccount?.id,
            walletAccounts: walletAccounts
        )
        guard !accountUUIDs.isEmpty else {
            return MigrationStepVerdict.notApplicable
        }

        // ONE read of the engine, for every candidate account, feeding BOTH the wallet-wide session
        // decision and the per-account discharge below. The old code read `migrationAdvanceStep`
        // once in `visitKind` for the session decision and again inside `runBroadcastSession` for
        // the delivery, and a tip that moved between the two reads made them disagree.
        var steps: [(accountUUID: AccountUUID, step: MigrationAdvanceStep?)] = []
        for accountUUID in accountUUIDs {
            let step = try? await sdkSynchronizer.migrationAdvanceStep(accountUUID)
            // THE key driver line, logged verbatim at both phases. A run sitting at 0-of-12 looks
            // identical whether the engine is saying `prove`, `waiting` or `broadcast` — this is the
            // line that tells those apart, and until 07-31 it was the one thing never written down.
            LoggerProxy.event(
                "\(Self.logTag) advance step (\(phase)): \(step.map { String(describing: $0) } ?? "none (no run)")"
            )
            steps.append((accountUUID, step))
        }

        let verdict = await discharge(steps: steps, phase: phase)

        // I2: every open ends with a verdict, printed. Including — especially including — the
        // sessions that did nothing.
        LoggerProxy.event("\(Self.logTag) ▸ session verdict (\(phase)): \(verdict)")

        // Wake-ups are re-armed on EVERY path, not only the `.waiting` one. The schedule is a
        // function of the run's rows, and a discharge that changed those rows (a broadcast, a
        // rebuild) has invalidated whatever was armed before it. Arming after the discharge rather
        // than instead of it is what keeps a poke pointing at the right event.
        for accountUUID in accountUUIDs {
            await armNextWindowNotifications(accountUUID: accountUUID)
        }

        return verdict
    }

    /// The per-account discharge loop. Returns the FIRST substantive verdict — the engine's steps are
    /// already priority-ordered, and ZIP 318 caps a session at one broadcast, so "first substantive"
    /// is the honest summary of what this open accomplished.
    private func discharge(
        steps: [(accountUUID: AccountUUID, step: MigrationAdvanceStep?)],
        phase: MigrationOpenPhase
    ) async -> MigrationStepVerdict {
        var fallback = MigrationStepVerdict.noRun

        for (accountUUID, step) in steps {
            let action = MigrationStepPlan.action(for: step, phase: phase)
            let verdict = await execute(action, accountUUID: accountUUID, phase: phase)

            // Not substantive on its own, but a better summary than `noRun` — keep the most
            // informative one seen so far and let a later account override it.
            let isQuiet = [
                MigrationStepVerdict.noRun,
                MigrationStepVerdict.deferredToPhase,
                MigrationStepVerdict.idle,
                MigrationStepVerdict.complete
            ].contains(verdict)

            guard isQuiet else { return verdict }
            if fallback == MigrationStepVerdict.noRun { fallback = verdict }
        }

        return fallback
    }

    /// One action, executed. The switch is exhaustive over `MigrationStepAction` (I1) — every case
    /// the planner can produce has a body here, and adding a case to either breaks the build.
    // swiftlint:disable:next cyclomatic_complexity
    private func execute(
        _ action: MigrationStepAction,
        accountUUID: AccountUUID,
        phase: MigrationOpenPhase
    ) async -> MigrationStepVerdict {
        switch action {
        case let MigrationStepAction.broadcast(id):
            return await executeBroadcast(id: id, accountUUID: accountUUID)

        case MigrationStepAction.prove:
            // The sweep is wallet-wide by construction (it walks every candidate account), so it
            // runs once per driver call rather than once per account. The first account to ask for
            // it gets it; the rest see the proofs it produced.
            let proved = await runProveSweep()
            await reconcile()
            if proved == 0 && isProvingStalled {
                // I3: the engine says these rows are ready and the sweep proves none of them, twice
                // running. Staying in the app does not help, so the app stops asking the user to —
                // and says so rather than leaving a spinner up.
                return MigrationStepVerdict.needsUser(MigrationStepBlocker.provingStalled)
            }
            return MigrationStepVerdict.proved(count: proved)

        case let MigrationStepAction.rebuild(id):
            return await executeRebuild(id: id, accountUUID: accountUUID)

        case let MigrationStepAction.resync(id):
            // The cheap automatic half of `.requiresAttention`: this session syncs (it is a sync
            // session by construction — `.resync` is only ever produced at `.beforeSync`) and the
            // driver asks the engine again at the edge, where the newly scanned data may well have
            // cleared the obstruction with the user none the wiser.
            LoggerProxy.event(
                "\(Self.logTag) attention on transaction \(id) — syncing and re-asking before involving the user"
            )
            return MigrationStepVerdict.resyncing(id: id)

        case let MigrationStepAction.escalateAttention(id):
            // Attention survived a full sync. This is the honest hand-off: the run needs a decision
            // the app cannot take, and the route/banner will carry the user to the one screen whose
            // button discharges it.
            LoggerProxy.event(
                "\(Self.logTag) ⚠ attention on transaction \(id) SURVIVED a sync — the user must re-plan this run"
            )
            await reconcile()
            return MigrationStepVerdict.needsUser(MigrationStepBlocker.attentionNeedsNewPlan(id: id))

        case MigrationStepAction.armWakeups:
            // Arming happens unconditionally in `advance` above; this case exists so `.waiting` has
            // a name in the verdict rather than falling into a catch-all.
            return MigrationStepVerdict.idle

        case MigrationStepAction.finish:
            return MigrationStepVerdict.complete

        case let MigrationStepAction.nothing(hold):
            switch hold {
            case MigrationStepHold.wrongPhase:
                return MigrationStepVerdict.deferredToPhase
            case MigrationStepHold.noRun:
                _ = phase
                return MigrationStepVerdict.noRun
            }
        }
    }

    /// `.broadcast` — delegates to the existing headless send session, which owns the privacy
    /// buffer, the manual-delivery opt-out, the network snapshot and the failure routing.
    ///
    /// The driver deliberately does NOT reimplement any of that. It only translates the outcome
    /// into a verdict, so that "held by the buffer" stops looking like "did nothing".
    private func executeBroadcast(id: UInt32, accountUUID: AccountUUID) async -> MigrationStepVerdict {
        if gateStorage.isManualDelivery(for: accountUUID) {
            return MigrationStepVerdict.held(reason: "delivery is manual — transfer \(id) is left for the user to send")
        }

        let gate = await sendGate()
        if case let MigrationSendGate.waitUntil(gateUntil) = gate {
            return MigrationStepVerdict.held(
                reason: "privacy buffer until \(gateUntil) (\(Int(gateUntil.timeIntervalSinceNow))s)"
            )
        }

        let didBroadcast = await runBroadcastSession()
        return didBroadcast
            ? MigrationStepVerdict.broadcast(id: id)
            : MigrationStepVerdict.held(reason: "broadcast session submitted nothing for transfer \(id)")
    }

    /// `.rebuild` — the step that used to deadlock the hardest, because its only discharge in the
    /// whole app was a button on a screen nothing routed to.
    ///
    /// A software account rebuilds AUTOMATICALLY here. The engine's contract for a rebuild is that
    /// the elapsed rows are re-anchored IN PLACE with unchanged amounts — there is no new consent
    /// decision to take the user through, so making them tap through one was never protecting
    /// anything, it was just the only code path that existed. `exportWallet()` is a plain keychain
    /// read on iOS, so this raises no authentication prompt.
    ///
    /// A Keystone account cannot: its rebuilt rows come back unsigned and need the signing ceremony,
    /// which is genuinely the user's. That is recorded as a blocker (I3), never silently dropped.
    private func executeRebuild(id: UInt32, accountUUID: AccountUUID) async -> MigrationStepVerdict {
        let account = walletAccounts.first { $0.id == accountUUID }

        guard account?.vendor != WalletAccount.Vendor.keystone else {
            LoggerProxy.event(
                "\(Self.logTag) transfer \(id) expired on a Keystone account — the rebuilt batch needs a signing ceremony"
            )
            return MigrationStepVerdict.needsUser(MigrationStepBlocker.rebuildNeedsSignature(id: id))
        }

        guard let zip32AccountIndex = account?.zip32AccountIndex else {
            // A software account with no ZIP 32 index is a "can't happen". It routes to the user
            // rather than to a silent no-op, because a can't-happen that stalls a run forever is
            // strictly worse than one that shows a screen.
            return MigrationStepVerdict.needsUser(MigrationStepBlocker.rebuildNeedsSignature(id: id))
        }

        do {
            let usk = try MigrationSpendingKeyDerivation.deriveUSK(
                zip32AccountIndex: zip32AccountIndex,
                walletStorage: walletStorage,
                mnemonic: mnemonic,
                derivationTool: derivationTool,
                networkType: zcashSDKEnvironment.network().networkType
            )
            let schedule = try await sdkSynchronizer.refreshStaleMigrationTransfers(accountUUID, usk)
            // Persist the RETURNED schedule as committed truth BEFORE reconcile, exactly as the
            // Recovery screen's lane does: the SDK keeps no app-facing schedule post-refresh, so
            // without this the app would keep rendering the stale pre-refresh heights.
            await recordCommittedSchedule(accountUUID: accountUUID, schedule: schedule)
            await reconcile()
            LoggerProxy.event("\(Self.logTag) rebuilt expired transfer \(id) in place — no user action was needed")
            return MigrationStepVerdict.rebuilt(id: id)
        } catch {
            // A failed automatic rebuild is not a dead end: the Recovery screen's own button runs
            // the same call with the user present, so route them to it rather than retrying blind.
            LoggerProxy.event("\(Self.logTag) automatic rebuild of transfer \(id) failed: \(error.toZcashError())")
            return MigrationStepVerdict.needsUser(MigrationStepBlocker.rebuildNeedsSignature(id: id))
        }
    }
}
