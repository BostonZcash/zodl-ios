//
//  RootInitialization.swift
//  Zashi
//
//  Created by Lukáš Korba on 01.12.2022.
//

import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

/// In this file is a collection of helpers that control all state and action related operations
/// for the `Root` with a connection to the app/wallet initialization and erasure of the wallet.

// MARK: - MOB-1466: the tick loop's interval as a dependency

/// MOB-1466: `Constants.migrationTickInterval`, surfaced as a dependency so tests can override it
/// — including to `.zero`, the OFF switch (see `migrationTickLoopEffect(state:)`'s leading guard).
/// The CONSTANT stays the single source of truth: both values below read it, and production never
/// overrides this key. `testValue == liveValue` is deliberate for a plain configuration VALUE (no
/// behavior to stub, nothing a forgotten override could silently fake) — existing suites keep the
/// shipped 30s without naming this key at all.
private enum MigrationTickIntervalKey: DependencyKey {
    static let liveValue: Swift.Duration = Root.Constants.migrationTickInterval
    static let testValue: Swift.Duration = Root.Constants.migrationTickInterval
}

extension DependencyValues {
    /// The tick loop's period. `.zero` disables the automatic loop entirely; the app-open pokes
    /// (`advance(.beforeSync)` at cold start/foreground, `advance(.afterSync)` at sync edges) are a
    /// separate lane and are never affected.
    var migrationTickInterval: Swift.Duration {
        get { self[MigrationTickIntervalKey.self] }
        set { self[MigrationTickIntervalKey.self] = newValue }
    }
}

extension Root {
    enum Constants {
        static let udIsRestoringWallet = "udIsRestoringWallet"
        static let udIsResyncingWallet = "udIsResyncingWallet"
        static let udLeavesScreenOpen = "udLeaves_screen_open"
        static let noAuthenticationWithinXMinutes = 15
        /// MOB-1466: the foreground migration tick loop's wake-up period — see
        /// `migrationTickLoopEffect(state:)`. `Swift.Duration`, not `ZcashLightClientKit`'s
        /// generated protobuf `Duration`, which shadows it once that module is imported
        /// unqualified. ZERO IS THE OFF SWITCH: at `.zero` the loop never spawns at all (the
        /// effect's leading guard), while the app-open pokes are a separate lane and keep working.
        /// Surfaced to reducers/tests as `DependencyValues.migrationTickInterval`.
        static let migrationTickInterval: Swift.Duration = .zero
        /// How many ticks between "the loop is alive" heartbeat lines — ~10 minutes at the interval
        /// above. Approximate on purpose (see `migrationTickCount`'s doc): the log line only ever
        /// claims the loop is running, never a precise cadence.
        static let migrationTickHeartbeatEvery = 20
    }

    enum InitializationAction {
        case appDelegate(AppDelegateAction)
        case checkBackupPhraseValidation
        case checkRestoreWalletFlag(SyncStatus)
        case checkWalletInitialization
        case checkWalletConfig
        case initializeSDK(WalletInitMode)
        case initializeSDKFinished
        case staleWalletDatabaseHealed
        case presentStaleWalletHealedAlert
        case initialSetups
        case initializationFailed(ZcashError)
        case initializationSuccessfullyDone
        case loadedWalletAccounts([WalletAccount])
        case resetZashi
        case resetZashiRequest(Bool)
        case resetZashiRequestCanceled
        case respondToWalletInitializationState(InitializationState)
        case restoreExistingWallet
        case seedValidationResult(Bool)
        case synchronizerStartFailed(ZcashError)
        case registerForSynchronizersUpdate
        case retryStart
        case walletConfigChanged(WalletConfig)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func initializationReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .initialization(.appDelegate(.didFinishLaunching)):
                // MOB-1466: the LIFECYCLE MARKERS. Every migration step on iOS happens inside one
                // app-open — proving, broadcasting, the sync that observes a mining — so a `[MIG]`
                // log without open/background boundaries reads as one undifferentiated stream and
                // "what did THIS session actually do" cannot be answered from it. These three lines
                // are the sequencing spine every other `[MIG]` line hangs off.
                MigrationTrace.beginSession(cause: .coldLaunch, tip: sdkSynchronizer.latestState().latestBlockHeight)
                state.appStartState = .didFinishLaunching
                // TODO: [#704], trigger the review request logic when approved by the team,
                // https://github.com/Electric-Coin-Company/zashi-ios/issues/704
                return .run { send in
                        try await mainQueue.sleep(for: .seconds(0.5))
                        await send(.initialization(.initialSetups))
                    }
                    .cancellable(id: state.DidFinishLaunchingId, cancelInFlight: true)

            case .initialization(.appDelegate(.willEnterForeground)):
                // See the cold-launch marker above. The tip rides along because it is the one piece
                // of context that decides what this session is allowed to do, and it survives
                // backgrounding in memory, so it is truthful at this exact moment.
                MigrationTrace.beginSession(cause: .foreground, tip: sdkSynchronizer.latestState().latestBlockHeight)
                if state.featureFlags.appLaunchBiometric {
                    let now = Date()
                    let before = Date.init(timeIntervalSince1970: TimeInterval(state.lastAuthenticationTimestamp))
                    if let xMinutesAgo = Calendar.current.date(byAdding: .minute, value: -Constants.noAuthenticationWithinXMinutes, to: now),
                       before < xMinutesAgo {
                        state.splashAppeared = false
                    }
                }
                state.appStartState = .willEnterForeground
                // Placed after the biometric re-auth block above so that block's possible
                // `splashAppeared = false` has already landed before the safety gate reads it.
                // The tip survives backgrounding in memory (`sdkSynchronizer.latestState()`),
                // which is what makes this call site immediate rather than waiting for a fresh
                // sync tick to repopulate it via `.synchronizerStateChanged`.
                presentIronwoodAnnouncementIfNeeded(state: &state, tip: sdkSynchronizer.latestState().latestBlockHeight)
                // MOB-1466: "the open breaks the loop's sleep" — a fresh foreground always
                // restarts the tick loop's 30s countdown from zero (`cancelInFlight: true` inside
                // `migrationTickLoopEffect`), whichever branch below this open actually takes.
                let migrationTickEffect = migrationTickLoopEffect(state: state)
                // MOB-1466 — STALENESS. iOS paints the previous frame on foreground, so until the
                // re-derivation below returns (seconds, not milliseconds) the smart banner states
                // last session's conclusion with full confidence. Raising `.checkingStatus` FIRST,
                // synchronously in this reducer, is what stops the user reading a promise that is
                // no longer true. It is a no-op unless the migration lane already owns the banner.
                //
                // Sits ALONGSIDE the tick effect above rather than replacing it — the two are
                // different halves of one problem. The tick keeps an ALREADY-OPEN screen fresh;
                // this covers the gap before the first answer of a NEW foreground, which no tick
                // interval can close because the stale frame is painted before any timer starts.
                let migrationCheck: Effect<Action> = state.featureFlags.migration
                    ? .send(.home(.smartBanner(.migrationForegroundCheckStarted)))
                    : .none
                if state.isLockedInKeychainUnavailableState || !sdkSynchronizer.latestState().syncStatus.isPrepared {
                    return .merge(migrationTickEffect, migrationCheck, .send(.initialization(.initialSetups)))
                } else {
                    return .merge(migrationTickEffect, migrationCheck, .send(.initialization(.retryStart)))
                }
                
            case .initialization(.appDelegate(.migrationNotificationTapped(let accountUUID, let isTorFailure))):
                // PHASE 4: a poke was tapped. Open the migration flow — the coordinator's own
                // `onAppear` re-entry routing then lands on whatever screen the run is actually on
                // (status/resume/review), so this does NOT need to know the run's shape.
                //
                // The Tor-failure route has no surface yet (Phase 5) — it falls through to the same
                // flow rather than nowhere, which is the honest degradation: the user still reaches
                // their run, just without the dedicated explanation sheet.
                // MOB-1466: the answer to "was this open the schedule working, or the user wandering
                // in". Arrives moments after `willEnterForeground` opened the session, so its own
                // elapsed stamp reads unmistakably as that session's cause.
                MigrationTrace.notificationTapped()
                _ = isTorFailure
                // `accountUUID` names the account the notification was COMPOSED for. Selecting it
                // is Phase 5's cross-account routing; for now a tap opens the flow for whichever
                // account is selected, which is the same account in every single-account case.
                _ = accountUUID
                // I4 — ENTRY PARITY. A tap that arrives before the app can act on it is LATCHED,
                // never dropped. On a cold launch this handler runs inside `didFinishLaunching`'s
                // half-second pause, before feature flags load, so the guard below used to swallow
                // the deep link entirely and the user landed on Home — the same tap, on a warm app,
                // opened their migration. See `Root.State.pendingMigrationNotificationTap`.
                //
                // `isInitializingSDK` covers the other half of the window: flags loaded, SDK not up
                // yet, so the flow would open over an app that cannot populate it.
                guard state.featureFlags.migration, !state.isInitializingSDK else {
                    state.pendingMigrationNotificationTap = true
                    LoggerProxy.event("\(MigrationManagerImpl.logTag) notification tap latched — app not ready yet; will replay")
                    return .none
                }
                return openMigrationCoordFlow(state: &state)

