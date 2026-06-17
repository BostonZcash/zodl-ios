//
//  ServerConfigEndpointTests.swift
//  zodlTests
//
//  Batch 4 — dependency logic. Covers UserPreferencesStorage.ServerConfig.endpoint(for:) parsing
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

    // See docs/testing/coverage-uplift-plan.md §6.3.
    // Intended: a 3-component "a:b:443" should keep the ':' between the first two segments.
    // Current impl concatenates them ("ab"), so the intended assertion is a known issue.
    @Test func threeComponentHostKeepsSeparator() {
        withKnownIssue("Bug coverage-uplift-plan.md §6.3: endpoint(for:) drops the ':' separator for 3-component hosts") {
            #expect(endpoint("a:b:443")?.host == "a:b")
        }
    }

    private func endpoint(_ string: String) -> LightWalletEndpoint? {
        UserPreferencesStorage.ServerConfig.endpoint(for: string, streamingCallTimeoutInMillis: 0)
    }
}
