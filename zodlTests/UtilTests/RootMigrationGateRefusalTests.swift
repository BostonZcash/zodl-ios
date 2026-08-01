//
//  RootMigrationGateRefusalTests.swift
//  zodlTests
//
//  MOB-1466 (B2, P0): TCA TestStore coverage for the sync gate's start() refusal handling in
//  Root.initializationReduce()'s `.initialization(.initializeSDK)` and `.initialization(.retryStart)`
//  cases (Features/Root/RootInitialization.swift).
//
//  THE BUG this pins: after a successful migration broadcast, the SDK's `start()` correctly throws
//  `ZcashError.migrationSyncBlocked` — the migration privacy gate says "this launch is a broadcast
//  session, don't sync". Before this fix, both call sites let that throw fall into their generic
//  catch (`.initializationFailed` on cold launch — a fatal alert with NO retry action — and
//  `.synchronizerStartFailed` on foreground retry, a dead end), bricking the wallet. The fix treats
//  the refusal as the send-visit signal it actually is: run the broadcast session and continue
//  exactly as a `.send`-visit would, so the existing resume machinery
//  (`.registerForSynchronizersUpdate`'s gate-stream subscription + `.migrationSyncGateChanged(false)`
//  -> `.retryStart`) picks the wallet back up once the gate reopens.
//
//  `extension Root.State: @retroactive Equatable` already exists, module-wide, at
//  RootInitializeSDKHealTests.swift. This file uses `TestStore` directly against that existing
//  conformance rather than redeclaring it — see that file's header, and
//  RootIronwoodAnnouncementGateTests.swift's header for why a second declaration would be a
//  duplicate-conformance compile error.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized per repo convention for suites driving `.initializeSDK`/`.retryStart` through a real
// TestStore — see RootInitializeSDKHealTests's identical `@Suite(.serialized)` rationale.
@Suite(.serialized) @MainActor struct RootMigrationGateRefusalTests {
    private static let seedDerivedAccount = WalletAccount(
        Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "Zashi",
            keySource: "zashi",
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        )
    )

    private static let seededWallet = StoredWallet.placeholder

    private struct OtherStartError: Error, Equatable { }

    /// Builds a `Root` `TestStore` wired for both `.initializeSDK` (cold launch) and `.retryStart`
    /// (foreground). `startError`, when non-nil, is thrown by every `sdkSynchronizer.start` call —
    /// `ZcashError.migrationSyncBlocked` exercises the gate-refusal path this suite is about;
    /// `OtherStartError` exercises the regression pin (every OTHER error must keep flowing to the
    /// existing failure handling, unchanged). `visitKind` defaults to `.sync` so the reducer takes
    /// the `sdkSynchronizer.start` branch rather than the already-covered `.send`-visit branch —
    /// the gate refusing `start()` while `visitKind()` still reads `.sync` is exactly the lagging-
    /// classifier scenario B2 fixes (see the file header). `runBroadcastSession` calls are recorded
    /// into `calls` so a test can assert the refusal was actually treated as a broadcast session.
    private func makeStore(
        calls: LockIsolated<[String]>,
        startError: Error?,
        visitKind: MigrationVisit = .sync,
        lastMigrationSyncGateBlocked: Bool = false,
        syncDeferredByMigrationGate: Bool = false
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
        initialState.syncDeferredByMigrationGate = syncDeferredByMigrationGate

        // Resolved here, in the suite's `@MainActor` context, rather than inside the `@Sendable`
        // dependency closures below — `seedDerivedAccount` is `@MainActor`-isolated (a static
        // member of this `@MainActor` suite), and a `@Sendable` closure literal cannot reach across
        // that isolation boundary to read it directly.
        let seedDerivedAccount = RootMigrationGateRefusalTests.seedDerivedAccount

        let store = TestStore(
            initialState: initialState
        ) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate

            $0.exchangeRate = .noOp
            $0.autolockHandler = .noOp
            $0.shieldingProcessor = ShieldingProcessorClient(
                observe: { Empty().eraseToAnyPublisher() },
                shieldFunds: { }
            )

            $0.mnemonic = .noOp

            $0.databaseFiles = .noOp

            let seededWallet = RootMigrationGateRefusalTests.seededWallet
            $0.walletStorage = .noOp
            $0.walletStorage.exportWallet = { seededWallet }

            $0.flexaHandler = .noOp
            $0.flexaHandler.signOut = { }

            $0.userStoredPreferences.removeAll = { }

            $0.readTransactionsStorage = .noOp

            $0.userDefaults.objectForKey = { _ in nil }
            $0.userDefaults.remove = { _ in }
            $0.userDefaults.setValue = { _, _ in }

            $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }

            $0.userMetadataProvider.load = { _ in }

            $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }

            $0.migrationManager.visitKind = { visitKind }
            $0.migrationManager.runBroadcastSession = {
                calls.withValue { $0.append("runBroadcastSession") }
                return true
            }

            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                latestState: {
                    var syncState = SynchronizerState.zero
                    syncState.syncStatus = .upToDate
                    return syncState
                },
                prepareWith: { _, _, _, _ in .success },
                start: { _ in
                    if let startError {
                        throw startError
                    }
                },
                getAllTransactions: { _ in [] },
                isSeedRelevantToAnyDerivedAccount: { _ in true },
                walletAccounts: { [seedDerivedAccount] }
            )
        }
        store.exhaustivity = .off
        return store
    }

    /// Lets the rest of the cascade past the assertion point (SmartBanner evaluation, contacts,
    /// user metadata, the battery-state subscription, the migration gate stream, …) settle without
    /// asserting on any of it — identical rationale to RootInitializeSDKHealTests's `drain`.
    private func drain(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.cancelAllRunningEffects)
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    // MARK: - Cold launch: gate refusal is treated as the broadcast-session signal, not a fatal error

    @Test func coldLaunchGateRefusalRunsBroadcastSessionInsteadOfFailingInit() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: ZcashError.migrationSyncBlocked, visitKind: .sync)

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        // Mutually exclusive with `.initializationFailed` — both are the ONLY two outcomes of the
        // same do/catch, so successfully receiving this one also proves the other was never sent.
        await store.receive(
            { action in
                guard case .initialization(.initializationSuccessfullyDone) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(calls.value.contains("runBroadcastSession"), "the refusal must be treated as a broadcast session")
        #expect(store.state.alert == nil, "a gate refusal must not surface the fatal init alert")
        #expect(store.state.appInitializationState != .failed, "a gate refusal must not mark initialization failed")

        await drain(store)
    }

    // MARK: - Cold launch: a DIFFERENT error still fails init (regression pin)

    @Test func coldLaunchOtherStartErrorStillFailsInitialization() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: OtherStartError(), visitKind: .sync)

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.initializationFailed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(!calls.value.contains("runBroadcastSession"), "a non-gate error must not be treated as a broadcast session")
        #expect(store.state.appInitializationState == .failed)
        #expect(store.state.alert != nil)

        await drain(store)
    }

    // MARK: - Resume: the gate reopening (`.migrationSyncGateChanged(false)`) triggers `.retryStart`
    //
    // This is what makes the refusal path above actually recover the wallet instead of just quietly
    // broadcasting once: `syncDeferredByMigrationGate`/`lastMigrationSyncGateBlocked` are the flags
    // a blocked start leaves behind (see their doc comments in RootStore.swift), and this is the
    // transition that reads them once the gate clears. No existing test in the suite drives
    // `.migrationSyncGateChanged` at all (verified via `grep -rl migrationSyncGateChanged
    // zodlTests/`), so this is not a duplicate of existing coverage.
    @Test func migrationSyncGateChangedToUnblockedTriggersRetryStart() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(
            calls: calls,
            startError: nil,
            visitKind: .sync,
            lastMigrationSyncGateBlocked: true,
            syncDeferredByMigrationGate: true
        )

        await store.send(.migrationSyncGateChanged(false)) { state in
            state.lastMigrationSyncGateBlocked = false
            state.syncDeferredByMigrationGate = false
        }

        await store.receive(
            { action in
                guard case .initialization(.retryStart) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        await drain(store)
    }

    // MARK: - .retryStart: gate refusal also runs the broadcast session instead of failing the retry

    @Test func retryStartGateRefusalRunsBroadcastSessionInsteadOfFailingStart() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: ZcashError.migrationSyncBlocked, visitKind: .sync)

        await store.send(.initialization(.retryStart))

        // Mutually exclusive with `.synchronizerStartFailed` — both are the ONLY two outcomes of
        // the same do/catch, so successfully receiving this one also proves the other was never
        // sent.
        await store.receive(
            { action in
                guard case .initialization(.registerForSynchronizersUpdate) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(calls.value.contains("runBroadcastSession"), "the refusal must be treated as a broadcast session")

        await drain(store)
    }

    // MARK: - .retryStart: a DIFFERENT error still routes to synchronizerStartFailed (regression pin)

    @Test func retryStartOtherErrorStillRoutesToSynchronizerStartFailed() async throws {
        let calls = LockIsolated<[String]>([])
        let store = makeStore(calls: calls, startError: OtherStartError(), visitKind: .sync)

        await store.send(.initialization(.retryStart))

        await store.receive(
            { action in
                guard case .initialization(.synchronizerStartFailed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(!calls.value.contains("runBroadcastSession"), "a non-gate error must not be treated as a broadcast session")

        await drain(store)
    }
}
