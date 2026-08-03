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
        activeBroadcastTxId: UInt32? = nil,
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
            isBroadcastInFlight: isBroadcastInFlight,
            activeBroadcastTxId: activeBroadcastTxId
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

    /// GROUND_RULES D6: the NUMBER is the id the session is ACTUALLY submitting, carried from the
    /// manager's own record — never inferred from `isBroadcasting` rows. The old inference named
    /// the PREVIOUS transfer whenever one was still broadcast-but-unmined while a new one went out
    /// (field: "T8 is sending..." during T9's submit). Here the active id names row index 1 and the
    /// banner says Transfer 2 — where the mined count would have said 1, and the old row inference
    /// would have too if an earlier unmined broadcast were present.
    @Test func theSendingNumberIsTheSessionsOwnId() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .active, isBroadcasting: true)
            ],
            isBroadcastInFlight: true,
            activeBroadcastTxId: 1
        )
        #expect(variant == .transferSending(number: 2), "the mined count would have said Transfer 1")
    }

    /// THE FIELD CASE, pinned: T8 broadcast-but-unmined from the previous window, T9 submitting
    /// NOW. Two rows on the wire; the banner names the session's own (T9), not the older one the
    /// row inference used to pick.
    @Test func aPreviousUnminedBroadcastDoesNotStealTheSendingNumber() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 7, total: 12)),
            transferRows: [
                Self.row(index: 7, status: .active, isBroadcasting: true),
                Self.row(index: 8, status: .active, isBroadcasting: true)
            ],
            isBroadcastInFlight: true,
            activeBroadcastTxId: 8
        )
        #expect(variant == .transferSending(number: 9), "must name T9 (the session's id), not the unmined T8")
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
    /// the delivery is the more specific truth. D6: the number comes from the session's active id.
    @Test func sendingBeatsPreparing() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .active, isBroadcasting: true),
                Self.row(index: 1, status: .pending, isPreparing: true)
            ],
            isBroadcastInFlight: true,
            activeBroadcastTxId: 0
        )
        #expect(variant == .transferSending(number: 1))
    }

    /// Preparing is RUN-level and plural: one prove sweep proves the whole run, and Figma C5 shows
    /// two transfers preparing at once. Any BLOCKED provable row raises it, wherever it sits — the
    /// second row here, not the first.
    @Test func preparingIsRaisedByAnyRowNotJustTheFirst() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .active),
                Self.row(index: 1, status: .overdue, isPreparing: true)
            ]
        )
        #expect(variant == .preparing)
    }

    /// …but a PENDING row that merely happens to be provable does NOT raise it, and this is the
    /// half the field had to teach us (2026-08-02, session s2).
    ///
    /// `isPreparing` means "the engine COULD prove this one". Provability is gated on each
    /// transfer's own anchor boundary, drawn on a jittered grid, so it fires for rows whose send
    /// window is still ten minutes out. Four such rows flipped a whole run's banner to "preparing":
    ///
    ///     BANNER: (first) → preparing · why: the prove sweep will run this session
    ///     ROWS:   … T7:preparing T8:preparing T9:preparing T10:preparing T11:~11m
    ///     ══ BACKGROUND — prove sweeps 0 · syncs completed 0
    ///
    /// The sweep did not run and could not: `start()` had been refused by the privacy gate, so
    /// there was no sync, no sync-complete edge, and no `advance(.afterSync)`. Forty-eight seconds
    /// of a banner promising imminent work over a session that did nothing.
    ///
    /// A run is only "preparing" when a row the user is actually waiting on cannot move for want of
    /// its proof. Everything else is progress.
    @Test func aPendingRowThatIsMerelyProvableDoesNotClaimTheRunIsPreparing() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .active),
                Self.row(index: 1, status: .pending, isPreparing: true),
                Self.row(index: 2, status: .pending, isPreparing: true)
            ]
        )

        #expect(variant != .preparing)
        #expect(variant == .inProgress(done: 0, total: 6, round: nil, totalRounds: nil))
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

    /// Nothing in flight, nothing due: GROUND_RULES D2 — the idle subtitle is the COUNTS family the
    /// design draws (Figma 33226 "0 of 6 transfers done · 0% complete", 34962 "1 of 6 ~ 16%"). The
    /// earlier assertion pinned "We'll notify you when to send" — copy from ONE frame (35439) — as
    /// the universal idle line; the full-canvas walk showed counts is the default and the notify
    /// line is a distinct designed state whose trigger rule is open with Andrea
    /// (`migrationBanner.idleInfo` stays in the catalog for it).
    @Test func anIdleRunReadsAsProgressWithTheCountsLine() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 1, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .pending)
            ]
        )
        #expect(variant == .inProgress(done: 1, total: 6, round: nil, totalRounds: nil))
        #expect(variant?.info == String(localizable: .migrationBannerProgressCountsInfo(1, 6, 16)))
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

