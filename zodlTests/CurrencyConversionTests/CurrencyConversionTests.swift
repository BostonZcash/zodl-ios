//
//  CurrencyConversionTests.swift
//  secantTests
//
//  Created by Cosmos on 18.05.2026.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct CurrencyConversionTests {
    @Test func initRoundsRatioToSixDecimals() {
        let conversion = CurrencyConversion(.usd, ratio: 1.123456789, timestamp: 0)

        #expect(
            abs(conversion.ratio - 1.123456) <= 0.0000001,
            "CurrencyConversion tests: `testInitRoundsRatioToSixDecimals` ratio is expected to be 1.123456 but it is \(conversion.ratio)"
        )
    }

    @Test func initPreservesExactRatioWithinPrecision() {
        let conversion = CurrencyConversion(.usd, ratio: 50.5, timestamp: 0)

        #expect(
            abs(conversion.ratio - 50.5) <= 0.0000001,
            "CurrencyConversion tests: `testInitPreservesExactRatioWithinPrecision` ratio is expected to be 50.5 but it is \(conversion.ratio)"
        )
    }

    @Test func initPreservesTimestamp() {
        let timestamp: TimeInterval = 1700000000
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: timestamp)

        #expect(
            conversion.timestamp == timestamp,
            "CurrencyConversion tests: `testInitPreservesTimestamp` timestamp is expected to be \(timestamp) but it is \(conversion.timestamp)"
        )
    }

    @Test func initPreservesISO4217() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)

        #expect(
            conversion.iso4217 == .usd,
            "CurrencyConversion tests: `testInitPreservesISO4217` iso4217 is expected to be .usd but it is \(conversion.iso4217)"
        )
    }

    @Test(arguments: zatoshiToDoubleCases)
    func convertZatoshiToDouble(_ testCase: ZatoshiToDoubleCase) {
        let conversion = CurrencyConversion(.usd, ratio: testCase.ratio, timestamp: 0)

        let result: Double = conversion.convert(Zatoshi(testCase.zatoshi))

        #expect(
            abs(result - testCase.expected) <= testCase.accuracy,
            "CurrencyConversion tests: convert(\(testCase.zatoshi) zatoshi @ ratio \(testCase.ratio)) is expected to be \(testCase.expected) but it is \(result)"
        )
    }

    @Test func convertZatoshiToStringFormatsAsCurrency() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)
        let oneZEC = Zatoshi(100_000_000)

        let result: String = conversion.convert(oneZEC)

        #expect(
            !result.isEmpty,
            "CurrencyConversion tests: `testConvertZatoshiToStringFormatsAsCurrency` is expected to produce a non-empty string"
        )
        #expect(
            result.contains("30") || result.contains("30.00"),
            "CurrencyConversion tests: `testConvertZatoshiToStringFormatsAsCurrency` is expected to contain the converted amount but it is \(result)"
        )
    }

    @Test func convertZatoshiToStringZeroAmount() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)
        let zero = Zatoshi(0)

        let result: String = conversion.convert(zero)

        #expect(
            !result.isEmpty,
            "CurrencyConversion tests: `testConvertZatoshiToStringZeroAmount` is expected to produce a non-empty string"
        )
    }

    @Test(arguments: doubleToZatoshiCases)
    func convertCurrencyToZatoshi(_ testCase: DoubleToZatoshiCase) {
        let conversion = CurrencyConversion(.usd, ratio: testCase.ratio, timestamp: 0)

        let result = conversion.convert(testCase.dollars)

        #expect(
            result.amount == testCase.expectedAmount,
            "CurrencyConversion tests: convert($\(testCase.dollars) @ ratio \(testCase.ratio)) amount is expected to be \(testCase.expectedAmount) but it is \(result.amount)"
        )
    }

    @Test func roundTripZatoshiToFiatAndBack() {
        let conversion = CurrencyConversion(.usd, ratio: 45.67, timestamp: 0)
        let original = Zatoshi(123_456_789)

        let fiatValue: Double = conversion.convert(original)
        let backToZatoshi = conversion.convert(fiatValue)

        let diff = abs(original.amount - backToZatoshi.amount)
        #expect(
            diff < 100,
            "CurrencyConversion tests: `testRoundTripZatoshiToFiatAndBack` round-trip is expected to be within 100 zatoshi but diff is \(diff)"
        )
    }

    @Test func currencyISO4217UsdCode() {
        #expect(
            CurrencyISO4217.usd.code == "USD",
            "CurrencyConversion tests: `testCurrencyISO4217UsdCode` code is expected to be USD but it is \(CurrencyISO4217.usd.code)"
        )
    }

    @Test func currencyISO4217UsdSymbol() {
        #expect(
            CurrencyISO4217.usd.symbol == "$",
            "CurrencyConversion tests: `testCurrencyISO4217UsdSymbol` symbol is expected to be $ but it is \(CurrencyISO4217.usd.symbol)"
        )
    }

    @Test func currencyISO4217AllCases() {
        #expect(
            CurrencyISO4217.allCases.count == 1,
            "CurrencyConversion tests: `testCurrencyISO4217AllCases` count is expected to be 1 but it is \(CurrencyISO4217.allCases.count)"
        )
        #expect(
            CurrencyISO4217.allCases.contains(.usd),
            "CurrencyConversion tests: `testCurrencyISO4217AllCases` is expected to contain .usd"
        )
    }

    @Test func equatableSameValuesAreEqual() {
        let a = CurrencyConversion(.usd, ratio: 30.0, timestamp: 1000)
        let b = CurrencyConversion(.usd, ratio: 30.0, timestamp: 1000)

        #expect(
            a == b,
            "CurrencyConversion tests: `testEquatableSameValuesAreEqual` conversions with same values are expected to be equal"
        )
    }

    @Test func equatableDifferentRatioAreNotEqual() {
        let a = CurrencyConversion(.usd, ratio: 30.0, timestamp: 1000)
        let b = CurrencyConversion(.usd, ratio: 31.0, timestamp: 1000)

        #expect(
            a != b,
            "CurrencyConversion tests: `testEquatableDifferentRatioAreNotEqual` conversions with different ratios are expected to not be equal"
        )
    }

    @Test func equatableDifferentTimestampAreNotEqual() {
        let a = CurrencyConversion(.usd, ratio: 30.0, timestamp: 1000)
        let b = CurrencyConversion(.usd, ratio: 30.0, timestamp: 2000)

        #expect(
            a != b,
            "CurrencyConversion tests: `testEquatableDifferentTimestampAreNotEqual` conversions with different timestamps are expected to not be equal"
        )
    }
}