            case .initialization(.appDelegate(.didEnterBackground)):
                // See the cold-launch marker above. `sdkSynchronizer.stop()` on the next line is
                // why this boundary matters so much to a migration run: sync does not merely pause
                // here, it STOPS, and nothing restarts it until the next foreground's `.retryStart`.
                // Anything the run was waiting to observe — a preparation mining, a transfer
                // confirming — waits for the user to come back.
                MigrationTrace.endSession(reason: "BACKGROUND — sync stopping")
                sdkSynchronizer.stop()
                state.bgTask?.setTaskCompleted(success: false)
                state.bgTask = nil
                state.appStartState = .didEnterBackground
                state.isLockedInKeychainUnavailableState = false
                return .merge(
                    .cancel(id: state.CancelStateId),
                    .cancel(id: state.CancelTransactionsStateId),
                    // MOB-1466: the tick loop is a FOREGROUND-only mechanism — the app cannot poll
                    // anything once backgrounded (there is no background lane), so its whole reason
                    // to exist stops the instant sync itself does, on the same boundary. The next
                    // foreground respawns it fresh if the spawn condition still holds.
                    .cancel(id: state.migrationTickCancelId)
                )

            case .initialization(.appDelegate(.backgroundTask(let task))):
                let keysPresent: Bool = (try? walletStorage.areKeysPresent()) ?? false
                if state.appStartState == .didFinishLaunching {
                    state.appStartState = .backgroundTask
                    if keysPresent {
                        state.bgTask = task
                        return .none
                    } else {
                        state.isLockedInKeychainUnavailableState = true
                        task.setTaskCompleted(success: false)
                        return .cancel(id: state.DidFinishLaunchingId)
                    }
                } else {
                    state.bgTask = task
                    state.appStartState = .backgroundTask
                    return .run { send in
                        await send(.initialization(.retryStart))
                    }
                }
                
            case .synchronizerStateChanged(let latestState):
                // Must run above the `selectedWalletAccount` guard and the background-task
                // branch below — both early-return, but the announcement gate has to keep
                // evaluating on every sync tick regardless of whether an account is selected
                // (normal on a fresh install) or a background task is in flight (already
                // excluded by `canPresentIronwoodAnnouncement`'s own `bgTask == nil` term).
                presentIronwoodAnnouncementIfNeeded(state: &state, tip: latestState.data.latestBlockHeight)

                let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)

                // Reconcile migration state on the EDGE into `.upToDate` — never on every tick while
                // already synced, which would storm `reconcile()` at the tip. Piggybacks on this
                // existing `stateStream()` subscription rather than opening a second one.
                // `recordSyncCompleted()` re-keys the app's SEND gate off the same edge: a
                // just-completed sync briefly disables migration sends, which is the app-direction
                // half of the privacy gate (the SDK owns the other direction).
                let didJustReachUpToDate = snapshot.syncStatus == .upToDate && !state.wasSyncUpToDateForMigration
                state.wasSyncUpToDateForMigration = snapshot.syncStatus == .upToDate
                let migrationReconcileEffect: Effect<Action> = didJustReachUpToDate
                    ? .run { [migrationManager] _ in
                        migrationManager.recordSyncCompleted()
                        // (P3's invalidation sweep used to run here, first. Both of its jobs are
                        // the ENGINE's now: foreign-spent funding notes are recorded by the
                        // engine's satisfiability oracle, and a broadcast this process submitted
                        // but failed to record is promoted on every `migrationAdvanceStep` —
                        // automatically, not only when this edge remembered to ask.)
                        // THE DRIVER at its second and last moment of the app-open, and this edge is
                        // the only correct place for it: sync has just reached the tip, so every
                        // settled anchor boundary is now witnessable and the engine's answer is
                        // computed against fresh data.
                        //
                        // This used to be three hand-sequenced calls — prove sweep, reconcile, re-arm
                        // — chosen by this call site rather than by the engine. That is exactly the
                        // shape the driver replaces: the app decided WHAT to do here and the engine
                        // was only ever consulted about broadcasts, so the two steps with no other
                        // discharge in the app (`.rebuild`, `.requiresAttention`) fell through this
                        // edge untouched, every time, forever. `advance` asks and obeys instead, and
                        // still does all three of those things when `.prove` is the answer.
                        //
                        // `accountUUID` is no longer threaded in: the driver arms wake-ups for every
                        // candidate account, not just the selected one, which is what a wallet with a
                        // Zodl and a Keystone account migrating in parallel actually needs.
                        await migrationManager.advance(.afterSync)
                    }
                    : .none

                // MOB-1466 (07-31, field-caught): `migrationReconcileEffect` must reach EVERY return
                // below, not just this one. It used to be returned here and nowhere else — so the
                // whole sync-complete migration edge (invalidation sweep, prove sweep, reconcile,
                // notification arming) ran only when NO account was selected, which is precisely the
                // case with nothing to migrate. On every real wallet the effect was built and thrown
                // away by the next `return`.
                //
                // What that looked like on a device: the engine asked to prove preparation (0,0) at
                // every open, forever. Nothing proved it, so nothing was ever broadcast, so the run
                // sat at 0-of-12 with every preparation reading "Ready now" — a committed migration
                // that could not take its first step. Giving the sweeps their callers (A24/A28) was
                // necessary and not sufficient: the callers existed and their effect was discarded
                // one line later.
                //
                // Merged into each return rather than hoisted, because the paths below legitimately
                // return different things and each one is reachable at a sync-complete edge. The
                // effect is `.none` unless this tick IS that edge, so merging costs nothing.
                guard let account = state.selectedWalletAccount else {
                    return migrationReconcileEffect
                }
                
                // update flexa balance
                if let accountBalance = latestState.data.accountsBalances[account.id] {
                    // Pool-agnostic accessors: sum sapling + orchard + ironwood (and any future
                    // shielded pool) instead of hand-summing individual pools.
                    let shieldedBalance = accountBalance.shieldedSpendableValue
                    let shieldedWithPendingBalance = accountBalance.shieldedTotal()

                    flexaHandler.updateBalance(shieldedWithPendingBalance, shieldedBalance)
                }

                // handle possible service unavailability
                if case .error(let error) = snapshot.syncStatus, checkUnavailableService(error) {
                    if state.walletStatus != .disconnected {
                        state.alert = AlertState.serviceUnavailable()
                    }
                    state.wasRestoringWhenDisconnected = state.walletStatus == .restoring
                    state.$walletStatus.withLock { $0 = .disconnected }
                } else if case .syncing = snapshot.syncStatus, state.walletStatus == .disconnected {
                    state.$walletStatus.withLock { $0 = state.wasRestoringWhenDisconnected ? .restoring : .none }
                }

