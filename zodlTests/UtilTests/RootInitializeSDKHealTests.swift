//
//  RootInitializeSDKHealTests.swift
//  zodlTests
//
//  TCA TestStore integration tests for the wallet-database heal WIRING inside
//  Root.initializationReduce()'s `.initialization(.initializeSDK)` case
//  (Features/Root/RootInitialization.swift) and the shared clears helper
//  (Root.clearDeviceScopedWalletState in Features/Root/RootStore.swift). The pure
//  reconciliation algorithm itself is covered by WalletDatabaseSeedReconcileTests;
//  this suite drives the REDUCER wiring around it through a real TestStore.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `Root.State` has no `Equatable` conformance in the app, and several of the nested
// feature/CoordFlow states it embeds (RestoreWalletCoordFlow.State, SendCoordFlow.State,
// TransactionsCoordFlow.State, …) aren't `Equatable` either — a synthesized conformance is not
// possible. `TestStore<State: Equatable, Action>` requires one regardless, so this test-scoped
// conformance compares only the handful of fields this suite's assertions actually touch
// (restore/heal flags and the presented alert's rendered content). It intentionally treats
// every other field as equal, so it must never be relied on outside this file, and it lives
// here — not in app sources — precisely so nothing in the shipping app could ever pick it up
// (e.g. an `@ObservableState`/SwiftUI diffing path silently short-circuiting on an untouched
// field).
extension Root.State: @retroactive Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isRestoringWallet == rhs.isRestoringWallet
            && lhs.walletStatus == rhs.walletStatus
            && lhs.appInitializationState == rhs.appInitializationState
            && lhs.alert?.title == rhs.alert?.title
            && lhs.alert?.message == rhs.alert?.message
    }
}

// Healing a stale wallet database calls through to `Root.clearDeviceScopedWalletState`, which
// (by design, see its doc comment in RootStore.swift) reaches past dependency injection into
// `UserDefaults.standard` and the app's Documents directory for a belt-and-suspenders cleanup.
// That is real, process-global state, so this suite is serialized per repo convention rather
// than relying solely on per-test dependency isolation.
@Suite(.serialized) @MainActor struct RootInitializeSDKHealTests {
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

