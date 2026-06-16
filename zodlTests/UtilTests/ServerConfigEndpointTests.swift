//
//  ServerConfigEndpointTests.swift
//  zodlTests
//
//  Covers UserPreferencesStorage.ServerConfig.endpoint(for:) parsing
//  (Dependencies/UserPreferencesStorage/UserPreferencesStorage.swift).
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct ServerConfigEndpointTests {
    @Test func parsesHostAndPort() {
        let result = endpoint("host.example.com:443")
        #expect(result?.host == "host.example.com")
        #expect(result?.port == 443)
    }

    @Test func stripsHttpsScheme() {
        let result = endpoint("https://host.example.com:9067")
        #expect(result?.host == "host.example.com")
        #expect(result?.port == 9067)
    }

    @Test func stripsHttpScheme() {
        let result = endpoint("http://host:8080")
        #expect(result?.host == "host")
        #expect(result?.port == 8080)
    }

    @Test func returnsNilWithoutPort() {
        #expect(endpoint("hostonly") == nil)
        #expect(endpoint("host.example.com") == nil)
    }

    @Test func threeComponentHostKeepsSeparator() {
        let result = endpoint("a:b:443")
        #expect(result?.host == "a:b")
        #expect(result?.port == 443)
    }

    private func endpoint(_ string: String) -> LightWalletEndpoint? {
        UserPreferencesStorage.ServerConfig.endpoint(for: string, streamingCallTimeoutInMillis: 0)
    }
}
