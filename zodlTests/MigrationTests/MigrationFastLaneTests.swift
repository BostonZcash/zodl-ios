//
//  MigrationFastLaneTests.swift
//  zodlTests
//
//  The fast lane's ONE testable property from inside a normal process: it is INERT unless the
//  process was launched with `-MigrationFastLane`. The test runner never passes the argument, so
//  this pins the default-off half of the double fence (the other half — Release compiling
//  `isActive` to a literal `false` — is a compile-time guarantee, not a runtime observation).
//  Every other suite doubles as coverage of the inert path: they all run with the lane off and
//  pin stock behavior.
//

import Foundation
import Testing
@testable import zodl_internal

struct MigrationFastLaneTests {
    @Test func fastLaneIsInertWithoutTheLaunchArgument() {
        #expect(MigrationFastLane.isActive == false, "the test runner passes no -MigrationFastLane — the lane must be off")
    }
}
