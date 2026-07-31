//
//  MigrationManualSendRiskTests.swift
//  zodlTests
//
//  A12's predicate: whether a manual send warns that it may spend Orchard funds a scheduled
//  migration depends on.
//
//  What these pin is a JUDGEMENT, not an algorithm — the predicate itself is two booleans. The
//  judgement is which states count as "a run a send could damage", and it is the opposite call from
//  the server-switch warning (A20, ruled quiet): that one fired when the user's action changed
//  nothing; this one fires when the action can invalidate a plan the user waited days for. Over-
//  warning is the cheap error here.
//

import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationManualSendRiskTests {
    private static func progress() -> MigrationProgress {
        MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 4,
            remainingOrchard: Zatoshi(500_000_000),
            nextTransferReadyAtHeight: 3_000_000
        )
    }

    // MARK: - Which runs are worth protecting

    /// A run that has not started has no plan to invalidate, and a complete one has nothing left to
    /// protect — warning in either case is pure noise.
    @Test(arguments: [MigrationState.notStarted, .complete])
    func aRunWithNothingAtStakeDoesNotWarn(state: MigrationState) {
        #expect(!MigrationManualSendRisk.isActiveRun(state))
    }

    /// Every live state counts, INCLUDING `.requiresAttention` — a run that already needs a re-plan
    /// can still be made worse, and the user is about to spend the funds the re-plan would use.
    @Test(arguments: [
        MigrationState.splitPendingConfirmation,
        .inProgress(MigrationManualSendRiskTests.progress()),
        .requiresAttention(.invalidTransfer),
        .requiresAttention(.transferExpired)
    ])
    func everyLiveRunIsWorthProtecting(state: MigrationState) {
        #expect(MigrationManualSendRisk.isActiveRun(state))
    }

    // MARK: - The predicate

    @Test func aLiveRunWithOrchardLeftWarns() {
        #expect(MigrationManualSendRisk.shouldWarn(hasActiveRun: true, hasUnmigratedOrchard: true))
    }

    /// The self-retiring half: once the run has swept the Orchard balance, there is nothing left
    /// for a send to reach into and the warning stops on its own.
    @Test func aLiveRunWithNothingLeftInOrchardIsQuiet() {
        #expect(!MigrationManualSendRisk.shouldWarn(hasActiveRun: true, hasUnmigratedOrchard: false))
    }

    /// Orchard funds with NO migration scheduled are just funds. Nothing is at stake, so an
    /// ordinary send is an ordinary send.
    @Test func orchardFundsWithNoRunAreJustFunds() {
        #expect(!MigrationManualSendRisk.shouldWarn(hasActiveRun: false, hasUnmigratedOrchard: true))
    }

    @Test func neitherConditionIsQuiet() {
        #expect(!MigrationManualSendRisk.shouldWarn(hasActiveRun: false, hasUnmigratedOrchard: false))
    }
}
