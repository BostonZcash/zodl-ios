//
//  ZcashSDKEnvironmentActivationHeightTests.swift
//  zodlTests
//
//  Covers `ZcashSDKEnvironment.ironwoodActivationHeight` — the NU6.3 ("Ironwood") activation height
//  per network (Dependencies/ZcashSDKEnvironment/ZcashSDKEnvironment{Interface,LiveKey,TestKey}.swift).
//

import Testing
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct ZcashSDKEnvironmentActivationHeightTests {
    @Test func mainnetReturnsHandMirroredActivationHeight() {
        let environment = ZcashSDKEnvironment.live(network: ZcashNetworkBuilder.network(for: .mainnet))
        #expect(environment.ironwoodActivationHeight() == 3_428_143)
    }

    @Test func testnetReturnsHandMirroredActivationHeight() {
        let environment = ZcashSDKEnvironment.live(network: ZcashNetworkBuilder.network(for: .testnet))
        #expect(environment.ironwoodActivationHeight() == 4_134_000)
    }

    @Test func regtestWithExplicitNU63ReturnsConfiguredHeight() {
        let network = ZcashNetworkBuilder.regtest(activationHeights: NetworkActivationHeights(nu6_3: 1_234))
        let environment = ZcashSDKEnvironment.live(network: network)
        #expect(environment.ironwoodActivationHeight() == 1_234)
    }

    @Test func regtestWithoutNU63ReturnsBlockHeightMax() {
        let network = ZcashNetworkBuilder.regtest(activationHeights: NetworkActivationHeights())
        let environment = ZcashSDKEnvironment.live(network: network)
        #expect(environment.ironwoodActivationHeight() == BlockHeight.max)
    }

    @Test func dependencyClientMemberwiseDefaultIsBlockHeightMax() {
        let environment = ZcashSDKEnvironment()
        #expect(environment.ironwoodActivationHeight() == BlockHeight.max)
    }
}