    /// Builds a `Root` `TestStore` wired for the `.initializeSDK` heal path. Every dependency the
    /// effect can reach is either a recorded fake (via `calls` / `removedUserDefaultsKeys` /
    /// `setUserDefaultsBools`) or a benign no-op, so the whole effect — including the
    /// `.initializationSuccessfullyDone` fan-out (SmartBanner priority evaluation, contacts,
    /// user metadata, the battery-state subscription, …) — runs to completion without ever
    /// touching an unimplemented dependency closure.
    private func makeStore(
        calls: LockIsolated<[String]>,
        removedUserDefaultsKeys: LockIsolated<[String]>,
        setUserDefaultsBools: LockIsolated<[String: Bool]>,
        firstPrepareResult: Initializer.InitializationResult,
        isSeedRelevant: Bool,
        walletAccountsResult: [WalletAccount] = [RootInitializeSDKHealTests.seedDerivedAccount]
    ) -> TestStore<Root.State, Root.Action> {
        let store = TestStore(
            initialState: Root.State(
                destinationState: Root.DestinationState(),
                exportLogsState: ExportLogs.State(),
                onboardingState: RestoreWalletCoordFlow.State(),
                phraseDisplayState: RecoveryPhraseDisplay.State(),
                walletConfig: .initial,
                welcomeState: Welcome.State()
            )
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

            let seededWallet = RootInitializeSDKHealTests.seededWallet
            $0.walletStorage = .noOp
            $0.walletStorage.exportWallet = { seededWallet }

            $0.flexaHandler = .noOp
            $0.flexaHandler.signOut = { calls.withValue { $0.append("flexaSignOut") } }

            $0.userStoredPreferences.removeAll = { calls.withValue { $0.append("userPrefsRemoveAll") } }

            $0.readTransactionsStorage = .noOp

            $0.userDefaults.objectForKey = { key in setUserDefaultsBools.value[key] }
            $0.userDefaults.remove = { key in removedUserDefaultsKeys.withValue { $0.append(key) } }
            $0.userDefaults.setValue = { value, key in
                guard let boolValue = value as? Bool else { return }
                setUserDefaultsBools.withValue { $0[key] = boolValue }
            }

            $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }

            $0.userMetadataProvider.load = { _ in }

            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                prepareWith: { _, _, walletMode, _, _ in
                    let modeLabel: String
                    switch walletMode {
                    case .newWallet: modeLabel = "newWallet"
                    case .restoreWallet: modeLabel = "restoreWallet"
                    case .existingWallet: modeLabel = "existingWallet"
                    }
                    calls.withValue { $0.append("prepareWith(\(modeLabel))") }
                    return walletMode == .restoreWallet ? .success : firstPrepareResult
                },
                getAllTransactions: { _ in [] },
                wipe: {
                    calls.withValue { $0.append("wipe") }
                    return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher()
                },
                isSeedRelevantToAnyDerivedAccount: { _ in
                    calls.withValue { $0.append("isSeedRelevant") }
                    return isSeedRelevant
                },
                walletAccounts: {
                    calls.withValue { $0.append("walletAccounts") }
                    return walletAccountsResult
                }
            )
        }
        store.exhaustivity = .off
        return store
    }

    /// Lets the rest of the `.initializeSDK` cascade (SmartBanner evaluation, contacts, user
    /// metadata, the battery-state subscription spun up by `.initializationSuccessfullyDone`, …)
    /// settle without asserting on any of it. `.cancelAllRunningEffects` is a best-effort
    /// cancellation — the battery subscription is spun up by `.initializationSuccessfullyDone`,
    /// which the still-running `.initializeSDK` effect may not have reached yet, so it can race
    /// this call and outlive it — so the `skip` calls unconditionally silence the test store's
    /// own bookkeeping afterward rather than waiting on `finish()`, which would otherwise just
    /// burn its full timeout on that never-completing subscription every time.
    private func drain(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.cancelAllRunningEffects)
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    // MARK: - Scenario 1: probe-false heal

    @Test func probeFalseHealWipesAndRepreparesInOrderThenSignalsRestore() async throws {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .success,
            isSeedRelevant: false
        )

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.staleWalletDatabaseHealed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isRestoringWallet = true
            state.$walletStatus.withLock { $0 = .restoring }
            state.alert = AlertState.staleWalletDatabaseHealed()
        }

        let recordedCalls = calls.value
        let wipeIndex = try #require(recordedCalls.firstIndex(of: "wipe"))
        let reprepareIndex = try #require(recordedCalls.firstIndex(of: "prepareWith(restoreWallet)"))
        #expect(wipeIndex < reprepareIndex, "the stale database must be wiped before it is re-prepared")

        #expect(setBools.value[Root.Constants.udIsRestoringWallet] == true)
        #expect(store.state.isRestoringWallet)
        #expect(store.state.walletStatus == .restoring)

        await drain(store)
    }

    // MARK: - Scenario 2: .seedNotRelevant heal guards F1

    @Test func seedNotRelevantHealsWithoutProbingRelevanceOrDerivation() async throws {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .seedNotRelevant,
            // If the F1 guard regresses and this gets consulted despite the database already
            // being known stale, answering "yes, relevant" makes reconcile bail out with no
            // heal — so a regression fails this test instead of coincidentally passing it.
            isSeedRelevant: true
        )

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.staleWalletDatabaseHealed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isRestoringWallet = true
            state.$walletStatus.withLock { $0 = .restoring }
            state.alert = AlertState.staleWalletDatabaseHealed()
        }

        let recordedCalls = calls.value
        let wipeIndex = try #require(recordedCalls.firstIndex(of: "wipe"))
        #expect(
            !recordedCalls[..<wipeIndex].contains("isSeedRelevant"),
            "a database already known stale (.seedNotRelevant) must not be probed for relevance"
        )
        #expect(
            !recordedCalls[..<wipeIndex].contains("walletAccounts"),
            "a database already known stale (.seedNotRelevant) must not be probed for a derived account"
        )

        await drain(store)
    }

    // MARK: - Scenario 3: no-op when the seed is already relevant

    @Test func relevantSeedSkipsHealAndLeavesNoAlert() async {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .success,
            isSeedRelevant: true
        )

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.initializationSuccessfullyDone) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(!calls.value.contains("wipe"), "no heal must occur when the seed is already relevant")
        #expect(store.state.alert == nil, "no heal alert should be shown")
        #expect(!store.state.isRestoringWallet)

        await drain(store)
    }

    // MARK: - Scenario 4: device-scoped state is cleared before the wipe (F2)

    @Test func clearsDeviceScopedStateBeforeWipingOnHeal() async throws {
        let calls = LockIsolated<[String]>([])
        let removedKeys = LockIsolated<[String]>([])
        let setBools = LockIsolated<[String: Bool]>([:])
        let store = makeStore(
            calls: calls,
            removedUserDefaultsKeys: removedKeys,
            setUserDefaultsBools: setBools,
            firstPrepareResult: .success,
            isSeedRelevant: false
        )

        await store.send(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(
            { action in
                guard case .initialization(.staleWalletDatabaseHealed) = action else { return false }
                return true
            },
            timeout: .seconds(5)
        ) { state in
            state.isRestoringWallet = true
            state.$walletStatus.withLock { $0 = .restoring }
            state.alert = AlertState.staleWalletDatabaseHealed()
        }

        let recordedCalls = calls.value
        let signOutIndex = try #require(recordedCalls.firstIndex(of: "flexaSignOut"))
        let userPrefsIndex = try #require(recordedCalls.firstIndex(of: "userPrefsRemoveAll"))
        let wipeIndex = try #require(recordedCalls.firstIndex(of: "wipe"))
        #expect(signOutIndex < wipeIndex, "the Flexa session must be cleared before the database is wiped")
        #expect(userPrefsIndex < wipeIndex, "cached preferences must be cleared before the database is wiped")

        #expect(
            removedKeys.value.contains(.votingConfigOverrideURL),
            "the voting chain override must be cleared before healing a stale database"
        )

        await drain(store)
    }
}
