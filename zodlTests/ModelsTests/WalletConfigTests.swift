//
//  WalletConfigTests.swift
//  zodlTests
//
//  Batch 2 — config. Covers WalletConfig / FeatureFlag (Models/WalletConfig.swift).
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct WalletConfigTests {
    @Test func isEnabledReturnsFlagValueAndDefaultsToFalse() {
        let config = WalletConfig(flags: [.showFiatConversion: true])
        #expect(config.isEnabled(.showFiatConversion))
        #expect(!config.isEnabled(.onboardingFlow)) // absent -> default false
    }

    @Test func allFeatureFlagsDisabledByDefault() {
        for flag in FeatureFlag.allCases {
            #expect(!flag.enabledByDefault)
        }
    }

    @Test func initialExcludesTestFlagsAndDisablesEverything() {
        let initial = WalletConfig.initial
        #expect(initial.flags[.testFlag1] == nil)
        #expect(initial.flags[.testFlag2] == nil)
        #expect(initial.flags.count == FeatureFlag.allCases.count - 2)
        #expect(!initial.isEnabled(.showFiatConversion))
        #expect(!initial.isEnabled(.onboardingFlow))
    }

    @Test func featureFlagCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(FeatureFlag.showFiatConversion)
        #expect(try JSONDecoder().decode(FeatureFlag.self, from: data) == .showFiatConversion)
    }
}
