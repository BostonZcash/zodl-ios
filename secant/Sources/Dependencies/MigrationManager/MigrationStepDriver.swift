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
    /// The call yielded without reading the engine at all. Two producers:
    /// - MOB-1466: a `.tick` arrived while another `advance` call was already in flight — the
    ///   single-flight latch's fast-reject path. Quiet by construction (see `isQuietForTick`): a
    ///   busy driver is not news the way a stalled or blocked run is, and logging it at `.event`
    ///   every time a 30s tick loses this race would be exactly the noise the tick's own log
    ///   hygiene exists to avoid. Ticks never park (FIFO waiting is the open lanes' privilege).
    /// - R0: an open lane (`.beforeSync`/`.afterSync`) whose per-session credit is already spent,
    ///   or that was called with no live session at all (fail-closed) — see the R0 credit gate in
    ///   `advance(phase:)`. Always `.event`-logged: a refused open-lane drive is the law working,
    ///   and the log line is how a field trace proves which path over-asked.
    case skipped
}

extension MigrationStepVerdict {
    /// Whether THIS verdict, produced at `.tick`, is quiet enough that the tick loop's wake-up
    /// should be treated as a no-op: no re-arm (arming reflects the run's ROWS, and a quiet tick
    /// changed none of them) and a `.debug`, not `.event`, log line (an idle tick every 30s must
    /// not compete, in volume, with the app-open lines every other `[MIG]` reader filters for).
    /// See `MigrationManagerImpl.advance(phase:)`'s tick-specific arming/log hygiene.
    ///
    /// EXHAUSTIVE BY CONSTRUCTION, the same discipline `MigrationStepPlan.action(for:phase:)` holds
    /// (I1): a verdict added to this enum must be classified here before the project compiles, so a
    /// new SUBSTANTIVE verdict can never silently fall quiet, and a new quiet one can never silently
    /// start spamming `.event` every 30 seconds.
    var isQuietForTick: Bool {
        switch self {
        case MigrationStepVerdict.notApplicable,
             MigrationStepVerdict.noRun,
             MigrationStepVerdict.held,
             MigrationStepVerdict.idle,
             MigrationStepVerdict.complete,
             MigrationStepVerdict.deferredToPhase,
             MigrationStepVerdict.skipped:
            return true
        case MigrationStepVerdict.broadcast,
             MigrationStepVerdict.proved,
             MigrationStepVerdict.rebuilt,
             MigrationStepVerdict.resyncing,
             MigrationStepVerdict.needsUser,
             MigrationStepVerdict.failed:
            return false
        }
    }
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
    ///
    /// MOB-1466: SINGLE-FLIGHT, around the whole body below. `.tick` — Root's recurring 30s
    /// foreground wake-up — tries the latch ONCE and yields (`.skipped`, no engine read at all) if
    /// another `advance` is already running; `.beforeSync`/`.afterSync` — an app-open's own driver
    /// calls — wait their turn (FIFO) instead, because an open's call must never be silently
    /// dropped for arriving mid-tick. See `advanceLatch`'s doc and the acquire/release functions
    /// below for the mechanism.
    @discardableResult
    func advance(phase: MigrationOpenPhase) async -> MigrationStepVerdict {
        if phase == .tick {
            LoggerProxy.debug("\(Self.logTag) ▸ Tick (\(phase))")
        }

        guard isIronwoodActivated() else {
            return MigrationStepVerdict.notApplicable
        }

        // R0 — THE GROUND RULE OF ALL GROUND RULES (Lukas, 2026-08-05): one zodl open = ONE
        // `nextStep()` pass, and nothing may ever drive an open lane again in the same foreground
        // session — not a second launch path (C6-1: an open traversing two of Root's `.beforeSync`
        // sites broadcast twice, 4 s apart — a ZIP 318 violation, the engine schedules those sends
        // APART), not a re-firing sync edge (`.afterSync` has two call sites of its own), not
        // navigation, not "something finished so ask again". Enforced here, at the chokepoint every
        // path shares, as consumable per-session credits: `beginSession` (cold launch / foreground)
        // arms ONE credit per open lane by rolling the ordinal; the lane's first drive consumes it;
        // every later same-session call yields with a logged verdict.
        //
        // FAIL-CLOSED: no live session = no credit = no drive. An open lane acting outside a
        // session would be exactly the "code calls nextStep() on its own clock" R0 exists to ban —
        // production always has one (`beginSession` is the first statement of both entry reducers),
        // so the refusal can only fire where it should: a background wake-up, a stray completion
        // handler, a future call site added outside the open. `.tick` is not an open lane and is
        // governed separately (mode belt, privacy buffer, engine schedule — see
        // `MigrationStepPlan`'s "THE THIRD PHASE").
        if phase == MigrationOpenPhase.beforeSync || phase == MigrationOpenPhase.afterSync {
            guard let sessionOrdinal = sessionOrdinalProvider() else {
                LoggerProxy.event(
                    "\(Self.logTag) ▸ session verdict (\(phase)): skipped — no live session; open-lane drives are fail-closed (R0)"
                )
                MigrationTrace.event("\(phase) REFUSED — no live session (R0 fail-closed)")
                return MigrationStepVerdict.skipped
            }
            let alreadyDriven = openLaneCredits.withLock { credits -> Bool in
                if phase == MigrationOpenPhase.beforeSync {
                    if credits.beforeSyncSpentSession == sessionOrdinal { return true }
                    credits.beforeSyncSpentSession = sessionOrdinal
                    return false
                } else {
                    if credits.afterSyncSpentSession == sessionOrdinal { return true }
                    credits.afterSyncSpentSession = sessionOrdinal
                    return false
                }
            }
            if alreadyDriven {
                LoggerProxy.event(
                    "\(Self.logTag) ▸ session verdict (\(phase)): skipped — \(phase) already driven this session (R0 once-credit)"
                )
                MigrationTrace.event("\(phase) SKIPPED — already driven this session (R0 once-credit)")
                return MigrationStepVerdict.skipped
            }
        }

        if phase == MigrationOpenPhase.tick {
            guard tryAcquireAdvanceLatch() else {
                LoggerProxy.debug("\(Self.logTag) ▸ session verdict (\(phase)): skipped — another advance is already in flight")
                return MigrationStepVerdict.skipped
            }
        } else {
            await acquireAdvanceLatch()
        }
        defer { releaseAdvanceLatch() }

        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: selectedWalletAccount?.id,
            walletAccounts: walletAccounts
        )
        guard !accountUUIDs.isEmpty else {
            return MigrationStepVerdict.notApplicable
        }