// Homogeneous convert(Zatoshi) -> Double cases (each row was its own `testConvert*` method).
struct ZatoshiToDoubleCase: Sendable {
    let ratio: Double
    let zatoshi: Int64
    let expected: Double
    let accuracy: Double
}

private let zatoshiToDoubleCases: [ZatoshiToDoubleCase] = [
    ZatoshiToDoubleCase(ratio: 30.0, zatoshi: 100_000_000, expected: 30.0, accuracy: 0.01),
    ZatoshiToDoubleCase(ratio: 100.0, zatoshi: 50_000_000, expected: 50.0, accuracy: 0.01),
    ZatoshiToDoubleCase(ratio: 30.0, zatoshi: 0, expected: 0.0, accuracy: 0.0001),
    ZatoshiToDoubleCase(ratio: 30.0, zatoshi: 1, expected: 0.0000003, accuracy: 0.00000001),
    ZatoshiToDoubleCase(ratio: 30.0, zatoshi: 10_000 * 100_000_000, expected: 300_000.0, accuracy: 0.01),
    ZatoshiToDoubleCase(ratio: 999999.0, zatoshi: 100_000_000, expected: 999999.0, accuracy: 1.0),
    ZatoshiToDoubleCase(ratio: 0.001, zatoshi: 100_000_000, expected: 0.001, accuracy: 0.0001),
    ZatoshiToDoubleCase(ratio: 30.0, zatoshi: -100_000_000, expected: -30.0, accuracy: 0.01)
]

// Homogeneous convert(Double) -> Zatoshi cases (each row was its own `testConvertCurrencyToZatoshi*` method).
struct DoubleToZatoshiCase: Sendable {
    let ratio: Double
    let dollars: Double
    let expectedAmount: Int64
}

private let doubleToZatoshiCases: [DoubleToZatoshiCase] = [
    DoubleToZatoshiCase(ratio: 30.0, dollars: 30.0, expectedAmount: 100_000_000),
    DoubleToZatoshiCase(ratio: 30.0, dollars: 15.0, expectedAmount: 50_000_000),
    DoubleToZatoshiCase(ratio: 30.0, dollars: 0.0, expectedAmount: 0),
    DoubleToZatoshiCase(ratio: 30.0, dollars: 0.01, expectedAmount: 33333),
    DoubleToZatoshiCase(ratio: 30.0, dollars: 3000.0, expectedAmount: 10_000_000_000)
]