                // handle BCGTask
                guard state.bgTask != nil else {
                    return .merge(
                        migrationReconcileEffect,
                        .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus)))
                    )
                }
                
                var finishBGTask = false
                var successOfBGTask = false
                
                switch snapshot.syncStatus {
                case .upToDate:
                    successOfBGTask = true
                    finishBGTask = true
                    if state.isRestoringWallet {
                        userDefaults.remove(Constants.udIsRestoringWallet)
                        userDefaults.remove(Constants.udIsResyncingWallet)
                        state.$walletStatus.withLock { $0 = .none }
                    }
                    state.isRestoringWallet = false
                case .stopped, .error:
                    successOfBGTask = false
                    finishBGTask = true
                default: break
                }
                
                if finishBGTask  {
                    LoggerProxy.event("BGTask setTaskCompleted(success: \(successOfBGTask)) from TCA")
                    state.bgTask?.setTaskCompleted(success: successOfBGTask)
                    state.bgTask = nil
                    return .merge(
                        migrationReconcileEffect,
                        .cancel(id: state.CancelStateId),
                        .cancel(id: state.CancelTransactionsStateId)
                    )
                }

                return .merge(
                    migrationReconcileEffect,
                    .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus)))
                )
                
            case .initialization(.checkRestoreWalletFlag(let syncStatus)):
                if state.isRestoringWallet && syncStatus == .upToDate {
                    state.isRestoringWallet = false
                    userDefaults.remove(Constants.udIsRestoringWallet)
                    userDefaults.remove(Constants.udIsResyncingWallet)
                    state.$walletStatus.withLock { $0 = .none }
                }
                return .none

            case .initialization(.synchronizerStartFailed):
                return .none
                
            // THE OTHER HALF of `SDKSynchronizerClient.stopSyncBeforeMigrationBroadcast()`
            // (matrix B12). A migration broadcast stops sync so the two are not correlated; without
            // this handler that sync never restarts and the wallet sits dead for the session.
            //
            // Resuming is checked INDEPENDENT of `isGenuineChange`, deliberately. Two edges need it:
            //  - a foreground broadcast stopped sync while no `.retryStart` happened to be running,
            //    so `syncDeferredByMigrationGate` was never set;
            //  - a broadcast that failed PRE-FLIGHT (a Tor bootstrap error, say) never reached the
            //    SDK's gate-setting code at all, so no `true -> false` transition will EVER arrive.
            // `migrationStoppedSyncForBroadcast` covers both: it stays set until the next
            // `.migrationSyncGateChanged(false)` from ANY source, which this resumes on rather than
            // letting the dedupe swallow it as "no change".
            //
            // `reconcile()` stays gated on a genuine change — it drives banner/re-entry derivation,
            // an unrelated concern that should not re-run on every re-push.
            case .migrationGateDeferredSyncStart:
                // The refusal handlers in `.initializeSDK`/`.retryStart` arm this BEFORE running
                // their broadcast session, so the clearing edge below resumes even when that
                // session finds nothing to broadcast (the buffer-shape refusal, where
                // `migrationStoppedSyncForBroadcast` never gets set either).
                state.syncDeferredByMigrationGate = true
                return .none

            // MOB-1466: THE TICK LOOP's one wake-up. See `migrationTickLoopEffect(state:)` for how
            // this got sent, and its own doc for why calling the driver lives HERE rather than in
            // the loop's `.run` body: only a reducer case can return `.cancel`/`.send` in response
            // to what the driver answers.
            //
            // I5 (RESUME INVARIANT): pre-arms `syncDeferredByMigrationGate` BEFORE the advance call
            // that may broadcast — the same flag `.migrationGateDeferredSyncStart` already arms for
            // the gate-refusal sites elsewhere in this file. Three sync states can exist the instant
            // a tick's broadcast lands: (a) actively syncing — `stopSyncBeforeMigrationBroadcast`
            // stops it and sets the shared `migrationStoppedSyncForBroadcast` flag itself, unchanged
            // by this pre-arm; (b) already stopped-and-deferred — `syncDeferredByMigrationGate` was
            // already true; (c) started but IDLE AT THE TIP — nothing for
            // `stopSyncBeforeMigrationBroadcast` to stop, so NEITHER flag would otherwise get set by
            // the broadcast itself, and once the SDK's own post-broadcast gate later clears,
            // `.migrationSyncGateChanged(false)`'s `shouldResume` computation would find both flags
            // false and never send `.retryStart` — sync stays unresumed for the rest of the
            // foreground. (a) and (b) already pass bare (pinned in
            // `RootMigrationTickLoopTests`/`RootMigrationGateRefusalTests`); this line is what makes
            // (c) pass too.
            //
            // Unconditional rather than gated on "did the fast path hold": that answer is
            // driver-internal (the plan stays pure — see `MigrationStepPlan`'s doc — and
            // `MigrationStepVerdict.held`'s reason is a free-form string, not a structured signal
            // worth pattern-matching on here). A QUIET tick pre-arms this flag for nothing, but that
            // is harmless: the flag just sits `true`, unread, until SOME later genuine gate
            // transition consumes it — at worst one extra, idempotent `.retryStart`.
            case .migrationTick:
                state.migrationTickCount += 1
                let tickNumber = state.migrationTickCount
                let logHeartbeat = tickNumber.isMultiple(of: Constants.migrationTickHeartbeatEvery)
                return .concatenate(
                    .send(.migrationGateDeferredSyncStart),
                    .run { [migrationManager] send in
                        let verdict = await migrationManager.advance(.tick)
                        if logHeartbeat {
                            LoggerProxy.event("\(MigrationManagerImpl.logTag) migration tick loop alive — last verdict: \(verdict)")
                        }
                        await send(.migrationTickAdvanced(verdict))
                    }
                )

            case .migrationTickAdvanced(let verdict):
                switch verdict {
                // Terminal/empty: nothing is left for the loop to help with. Self-stop — the next
                // foreground respawns it if a fresh run starts a new candidate.
                case MigrationStepVerdict.complete, MigrationStepVerdict.noRun, MigrationStepVerdict.notApplicable:
                    return .cancel(id: state.migrationTickCancelId)
                // SUBSTANTIVE — the same set `MigrationStepVerdict.isQuietForTick` calls NOT quiet,
                // esp. `.broadcast`: a tick just changed something about the run, so re-derive the
                // banner rather than waiting for a sync transition that a tick, by construction,
                // never causes. Reuses the SAME reevaluation `.migrationCoordFlow(.flowFinished)`
                // already sends after a manual delivery (see `RootCoordinator.swift`) — harmless
                // when nothing visibly changed, since the re-read just returns the same variant.
                case MigrationStepVerdict.broadcast, MigrationStepVerdict.rebuilt, MigrationStepVerdict.needsUser,
                     MigrationStepVerdict.failed, MigrationStepVerdict.resyncing, MigrationStepVerdict.proved:
                    return .send(.home(.smartBanner(.migrationReevaluationRequested)))
                // Quiet: nothing changed, and arming/logging already handled the rest inside the
                // driver — see `advance(phase:)`'s tick-specific hygiene.
                case MigrationStepVerdict.held, MigrationStepVerdict.idle, MigrationStepVerdict.deferredToPhase,
                     MigrationStepVerdict.skipped:
                    return .none
                }

            case .migrationSyncGateChanged(let isBlocked):
                @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false

                let isGenuineChange = isBlocked != state.lastMigrationSyncGateBlocked
                let shouldResume = !isBlocked && (state.syncDeferredByMigrationGate || migrationStoppedSyncForBroadcast)
                guard isGenuineChange || shouldResume else { return .none }

                state.lastMigrationSyncGateBlocked = isBlocked
                let reconcileEffect: Effect<Action> = isGenuineChange
                    ? .run { [migrationManager] _ in await migrationManager.reconcile() }
                    : .none

                // MOB-1466 (foreground wedge, field-caught 2026-08-02): THE STOP HALF of this
                // handler's pair. `blocked == true` means "this wallet should not be syncing" —
                // a ready broadcast is waiting, or a post-broadcast buffer is running — but the
                // SDK enforces that only on a NEW start(); an already-running engine keeps
                // completing passes, and every completion re-arms the app-side send window
                // (`sendGate`'s network-scaled buffer — up to 600 s mainnet, 180 s testnet —
                // measured from `lastSyncCompletedAt`) before it can expire. The tick lane then
                // holds forever: nine `broadcast(id:)` reads over 15+ minutes, every tick
                // `held(privacy buffer until …)` with a sliding deadline — up to ~10 minutes of
                // paused sync on mainnet before the tick lane can send. Stopping the running sync
                // here is what makes the silence the gate is waiting for actually arrive; the
                // window expires within one buffer and the tick lane broadcasts.
                //
                // Scoped to the runs whose broadcasts RIDE ticks: `.privateScheduled` with manual
                // delivery off. An `.immediate` run delivers from the open lanes and a manual-
                // delivery run delivers by hand (its Send-now lane performs its own stop) —
                // stopping their sync would strand them with no lane to use the silence. The
                // SDK's gate is WALLET-wide (`isMigrationSyncBlocked()` has no per-account view),
                // so eligibility is checked over the same candidate set
                // `migrationTickLoopEffect(state:)` scopes itself by
                // (`MigrationDerivations.candidateAccountUUIDs`), not just the selected account —
                // a second candidate's scheduled run must be able to stop sync even when the
                // selected account is immediate-mode or none is selected. Residual gap, not
                // solved here: with two eligible candidates where only a manual-delivery
                // account's ready broadcast is what is blocking the gate, this can still stop
                // sync for the OTHER eligible account, pausing it for a broadcast nothing
                // automatic will send — attributing the gate to the specific account that tripped
                // it needs SDK surface this does not add.
                //
                // Also gated on the tick loop's own off switch (`migrationTickInterval >
                // Swift.Duration.zero`, the same dependency `migrationTickLoopEffect(state:)`
                // reads): with the loop disabled nothing will ever consume the silence this buys,
                // so stopping here would strand sync for the rest of the foreground instead of
                // helping it.
                //
                // `stopStartedSyncForMigrationGate()` (not `stopSyncBeforeMigrationBroadcast()`,
                // the broadcast lanes' own stop): its predicate is "started" (`.syncing` OR
                // `.upToDate`), not `isSyncing()` — the wedge is an engine idling AT the tip
                // between blocks, where `isSyncing()` reads false at every tick, which is exactly
                // why the broadcast lanes' guard could never serve this call site. Same contract
                // as its sibling otherwise: sets `migrationStoppedSyncForBroadcast` only when it
                // genuinely stopped something — which is exactly what arms this same handler's
                // resume half for the `false` edge. One stop per false->true transition (the
                // `isGenuineChange` dedupe); the SDK's own start() throw backstops any restart
                // attempt while blocked.
                let tickLoopCanConsumeTheStop = migrationTickInterval > Swift.Duration.zero
                let stopEffect: Effect<Action>
                // Short-circuited deliberately, not pre-computed: `migrationMode`/
                // `isManualDelivery` must only be READ when a stop is otherwise on the table.
                // Suites that drive `.migrationSyncGateChanged` without a `.privateScheduled`
                // scenario in mind (e.g. `RootMigrationGateRefusalTests`) never stub either
                // closure — calling them unconditionally would trap on every gate emission,
                // not just the ones this handler's stop half actually cares about.
                if isGenuineChange && isBlocked && tickLoopCanConsumeTheStop {
                    let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
                        selectedAccountUUID: state.selectedWalletAccount?.id,
                        walletAccounts: state.walletAccounts
                    )
                    let hasStoppableCandidate = accountUUIDs.contains { accountUUID in
                        migrationManager.migrationMode(accountUUID) == MigrationMode.privateScheduled
                            && !migrationManager.isManualDelivery(accountUUID)
                    }
                    stopEffect = hasStoppableCandidate
                        ? .run { [sdkSynchronizer] _ in
                            await sdkSynchronizer.stopStartedSyncForMigrationGate()
                        }
                        : .none
                } else {
                    stopEffect = .none
                }

                guard shouldResume else { return .merge(reconcileEffect, stopEffect) }

                state.syncDeferredByMigrationGate = false
                $migrationStoppedSyncForBroadcast.withLock { $0 = false }
                return .merge(
                    reconcileEffect,
                    // A broadcast just landed (or failed) — the next window moved either way.
                    .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                        await migrationManager.armNextWindowNotifications(accountUUID)
                    },
                    .send(.initialization(.retryStart))
                )

            case .initialization(.retryStart):
                if !diskSpaceChecker.hasEnoughFreeSpaceForSync() {
                    state.destinationState.preNotEnoughFreeSpaceDestination = state.destinationState.internalDestination
                    return .send(.destination(.updateDestination(.notEnoughFreeSpace)))
                } else if let preNotEnoughFreeSpaceDestination = state.destinationState.preNotEnoughFreeSpaceDestination {
                    state.destinationState.internalDestination = preNotEnoughFreeSpaceDestination
                    state.destinationState.preNotEnoughFreeSpaceDestination = nil
                }
                // Try the start only if the synchronizer has been already prepared
                guard sdkSynchronizer.latestState().syncStatus.isPrepared else {
                    return .none
                }
                return .run { [state] send in
                    do {
                        // ZIP 318 session separation, decided BEFORE the wire is touched: if any
                        // account has a proven transfer due, this open is a BROADCAST session and
                        // must not initiate sync. Stopping an in-flight sync (the reactive gate
                        // below) is too late for the privacy property — the correlation exists the
                        // moment sync connects. See `MigrationVisit`.
                        if await migrationManager.visitKind() == .send {
                            LoggerProxy.event("\(MigrationManagerImpl.logTag) skipping sync start — broadcast session")
                            // MOB-1466 (N4, field-caught 2026-08-01): ARM THE RESUME, exactly as the
                            // refusal handler below does. This branch is the one that was missing it,
                            // and it is the COMMON path — the planned broadcast session, the one
                            // `visitKind()` classifies up front.
                            //
                            // Without it the run freezes for the rest of the app-open. The chain:
                            // sync never starts here, so `syncDeferredByMigrationGate` stays false;
                            // `stopSyncBeforeMigrationBroadcast()` then early-returns on
                            // `guard isSyncing()` — correctly, there was nothing to stop — so
                            // `migrationStoppedSyncForBroadcast` stays false too. The broadcast
                            // succeeds, the SDK's post-broadcast buffer blocks sync for 180 s, and
                            // when it clears `.migrationSyncGateChanged(false)` computes
                            // `shouldResume = !isBlocked && (false || false)` and returns without
                            // `.retryStart`. Sync never resumes. No polling, no sync-complete edge,
                            // no reconcile, no pokes — the UI holds whatever it last rendered.
                            //
                            // On the device that was six minutes of "Preparing transaction…" with
                            // spinners and an EMPTY LOG, cured only by backgrounding and
                            // foregrounding (which reaches `.retryStart` by another road). The
                            // tester's reading — "I assume it's finished but UI is stale" — was
                            // exactly right.
                            //
                            // `.migrationGateDeferredSyncStart`'s own doc already describes this
                            // shape ("even when that session finds nothing to broadcast … where
                            // `migrationStoppedSyncForBroadcast` never gets set either"); it was
                            // armed in the refusal handler and not here.
                            await send(.migrationGateDeferredSyncStart)
                            // A13: and then USE the session for what it was claimed for. With no
                            // background lane on iOS this open IS the delivery window — suppressing
                            // sync without broadcasting would just stall a schedule the user
                            // already confirmed.
                            await migrationManager.advance(.beforeSync)
                        } else {
                            // THE DRIVER, on the sync branch too. `visitKind()` above answers only
                            // "may this session sync?"; this is where the engine's actual next step
                            // gets discharged. On a sync visit most steps defer to the post-sync
                            // edge — but `.requiresAttention` and `.complete` are answered here, the
                            // wake-ups are re-armed here, and, crucially, this open now LOGS a
                            // verdict whether or not it did anything. A session that did nothing and
                            // said nothing is indistinguishable from a frozen app.
                            await migrationManager.advance(.beforeSync)
                            do {
                                try await sdkSynchronizer.start(true)
                            } catch ZcashError.migrationSyncBlocked {
                                // Same signal as the cold-launch site in `.initializeSDK`: the gate
                                // refusing start() up front IS the send-visit signal — `visitKind()`
                                // classifies from the SCANNED-tip-only `migrationAdvanceStep()` and
                                // can still lag this gate's (`isMigrationSyncBlocked`) ESTIMATED-tip
                                // view right after a no-sync broadcast session. Treat the refusal
                                // like a `.send` visit rather than a `.synchronizerStartFailed` dead
                                // end: run the broadcast session, then fall through unchanged into
                                // the same post-start code below. `.registerForSynchronizersUpdate`
                                // subscribes the gate stream, and `.migrationSyncGateChanged(false)`
                                // resumes with another `.retryStart` once the gate reopens. The
                                // broadcast lane itself reads `useEstimatedTip: true`, so it sees
                                // exactly what the gate saw when it refused.
                                let refusalReason = "start refused — migration gate active; running broadcast session"
                                LoggerProxy.event("\(MigrationManagerImpl.logTag) \(refusalReason)")
                                await send(.migrationGateDeferredSyncStart)
                                await migrationManager.advance(.beforeSync)
                            }
                        }
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() PASSED")
                        }
                        await send(.initialization(.registerForSynchronizersUpdate))
                        await send(.refreshAutomaticServer)
                    } catch {
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() failed \(error.toZcashError())")
                        }
                        await send(.initialization(.synchronizerStartFailed(error.toZcashError())))
                    }
                }
                
            case .initialization(.registerForSynchronizersUpdate):
                let stateStreamEffect = Effect.publisher {
                    sdkSynchronizer.stateStream()
                        .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                        .map { $0.redacted }
                        .map(Root.Action.synchronizerStateChanged)
                }
                .cancellable(id: state.CancelStateId, cancelInFlight: true)

                // Both migration gate feeds funnel into the SAME action under the SAME cancel id, so
                // they start and stop together. The SDK's own stream re-evaluates the wallet
                // predicate on a ~15 s ticker (and immediately after a broadcast) and dedupes
                // internally; the app-side feed is what a broadcast-failure site nudges when it
                // stopped sync for a broadcast that never reached a successful outcome. The seed
                // read ahead of the stream is what makes a cold start resume a sync stopped by a
                // broadcast in a previous session.
                let migrationSyncGateEffect = Effect.merge(
                    Effect.concatenate(
                        .run { [sdkSynchronizer] send in
                            await send(.migrationSyncGateChanged(await sdkSynchronizer.isMigrationSyncBlocked()))
                        },
                        Effect.publisher {
                            sdkSynchronizer.migrationSyncBlockedStream()
                                .dropFirst()
                                .map(Root.Action.migrationSyncGateChanged)
                        }
                    ),
                    .run { [migrationManager] send in
                        for await isBlocked in migrationManager.migrationSyncGateFeed() {
                            await send(.migrationSyncGateChanged(isBlocked))
                        }
                    }
                )
                .cancellable(id: state.migrationSyncGateCancelId, cancelInFlight: true)

                if state.bgTask != nil {
                    return .merge(stateStreamEffect, migrationSyncGateEffect)
                } else {
                    return .merge(
                        stateStreamEffect,
                        migrationSyncGateEffect,
                        .send(.home(.smartBanner(.evaluatePriority1)))
                    )
                }

            case .initialization(.checkWalletConfig):
                return .run { send in
                    let walletConfig = await walletConfigProvider.load()
                    await send(.walletConfigLoaded(walletConfig))
                }
                .cancellable(id: state.WalletConfigCancelId, cancelInFlight: true)

            case .walletConfigLoaded(let walletConfig):
                if walletConfig == WalletConfig.initial {
                    return .send(.initialization(.initialSetups))
                } else {
                    return .send(.initialization(.walletConfigChanged(walletConfig)))
                }
                
            case .initialization(.walletConfigChanged(let walletConfig)):
                return .concatenate(
                    .send(.updateStateAfterConfigUpdate(walletConfig)),
                    .send(.initialization(.initialSetups))
                )
                
            case .initialization(.initialSetups):
                if !diskSpaceChecker.hasEnoughFreeSpaceForSync() {
                    state.destinationState.preNotEnoughFreeSpaceDestination = state.destinationState.internalDestination
                    return .send(.destination(.updateDestination(.notEnoughFreeSpace)))
                } else if let preNotEnoughFreeSpaceDestination = state.destinationState.preNotEnoughFreeSpaceDestination {
                    state.destinationState.internalDestination = preNotEnoughFreeSpaceDestination
                    state.destinationState.preNotEnoughFreeSpaceDestination = nil
                }
                // TODO: [#524] finish all the wallet events according to definition, https://github.com/Electric-Coin-Company/zashi-ios/issues/524
                LoggerProxy.event(".appDelegate(.didFinishLaunching)")
                /// We need to fetch data from keychain, in order to be 100% sure the keychain can be read we delay the check a bit
                return .send(.initialization(.checkWalletInitialization))

                /// Evaluate the wallet's state based on keychain keys and database files presence
            case .initialization(.checkWalletInitialization):
                let walletState = Root.walletInitializationState(
                    databaseFiles: databaseFiles,
                    walletStorage: walletStorage,
                    zcashNetwork: zcashSDKEnvironment.network()
                )
                return .send(.initialization(.respondToWalletInitializationState(walletState)))

                /// Respond to all possible states of the wallet and initiate appropriate side effects including errors handling
            case .initialization(.respondToWalletInitializationState(let walletState)):
                switch walletState {
                case .osStatus(let osStatus):
                    state.osStatusErrorState.osStatus = osStatus
                    return .send(.destination(.updateDestination(.osStatusError)))
                case .failed:
                    state.appInitializationState = .failed
                    state.alert = AlertState.walletStateFailed(walletState)
                    return .none
                case .keysMissing:
                    state.appInitializationState = .keysMissing
                    return .send(.destination(.updateDestination(.onboarding)))
                case .filesMissing:
                    state.appInitializationState = .filesMissing
                    state.isRestoringWallet = true
                    userDefaults.setValue(true, Constants.udIsRestoringWallet)
                    state.$walletStatus.withLock { $0 = .restoring }
                    return .concatenate(
                        .send(.initialization(.initializeSDK(.restoreWallet))),
                        .send(.initialization(.checkBackupPhraseValidation))
                    )
                case .initialized:
                    if let isRestoringWallet = userDefaults.objectForKey(Constants.udIsRestoringWallet) as? Bool, isRestoringWallet {
                        state.isRestoringWallet = true
                        state.$walletStatus.withLock { $0 = .restoring }
                        return .concatenate(
                            .send(.initialization(.initializeSDK(.restoreWallet))),
                            .send(.initialization(.checkBackupPhraseValidation))
                        )
                    } else if let isResyncingWallet = userDefaults.objectForKey(Constants.udIsResyncingWallet) as? Bool, isResyncingWallet {
                        state.isRestoringWallet = true
                        state.$walletStatus.withLock { $0 = .resyncing }
                        return .concatenate(
                            .send(.initialization(.initializeSDK(.restoreWallet))),
                            .send(.initialization(.checkBackupPhraseValidation))
                        )
                    }
                    return .concatenate(
                        .send(.initialization(.initializeSDK(.existingWallet))),
                        .send(.initialization(.checkBackupPhraseValidation))
                    )
                case .uninitialized:
                    state.appInitializationState = .uninitialized
                    return .run { send in
                        try await mainQueue.sleep(for: .seconds(0.5))
                        await send(.destination(.updateDestination(.onboarding)))
                    }
                    .cancellable(id: state.CancelId, cancelInFlight: true)
                }
                
                /// Stored wallet is present, database files may or may not be present, trying to initialize app state variables and environments.
                /// When initialization succeeds user is taken to the home screen.
            case .initialization(.initializeSDK(let walletMode)):
                // First prepare wins: a foreground transition (or any other re-entry into the
                // initialization chain) while `prepareWith` is still in flight must not start a
                // second concurrent prepare — see `isInitializingSDK`. Dropping the action is
                // safe: the in-flight effect always ends in one of the terminal actions that
                // clear the latch and drive navigation themselves.
                guard !state.isInitializingSDK else { return .none }
                do {
                    let storedWallet: StoredWallet
                    do {
                        storedWallet = try walletStorage.exportWallet()
                    } catch {
                        return .send(.destination(.updateDestination(.osStatusError)))
                    }
                    let birthday = storedWallet.birthday?.value() ?? zcashSDKEnvironment.latestCheckpoint()
                    try mnemonic.isValid(storedWallet.seedPhrase.value())
                    let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())

                    state.isInitializingSDK = true
                    return .run { send in
                        do {
                            let result: Initializer.InitializationResult
                            do {
                                result = try await sdkSynchronizer.prepareWith(
                                    seedBytes,
                                    // The SDK derives the init flow itself now; a nil birthday tells it
                                    // "brand-new wallet, pick a reorg-safe recent height" (see WalletInitMode).
                                    walletMode == .newWallet ? nil : birthday,
                                    String(localizable: .accountsZashi),
                                    String(localizable: .accountsZashi).lowercased()
                                )
                            } catch ZcashError.initializerSeedMismatch {
                                // The SDK now runs this same integrity check inside
                                // Initializer.initialize and throws instead of returning, for
                                // exactly the case reconcileWalletDatabaseWithSeed below already
                                // exists to heal. Map the throw onto .seedNotRelevant so that
                                // knownStale: true heal still runs unchanged.
                                //
                                // Safe unconditionally: wipe() below leaves no accounts in the
                                // database, so the re-prepare that follows cannot hit this
                                // mismatch again. And prepare() throws before the synchronizer
                                // ever leaves .unprepared (SDKSynchronizer.prepare only advances
                                // status once initialize() returns successfully), so that
                                // re-prepare isn't blocked by prepare's own
                                // `guard status == .unprepared` early-return either.
                                result = .seedNotRelevant
                            }

                            let healed: Bool
                            switch result {
                            case .seedRequired:
                                throw ZcashError.synchronizerNotPrepared
                            case .seedNotRelevant, .success:
                                healed = try await Root.reconcileWalletDatabaseWithSeed(
                                    knownStale: result == .seedNotRelevant,
                                    seedBytes: seedBytes,
                                    isSeedRelevant: { try await sdkSynchronizer.isSeedRelevantToAnyDerivedAccount($0) },
                                    hasSeedDerivedAccount: {
                                        let accounts = try await sdkSynchronizer.walletAccounts()
                                        return accounts.contains { $0.zip32AccountIndex != nil }
                                    },
                                    clearDeviceScopedState: {
                                        Root.clearDeviceScopedWalletState(
                                            userDefaults: userDefaults,
                                            flexaHandler: flexaHandler,
                                            userStoredPreferences: userStoredPreferences,
                                            readTransactionsStorage: readTransactionsStorage
                                        )
                                    },
                                    wipe: {
                                        guard let wipePublisher = sdkSynchronizer.wipe() else {
                                            throw Root.WalletDatabaseHealError.wipeUnavailable
                                        }
                                        for try await _ in wipePublisher.values { }
                                    },
                                    reprepare: {
                                        let reprepareResult = try await sdkSynchronizer.prepareWith(
                                            seedBytes,
                                            birthday,
                                            String(localizable: .accountsZashi),
                                            String(localizable: .accountsZashi).lowercased()
                                        )
                                        guard reprepareResult == .success else {
                                            throw ZcashError.synchronizerNotPrepared
                                        }
                                    }
                                )
                            }
                            if healed {
                                await send(.initialization(.staleWalletDatabaseHealed))
                            }

                            await send(.fetchTransactionsForTheSelectedAccount)
                            /// The TCA spins an async Task in `fetchTransactionsForTheSelectedAccount` and it's needed to run
                            /// before next code here therefore Task is asleep for 0.01s. The purpose is also to not block the main thread
                            /// so await of mainQueue is not used.
                            try? await Task.sleep(nanoseconds: 10_000_000)

                            let walletAccounts = try await sdkSynchronizer.walletAccounts()
                            await send(.initialization(.loadedWalletAccounts(walletAccounts)))
                            await send(.resolveMetadataEncryptionKeys)
                            await send(.loadUserMetadata)

                            // Same session separation as the foreground path above — a launch that
                            // lands in a due broadcast window must not sync either. See
                            // `MigrationVisit`.
                            if await migrationManager.visitKind() == .send {
                                LoggerProxy.event("\(MigrationManagerImpl.logTag) skipping sync start on launch — broadcast session")
                                // I5, N4's TWIN — live until 2026-08-02 and identical in shape to the
                                // bug that froze a foreground session for six minutes. `.retryStart`
                                // got its `.migrationGateDeferredSyncStart` on 08-01; THIS site, the
                                // cold-launch one, did not, so a launch that landed in a due
                                // broadcast window suppressed sync and armed nothing to bring it
                                // back: `syncDeferredByMigrationGate` stayed false, and
                                // `stopSyncBeforeMigrationBroadcast()` early-returned on
                                // `guard isSyncing()` (correctly — there was no sync to stop), so
                                // `migrationStoppedSyncForBroadcast` stayed false too. When the
                                // post-broadcast buffer cleared, `.migrationSyncGateChanged(false)`
                                // computed `shouldResume = !isBlocked && (false || false)` and
                                // returned without a `.retryStart`. Sync never resumed for the whole
                                // launch — no polling, no sync-complete edge, no driver call at the
                                // edge, no reconcile, no pokes. The rule that closes the whole class:
                                // A SESSION THAT SUPPRESSES SYNC ALWAYS ARMS ITS OWN RESUME.
                                await send(.migrationGateDeferredSyncStart)
                                await migrationManager.advance(.beforeSync)
                            } else {
                                await migrationManager.advance(.beforeSync)
                                do {
                                    try await sdkSynchronizer.start(false)
                                } catch ZcashError.migrationSyncBlocked {
                                    // The gate refusing start() up front IS the send-visit signal:
                                    // `visitKind()` classifies from `migrationAdvanceStep()`, which
                                    // reflects the SCANNED tip, while this gate
                                    // (`isMigrationSyncBlocked`) reads the ESTIMATED tip — so a
                                    // launch right after a no-sync broadcast session can see
                                    // `visitKind() == .sync` here yet still get refused. Treat the
                                    // refusal exactly like a `.send` visit rather than a fatal
                                    // `initializationFailed` (which has no retry action): run the
                                    // broadcast session, then fall through unchanged into the same
                                    // post-start code below. `.registerForSynchronizersUpdate`
                                    // (reached via `.initializationSuccessfullyDone`) subscribes the
                                    // gate stream, and `.migrationSyncGateChanged(false)` resumes
                                    // with `.retryStart` once the gate reopens — see that case for
                                    // the resume. The broadcast lane itself reads
                                    // `useEstimatedTip: true`, so it sees exactly what the gate saw
                                    // when it refused.
                                    let refusalReason = "start refused — migration gate active; treating launch as broadcast session"
                                    LoggerProxy.event("\(MigrationManagerImpl.logTag) \(refusalReason)")
                                    await send(.migrationGateDeferredSyncStart)
                                    await migrationManager.advance(.beforeSync)
                                }
                            }

                            var selectedAccount: WalletAccount?
                            
                            for account in walletAccounts {
                                if account.vendor == .zcash {
                                    selectedAccount = account
                                }
                            }

                            exchangeRate.refreshExchangeRateUSD()

                            if let account = selectedAccount {
                                let addressBookEncryptionKeys = try? walletStorage.exportAddressBookEncryptionKeys()
                                if addressBookEncryptionKeys == nil {
                                    do {
                                        var keys = AddressBookEncryptionKeys.empty
                                        try keys.cacheFor(
                                            seed: seedBytes,
                                            account: account.account,
                                            network: zcashSDKEnvironment.network().networkType
                                        )
                                        try walletStorage.importAddressBookEncryptionKeys(keys)
                                    } catch {
                                        // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                                    }
                                }

                                await send(.initialization(.initializationSuccessfullyDone))
                            } else {
                                await send(.initialization(.initializationSuccessfullyDone))
                            }
                        } catch Root.WalletDatabaseHealError.reprepareFailed {
                            // The stale database was already wiped before re-prepare failed, so
                            // there is no database left to leave the user staring at a dead-end
                            // `initializationFailed` alert for (that only recovers on relaunch).
                            // Recompute wallet-initialization state in-session instead: with the
                            // database gone this resolves to `.filesMissing`, which re-enters the
                            // existing restore path. The latch must drop first or the re-entry's
                            // own `.initializeSDK` would be swallowed by the single-flight guard.
                            await send(.initialization(.initializeSDKFinished))
                            await send(.initialization(.checkWalletInitialization))
                        } catch {
                            await send(.initialization(.initializationFailed(error.toZcashError())))
                        }
                    }
                } catch {
                    return .send(.initialization(.initializationFailed(error.toZcashError())))
                }

            case .initialization(.staleWalletDatabaseHealed):
                state.isRestoringWallet = true
                userDefaults.setValue(true, Constants.udIsRestoringWallet)
                state.$walletStatus.withLock { $0 = .restoring }
                state.isStaleWalletHealedAlertPending = true
                // Covers the third transition point: the destination may have already settled
                // on `.home` before this heal signal arrives (e.g. the new-wallet cascade), in
                // which case neither of the other two hooks (`updateDestination` / the
                // `.phraseDisplay`/`.onboarding` bypass arm) will ever fire again to deliver it.
                if state.destinationState.destination == .home {
                    return presentStaleWalletHealedAlertEffect(cancelId: state.staleWalletHealedAlertCancelId)
                }
                return .none

            case .initialization(.presentStaleWalletHealedAlert):
                // Re-check the destination: the 0.5s wait isn't cancelled by leaving `.home`
                // (only re-entering `.home` reschedules this effect), so a deep link or other
                // navigation during the window must not present the notice over whatever screen
                // is showing now. Leave the flag set so a later return to `.home` re-fires the
                // hook and the notice still gets delivered.
                guard state.isStaleWalletHealedAlertPending, state.destinationState.destination == .home else {
                    return .none
                }
                state.isStaleWalletHealedAlertPending = false
                state.alert = AlertState.staleWalletDatabaseHealed()
                return .none

            case .initialization(.initializeSDKFinished):
                state.isInitializingSDK = false
                return .none

            case .initialization(.initializationSuccessfullyDone):
                state.isInitializingSDK = false
                // I4: replay a notification tap that landed while the app was still coming up. Done
                // HERE, at the one point where "the app is ready" is unambiguously true, so the cold
                // and warm entries converge on the same screen by the same route.
                var replayEffect = Effect<Action>.none
                if state.pendingMigrationNotificationTap && state.featureFlags.migration {
                    state.pendingMigrationNotificationTap = false
                    LoggerProxy.event("\(MigrationManagerImpl.logTag) replaying the latched notification tap")
                    replayEffect = openMigrationCoordFlow(state: &state)
                } else {
                    // Never carry a stale latch into the next launch: a tap the user has since
                    // resolved must not reopen the flow behind them.
                    state.pendingMigrationNotificationTap = false
                }
                return .merge(
                    replayEffect,
                    .send(.initialization(.registerForSynchronizersUpdate)),
                    .publisher {
                        autolockHandler.batteryStatePublisher()
                            .map { _ in Root.Action.batteryStateChanged }
                    }
                    .cancellable(id: state.CancelBatteryStateId, cancelInFlight: true),
                    .send(.batteryStateChanged),
                    .send(.observeTransactions),
                    .send(.observeShieldingProcessor),
                    .send(.observeTorInit),
                    .send(.refreshAutomaticServer),
                    // MOB-1466: the OTHER start/restart site — a completed launch is just as much
                    // "the app is now open" as a foreground re-entry is. See `willEnterForeground`'s
                    // identical call for the "the open breaks the loop's sleep" rationale.
                    migrationTickLoopEffect(state: state)
                )
                
            case .initialization(.loadedWalletAccounts(let walletAccounts)):
                state.$walletAccounts.withLock { $0 = walletAccounts }
                if state.selectedWalletAccount == nil {
                    for account in walletAccounts {
                        if account.vendor == .zcash {
                            state.$selectedWalletAccount.withLock { $0 = account }
                            state.$zashiWalletAccount.withLock { $0 = account }
                            break
                        }
                    }
                }
                return .merge(
                    .send(.loadContacts),
                    .send(.loadUserMetadata),
                    .send(.loadSwapAPIAccess)
                )

            case .resolveMetadataEncryptionKeys:
                do {
                    let storedWallet: StoredWallet
                    do {
                        storedWallet = try walletStorage.exportWallet()
                    } catch {
                        return .send(.destination(.updateDestination(.osStatusError)))
                    }
                    try mnemonic.isValid(storedWallet.seedPhrase.value())
                    let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                    
                    return .run { [walletAccounts = state.walletAccounts] send in
                        do {
                            
                            for account in walletAccounts {
                                let userMetadataEncryptionKeys = try? walletStorage.exportUserMetadataEncryptionKeys(account.account)
                                if userMetadataEncryptionKeys == nil {
                                    do {
                                        var keys = UserMetadataEncryptionKeys.empty
                                        try keys.cacheFor(
                                            seed: seedBytes,
                                            account: account.account,
                                            network: zcashSDKEnvironment.network().networkType
                                        )
                                        try walletStorage.importUserMetadataEncryptionKeys(keys, account.account)
                                        await send(.loadUserMetadata)
                                    } catch {
                                        // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                                    }
                                }
                            }
                        }
                    }
                } catch { }
                return .none
                
            case .initialization(.checkBackupPhraseValidation):
                do {
                    let _ = try walletStorage.exportWallet()
                } catch {
                    return .send(.destination(.updateDestination(.osStatusError)))
                }

                state.appInitializationState = .initialized
                let isAtDeeplinkWarningScreen = state.destinationState.destination == .deeplinkWarning

                return .run { send in
                    // Delay the splash overlay dismissal
                    try await mainQueue.sleep(for: .seconds(0.5))
                    if !isAtDeeplinkWarningScreen {
                        await send(.destination(.updateDestination(Root.DestinationState.Destination.home)))
                    }
                }
                .cancellable(id: state.CancelId, cancelInFlight: true)
                
            case .initialization(.resetZashiRequest(let areMetadataPreserved)):
                state.areMetadataPreserved = areMetadataPreserved
                return .send(.initialization(.resetZashi))
                
            case .initialization(.resetZashiRequestCanceled):
                state.alert = nil
                for (id, element) in zip(state.settingsState.path.ids, state.settingsState.path) {
                    if element.is(\.resetZashi) {
                        return .send(.settings(.path(.element(id: id, action: .resetZashi(.deleteCanceled)))))
                    }
                }
                return .none

            case .initialization(.resetZashi):
                guard let wipePublisher = sdkSynchronizer.wipe() else {
                    return .send(.resetZashiSDKFailed)
                }
                return .publisher {
                    wipePublisher
                        .replaceEmpty(with: Void())
                        .map { _ in return Root.Action.resetZashiSDKSucceeded }
                        .replaceError(with: Root.Action.resetZashiSDKFailed)
                        .receive(on: mainQueue)
                }
                .cancellable(id: state.SynchronizerCancelId, cancelInFlight: true)

            case .resetZashiSDKSucceeded:
                state.splashAppeared = true
                state.isRestoringWallet = false
                Root.clearDeviceScopedWalletState(
                    userDefaults: userDefaults,
                    flexaHandler: flexaHandler,
                    userStoredPreferences: userStoredPreferences,
                    readTransactionsStorage: readTransactionsStorage
                )
                if !state.areMetadataPreserved {
                    state.walletAccounts.forEach { account in
                        try? userMetadataProvider.resetAccount(account.account)
                        try? addressBook.resetAccount(account.account)
                        #if VOTING_ENABLED
                        try? votingMetadata.resetAccount(account.account)
                        #endif
                    }
                }
                state.walletAccounts.forEach { account in
                    try? walletStorage.clearEncryptionKeys(account.account)
                }
                state.autoUpdateSwapCandidates.removeAll()
                try? userMetadataProvider.reset()
                #if VOTING_ENABLED
                votingMetadata.reset()
                #endif
                state.$walletStatus.withLock { $0 = .none }
                state.$selectedWalletAccount.withLock { $0 = nil }
                state.$walletAccounts.withLock { $0 = [] }
                state.$zashiWalletAccount.withLock { $0 = nil }
                state.$transactionMemos.withLock { $0 = [:] }
                state.$addressBookContacts.withLock { $0 = .empty }
                state.$transactions.withLock { $0 = [] }
                state.path = nil
                if state.appInitializationState != .keysMissing {
                    state = .initial
                }

                // MOB-1466 (N3, field-caught 2026-08-01): the migration wipe rides this same reset
                // boundary as `clearDeviceScopedWalletState` above, for the identical reason that
                // helper gives for its voting sweep — nothing from the previous owner of this device
                // survives it. Without it, a notification armed by the DELETED wallet fires against
                // a freshly restored one and invites the user into a migration run that is not
                // theirs, backed by persisted state keyed to a wallet that no longer exists.
                //
                // Async, so it cannot ride `clearDeviceScopedWalletState` (a synchronous static);
                // sequenced ahead of `.resetZashiKeychainRequest` so the reset chain continues only
                // once the pokes have actually been withdrawn.
                return .run { [migrationManager] send in
                    await migrationManager.wipeAllMigrationState()
                    await send(.resetZashiKeychainRequest)
                }

            case .resetZashiKeychainRequest:
                return .run { send in
                    do {
                        try walletStorage.resetZashi()
                        await send(.resetZashiFinishProcessing)
                    } catch WalletStorage.KeychainError.unknown(let osStatus) {
                        await send(.resetZashiKeychainFailed(osStatus))
                    }
                }

            case .resetZashiFinishProcessing:
                do {
                    let areKeysPresent = try walletStorage.areKeysPresent()
                    if areKeysPresent {
                        return .send(.resetZashiKeychainFailedWithCorruptedData("Keychain keys are still present"))
                    }
                } catch WalletStorage.WalletStorageError.alreadyImported {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("alreadyImported"))
                } catch WalletStorage.WalletStorageError.uninitializedAddressBookEncryptionKeys {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("uninitializedAddressBookEncryptionKeys"))
                } catch WalletStorage.WalletStorageError.storageError(let error) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("storageError, \(error.localizedDescription)"))
                } catch WalletStorage.WalletStorageError.unsupportedVersion(let version) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unsupportedVersion \(version)"))
                } catch WalletStorage.WalletStorageError.unsupportedLanguage(let language) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unsupportedLanguage, \(language)"))
                } catch WalletStorage.KeychainError.decoding {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("decoding"))
                } catch WalletStorage.KeychainError.duplicate {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("duplicate"))
                } catch WalletStorage.KeychainError.encoding {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("encoding"))
                } catch WalletStorage.KeychainError.noDataFound {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("noDataFound"))
                } catch WalletStorage.KeychainError.unknown(let osStatus) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unknown, OSStatus \(osStatus)"))
                } catch WalletStorage.WalletStorageError.uninitializedWallet {
                    // this is valid state and what we expect
                } catch {
                    return .send(.resetZashiKeychainFailedWithCorruptedData(error.localizedDescription))
                }

                // TODO: [#1627] validate whether this code makes sense
                // https://github.com/zodl-inc/zodl-ios/issues/1627