        // MOB-1466: THE TICK FAST PATH — before any candidate/engine reads, consult the same
        // privacy-buffer source `executeBroadcast` uses below. A tick fires every 30s; spending a
        // per-account engine read on every one of them just to re-learn "the buffer is holding",
        // which this cheap, wallet-wide, no-SDK-read check already knows, would make an idle tick
        // far from free. `executeBroadcast` still re-checks the same gate once a broadcast is
        // actually due (this is a fast REJECT, not a replacement for that check) — harmless and
        // cheap either way.
        if phase == MigrationOpenPhase.tick {
            let gate = await sendGate()
            if case let MigrationSendGate.waitUntil(gateUntil) = gate {
                let reason = "privacy buffer until \(gateUntil) (\(Int(gateUntil.timeIntervalSinceNow))s)"
                LoggerProxy.debug("\(Self.logTag) ▸ session verdict (\(phase)): held(\(reason))")
                return MigrationStepVerdict.held(reason: reason)
            }
        }

        // ONE read of the engine, for every candidate account, feeding BOTH the wallet-wide session
        // decision and the per-account discharge below. The old code read `migrationAdvanceStep`
        // once in `visitKind` for the session decision and again inside `runBroadcastSession` for
        // the delivery, and a tip that moved between the two reads made them disagree.
        //
        // NOT `try?` (audit 2026-08-03, P1): flattening a THROWN read into `nil` made a transient
        // engine error indistinguishable from "no run stored" — and `.noRun` is the verdict the
        // tick loop SELF-CANCELS on, so one contended read (a prove sweep holding the wallet DB,
        // a synchronizer mid-teardown) killed the tick lane for the rest of the session. This is
        // the exact flattening `MigrationManagerLiveKey`'s own state-read doc forbids. A throw is
        // recorded per-account; accounts that read cleanly still discharge, and an all-throw pass
        // surfaces as `.failed` below — substantive, event-logged, loop-surviving.
        var steps: [(accountUUID: AccountUUID, step: MigrationAdvanceStep?)] = []
        // MOB-1466: buffered, not logged immediately — a `.tick`'s log LEVEL depends on the verdict
        // these reads feed into, which isn't known until `discharge` below returns. See the emission
        // loop after it.
        var stepLogLines: [String] = []
        var stepReadFailure: String?
        for accountUUID in accountUUIDs {
            let step: MigrationAdvanceStep?
            do {
                step = try await sdkSynchronizer.migrationAdvanceStep(accountUUID)
            } catch {
                stepReadFailure = "\(error.toZcashError())"
                stepLogLines.append("\(Self.logTag) advance step (\(phase)): READ FAILED — \(error.toZcashError())")
                continue
            }
            // THE key driver line, logged verbatim at both phases. A run sitting at 0-of-12 looks
            // identical whether the engine is saying `prove`, `waiting` or `broadcast` — this is the
            // line that tells those apart, and until 07-31 it was the one thing never written down.
            stepLogLines.append(
                "\(Self.logTag) advance step (\(phase)): \(step.map { String(describing: $0) } ?? "none (no run)")"
            )
            steps.append((accountUUID, step))
        }

