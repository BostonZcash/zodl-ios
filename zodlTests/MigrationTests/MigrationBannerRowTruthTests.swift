//
//  MigrationBannerRowTruthTests.swift
//  zodlTests
//
//  MOB-1466, the smart-banner pass: the banner and the transfer timeline must tell the same story,
//  because they are two views of one run and the user sees them within one tap of each other.
//
//  They did not. The banner derived "which transfer" from `MigrationProgress.completedTransfers`,
//  which counts MINED transfers, while the timeline numbered rows by position. A transfer mines
//  minutes after it sends, so for that entire window the banner named the transfer that had already
//  gone out and the timeline named the next one. Field report, verbatim: "transfer 1 has been done,
//  transfer 2 ready but smart widget still writes transfer 1".
//
//  What these pin is the replacement rule — the banner reads the same live ROWS the timeline
//  renders — and the line that rule had to learn the hard way:
//
//  - The NUMBERS come from row position in both surfaces, so they agree by construction.
//  - PREPARING exists, a state the banner had no word for at all, during the longest phase of a run.
//  - A KEEP-OPEN ASK belongs only to work that dies when the app closes. The first cut raised it
//    from the durable `.broadcast(txid:)` row, which means SUBMITTED and awaiting mining — minutes
//    during which the SDK's own post-broadcast buffer holds sync so the wallet cannot even observe
//    the mining. The banner asked the user to watch a spinner while the app did nothing, and the
//    tester read three minutes of it as a hang. The row still names WHICH transfer; the in-session
//    `isBroadcastInFlight` flag decides whether we may ask them to stay.
//
//  On iOS this is not decoration. Zodl has no background lane: proving and broadcasting happen only
//  while the app is open and on screen. A banner that says nothing — or says "waiting" — during work
//  that only runs on screen is what makes the user close the app and stop it. The mirror failure is
//  just as bad: asking them to stay for work that is already out of our hands teaches them the ask
//  means nothing.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationBannerRowTruthTests {
    // MARK: - Fixtures

    private static let clock = MigrationChainClock(tip: 3_000_000)

    private static func progress(completed: Int, total: Int, isImmediate: Bool = false) -> MigrationProgress {
        MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchard: Zatoshi(500_000_000),
            nextTransferReadyAtHeight: 3_000_000,
            isImmediate: isImmediate
        )
    }

    private static func row(
        index: Int,
        status: MigrationTransferRow.Status,
        isBroadcasting: Bool = false,
        isPreparing: Bool = false,
        kind: MigrationTransferRow.Kind = .transfer
    ) -> MigrationTransferRow {
        MigrationTransferRow(
            id: "\(index)",
            index: index,
            amount: Zatoshi(100_000_000),
            status: status,
            hoursFromNow: 0,
            isBroadcasting: isBroadcasting,
            isPreparing: isPreparing,
            kind: kind
        )
    }

    private static func variant(
        state: MigrationState,
        transferRows: [MigrationTransferRow],
        preparationRows: [MigrationTransferRow] = [],
        hasOverdue: Bool = false,
        isManualDelivery: Bool = false,
        isNextTransferDue: Bool = false,
        isBroadcastInFlight: Bool = false,
        progressCompleted: Int = 0,
        progressTotal: Int = 6
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
            transferRows: transferRows,
            preparationRows: preparationRows,
            isBroadcastInFlight: isBroadcastInFlight
        )
    }

    private static func status(
        id: UInt32,
        kind: MigrationTransactionStatus.Kind,
        state: MigrationTransactionStatus.State,
        isReady: Bool = false,
        nextAction: MigrationTransactionStatus.NextAction? = nil,
        blockedOn: MigrationTransactionStatus.Blocker? = nil
    ) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: kind,
            state: state,
            scheduledHeight: 3_000_100,
            expiryHeight: nil,
            isReady: isReady,
            nextAction: nextAction,
            blockedOn: blockedOn,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    // MARK: - Sending, from durable row state

    /// THE correction, field-caught 2026-08-01. A `.broadcast(txid:)` row means SUBMITTED and
    /// awaiting mining — minutes, during which the SDK's post-broadcast buffer holds sync so the
    /// wallet cannot even observe the mining. Raising the keep-open banner off it asked the user to
    /// sit and watch a spinner while the app did nothing, and the tester read that as a hang.
    ///
    /// Leaving costs the user nothing once the transaction is on the wire. Only work that dies when
    /// the app closes may ask them to stay.
    @Test func aBroadcastRowAloneDoesNotAskTheUserToStay() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .active, isBroadcasting: true),
                Self.row(index: 1, status: .pending)
            ]
        )
        #expect(variant != .transferSending(number: 1))
        #expect(variant == .inProgress(done: 0, total: 6, round: nil, totalRounds: nil))
    }

    /// Same rule in the split phase, where it actually bit: a broadcast Split Balance awaiting its
    /// mining is not a reason to keep the app open.
    @Test func aBroadcastPreparationAloneDoesNotAskTheUserToStay() {
        let variant = Self.variant(
            state: .splitPendingConfirmation,
            transferRows: [Self.row(index: 0, status: .pending)],
            preparationRows: [Self.row(index: 0, status: .active, isBroadcasting: true, kind: .splitBalance)]
        )
        #expect(variant != .preparing)
    }

    /// The submission itself DOES ask — that window is seconds long and dies with the app.
    @Test func anInFlightSubmissionAsksTheUserToStay() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [Self.row(index: 0, status: .active)],
            isBroadcastInFlight: true
        )
        #expect(variant == .transferSending(number: 1))
    }

    /// The NUMBER still comes from row position — that half of the row-truth pass stands, and it is
    /// what makes the banner and the timeline agree on WHICH transfer. Here the engine has seen
    /// transfer 1 mined while `completedTransfers` still reads 0: the mined count would have said
    /// Transfer 1, the rows correctly say Transfer 2.
    @Test func theSendingNumberIsThePositionNotTheMinedCount() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .active, isBroadcasting: true)
            ],
            isBroadcastInFlight: true
        )
        #expect(variant == .transferSending(number: 2), "the mined count would have said Transfer 1")
    }

    /// Same lag, the waiting arm. A run whose first transfer has landed but whose progress read has
    /// not caught up must still call the pending one Transfer 2 — the number the timeline shows.
    @Test func theWaitingNumberFollowsTheRowsNotTheMinedCount() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .overdue)
            ],
            hasOverdue: true
        )
        #expect(variant == .transferWaiting(number: 2, torHold: false))
    }

    @Test func theReadyNumberFollowsTheRowsNotTheMinedCount() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .active)
            ],
            isManualDelivery: true,
            isNextTransferDue: true
        )
        #expect(variant == .transferReady(number: 2))
    }

    /// With no rows to read — a run with no persisted schedule and no live statuses — the mined
    /// count is still the best available answer, and the pre-existing behaviour stands.
    @Test func withoutRowsTheMinedCountStillDrivesTheNumber() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 2, total: 6)),
            transferRows: [],
            hasOverdue: true
        )
        #expect(variant == .transferWaiting(number: 3, torHold: false))
    }

    // MARK: - Preparing

    /// The state the banner had no word for. A transfer the engine says it can prove right now is
    /// work happening in this session — and on iOS, work that stops when the app closes.
    @Test func aProvableRowRaisesPreparing() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [Self.row(index: 0, status: .active, isPreparing: true)]
        )
        #expect(variant == .preparing)
    }

    /// THE field ordering. A transfer whose window passed while its proof was outstanding is both
    /// overdue and un-sendable; the old ranking advertised "Tap to reschedule or send now" and
    /// tapping Send now answered "due but awaiting proof — deferring to the next sync visit".
    @Test func preparingBeatsWaiting() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [Self.row(index: 0, status: .overdue, isPreparing: true)],
            hasOverdue: true
        )
        #expect(variant == .preparing)
    }

    /// Same reason in the manual lane: offering Review for a transfer that cannot be sent yet ends
    /// in the same dead end, one screen deeper.
    @Test func preparingBeatsReady() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [Self.row(index: 0, status: .active, isPreparing: true)],
            isManualDelivery: true,
            isNextTransferDue: true
        )
        #expect(variant == .preparing)
    }

    /// But a broadcast already in flight outranks it — that transfer is past preparing, and naming
    /// the delivery is the more specific truth.
    @Test func sendingBeatsPreparing() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .active, isBroadcasting: true),
                Self.row(index: 1, status: .pending, isPreparing: true)
            ],
            isBroadcastInFlight: true
        )
        #expect(variant == .transferSending(number: 1))
    }

    /// Preparing is RUN-level and plural: one prove sweep proves the whole run, and Figma C5 shows
    /// two transfers preparing at once. Any provable row raises it, wherever it sits.
    @Test func preparingIsRaisedByAnyRowNotJustTheFirst() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .active),
                Self.row(index: 1, status: .pending, isPreparing: true)
            ]
        )
        #expect(variant == .preparing)
    }

    /// A note-split preparation is work exactly as much as a crossing transfer is, and the split
    /// phase is where a large wallet spends its first minutes with the app open.
    @Test func aProvablePreparationRaisesPreparingDuringTheSplitPhase() {
        let variant = Self.variant(
            state: .splitPendingConfirmation,
            transferRows: [Self.row(index: 0, status: .pending)],
            preparationRows: [Self.row(index: 0, status: .active, isPreparing: true, kind: .splitBalance)]
        )
        #expect(variant == .preparing)
    }

    /// FIELD-CAUGHT 2026-08-01. A note-split is proved at commit and BROADCAST later, in its own
    /// scheduled window — ZIP 318 applies to preparations too — so the split's broadcast happens
    /// inside `splitPendingConfirmation`, not `.inProgress`. The first cut of this pass added the
    /// preparing check to that arm and left the broadcast check in `.inProgress` only, so the
    /// banner read "We'll notify you when to send" while the timeline one tap away read
    /// "Split Balance 1 · Sending now". Same disagreement, one arm later.
    @Test func aPreparationBeingSubmittedRaisesPreparingNotIdle() {
        let variant = Self.variant(
            state: .splitPendingConfirmation,
            transferRows: [Self.row(index: 0, status: .pending)],
            preparationRows: [Self.row(index: 0, status: .active, isBroadcasting: true, kind: .splitBalance)],
            isBroadcastInFlight: true
        )
        #expect(variant == .preparing)
    }

    /// `.preparing` and not `.transferSending`, deliberately: the thing going out is a Split
    /// Balance, not a numbered transfer, and "Transfer 1 is sending…" over a split would be a
    /// confident lie.
    @Test func aPreparationBeingSubmittedIsNeverNumberedAsATransfer() {
        let variant = Self.variant(
            state: .splitPendingConfirmation,
            transferRows: [Self.row(index: 0, status: .pending)],
            preparationRows: [Self.row(index: 0, status: .active, isBroadcasting: true, kind: .splitBalance)],
            isBroadcastInFlight: true
        )
        #expect(variant != .transferSending(number: 1))
    }

    /// The in-session flag has to be read in this arm too. It is set the instant
    /// `runBroadcastSession` starts and pokes — which is exactly the moment the field log caught,
    /// seconds before the engine had written `.broadcast` to any row.
    @Test func theInFlightFlagAloneRaisesPreparingDuringTheSplitPhase() {
        let variant = Self.variant(
            state: .splitPendingConfirmation,
            transferRows: [Self.row(index: 0, status: .pending)],
            isBroadcastInFlight: true
        )
        #expect(variant == .preparing)
    }

    /// The immediate (send-max) lane keeps its deliberate silence — it runs behind its own
    /// full-screen Sending flow, so there is no banner to raise. The `isImmediate` guard stays
    /// ahead of every new arm.
    @Test func theImmediateLaneStaysQuietWhilePreparing() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 1, isImmediate: true)),
            transferRows: [Self.row(index: 0, status: .active, isPreparing: true)]
        )
        #expect(variant == nil)
    }

    // MARK: - Idle

    /// Nothing in flight, nothing due: the designed copy is a promise the app keeps (window
    /// notifications are armed at every reconcile), not a progress readout that lags by a
    /// confirmation.
    @Test func anIdleRunReadsAsProgressWithTheNotifyLine() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 1, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .pending)
            ]
        )
        #expect(variant == .inProgress(done: 1, total: 6, round: nil, totalRounds: nil))
        #expect(variant?.info == "We'll notify you when to send")
    }

    /// Both work-in-flight states carry the same second line, because both are asking for the same
    /// one thing. Figma 5139:35270 and 5139:34287 print it identically.
    @Test func bothWorkingStatesAskTheUserToStay() {
        let keepOpen = "Keep Zodl open on active phone screen"
        #expect(MigrationBannerVariant.preparing.info == keepOpen)
        #expect(MigrationBannerVariant.transferSending(number: 1).info == keepOpen)
    }

    /// Preparing is run-level, so it borrows the run-level title and the run-level button — it is
    /// not about one transfer and must not offer to review one.
    @Test func preparingIsTitledAndButtonedAtRunLevel() {
        #expect(MigrationBannerVariant.preparing.title == MigrationBannerVariant.inProgress(done: 0, total: 6, round: nil, totalRounds: nil).title)
        #expect(MigrationBannerVariant.preparing.buttonLabel == MigrationBannerVariant.required.buttonLabel)
    }

    // MARK: - The row flag itself

    /// `isPreparing` is the ENGINE's readiness verdict, not a lifecycle guess. `isReady` +
    /// `nextAction == .prove` is the engine saying, in as many words, "you can prove this now".
    @Test func aReadyToProveStatusMarksTheRowPreparing() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .signed, isReady: true, nextAction: .prove)],
            clock: Self.clock
        )
        #expect(rows?[0].isPreparing == true)
    }

    /// And the case that makes readiness the right signal rather than the `.signed` state: a
    /// transfer whose anchor boundary the wallet has not scanned yet is `.signed` too, and nothing
    /// the user does by staying makes it prove. That row must NOT wear a "keep Zodl open" ask.
    ///
    /// This is the shape of the bug that blocked the first successful transfer for a full day —
    /// signed, unprovable, retried forever. Keeping it out of `.preparing` is what stops the banner
    /// from asking the user to sit and watch a stall.
    @Test func aSignedButAnchorBlockedStatusIsNotPreparing() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .signed, blockedOn: .anchorBoundary)],
            clock: Self.clock
        )
        #expect(rows?[0].isPreparing == false)
    }

    /// A proved transfer waiting for its window is ready to BROADCAST, not to prove — nothing is
    /// running, and the idle banner is the honest one.
    @Test func aProvedRowAwaitingItsWindowIsNotPreparing() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .proved, isReady: true, nextAction: .broadcast)],
            clock: Self.clock
        )
        #expect(rows?[0].isPreparing == false)
    }

    /// A mined transfer is finished; readiness is meaningless on it and the flag must stay off, or
    /// a completed row would carry a spinner.
    @Test func aMinedRowIsNeverPreparing() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .mined(height: 2_999_000), isReady: true, nextAction: .prove)],
            clock: Self.clock
        )
        #expect(rows?[0].isPreparing == false)
        #expect(rows?[0].status == .sent)
    }

    /// `isInFlight` is what the timeline's spinner reads, and it is PROVING ONLY.
    ///
    /// `isBroadcasting` was dropped from it 2026-08-01, with the caption, for one reason: a
    /// `.broadcast(txid:)` row is submitted and awaiting mining — minutes — and a spinner over it
    /// claims the app is working when the remaining work is the chain's. Field report that produced
    /// this: "there is never ending sending of split 1." A spinner that never stops is how a wallet
    /// teaches someone it is broken.
    @Test func inFlightIsProvingOnly() {
        #expect(Self.row(index: 0, status: .active, isPreparing: true).isInFlight)
        #expect(
            !Self.row(index: 0, status: .active, isBroadcasting: true).isInFlight,
            "a broadcast row is waiting on the chain, not on us"
        )
        #expect(!Self.row(index: 0, status: .active).isInFlight)
        #expect(!Self.row(index: 0, status: .sent).isInFlight)
    }

    // MARK: - No regressions on the quiet paths

    /// A terminal or unstarted run cannot have work in flight, and the two new row FLAGS must not
    /// be able to manufacture a preparing or sending banner out of one. Compared against the same
    /// rows with the flags cleared, so the comparison isolates the flags — `.transfersExpired` does
    /// legitimately read the rows (for its first/last bounds), and always has.
    @Test(arguments: [MigrationState.notStarted, .complete, .requiresAttention(.transferExpired)])
    func theNewRowFlagsDoNotLeakOutsideAnInProgressRun(state: MigrationState) {
        let flagged = Self.variant(
            state: state,
            transferRows: [
                Self.row(index: 0, status: .expired, isBroadcasting: true, isPreparing: true)
            ]
        )
        let unflagged = Self.variant(
            state: state,
            transferRows: [Self.row(index: 0, status: .expired)]
        )
        #expect(flagged == unflagged)
        #expect(flagged != .preparing)
        #expect(flagged != .preparing)
    }

    /// The two new parameters default, so every pre-existing call site — none of which know they
    /// exist — derives what it always did.
    @Test func omittingTheNewParametersMatchesTheOldSignature() {
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
        #expect(omitted == .transferWaiting(number: 3, torHold: false))
    }
}
