//
//  MigrationBroadcastBannerTests.swift
//  zodlTests
//
//  Covers A13's pure seam: `MigrationDerivations.bannerVariant`'s `isBroadcastInFlight` arm, which
//  raises `.transferSending` while `MigrationManagerImpl.runBroadcastSession` is submitting.
//
//  The precedence is the whole point and is what these pin. During a headless broadcast, EVERY
//  "something is due" signal is simultaneously true — `hasOverdue` (the transfer is due, that is
//  why it is being sent) and, in a manual-delivery run, `isNextTransferDue` as well. Whichever arm
//  is checked first wins, so the ordering is load-bearing, not incidental: a banner reading
//  "Transfer 3 is waiting" while transfer 3 is going out over the wire is the wrong half of a true
//  statement, and — worse — it asks the user for nothing, when the one thing this session actually
//  needs is for them to keep the app open.
//

import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationBroadcastBannerTests {
    // MARK: - Fixtures

    private static func progress(completed: Int, total: Int, isImmediate: Bool = false) -> MigrationProgress {
        MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchard: Zatoshi(500_000_000),
            nextTransferReadyAtHeight: 3_000_000,
            isImmediate: isImmediate
        )
    }

    /// Every input at its quiet default except the ones a test varies — so a failure names the one
    /// signal that moved.
    private static func variant(
        state: MigrationState,
        hasOverdue: Bool = false,
        isManualDelivery: Bool = false,
        isNextTransferDue: Bool = false,
        isBroadcastInFlight: Bool = false
    ) -> MigrationBannerVariant? {
        MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: state,
            hasOverdue: hasOverdue,
            isManualDelivery: isManualDelivery,
            isNextTransferDue: isNextTransferDue,
            orchardBalance: Zatoshi(500_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: [],
            isBroadcastInFlight: isBroadcastInFlight
        )
    }

    // MARK: - The sending banner

    /// Numbering matches every other per-transfer arm: the transfer IN FLIGHT is the one after the
    /// last completed one.
    @Test func inFlightBroadcastReadsAsSending() {
        let variant = Self.variant(state: .inProgress(Self.progress(completed: 2, total: 6)), isBroadcastInFlight: true)
        #expect(variant == .transferSending(number: 3))
    }

    /// The precedence that matters most: `hasOverdue` is ALWAYS true during a broadcast (a due
    /// transfer is exactly what is being sent), so "waiting" would otherwise win and describe the
    /// state as its own opposite.
    @Test func sendingBeatsWaiting() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 3)),
            hasOverdue: true,
            isBroadcastInFlight: true
        )
        #expect(variant == .transferSending(number: 1))
    }

    /// A manual-delivery run reaches a broadcast only because the user tapped Send. Once it is in
    /// flight, re-offering "Review" would invite a second tap on a transfer already going out.
    @Test func sendingBeatsReadyInAManualRun() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 1, total: 4)),
            isManualDelivery: true,
            isNextTransferDue: true,
            isBroadcastInFlight: true
        )
        #expect(variant == .transferSending(number: 2))
    }

    /// The immediate (send-max) lane keeps its deliberate silence — it broadcasts from its own
    /// full-screen Sending flow, so there is no banner to raise behind it. The `isImmediate` guard
    /// stays AHEAD of the in-flight check for that reason.
    @Test func theImmediateLaneStaysQuietEvenMidBroadcast() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 1, isImmediate: true)),
            hasOverdue: true,
            isBroadcastInFlight: true
        )
        #expect(variant == nil)
    }

    // MARK: - No regression when nothing is in flight

    @Test func waitingIsUnchangedWhenNothingIsInFlight() {
        let variant = Self.variant(state: .inProgress(Self.progress(completed: 2, total: 6)), hasOverdue: true)
        #expect(variant == .transferWaiting(number: 3, torHold: false))
    }

    @Test func readyIsUnchangedWhenNothingIsInFlight() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 1, total: 4)),
            isManualDelivery: true,
            isNextTransferDue: true
        )
        #expect(variant == .transferReady(number: 2))
    }

    /// The parameter defaults to `false`, so every pre-A13 call site — none of which know the flag
    /// exists — derives exactly what it derived before.
    @Test func omittingTheFlagMatchesPassingItFalse() {
        let omitted = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: .inProgress(Self.progress(completed: 2, total: 6)),
            hasOverdue: true,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi(500_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: []
        )
        #expect(omitted == Self.variant(state: .inProgress(Self.progress(completed: 2, total: 6)), hasOverdue: true))
    }

    // MARK: - The flag is scoped to a run in progress

    /// A run that is not in progress cannot have a transfer in flight, and the flag must not be
    /// able to manufacture a sending banner out of a terminal or unstarted state.
    @Test(arguments: [MigrationState.notStarted, .complete, .requiresAttention(.transferExpired)])
    func theFlagDoesNotLeakOutsideAnInProgressRun(state: MigrationState) {
        #expect(Self.variant(state: state, isBroadcastInFlight: true) == Self.variant(state: state))
    }
}