//                if state.appInitializationState == .keysMissing && state.onboardingState.isImportingWallet {
//                    state.appInitializationState = .uninitialized
//                    return .cancel(id: SynchronizerCancelId)
//                } else if state.appInitializationState == .keysMissing && state.onboardingState.destination == .createNewWallet {
//                    state.appInitializationState = .uninitialized
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.onboarding(.createNewWalletRequested))
//                    )
//                } else {
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.initialization(.checkWalletInitialization))
//                    )
//                }

                // TODO: [#1627] this might need to be recreated
                // https://github.com/zodl-inc/zodl-ios/issues/1627
//                if state.appInitializationState == .keysMissing && state.onboardingState.destination == .importExistingWallet {
//                    state.appInitializationState = .uninitialized
//                    return .cancel(id: SynchronizerCancelId)
//                } else if state.appInitializationState == .keysMissing && state.onboardingState.destination == .createNewWallet {
//                    state.appInitializationState = .uninitialized
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.onboarding(.createNewWalletRequested))
//                    )
//                } else {
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.initialization(.checkWalletInitialization))
//                    )
//                }
                return .concatenate(
                    .cancel(id: state.SynchronizerCancelId),
                    .send(.initialization(.checkWalletInitialization))
                )

            case .resetZashiKeychainFailedWithCorruptedData(let errMsg):
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeKeychainFailed(errMsg)
                return .cancel(id: state.SynchronizerCancelId)

            case .resetZashiKeychainFailed(let osStatus):
                guard state.maxResetZashiAppAttempts == 0 else {
                    state.maxResetZashiAppAttempts -= 1
                    return .send(.resetZashiKeychainRequest)
                }
                state.maxResetZashiAppAttempts = ResetZashiConstants.maxResetZashiAppAttempts
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeFailed(osStatus)
                return .cancel(id: state.SynchronizerCancelId)

            case .resetZashiSDKFailed:
                guard state.maxResetZashiSDKAttempts == 0 else {
                    state.maxResetZashiSDKAttempts -= 1
                    return .concatenate(
                        .cancel(id: state.SynchronizerCancelId),
                        .send(.initialization(.resetZashi))
                    )
                }
                state.maxResetZashiSDKAttempts = ResetZashiConstants.maxResetZashiSDKAttempts
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeFailed(Int32.max)
                return .cancel(id: state.SynchronizerCancelId)

            case .phraseDisplay(.finishedTapped), .onboarding(.newWalletSuccessfulyCreated):
                state.destinationState.destination = .home
                // This is the second (synchronous, action-round-trip-free) place the destination
                // can land on `.home` — see `presentStaleWalletHealedAlertEffect` (RootStore.swift).
                if state.isStaleWalletHealedAlertPending {
                    return presentStaleWalletHealedAlertEffect(cancelId: state.staleWalletHealedAlertCancelId)
                }
                return .none

            case .onboarding(.createNewWalletTapped):
                if state.appInitializationState == .keysMissing {
                    state.alert = AlertState.existingWallet()
                    return .none
                } else {
                    return .send(.onboarding(.createNewWalletRequested))
                }

            case .initialization(.restoreExistingWallet):
                return .run { send in
                    await send(.onboarding(.dismissDestination))
                    try await mainQueue.sleep(for: .seconds(1))
                    await send(.onboarding(.importExistingWallet))
                }

            case .initialization(.seedValidationResult(let validSeed)):
                if !validSeed {
                    state.alert = AlertState.differentSeed()
                }
                return .none

            case .updateStateAfterConfigUpdate(let walletConfig):
                state.walletConfig = walletConfig
                return .none

            case .initialization(.initializationFailed(let error)):
                state.isInitializingSDK = false
                state.appInitializationState = .failed
                state.alert = AlertState.initializationFailed(error)
                return .none

            default:
                return .none
            }
        }
    }
    
    private func checkUnavailableService(_ error: Error) -> Bool {
        switch error {
        case ZcashError.serviceGetInfoFailed(.timeOut),
            ZcashError.serviceLatestBlockFailed(.timeOut),
            ZcashError.serviceLatestBlockHeightFailed(.timeOut),
            ZcashError.serviceBlockRangeFailed(.timeOut),
            ZcashError.serviceSubmitFailed(.timeOut),
            ZcashError.serviceFetchTransactionFailed(.timeOut),
            ZcashError.serviceFetchUTXOsFailed(.timeOut),
            ZcashError.serviceBlockStreamFailed(.timeOut),
            ZcashError.serviceSubtreeRootsStreamFailed(.timeOut):
            return true
        default: return false
        }
    }

    /// Presents the one-time Ironwood announcement screen once the device hasn't acknowledged
    /// it yet, Ironwood is active on chain, and it is safe to take the screen over. Called from
    /// both `.synchronizerStateChanged` (cold start and the tail of a restore) and
    /// `.appDelegate(.willEnterForeground)` (returning to the foreground, where the tip is
    /// already known in memory from before backgrounding) — together the two cover every moment
    /// the tip or the safety gate can newly satisfy the predicate.
    ///
    /// Each guard below is load-bearing and deliberately ordered:
    /// 1. the in-memory per-session latch short-circuits every call once the gate has already
    ///    "resolved" this session (presented, or found already-acknowledged in the keychain);
    /// 2. the tip/activation check runs before any keychain access — cheap, and it keeps the
    ///    (overwhelmingly common, pre-activation) path from ever touching the keychain. `tip > 0`
    ///    is a deliberate fail-safe: the chain tip is in-memory only and reads `0` before the
    ///    first successful server round-trip, and an unknown tip must count as "not active" —
    ///    never as a false positive that skips straight past activation;
    /// 3. the keychain read happens at most once per session: as soon as it reports
    ///    already-acknowledged, the latch is set so this guard is never evaluated again;
    /// 4. the safety gate is re-checked on every call and deliberately does NOT set the latch on
    ///    failure, so a blocked attempt (e.g. mid-flow) retries on a later tick instead of being
    ///    silently skipped for the rest of the session.
    func presentIronwoodAnnouncementIfNeeded(state: inout Root.State, tip: BlockHeight) {
        guard !state.ironwoodAnnouncementResolved else { return }
        guard tip > 0, tip >= zcashSDKEnvironment.ironwoodActivationHeight() else { return }
        guard walletStorage.exportIronwoodAnnouncementFlag() != true else {
            state.ironwoodAnnouncementResolved = true
            return
        }
        guard state.canPresentIronwoodAnnouncement else { return }
        state.ironwoodAnnouncementResolved = true
        // Assigned directly rather than sending `.destination(.updateDestination(...))`: the
        // two call sites below have several early-return paths of their own, and merging an
        // effect into all of them would be invasive. The two things `updateDestination` adds
        // over a direct assignment — the deeplink-warning guard and the deferred
        // stale-wallet-healed alert hook — are both no-ops here: `canPresentIronwoodAnnouncement`
        // already requires `destination == .home`, so the deeplink-warning screen can't be in
        // play, and the heal hook only fires when the destination is moving TO `.home`, not away
        // from it. There is precedent for a direct assignment in this same file — see
        // `state.destinationState.destination = .home` in the `.phraseDisplay(.finishedTapped)` /
        // `.onboarding(.newWalletSuccessfulyCreated)` arm above.
        state.destinationState.destination = .ironwoodAnnouncement
    }

    // MARK: - MOB-1466: the foreground migration TICK LOOP

    /// A `privateScheduled` migration run's broadcast opportunities used to come from app-opens
    /// ALONE (`.beforeSync`) — an app left sitting open in the foreground for the ten-plus minutes
    /// between transfer windows advanced nothing on its own, however long it stayed frontmost,
    /// because nothing short of a fresh open ever asked the engine again. This effect closes that
    /// gap: a recurring 30s wake-up (`.migrationTick`, handled above) for exactly as long as the app
    /// stays open and a run exists that could use it.
    ///
    /// SPAWN CONDITION, re-derived fresh at every call site rather than cached in state: Ironwood
    /// must be active AND at least one CANDIDATE account (the identical set
    /// `MigrationStepDriver.advance` itself derives, via the same `MigrationDerivations
    /// .candidateAccountUUIDs`) must be running `.privateScheduled`. An `.immediate`-only wallet has
    /// nothing a tick could ever help with — see `MigrationStepPlan`'s tick column and the mode belt
    /// in `executeBroadcast` — so spawning the loop for one would just be a silent no-op every 30s,
    /// forever, for a wallet that will never have anything for it to do.
    ///
    /// `cancelInFlight: true` on the SAME `migrationTickCancelId` at every start/restart site is
    /// "the open breaks the loop's sleep": both call sites below are lifecycle edges (a fresh
    /// foreground, a just-completed launch) at which resetting the countdown to zero is exactly
    /// right — there is no reason for a wake-up armed several minutes into a PREVIOUS foreground to
    /// fire moments after a new one begins.
    ///
    /// The effect's own body only ever SENDS `.migrationTick` — ticking is all it does. Calling the
    /// driver, deciding whether to keep going, and reacting to what it found are the REDUCER's job
    /// (the `.migrationTick`/`.migrationTickAdvanced` cases above), which is what lets this effect be
    /// cancelled cleanly at any instant without ever leaving an in-flight `advance()` half-handled.
    func migrationTickLoopEffect(state: Root.State) -> Effect<Root.Action> {
        // MOB-1466: THE OFF SWITCH, checked before anything else. `.zero` (set on
        // `Constants.migrationTickInterval`, or injected by a test) means the automatic loop does
        // not exist: no spawn, no timer, no engine reads — while the app-open pokes, a separate
        // lane entirely, keep working (pinned by `zeroIntervalKeepsTheForegroundPokeWorking`).
        guard migrationTickInterval > Swift.Duration.zero else {
            return .none
        }

        // `isIronwoodActivated` gated FIRST, as its own `guard`, deliberately — every OTHER Root
        // lifecycle test in the suite reaches this call site (it runs on every
        // `.initializationSuccessfullyDone`/`.willEnterForeground`), and most of them have no
        // reason to stub `migrationManager` at all. `migrationMode` has no macro-supplied default
        // (unlike `isIronwoodActivated`, which safely defaults `false`), so it traps under
        // `MigrationManagerClient.testValue` when called unstubbed — this guard must therefore
        // short-circuit BEFORE `migrationMode` is ever reached, not merely list both conditions in
        // one `guard a, b` (which still evaluates a `let` computed ahead of it regardless of `a`).
        guard migrationManager.isIronwoodActivated() else {
            return .none
        }

        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: state.selectedWalletAccount?.id,
            walletAccounts: state.walletAccounts
        )
        let hasScheduledCandidate = accountUUIDs.contains { accountUUID in
            migrationManager.migrationMode(accountUUID) == MigrationMode.privateScheduled
        }
        guard hasScheduledCandidate else {
            return .none
        }

        return .run { send in
            // The first tick fires 30s from NOW, never at t=0: `clock.timer(interval:)` sleeps a
            // full interval before its first element, and an app-open already just ran its own
            // `.beforeSync`/`.afterSync` pair moments ago (or is about to) — an immediate tick would
            // only ever race that, never add anything.
            for await _ in continuousClock.timer(interval: migrationTickInterval) {
                await send(.migrationTick)
            }
        }
        .cancellable(id: state.migrationTickCancelId, cancelInFlight: true)
    }

    // MARK: - PHASE 7: opening the migration flow from OUTSIDE it

    /// The single entry point for every Root-side site that opens (or re-opens) the migration flow:
    /// the banner tap and the notification tap. Both replace `migrationCoordFlowState` wholesale, so
    /// both must run the same defensive teardown first — hence one helper rather than two inline
    /// resets that can drift.
    func openMigrationCoordFlow(state: inout Root.State) -> Effect<Root.Action> {
        let cancelEffect = cancelAbandonedKeystoneMigrationRun(state: state)
        state.migrationCoordFlowState = MigrationCoordFlow.State.initial
        state.path = Root.State.Path.migrationCoordFlow
        return cancelEffect
    }

    /// Cancels the engine run a Keystone BATCH ceremony created, when the flow is being torn down
    /// from OUTSIDE while that ceremony is still live.
    ///
    /// The engine creates a Keystone commit's ENTIRE run — preparations and the schedule's transfers
    /// alike — the moment its PCZTs are built (`proposeNoteSplitPCZTs`, called by
    /// `MigrationCommitPipeline.proposeKeystoneBatch`), and always resumes a stored non-terminal run
    /// on the next attempt, ignoring any newer preview. Wiping `migrationCoordFlowState` while
    /// `pendingKeystoneSigning` is live would strand that run: a later re-entry would silently resume
    /// signing the same, by-then-stale PCZTs instead of proposing a fresh preview.
    ///
    /// `pendingKeystoneSigning` is only ever set once the ceremony actually started, so its presence
    /// here means exactly "a ceremony was begun and never resolved". Cancel via
    /// `restartCurrentMigrationStep`, discarding the fresh schedule it returns — the user re-runs the
    /// ceremony from a fresh preview, the same v1 semantics as the in-flow
    /// `.keystoneScanAbandoned` twin.
    ///
    /// Restricted to `.planCommit`: the immediate lane's `createPCZTFromProposal` is engine-external
    /// and created no run, so cancelling for it would at best be a no-op and at worst restart an
    /// unrelated committed run. Read BEFORE the caller resets the state, and cancelled on the run's
    /// RECORDED owner (`pendingKeystoneSigningAccountUUID`) rather than the currently-selected
    /// account, which can have moved on by the time this runs. Fire-and-forget: a failure just leaves
    /// the stray run for the next attempt to encounter and cancel itself.
    func cancelAbandonedKeystoneMigrationRun(state: Root.State) -> Effect<Root.Action> {
        guard case .planCommit? = state.migrationCoordFlowState.pendingKeystoneSigning,
              let accountUUID = state.migrationCoordFlowState.pendingKeystoneSigningAccountUUID
                ?? state.selectedWalletAccount?.id else {
            return .none
        }

        return .run { [sdkSynchronizer] _ in
            _ = try? await sdkSynchronizer.restartCurrentMigrationStep(accountUUID)
        }
    }
}
