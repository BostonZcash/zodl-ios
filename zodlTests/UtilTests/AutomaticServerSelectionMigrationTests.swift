import Testing
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct AutomaticServerSelectionMigrationTests {
    /// In-memory stand-in for the parts of `userStoredPreferences` the migration touches.
    private final class Box: @unchecked Sendable {
        var server: UserPreferencesStorage.ServerConfig?
        var flag: Bool?
        init(server: UserPreferencesStorage.ServerConfig?) { self.server = server }
    }

    private func runMigration(network: NetworkType, server: UserPreferencesStorage.ServerConfig?) -> Bool? {
        let box = Box(server: server)
        withDependencies {
            $0.userStoredPreferences.server = { box.server }
            $0.userStoredPreferences.automaticServerSelection = { box.flag }
            $0.userStoredPreferences.setAutomaticServerSelection = { box.flag = $0 }
        } operation: {
            ZcashSDKEnvironment.initializeAutomaticServerSelectionIfNeeded(for: network)
        }
        return box.flag
    }

    @Test func noStoredServerEnablesAutomatic() {
        #expect(runMigration(network: .mainnet, server: nil) == true)
    }

    @Test func defaultServerEnablesAutomatic() {
        let def = ZcashSDKEnvironment.defaultEndpoint(for: .mainnet)
        let config = UserPreferencesStorage.ServerConfig(host: def.host, port: def.port, isCustom: false)
        #expect(runMigration(network: .mainnet, server: config) == true)
    }

    @Test func customServerSelectsManual() {
        let config = UserPreferencesStorage.ServerConfig(host: "my.server.example", port: 9067, isCustom: true)
        #expect(runMigration(network: .mainnet, server: config) == false)
    }

    @Test func nonDefaultKnownServerSelectsManual() {
        let config = UserPreferencesStorage.ServerConfig(host: "na.zec.rocks", port: 443, isCustom: false)
        #expect(runMigration(network: .mainnet, server: config) == false)
    }

    @Test func runsOnlyOnce() {
        let box = Box(server: nil)
        box.flag = false // pretend the user already chose Manual
        withDependencies {
            $0.userStoredPreferences.server = { box.server }
            $0.userStoredPreferences.automaticServerSelection = { box.flag }
            $0.userStoredPreferences.setAutomaticServerSelection = { box.flag = $0 }
        } operation: {
            ZcashSDKEnvironment.initializeAutomaticServerSelectionIfNeeded(for: .mainnet)
        }
        #expect(box.flag == false, "Migration must not overwrite an already-set flag")
    }
}