// MARK: - The stall verdict

/// MOB-1466, field-caught 2026-08-02 on an overnight run.
///
/// Twelve transfers all reported `blocked -` — nil, i.e. the engine saying "actionable now" — with
/// anchors ~800 blocks BEHIND the scanned tip, and every prove sweep produced zero. The app showed
/// twelve "Preparing transaction…" spinners and a "Keep Zodl open on active phone screen" banner,
/// and the tester sat there for minutes because that is what it asked for.
///
/// The rule these pin: THE APP MAY ONLY ASK THE USER TO STAY FOR WORK THAT IS ACTUALLY HAPPENING.
/// The engine's readiness verdict is necessary but not sufficient — once sweeps have demonstrably
/// produced nothing against that verdict, the claim is revoked, because a spinner over stopped work
/// spends the credibility every future keep-open ask depends on.
@Suite struct MigrationProveStallTests {
    private static let clock = MigrationChainClock(tip: 3_000_000)

    private static func provable(id: UInt32, crossing: Int) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: .transfer(crossing: crossing),
            state: .signed,
            scheduledHeight: 2_999_000,
            expiryHeight: nil,
            isReady: true,
            nextAction: .prove,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: 2_998_000
        )
    }

    /// The engine's verdict alone still drives the caption while proving is working.
    @Test func aProvableRowPreparesWhileProvingWorks() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.provable(id: 1, crossing: 0)],
            clock: Self.clock,
            isProvingStalled: false
        )
        #expect(rows?[0].isPreparing == true)
        #expect(rows?[0].isInFlight == true, "the spinner is on")
    }

    /// And is revoked once the app has watched proving produce nothing. Same engine answer, same
    /// row — different claim, because the claim was about US, not about the engine.
    @Test func aStalledSweepRevokesTheClaim() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.provable(id: 1, crossing: 0)],
            clock: Self.clock,
            isProvingStalled: true
        )
        #expect(rows?[0].isPreparing == false)
        #expect(rows?[0].isInFlight == false, "no spinner over work that is not happening")
    }

    /// Which is what drops the banner's keep-open ask: `.preparing` derives from the rows, so
    /// revoking the row flag revokes the ask with it — no separate gate to keep in step.
    @Test func aStalledSweepDropsTheKeepOpenBanner() {
        let stalledRows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.provable(id: 1, crossing: 0)],
            clock: Self.clock,
            isProvingStalled: true
        ) ?? []

        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: .inProgress(
                MigrationProgress(
                    completedTransfers: 0,
                    totalTransfers: 12,
                    remainingOrchard: Zatoshi(9_999_760_000),
                    nextTransferReadyAtHeight: 2_999_000,
                    isImmediate: false
                )
            ),
            hasOverdue: true,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi(9_999_760_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: stalledRows
        )

        #expect(variant != .preparing, "never ask the user to stay for a sweep that produces nothing")
        #expect(variant == .transferWaiting(number: 1, torHold: false))
    }

    /// The preparation rows take the same verdict — the split phase is where the first overnight
    /// stall was seen, and its banner asks for the same thing.
    @Test func preparationRowsTakeTheSameVerdict() {
        let statuses = [
            MigrationTransactionStatus(
                id: 0,
                kind: .preparation(layer: 0, index: 0),
                state: .signed,
                scheduledHeight: 2_999_000,
                expiryHeight: nil,
                isReady: true,
                nextAction: .prove,
                blockedOn: nil,
                dependsOn: [],
                anchorBoundaryHeight: nil
            )
        ]
        #expect(MigrationDerivations.preparationRows(statuses: statuses, clock: Self.clock, isProvingStalled: false)?[0].isPreparing == true)
        #expect(MigrationDerivations.preparationRows(statuses: statuses, clock: Self.clock, isProvingStalled: true)?[0].isPreparing == false)
    }
}