        var verdict = await discharge(steps: steps, phase: phase)
        if steps.isEmpty, let stepReadFailure {
            // EVERY candidate's read threw: the honest session answer is the failure, never
            // `.noRun` — "the engine could not be asked" and "there is nothing to do" must not
            // share a verdict (the latter self-cancels the tick loop).
            verdict = MigrationStepVerdict.failed("engine step read failed: \(stepReadFailure)")
        }

        // MOB-1466: LOG HYGIENE. A quiet `.tick` verdict — nothing changed, nothing needed the user
        // — logs at `.debug`: every 30s, forever, while the app sits open with a scheduled run, is
        // not a volume `.event` (read by default) should carry. A SUBSTANTIVE tick verdict (a
        // broadcast, a rebuild, an escalation…) keeps `.event`, identically to `.beforeSync`/
        // `.afterSync`, which always do (`isQuietForTick` is never consulted for them below).
        let isQuietTick = phase == MigrationOpenPhase.tick && verdict.isQuietForTick
        for line in stepLogLines {
            isQuietTick ? LoggerProxy.debug(line) : LoggerProxy.event(line)
        }
        // I2: every open ends with a verdict, printed. Including — especially including — the
        // sessions that did nothing.
        let verdictLine = "\(Self.logTag) ▸ session verdict (\(phase)): \(verdict)"
        isQuietTick ? LoggerProxy.debug(verdictLine) : LoggerProxy.event(verdictLine)

        // GROUND_RULES R3: the session's verdict now EXISTS — this is the one edge that releases
        // the banner's `.checkingStatus` hold. Marked before the arming/poke below so the very
        // emissions that arming triggers already pass the banner's verdict gate.
        markSessionVerdictKnown()

        // MOB-1466: ARMING HYGIENE. Wake-ups are re-armed on every `.beforeSync`/`.afterSync` path,
        // not only the `.waiting` one — unchanged, see the doc this replaces. A QUIET `.tick`,
        // though, changed none of the run's rows (nothing to re-derive a schedule from), so arming
        // again would be pure repeated work for an identical answer; a SUBSTANTIVE tick verdict
        // keeps arming, exactly like the two opens.
        if !isQuietTick {
            for accountUUID in accountUUIDs {
                await armNextWindowNotifications(accountUUID: accountUUID)
            }
        }

