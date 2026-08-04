//
//  MigrationCacheEpochTests.swift
//  zodlTests
//
//  M5 (field, 2026-08-04): Lukas's two-worlds screen. The migration content caches were built to
//  bridge a 33-second prove sweep ("the rows cannot have changed while the work that would change
//  them is still running") — a justification that holds across one piece of in-flight work, not
//  across an absence. A suspended app carried the caches over a 90-minute gap; under an overdue
//  pile-up every open is a broadcast session, so `isMigrationWorkInFlight` was true at every read
//  and the guards resurrected the pre-gap world: the screen alternated between two
//  internally-consistent epochs — greens flipping back to neutral, the pool bubbles disagreeing
//  with themselves by exactly the crossed amount, the remaining-count off by the flips.
//
//  The fix: an epoch may only SERVE while young enough to be bridging in-flight work
//  (`MigrationRowsSnapshot.maxServableAge`, 120 s — sweeps run ≤ ~45 s, broadcasts ~7 s). These
//  tests pin the bound — if it ever softens past an absence, the two-worlds screen returns.
//

import Foundation
import Testing
@testable import zodl_internal

struct MigrationCacheEpochTests {
    private static func epoch(ageSeconds: TimeInterval, now: Date) -> MigrationRowsSnapshot {
        MigrationRowsSnapshot(
            transfers: [],
            computedAt: now.addingTimeInterval(-ageSeconds),
            statuses: nil
        )
    }

    /// The legitimate bridge: a cache from moments ago serves while a sweep or broadcast holds
    /// the actor.
    @Test func aFreshEpochServes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Self.epoch(ageSeconds: 10, now: now).isServable(asOf: now))
    }

    /// The longest work the guard exists for (a ~45 s sweep) is comfortably inside the bound.
    @Test func aSweepLengthEpochServes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Self.epoch(ageSeconds: 60, now: now).isServable(asOf: now))
    }

    /// The exact bound is still servable; one second past it is not — the cliff is deliberate,
    /// not fuzzy.
    @Test func theBoundIsExact() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Self.epoch(ageSeconds: MigrationRowsSnapshot.maxServableAge, now: now).isServable(asOf: now))
        #expect(!Self.epoch(ageSeconds: MigrationRowsSnapshot.maxServableAge + 1, now: now).isServable(asOf: now))
    }

    /// The field case: a 90-minute-old epoch (the pre-absence world) must never serve, no matter
    /// how the work-in-flight flag reads at the moment of the ask.
    @Test func theNinetyMinuteWorldIsRefused() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!Self.epoch(ageSeconds: 90 * 60, now: now).isServable(asOf: now))
    }
}
