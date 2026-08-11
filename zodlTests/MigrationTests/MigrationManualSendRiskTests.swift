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

    // MARK: - The predicate — proposal truth is primary now that B6 has landed

    /// THE headline case: a live run, and this send's own proposal reaches into legacy Orchard.
    /// `hasUnmigratedOrchard` is deliberately the opposite of the answer to prove the proposal's
    /// verdict is what decides this — not the wallet-wide approximation.
    @Test func aLiveRunWithASpendingProposalWarns() {
        #expect(MigrationManualSendRisk.shouldWarn(
            hasActiveRun: true,
            proposalSpendsOrchard: true,
            hasUnmigratedOrchard: false
        ))
    }

    /// The §10.3 case dying: before B6, a live run with unmigrated Orchard SOMEWHERE in the wallet
    /// warned on every manual send, transparent-only sends included. Now the proposal itself says
    /// this send does not touch Orchard, so it is quiet — `hasUnmigratedOrchard: true` proves the
    /// leftover balance elsewhere no longer matters once the proposal has answered.
    @Test func aTransparentOnlySendDuringALiveRunIsNowQuiet() {
        #expect(!MigrationManualSendRisk.shouldWarn(
            hasActiveRun: true,
            proposalSpendsOrchard: false,
            hasUnmigratedOrchard: true
        ))
    }

    /// A spending proposal with no run to protect is just an ordinary send: nothing is at stake.
    @Test func aSpendingProposalWithNoRunIsJustFunds() {
        #expect(!MigrationManualSendRisk.shouldWarn(
            hasActiveRun: false,
            proposalSpendsOrchard: true,
            hasUnmigratedOrchard: true
        ))
    }

    /// The nil-proposal fallback, warn half: no proposal to ask yet, so this falls back to the
    /// pre-B6 approximation — a live run plus unmigrated Orchard still on the books.
    @Test func aLiveRunWithOrchardLeftWarnsWhenNoProposalIsKnown() {
        #expect(MigrationManualSendRisk.shouldWarn(
            hasActiveRun: true,
            proposalSpendsOrchard: nil,
            hasUnmigratedOrchard: true
        ))
    }

    /// The nil-proposal fallback, quiet half — the self-retiring case: once the run has swept the
    /// Orchard balance, there is nothing left for a send to reach into and the fallback goes quiet
    /// on its own, same as before B6.
    @Test func aLiveRunWithNothingLeftInOrchardIsQuietWhenNoProposalIsKnown() {
        #expect(!MigrationManualSendRisk.shouldWarn(
            hasActiveRun: true,
            proposalSpendsOrchard: nil,
            hasUnmigratedOrchard: false
        ))
    }
}
