//
//  RootMigrationGateStopOnBlockTests.swift
//  zodlTests
//
//  MOB-1466 — the STOP half of Root's migration sync-gate pair, field-caught 2026-08-02
//  (evening log): with the app foregrounded and the tick loop running, a proved, due transfer
//  sat unbroadcast for 15+ minutes. The engine answered `broadcast(id:)` on every read; every
//  tick was `held(privacy buffer until …)` with a deadline that slid forward forever, because
//  the app-side send window re-armed faster than it could expire — the foreground sync completed
//  every ~2.5 minutes throughout.
//
//  FIRST CUT (superseded by this file's current content, kept for history): stopped a running
//  sync through `stopSyncBeforeMigrationBroadcast()`, guarded by `isSyncing()`. The WHOLE-BRANCH
//  review caught that this guard is false in exactly the wedge state it exists to fix — the
//  engine the field log describes sits at `.upToDate` BETWEEN blocks, not mid-scan, so
//  `isSyncing()` reads false at every tick and the original stop never fired in its own
//  motivating scenario. Two further scoping holes: the stop read only the SELECTED account's
//  `migrationMode`/`isManualDelivery`, though the SDK gate is wallet-wide; and nothing stopped
//  the effect from firing while the tick loop's own off switch (`migrationTickInterval == .zero`)
//  meant no lane existed to consume the silence it bought.
//
//  THIS suite now pins `stopStartedSyncForMigrationGate()` (SDKSynchronizerInterface.swift) — the
//  sibling whose predicate is "started" (`.syncing` OR `.upToDate`), not "syncing" — plus
//  wallet-wide candidate scoping (`MigrationDerivations.candidateAccountUUIDs`, the same set
//  `migrationTickLoopEffect(state:)` scopes itself by) and the tick-loop-off-switch gate. The
//  RESUME half of the pair (`.migrationSyncGateChanged(false)` -> `.retryStart`) is unchanged and
//  untouched here — see `RootMigrationGateRefusalTests`/`RootMigrationTickLoopTests` for its
//  coverage.
//
//  `extension Root.State: @retroactive Equatable` already exists module-wide at
//  RootInitializeSDKHealTests.swift — this file uses it rather than redeclaring (see
//  RootMigrationGateRefusalTests's header for the duplicate-conformance rationale).
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: resets the process-global `@Shared(.inMemory(.migrationStoppedSyncForBroadcast))`
// flag per test, plus the shared `selectedWalletAccount`/`walletAccounts` candidate keys every
// `makeStore` call (re)installs — the same shared-state discipline
// `MigrationTickDriverTests`/`RootMigrationTickLoopTests` serialize their own suites over.
@Suite(.serialized) @MainActor struct RootMigrationGateStopOnBlockTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x08, count: 16))
    private static let secondCandidateAccountUUID = AccountUUID(id: [UInt8](repeating: 0x09, count: 16))

    private static func account(_ uuid: AccountUUID) -> WalletAccount {
        WalletAccount(
            Account(
                id: uuid,
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// Builds a `Root` `TestStore` for driving `.migrationSyncGateChanged` directly. `stopCalls`
    /// counts `sdkSynchronizer.stop()` — `stopStartedSyncForMigrationGate()` is an extension
    /// composed of the client's own `latestState()` + `stop()` closures, so spying `stop` observes
    /// the real production path, predicate included.
    ///
    /// Always installs `accountUUID` as the selected account AND the sole entry of
    /// `walletAccounts`, so `MigrationDerivations.candidateAccountUUIDs` has exactly one candidate
    /// for every test except `aCandidateAccountEligibilityIsWalletWide`, which passes
    /// `secondCandidateMode` to install a SECOND candidate (`secondCandidateAccountUUID`)
    /// alongside it, with its own independent mode.
    private func makeStore(
        stopCalls: LockIsolated<Int>,
        syncStatus: SyncStatus,
        mode: MigrationMode?,
        isManualDelivery: Bool,
        tickInterval: Swift.Duration = .seconds(30),
        lastMigrationSyncGateBlocked: Bool = false,
        secondCandidateMode: MigrationMode? = nil
    ) -> TestStore<Root.State, Root.Action> {
        var initialState = Root.State(
            destinationState: Root.DestinationState(internalDestination: .welcome),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )
        initialState.lastMigrationSyncGateBlocked = lastMigrationSyncGateBlocked

        // Resolved here, in the suite's `@MainActor` context, rather than inside the `@Sendable`
        // dependency closure below — mirrors `RootMigrationGateRefusalTests.makeStore`'s
        // `seedDerivedAccount` rationale: a `@Sendable` closure literal cannot reach across the
        // `@MainActor` isolation boundary to read a static member of this suite directly.
        let secondAccountUUID = RootMigrationGateStopOnBlockTests.secondCandidateAccountUUID

        let selectedAccount = Self.account(Self.accountUUID)
        initialState.$selectedWalletAccount.withLock { $0 = selectedAccount }
        if secondCandidateMode != nil {
            let secondAccount = Self.account(secondAccountUUID)
            initialState.$walletAccounts.withLock { $0 = [selectedAccount, secondAccount] }
        } else {
            initialState.$walletAccounts.withLock { $0 = [selectedAccount] }
        }

        let store = TestStore(
            initialState: initialState
        ) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationTickInterval = tickInterval

            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationMode = { accountUUID in
                if let secondCandidateMode, accountUUID == secondAccountUUID {
                    return secondCandidateMode
                }
                return mode
            }
            $0.migrationManager.isManualDelivery = { _ in isManualDelivery }

            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                latestState: {
                    var syncState = SynchronizerState.zero
                    syncState.syncStatus = syncStatus
                    return syncState
                },
                stop: {
                    stopCalls.withValue { $0 += 1 }
                }
            )
        }
        store.exhaustivity = .off
        return store
    }

    /// Resets the shared resume flag the production stop sets — process-global, so each test
    /// starts from a known false.
    private func resetSharedResumeFlag() {
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = false }
    }

    // MARK: - THE wedge state: a started engine idling at the tip between blocks

    /// THE requirement the whole-branch review's C1 finding exists for: the genuine false->true
    /// edge stops a `.privateScheduled`, non-manual run's sync even when the engine is NOT
    /// mid-scan — `.upToDate` is the actual field-caught wedge shape (`isSyncing()` reads false
    /// there, which is why the first cut's guard never fired). Through the shared-flag-setting
    /// production path, so the existing false-edge resume machinery will restart sync later.
    @Test func blockedEdgeStopsAnEngineIdlingAtTheTip() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,
            isManualDelivery: false
        )

        await store.send(.migrationSyncGateChanged(true))
        await store.finish()

        #expect(stopCalls.value == 1, "the blocked edge must stop a sync idling at the tip, not just an in-flight scan")
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        #expect(migrationStoppedSyncForBroadcast == true, "the stop must go through stopStartedSyncForMigrationGate, arming the resume half")
    }

    /// The shape the first cut of this handler already covered: an in-flight scan also counts as
    /// "started" and must still stop. `.syncing`'s associated values (progress, funds-spendable)
    /// are irrelevant to the predicate — any payload must match.
    @Test func blockedEdgeStopsAnInFlightScan() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.syncing(0, false),
            mode: MigrationMode.privateScheduled,
            isManualDelivery: false
        )

        await store.send(.migrationSyncGateChanged(true))
        await store.finish()

        #expect(stopCalls.value == 1, "an in-flight scan must still be stopped")
    }

    /// The B12 contract, unchanged by this rework: an engine that was never started has nothing to
    /// stop, and the resume flag must never be armed for a sync nobody paused.
    @Test func aStoppedEngineIsLeftAlone() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.stopped,
            mode: MigrationMode.privateScheduled,
            isManualDelivery: false
        )

        await store.send(.migrationSyncGateChanged(true))
        await store.finish()

        #expect(stopCalls.value == 0, "a stopped engine has nothing to stop")
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        #expect(!migrationStoppedSyncForBroadcast, "never arm the resume flag for a sync nobody paused")
    }

    // MARK: - Scoping holes closed by the whole-branch review (C2 / I4)

    /// C2: a stop that lands while the tick loop's own off switch is set would strand sync with no
    /// lane left to consume the silence it bought — the stop must not fire at all in that shape.
    @Test func theTickLoopOffSwitchDisablesTheStop() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,
            isManualDelivery: false,
            tickInterval: Swift.Duration.zero
        )

        await store.send(.migrationSyncGateChanged(true))
        await store.finish()

        #expect(stopCalls.value == 0, "with the tick loop disabled, nothing can ever consume the stop's silence")
    }

    /// I4: the SDK gate is WALLET-wide, not selected-account-scoped — a second candidate account's
    /// `.privateScheduled` run must be able to stop sync even when the selected account itself is
    /// `.immediate` (and so, under the old selected-account-only guard, would never have stopped
    /// anything).
    @Test func aCandidateAccountEligibilityIsWalletWide() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.immediate,
            isManualDelivery: false,
            secondCandidateMode: MigrationMode.privateScheduled
        )

        await store.send(.migrationSyncGateChanged(true))
        await store.finish()

        #expect(stopCalls.value == 1, "a second candidate's privateScheduled run must stop sync although the selected account is immediate-mode")
    }

    // MARK: - Mode / delivery scoping (unchanged from the first cut)

    /// An `.immediate` run's broadcasts ride the open lanes, never ticks — stopping its sync
    /// would strand it, not help it.
    @Test func immediateModeRunKeepsItsSyncRunning() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.immediate,
            isManualDelivery: false
        )

        await store.send(.migrationSyncGateChanged(true))
        await store.finish()

        #expect(stopCalls.value == 0, "an immediate-mode run must keep today's behavior — no stop")
    }

    /// A manual-delivery run broadcasts by hand (the Send-now lane does its own stop) — the
    /// automatic stop must leave its sync alone.
    @Test func manualDeliveryRunKeepsItsSyncRunning() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,
            isManualDelivery: true
        )

        await store.send(.migrationSyncGateChanged(true))
        await store.finish()

        #expect(stopCalls.value == 0, "a manual-delivery run must keep today's behavior — no stop")
    }

    /// The handler's existing dedupe scopes the stop to the TRANSITION: a repeated `true`
    /// emission (the stream re-evaluates every 15 s) must not stop again.
    @Test func repeatedBlockedEmissionsStopOnlyOnce() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,
            isManualDelivery: false
        )

        await store.send(.migrationSyncGateChanged(true))
        await store.finish()
        await store.send(.migrationSyncGateChanged(true))
        await store.finish()

        #expect(stopCalls.value == 1, "only the false->true TRANSITION stops — repeated emissions are quiet")
    }

    /// The false edge (gate clearing) must never stop — it is the RESUME half's edge.
    @Test func clearingEdgeNeverStops() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(
            stopCalls: stopCalls,
            syncStatus: SyncStatus.upToDate,
            mode: MigrationMode.privateScheduled,
            isManualDelivery: false,
            lastMigrationSyncGateBlocked: true
        )

        await store.send(.migrationSyncGateChanged(false))
        await store.finish()

        #expect(stopCalls.value == 0, "the clearing edge belongs to the resume half — no stop")
    }
}
