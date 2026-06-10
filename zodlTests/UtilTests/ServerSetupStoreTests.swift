import Testing
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@MainActor
@Suite struct ServerSetupStoreTests {
    private final class Prefs: @unchecked Sendable {
        var automatic: Bool?
        var server: UserPreferencesStorage.ServerConfig?
    }

    @Test func manualSaveSwitchesPersistsAndFlagsManual() async {
        let prefs = Prefs()
        let switched = LockIsolated<LightWalletEndpoint?>(nil)

        var initial = ServerSetup.State()
        initial.connectionMode = .manual
        initial.initialConnectionMode = .automatic // a real change so hasChanges is true
        initial.selectedServer = "na.zec.rocks:443"
        initial.network = .mainnet

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.endpoint = {
                LightWalletEndpoint(address: "zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            }
            $0.sdkSynchronizer.switchToEndpoint = { switched.setValue($0) }
            $0.userStoredPreferences.setAutomaticServerSelection = { prefs.automatic = $0 }
            $0.userStoredPreferences.setServer = { prefs.server = $0 }
            $0.transactionGuard = .testValue
        }
        store.exhaustivity = .off

        await store.send(.setServerTapped)
        await store.receive(\.switchSucceeded)

        #expect(switched.value?.host == "na.zec.rocks")
        #expect(prefs.automatic == false)
        #expect(prefs.server?.host == "na.zec.rocks")
        #expect(prefs.server?.isCustom == false)
    }

    @Test func automaticSaveFlagsAutomatic() async {
        let prefs = Prefs()

        var initial = ServerSetup.State()
        initial.connectionMode = .automatic
        initial.initialConnectionMode = .manual // a real change
        initial.topKServers = [ZcashSDKEnvironment.Server.hardcoded("na.zec.rocks:443")]   // recommendedSyncServer derives from topKServers.first
        initial.network = .mainnet

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.endpoint = {
                LightWalletEndpoint(address: "zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            }
            $0.sdkSynchronizer.switchToEndpoint = { _ in }
            $0.sdkSynchronizer.evaluateBestOf = { _, _, _, _, _ in [] }
            $0.userStoredPreferences.setAutomaticServerSelection = { prefs.automatic = $0 }
            $0.userStoredPreferences.setServer = { prefs.server = $0 }
            $0.transactionGuard = .testValue
        }
        store.exhaustivity = .off

        await store.send(.setServerTapped)
        await store.receive(\.switchSucceeded)

        #expect(prefs.automatic == true)
        #expect(prefs.server?.host == "na.zec.rocks")
    }

    @Test func noChangesDoesNothing() async {
        let store = TestStore(initialState: ServerSetup.State()) {
            ServerSetup()
        } withDependencies: {
            $0.transactionGuard = .testValue
        }
        // connectionMode == initialConnectionMode and no selection -> hasChanges is false
        await store.send(.setServerTapped)
    }

    @Test func onAppearClearsStuckUpdatingFlag() async {
        var initial = ServerSetup.State()
        initial.isUpdatingServer = true   // a previous switch that hung or was cancelled left this set
        initial.network = .mainnet
        initial.topKServers = [.default]  // non-empty so onAppear doesn't kick off an evaluation

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.serverConfig = {
                UserPreferencesStorage.ServerConfig(host: "zec.rocks", port: 443, isCustom: false)
            }
            $0.userStoredPreferences.automaticServerSelection = { true }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)

        #expect(!store.state.isUpdatingServer, "onAppear must clear a stuck isUpdatingServer flag so the screen isn't wedged")
    }

    @Test func switchingToAutomaticBenchmarksWhenNoFreshResultAndOffersFastest() async {
        var initial = ServerSetup.State()
        initial.connectionMode = .manual
        initial.activeSyncServer = "na.zec.rocks:443" // current server, offered as a placeholder
        initial.network = .mainnet
        // topKServers empty -> switching to Automatic must benchmark

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.sdkSynchronizer.evaluateBestOf = { _, _, _, _, _ in
                [LightWalletEndpoint(address: "eu.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)]
            }
            $0.transactionGuard = .testValue
        }
        store.exhaustivity = .off

        // Before benchmarking, Automatic offers the current server as a placeholder.
        #expect(store.state.automaticDisplayServer == "na.zec.rocks:443")

        await store.send(.connectionModeChanged(.automatic))
        await store.receive(\.evaluateServers)
        await store.receive(\.evaluatedServers)

        // After benchmarking, Automatic offers the fastest server.
        #expect(store.state.recommendedSyncServer == "eu.zec.rocks:443")
        #expect(store.state.automaticDisplayServer == "eu.zec.rocks:443")
    }

    @Test func switchingToAutomaticReusesFreshBenchmark() async {
        let benchmarked = LockIsolated(false)

        var initial = ServerSetup.State()
        initial.connectionMode = .manual
        initial.activeSyncServer = "na.zec.rocks:443"
        initial.topKServers = [.hardcoded("eu.zec.rocks:443")] // a fresh result already exists
        initial.network = .mainnet

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.sdkSynchronizer.evaluateBestOf = { _, _, _, _, _ in
                benchmarked.setValue(true)
                return []
            }
            $0.transactionGuard = .testValue
        }
        store.exhaustivity = .off

        await store.send(.connectionModeChanged(.automatic))

        // No benchmark runs; Automatic immediately offers the existing fastest server.
        #expect(!benchmarked.value, "must not re-benchmark when a fresh result already exists")
        #expect(store.state.connectionMode == .automatic)
        #expect(store.state.automaticDisplayServer == "eu.zec.rocks:443")
    }
}