        return verdict
    }

    /// Non-blocking acquire for `.tick` callers — see `advance(phase:)`'s single-flight latch.
    /// `true` means the latch is now held by THIS call; `false` means another `advance` is already
    /// running and this caller must yield (`.skipped`) rather than park.
    private func tryAcquireAdvanceLatch() -> Bool {
        advanceLatch.withLock { state in
            guard !state.isBusy else { return false }
            state.isBusy = true
            return true
        }
    }

    /// FIFO blocking acquire for `.beforeSync`/`.afterSync` callers — mirrors
    /// ../zcash-swift-wallet-sdk's `OrchardMigration.serializedBroadcastFlow`'s wait loop, adapted
    /// from actor isolation to an explicit lock (see `MigrationAdvanceLatchState`'s doc).
    ///
    /// The busy check and the enqueue-or-resume decision happen in ONE `withLock` call rather than
    /// two (check busy; if so, separately append a continuation) — splitting them would open a
    /// window in which a concurrent `releaseAdvanceLatch()` observes an EMPTY waiter list between
    /// the two calls and clears `isBusy`, stranding this continuation in the queue with nobody left
    /// to resume it. Calling `continuation.resume()` from inside the lock is safe: `resume()` is
    /// synchronous — it hands the continuation off, it does not itself suspend — so this never
    /// violates "no `await` inside `withLock`" (`OSAllocatedUnfairLock.withLock`'s closure is
    /// synchronous and could not compile an `await` inside it regardless).
    private func acquireAdvanceLatch() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            advanceLatch.withLock { state in
                if state.isBusy {
                    state.waiters.append(continuation)
                } else {
                    state.isBusy = true
                    continuation.resume()
                }
            }
        }
    }

    /// Releases the latch. When a caller is parked, ownership transfers DIRECTLY to the oldest one
    /// (FIFO) rather than clearing `isBusy` and letting whoever gets there first win — that is what
    /// keeps a `.tick` racing in from jumping the queue ahead of an app-open's own waiting call.
    private func releaseAdvanceLatch() {
        advanceLatch.withLock { state in
            guard !state.waiters.isEmpty else {
                state.isBusy = false
                return
            }
            let next = state.waiters.removeFirst()
            next.resume() // `isBusy` stays true — ownership transfers to the resumed waiter.
        }
    }

    /// The per-account discharge loop. Returns the FIRST substantive verdict — the engine's steps are
    /// already priority-ordered, and ZIP 318 caps a session at one broadcast, so "first substantive"
    /// is the honest summary of what this open accomplished.
    private func discharge(
        steps: [(accountUUID: AccountUUID, step: MigrationAdvanceStep?)],
        phase: MigrationOpenPhase
    ) async -> MigrationStepVerdict {
        var fallback = MigrationStepVerdict.noRun
        var firstHeld: MigrationStepVerdict?

        // The plan's one status-aware cell (the `.prove` row's `.tick` column) keys off whether
        // sync currently reads `.upToDate` — read ONCE per driver call, from the same live source
        // the flowFinished drive uses, so every account's discharge sees the same answer.
        let isWalletAtTip: Bool
        if case .upToDate = sdkSynchronizer.latestState().syncStatus {
            isWalletAtTip = true
        } else {
            isWalletAtTip = false
        }

        for (accountUUID, step) in steps {
            let action = MigrationStepPlan.action(for: step, phase: phase, isWalletAtTip: isWalletAtTip)
            let verdict = await execute(action, accountUUID: accountUUID, phase: phase)

            // Audit 2026-08-03 (#13): remember per-account whether this discharge needs the USER —
            // `armNextWindowNotifications` turns that into a near-term poke, because a blocked run
            // has no prove/send window of its own to wake anyone for.
            if case .needsUser = verdict {
                recordStepBlocker(accountUUID: accountUUID, isBlocked: true)
            } else {
                recordStepBlocker(accountUUID: accountUUID, isBlocked: false)
            }

            // `.held` is a PER-ACCOUNT outcome (audit 2026-08-03, #4): the mode belt and the
            // manual-delivery read hold ONE account's step, not the wallet's. Returning on the
            // first hold starved every later account — an `.immediate` account's permanently-due
            // broadcast blocked a `.privateScheduled` sibling's delivery on every single tick.
            // Remember the first hold as the session's summary and keep discharging; a later
            // account's SUBSTANTIVE verdict still wins the return below. (The wallet-wide
            // privacy buffer holds every account identically, so continuing under it just
            // collects the same hold once.)
            if case .held = verdict {
                if firstHeld == nil { firstHeld = verdict }
                continue
            }

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

        return firstHeld ?? fallback
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
            if phase == MigrationOpenPhase.tick {
                // MOB-1466: a tick that reaches a broadcast action is a genuine, tick-triggered
                // network event — the same kind of thing an app-open's own `.beforeSync` session
                // already is — so it gets its own `[MIG]` session marker, distinguishing it from
                // the ambient foreground session it interrupts. `tip` comes from the exact source
                // every other `beginSession` call site uses (`sdkSynchronizer.latestState()`); the
                // driver already depends on `sdkSynchronizer` for the engine reads above, so no new
                // seam is needed to reach it. Begun here rather than only once the broadcast lands:
                // "about to attempt" is the trigger, not "succeeded" — `executeBroadcast` below may
                // still hold this (mode belt, manual delivery, the buffer), and that hold is itself
                // worth its own session-scoped log lines.
                MigrationTrace.beginSession(cause: MigrationTrace.Cause.timer, tip: sdkSynchronizer.latestState().latestBlockHeight)
            }
            return await executeBroadcast(id: id, accountUUID: accountUUID, phase: phase)

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
    /// into a verdict, so that "held by the buffer" stops looking like "did nothing". `phase` is
    /// threaded through (rather than read from a stored property) so `MigrationStepPlan` stays
    /// pure — the plan already decided this action is due; this is the one place that still needs
    /// to know WHICH phase asked, for the mode belt below.
    private func executeBroadcast(id: UInt32, accountUUID: AccountUUID, phase: MigrationOpenPhase) async -> MigrationStepVerdict {
        // MOB-1466: THE MODE BELT. A tick is a broadcast opportunity ONLY for a run the user chose
        // to run on a schedule (`.privateScheduled`) — see `MigrationStepPlan`'s tick-column doc. An
        // `.immediate` run still gets its one delivery from the open lanes (`.beforeSync`); ticking
        // it too would send the moment Ironwood activates rather than at the user's own chosen
        // pace, on whatever 30s boundary the app happened to be foregrounded across. Checked BEFORE
        // the manual-delivery read below: an immediate-mode account is never manual-delivery's
        // business to begin with, and ordering it first keeps "why this tick held" from ever being
        // misread as the user's own delivery preference.
        if phase == MigrationOpenPhase.tick, migrationMode(accountUUID: accountUUID) != MigrationMode.privateScheduled {
            return MigrationStepVerdict.held(reason: "immediate-mode run — ticks leave it to the open lanes")
        }

        if gateStorage.isManualDelivery(for: accountUUID) {
            return MigrationStepVerdict.held(reason: "delivery is manual — transfer \(id) is left for the user to send")
        }

        let gate = await sendGate()
        if case let MigrationSendGate.waitUntil(gateUntil) = gate {
            return MigrationStepVerdict.held(
                reason: "privacy buffer until \(gateUntil) (\(Int(gateUntil.timeIntervalSinceNow))s)"
            )
        }

        // The account THIS discharge vetted (mode belt, manual delivery, send gate above) is the
        // one the session delivers — see `runBroadcastSession(vettedAccountUUID:)`'s doc for the
        // held-account submission its own sweep used to make.
        let didBroadcast = await runBroadcastSession(vettedAccountUUID: accountUUID)
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
