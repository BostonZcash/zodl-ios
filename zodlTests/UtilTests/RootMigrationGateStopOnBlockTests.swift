//
//  RootMigrationGateStopOnBlockTests.swift
//  zodlTests
//
//  MOB-1466 — the STOP half of Root's migration sync-gate pair, field-caught 2026-08-02
//  (evening log): with the app foregrounded and the tick loop running, a proved, due transfer
//  sat unbroadcast for 15+ minutes. The engine answered `broadcast(id:)` on every read; every
//  tick was `held(privacy buffer until …)` with a deadline that slid forward forever, because
//  the app-side send window (180 s from every completed sync) re-armed faster than it could
//  expire — the foreground sync completed every ~2.5 minutes throughout.
//
//  The SDK's `isMigrationSyncBlocked()` said blocked (ready broadcast waiting) the whole time,
//  but `SlipstreamSynchronizer.start()` enforces that only on NEW starts ("an already-running
//  engine is unaffected"), and Root's `.migrationSyncGateChanged(true)` handler only re-derived
//  banners. The RESUME half of the pair already existed (`.migrationSyncGateChanged(false)` ->
//  `.retryStart`); this suite pins the new STOP half: on the genuine false->true edge, Root
//  stops the running sync — through the same `stopSyncBeforeMigrationBroadcast()` every
//  broadcast path uses, so the shared resume flag is set only when something actually stopped —
//  and only for runs whose broadcasts ride ticks (`.privateScheduled`, manual delivery off).
//  Silence follows, the send window expires, the tick lane broadcasts.
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
// flag per test, the same shared key the other Root gate suites serialize over.
@Suite(.serialized) @MainActor struct RootMigrationGateStopOnBlockTests {
    /// Builds a `Root` `TestStore` for driving `.migrationSyncGateChanged` directly. `stopCalls`
    /// counts `sdkSynchronizer.stop()` — `stopSyncBeforeMigrationBroadcast()` is an extension
    /// composed of the client's own `isSyncing()` + `stop()` closures, so spying `stop` observes
    /// the real production path, guard included.
    private func makeStore(
        stopCalls: LockIsolated<Int>,
        isSyncing: Bool,
        mode: MigrationMode?,
        isManualDelivery: Bool,
        lastMigrationSyncGateBlocked: Bool = false
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

        let store = TestStore(
            initialState: initialState
        ) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate

            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationMode = { _ in mode }
            $0.migrationManager.isManualDelivery = { _ in isManualDelivery }

            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                latestState: { SynchronizerState.zero },
                stop: {
                    stopCalls.withValue { $0 += 1 }
                },
                isSyncing: { isSyncing }
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

    /// THE requirement: the genuine false->true edge stops a running sync for a
    /// `.privateScheduled`, non-manual run — and through the shared-flag-setting production
    /// path, so the existing false-edge resume machinery will restart sync later.
    @Test func blockedEdgeStopsARunningSyncForAPrivateScheduledRun() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(stopCalls: stopCalls, isSyncing: true, mode: MigrationMode.privateScheduled, isManualDelivery: false)

        await store.send(.migrationSyncGateChanged(true))
        await store.finish()

        #expect(stopCalls.value == 1, "the blocked edge must stop the running sync exactly once")
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        #expect(migrationStoppedSyncForBroadcast == true, "the stop must go through stopSyncBeforeMigrationBroadcast, arming the resume half")
    }

    /// An `.immediate` run's broadcasts ride the open lanes, never ticks — stopping its sync
    /// would strand it, not help it.
    @Test func immediateModeRunKeepsItsSyncRunning() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(stopCalls: stopCalls, isSyncing: true, mode: MigrationMode.immediate, isManualDelivery: false)

        await store.send(.migrationSyncGateChanged(true))
        await store.finish()

        #expect(stopCalls.value == 0, "an immediate-mode run must keep today's behavior — no stop")
    }

    /// A manual-delivery run broadcasts by hand (the Send-now lane does its own stop) — the
    /// automatic stop must leave its sync alone.
    @Test func manualDeliveryRunKeepsItsSyncRunning() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(stopCalls: stopCalls, isSyncing: true, mode: MigrationMode.privateScheduled, isManualDelivery: true)

        await store.send(.migrationSyncGateChanged(true))
        await store.finish()

        #expect(stopCalls.value == 0, "a manual-delivery run must keep today's behavior — no stop")
    }

    /// The handler's existing dedupe scopes the stop to the TRANSITION: a repeated `true`
    /// emission (the stream re-evaluates every 15 s) must not stop again.
    @Test func repeatedBlockedEmissionsStopOnlyOnce() async {
        resetSharedResumeFlag()
        let stopCalls = LockIsolated(0)
        let store = makeStore(stopCalls: stopCalls, isSyncing: true, mode: MigrationMode.privateScheduled, isManualDelivery: false)

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
            isSyncing: true,
            mode: MigrationMode.privateScheduled,
            isManualDelivery: false,
            lastMigrationSyncGateBlocked: true
        )

        await store.send(.migrationSyncGateChanged(false))
        await store.finish()

        #expect(stopCalls.value == 0, "the clearing edge belongs to the resume half — no stop")
    }
}
