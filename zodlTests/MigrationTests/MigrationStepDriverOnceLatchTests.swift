//
//  MigrationStepDriverOnceLatchTests.swift
//  zodlTests
//
//  C6-1 (campaign-6, 2026-08-05): Lukas's law — "zodl open = ONE nextStep() until the next
//  open" — was enforced only by convention across Root's several launch paths, and a cold open
//  that traversed two of them drove the engine twice: with a due pile-up, each drive is a
//  BROADCAST (two sends 4 s apart in one session, on camera). The fix is a once-latch at the
//  driver chokepoint: at most one `.beforeSync` discharge per session, keyed on the trace's
//  session ordinal.
//
//  TEST-HARNESS CAVEAT: `MigrationTrace` session state is process-global, and parallel suites
//  exercise Root reducers whose production paths call `beginSession` — so another suite can
//  roll the ordinal between any two statements here. The test therefore RETRIES the same-session
//  observation with a fresh session per attempt: the pinned property is "the latch CAN hold
//  within one session and a new session drives again", which one clean attempt proves; churn
//  makes an attempt inconclusive, never wrong.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) struct MigrationStepDriverOnceLatchTests {
    private static let activationHeight: BlockHeight = 4_134_000
    private static let tip: BlockHeight = 4_200_000

    private static func atTipState() -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = tip
        return state
    }

    /// Within one session the second `.beforeSync` is skipped; a NEW session drives again.
    /// (`.notApplicable` is what a drive verdicts to with no wallet accounts installed — still a
    /// DRIVE: the latch marks attempts, not successes.)
    @Test func secondBeforeSyncInOneSessionIsSkippedAndANewSessionDrives() async {
        await withDependencies {
            $0.sdkSynchronizer = .mocked(latestState: { Self.atTipState() })
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = MigrationManagerImpl()

            var observedLatch = false
            for _ in 0..<3 {
                MigrationTrace.beginSession(cause: .foreground, tip: Self.tip)
                let first = await manager.advance(phase: .beforeSync)
                let second = await manager.advance(phase: .beforeSync)
                MigrationTrace.endSession(reason: "test attempt teardown")

                // A parallel suite rolling the global ordinal between the two calls makes both
                // drives "first" — inconclusive, retry. A clean attempt shows the law exactly.
                if first == .notApplicable && second == .skipped {
                    observedLatch = true
                    break
                }
            }
            #expect(observedLatch, "one clean attempt must show: first drives, second same-session call yields to the once-latch")

            // The reset arm: a fresh session gets its one drive (whatever parallel churn does to
            // the ordinal, it can only make this a DIFFERENT session — which must drive).
            MigrationTrace.beginSession(cause: .foreground, tip: Self.tip)
            let nextSession = await manager.advance(phase: .beforeSync)
            MigrationTrace.endSession(reason: "test teardown")
            #expect(nextSession == .notApplicable, "a NEW session gets its one drive")
        }
    }
}
