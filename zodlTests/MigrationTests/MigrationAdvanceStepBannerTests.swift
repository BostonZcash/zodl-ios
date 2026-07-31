//
//  MigrationAdvanceStepBannerTests.swift
//  zodlTests
//
//  A15 — the smart-banner audit, made permanent.
//
//  The migration's whole control flow now hangs off ONE engine answer: `next_step()`. Everything the
//  user sees is two hops from it — `MigrationAdvanceStep` → `MigrationState.derive` → `bannerVariant`
//  — and each hop was written and reviewed separately. This suite walks the composed chain for every
//  advance-step case, so the audit is a table that fails when the mapping drifts rather than a
//  paragraph in a board that goes stale.
//
//  Reading these as a table: the left column is what the ENGINE said, the right is what the USER is
//  told. Nothing here asserts an intermediate state — an intermediate that changes while the
//  user-visible answer stays correct is a refactor, not a regression.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationAdvanceStepBannerTests {
    // MARK: - Fixtures

    private static func progress(completed: Int = 1, total: Int = 4, isImmediate: Bool = false) -> MigrationProgress {
        MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchard: Zatoshi(500_000_000),
            nextTransferReadyAtHeight: 3_000_000,
            isImmediate: isImmediate
        )
    }

    private static func status(
        id: UInt32,
        kind: MigrationTransactionStatus.Kind,
        state: MigrationTransactionStatus.State,
        isReady: Bool = false,
        blockedOn: MigrationTransactionStatus.Blocker? = nil,
        dependsOn: [UInt32] = []
    ) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: kind,
            state: state,
            scheduledHeight: 3_000_000,
            expiryHeight: nil,
            isReady: isReady,
            nextAction: isReady ? .broadcast : nil,
            blockedOn: blockedOn,
            dependsOn: dependsOn,
            anchorBoundaryHeight: nil
        )
    }

    /// The full chain, end to end: what the engine reports → what the banner says.
    private static func banner(
        advanceStep: MigrationAdvanceStep?,
        progress: MigrationProgress? = nil,
        statuses: [MigrationTransactionStatus] = [],
        hasInvalid: Bool = false,
        hasOverdue: Bool = false,
        isManualDelivery: Bool = false,
        isNextTransferDue: Bool = false,
        isBroadcastInFlight: Bool = false,
        orchardBalance: Zatoshi = Zatoshi(500_000_000),
        isCompleteAcknowledged: Bool = false,
        transferRows: [MigrationTransferRow] = []
    ) -> MigrationBannerVariant? {
        let state = MigrationState.derive(
            advanceStep: advanceStep,
            progress: progress,
            statuses: statuses,
            hasInvalidTransfers: hasInvalid
        )
        return MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: state,
            hasOverdue: hasOverdue,
            isManualDelivery: isManualDelivery,
            isNextTransferDue: isNextTransferDue,
            orchardBalance: orchardBalance,
            isCompleteAcknowledged: isCompleteAcknowledged,
            isMigrationRemainderPending: false,
            transferRows: transferRows,
            isBroadcastInFlight: isBroadcastInFlight
        )
    }

    // MARK: - No run stored

    @Test func noRunWithABalanceOffersTheMigration() {
        #expect(Self.banner(advanceStep: nil) == .required)
    }

    @Test func noRunAndNoBalanceShowsNothing() {
        #expect(Self.banner(advanceStep: nil, orchardBalance: .zero) == nil)
    }

    /// The immediate send-max sweep runs without a stored run at all. Its aftermath is deliberately
    /// quiet — the balance is already spent, so there is nothing to prompt.
    @Test func theImmediateSweepIsSilent() {
        #expect(Self.banner(advanceStep: nil, progress: Self.progress(isImmediate: true)) == nil)
    }

    // MARK: - Terminal

    @Test func completeAsksForAnAcknowledgement() {
        #expect(Self.banner(advanceStep: .complete) == .complete)
    }

    @Test func anAcknowledgedCompleteWithNoRemainderIsSilent() {
        #expect(Self.banner(advanceStep: .complete, isCompleteAcknowledged: true) == nil)
    }

    // MARK: - Rebuild

    /// `.rebuild` is the engine saying a transfer expired unmined: its pre-signed artifact is dead
    /// (the signature commits to the expiry height), so this is a user-facing recovery, not a retry.
    @Test func rebuildSurfacesAsExpired() {
        let rows = [
            MigrationTransferRow(id: "1", index: 0, amount: nil, status: .expired, hoursFromNow: 0),
            MigrationTransferRow(id: "2", index: 1, amount: nil, status: .pending, hoursFromNow: 6)
        ]
        #expect(Self.banner(advanceStep: .rebuild(id: 1), transferRows: rows) == .transfersExpired(first: 1, last: 1))
    }

    // MARK: - Invalidation outranks the step

    /// The precedence that A28 made reachable. The engine can still report a perfectly live
    /// `.waiting` for a run whose funding notes were spent elsewhere — it has no way to know until
    /// the app's invalidation sweep tells it — so a live-looking step must not mask a dead run.
    @Test(arguments: [MigrationAdvanceStep.waiting, .prove(id: 1, kind: .transfer(crossing: 0)), .broadcast(id: 1)])
    func invalidationOutranksALiveStep(step: MigrationAdvanceStep) {
        #expect(Self.banner(advanceStep: step, hasInvalid: true) == .updatePlan)
    }

    // MARK: - Running

    @Test func provingATransferReadsAsProgress() {
        let variant = Self.banner(advanceStep: .prove(id: 1, kind: .transfer(crossing: 0)), progress: Self.progress())
        #expect(variant == MigrationBannerVariant.inProgress(done: 1, total: 4, round: nil, totalRounds: nil))
    }

    /// A run whose preparations have not all mined is still SPLITTING — and that reads as progress,
    /// not as "Migration Required" (which is what the retired `.splitting` variant said, and exactly
    /// the post-confirm confusion QA reported).
    @Test func anUnminedPreparationReadsAsProgressNotAsAFreshOffer() {
        let statuses = [
            Self.status(id: 1, kind: .preparation(layer: 0, index: 0), state: .mined(height: 100)),
            Self.status(id: 2, kind: .preparation(layer: 1, index: 0), state: .broadcast(txid: Data()))
        ]
        let rows = [MigrationTransferRow(id: "10", index: 0, amount: nil, status: .pending, hoursFromNow: 6)]
        let variant = Self.banner(
            advanceStep: .prove(id: 2, kind: .preparation(layer: 1, index: 0)),
            progress: Self.progress(),
            statuses: statuses,
            transferRows: rows
        )
        #expect(variant == MigrationBannerVariant.inProgress(done: 0, total: 1, round: nil, totalRounds: nil))
    }

    @Test func waitingWithAnOverdueTransferAsksTheUserToOpenTheApp() {
        let variant = Self.banner(advanceStep: .waiting, progress: Self.progress(), hasOverdue: true)
        #expect(variant == .transferWaiting(number: 2, torHold: false))
    }

    // MARK: - Broadcast

    /// A13: the engine says broadcast, the app is broadcasting, the banner says so.
    @Test func aDrivenBroadcastReadsAsSending() {
        let variant = Self.banner(
            advanceStep: .broadcast(id: 1),
            progress: Self.progress(),
            hasOverdue: true,
            isBroadcastInFlight: true
        )
        #expect(variant == .transferSending(number: 2))
    }

    /// The same engine answer in a MANUAL-delivery run: the driver deliberately does not broadcast,
    /// so the banner asks the user to, and its button reads "Review" rather than "More".
    @Test func aManualBroadcastAsksTheUserToReview() {
        let variant = Self.banner(
            advanceStep: .broadcast(id: 1),
            progress: Self.progress(),
            isManualDelivery: true,
            isNextTransferDue: true
        )
        #expect(variant == .transferReady(number: 2))
        #expect(variant?.buttonLabel == String(localizable: .sendReview))
    }

    // MARK: - Coverage

    /// Every advance step the engine can report produces SOME user-visible answer — none of them
    /// falls into a hole that renders nothing while a run is live.
    @Test(arguments: [
        MigrationAdvanceStep.prove(id: 1, kind: .transfer(crossing: 0)),
        .prove(id: 1, kind: .preparation(layer: 0, index: 0)),
        .broadcast(id: 1),
        .rebuild(id: 1),
        .waiting,
        .complete
    ])
    func everyAdvanceStepProducesABanner(step: MigrationAdvanceStep) {
        #expect(Self.banner(advanceStep: step, progress: Self.progress()) != nil)
    }
}
