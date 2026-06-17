//
//  ClampedTests.swift
//  zodlTests
//
//  Batch 1 — pure logic. Covers the @Clamped property wrapper (Utils/Clamped.swift).
//

import Testing
@testable import zodl_internal

@Suite struct ClampedTests {
    private struct InRangeBox {
        @Clamped(0...10) var value: Int = 5
    }

    private struct AboveRangeBox {
        @Clamped(0...10) var value: Int = 20
    }

    private struct BelowRangeBox {
        @Clamped(0...10) var value: Int = -5
    }

    // Initialiser clamping works correctly (clamp() reads the freshly-stored value).
    @Test func initialValueWithinRangeIsKept() {
        #expect(InRangeBox().value == 5)
    }

    @Test func initialValueAboveRangeIsClampedToUpper() {
        #expect(AboveRangeBox().value == 10)
    }

    @Test func initialValueBelowRangeIsClampedToLower() {
        #expect(BelowRangeBox().value == 0)
    }

    // See docs/testing/coverage-uplift-plan.md §6.6.
    // The setter's clamp() reads the *current stored* value instead of the incoming one,
    // so assignments never take effect. These intended-behaviour assertions are recorded
    // as known issues until the wrapper is fixed.
    @Test func assigningInRangeValueShouldUpdateIt() {
        withKnownIssue("Bug coverage-uplift-plan.md §6.6: Clamped setter ignores the new value") {
            var box = InRangeBox()
            box.value = 8
            #expect(box.value == 8)
        }
    }

    @Test func assigningAboveRangeShouldClampToUpper() {
        withKnownIssue("Bug coverage-uplift-plan.md §6.6: Clamped setter ignores the new value") {
            var box = InRangeBox()
            box.value = 20
            #expect(box.value == 10)
        }
    }

    @Test func assigningBelowRangeShouldClampToLower() {
        withKnownIssue("Bug coverage-uplift-plan.md §6.6: Clamped setter ignores the new value") {
            var box = InRangeBox()
            box.value = -5
            #expect(box.value == 0)
        }
    }
}
