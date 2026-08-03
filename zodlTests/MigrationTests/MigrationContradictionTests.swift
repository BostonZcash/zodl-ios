//
//  MigrationContradictionTests.swift
//  zodlTests
//
//  GROUND_RULES R4: the smart banner and the migration screen must never contradict each other.
//  Five of last week's eight field bugs were exactly that — two surfaces disagreeing about one
//  state — and not one of the existing 972 tests compared two surfaces to catch any of them. Every
//  other Migration*Tests file pins ONE surface's answer for ONE crafted input; this suite is the
//  missing class, at the pure-derivation layer: given a GENERATED matrix of row sets, does
//  `MigrationDerivations.bannerVariant` — the banner's pure derivation — stay consistent with the
//  very rows the timeline renders, across as many shapes as a bounded matrix can cheaply cover,
//  rather than only the one shape a field report happened to catch.
//
//  Each test below is an INVARIANT, not a pinned answer: a property that must hold for every row
//  set its matrix generates, stated once and checked hundreds of times instead of asserted on one
//  hand-picked example. A regression that breaks the property fails somewhere in the matrix even if
//  the exact input that would have shipped the bug was never imagined by hand. `bannerVariant` is
//  sync and pure, so the whole matrix runs with no async, no TestStore, and no mocked dependency —
//  every generated case here is under 600 total `bannerVariant` calls, so the suite still runs in
//  milliseconds.
//

import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationContradictionTests {
    // MARK: - Fixtures (mirrors MigrationBannerRowTruthTests' helper shapes)

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
        isPreparing: Bool = false
    ) -> MigrationTransferRow {
        MigrationTransferRow(
            id: "\(index)",
            index: index,
            amount: Zatoshi(100_000_000),
            status: status,
            hoursFromNow: 0,
            isBroadcasting: isBroadcasting,
            isPreparing: isPreparing
        )
    }

    private static func variant(
        state: MigrationState,
        transferRows: [MigrationTransferRow],
        preparationRows: [MigrationTransferRow] = [],
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
            transferRows: transferRows,
            preparationRows: preparationRows,
            isBroadcastInFlight: isBroadcastInFlight
        )
    }

    /// Extracts the transfer number out of whichever of the two per-transfer "actionable" variants
    /// carries one — the two cases invariant 1 polices — or `nil` for every other variant.
    private static func actionableNumber(_ variant: MigrationBannerVariant?) -> Int? {
        guard let variant else { return nil }
        if case let .transferWaiting(number, _) = variant {
            return number
        }
        if case let .transferReady(number) = variant {
            return number
        }
        return nil
    }

    /// True iff `variant` is `.transferSending`, for ANY number — invariant 2 needs this because
    /// `!= .transferSending(number: 1)` would say nothing about every other number.
    private static func isTransferSending(_ variant: MigrationBannerVariant?) -> Bool {
        guard let variant else { return false }
        if case .transferSending = variant {
            return true
        }
        return false
    }

    /// One row's (status, isPreparing) shape for invariant 3's matrix — every status the row model
    /// has, each both preparing and not. No `(.sent, true)`: a mined row is never preparing (see
    /// `MigrationTransferRow.isPreparing`'s doc), so that combination is not one the real derivation
    /// rows can produce.
    private static let preparingRowShapes: [(status: MigrationTransferRow.Status, isPreparing: Bool)] = [
        (.sent, false),
        (.active, false),
        (.active, true),
        (.overdue, false),
        (.overdue, true),
        (.pending, false),
        (.pending, true)
    ]

    /// Builds one row set for `bannerNeverNamesANonActionableTransfer`: a sent prefix, an overdue
    /// row at `overdueIndex`, and every other row `.active` — broadcasting exactly the positions in
    /// `broadcasting` (always a subset of the non-sent, non-overdue rows, matching how the app only
    /// ever marks an `.active` row `isBroadcasting`; see `MigrationTransferRow.isBroadcasting`'s
    /// doc — "same `.active` badge as a merely-queued row").
    private static func matrixRows(
        count: Int,
        sentPrefix: Int,
        overdueIndex: Int,
        broadcasting: Set<Int>
    ) -> [MigrationTransferRow] {
        (0..<count).map { i in
            if i < sentPrefix {
                return Self.row(index: i, status: .sent)
            }
            if i == overdueIndex {
                return Self.row(index: i, status: .overdue)
            }
            return Self.row(index: i, status: .active, isBroadcasting: broadcasting.contains(i))
        }
    }

    /// `sentCount` sent rows followed by non-sent rows (never preparing, never broadcasting, so the
    /// branch stays on the idle `.inProgress` rendering) for `progressCountsEqualTheRowTruth`'s
    /// matrix — the row list `progress` is built to match.
    private static func progressMatrixRows(count: Int, sentCount: Int) -> [MigrationTransferRow] {
        let nonSentStatuses: [MigrationTransferRow.Status] = [.active, .pending, .overdue]
        return (0..<count).map { i in
            if i < sentCount {
                return Self.row(index: i, status: .sent)
            }
            return Self.row(index: i, status: nonSentStatuses[i % nonSentStatuses.count])
        }
    }

    /// Rows `[first, last]` (0-based, inclusive) marked `.expired` for
    /// `expiredBoundsNameRealExpiredRows`'s matrix; every other row `.active`.
    private static func expiredRunRows(count: Int, first: Int, last: Int) -> [MigrationTransferRow] {
        (0..<count).map { i in
            let status: MigrationTransferRow.Status = (first...last).contains(i) ? .expired : .active
            return Self.row(index: i, status: status)
        }
    }

    /// One (transferRows, preparationRows) case of `preparingBannerMatchesInFlightRows`'s matrix.
    /// `progress` is built FROM `transferRows` (completed = sent count, total = row count) so the
    /// banner and the row truth are never disagreeing about the input by construction — only about
    /// what `bannerVariant` derives from it.
    private static func assertPreparingInvariant(
        transferRows: [MigrationTransferRow],
        preparationRows: [MigrationTransferRow]
    ) {
        let sentCount = transferRows.filter { $0.status == .sent }.count
        let transferShapes = String(describing: transferRows.map { ($0.status, $0.isPreparing) })
        let preparationShapes = String(describing: preparationRows.map { ($0.status, $0.isPreparing) })
        let context = "transferRows=\(transferShapes) preparationRows=\(preparationShapes)"

        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: sentCount, total: transferRows.count)),
            transferRows: transferRows,
            preparationRows: preparationRows,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            isBroadcastInFlight: false
        )

        // The mirror of `MigrationTransferRow.isInFlight`, restricted to `isSubmitting == false` —
        // every row this matrix builds holds that (the matrix never sets `isSubmitting`), so this
        // predicate and `isInFlight` agree exactly for every row generated here.
        let anyRowInFlight = (transferRows + preparationRows).contains {
            $0.isPreparing && ($0.status == .active || $0.status == .overdue)
        }

        if variant == .preparing {
            #expect(anyRowInFlight, "banner is .preparing with no row actually in flight: \(context)")
        }
        if !anyRowInFlight {
            #expect(
                variant == .inProgress(done: sentCount, total: transferRows.count, round: nil, totalRounds: nil),
                "expected the idle progress rendering, got \(String(describing: variant)): \(context)"
            )
            #expect(variant != .preparing, "spinner with no counterpart: \(context)")
        }
    }

    // MARK: - Invariant 1: the named transfer is always the one the user can act on

    /// THE field case this whole suite exists to generalise (MOB-1466, see
    /// `MigrationBannerNamesTests`): a run where `BANNER -> transferWaiting(number: 4)` while
    /// `ROWS: … T4:broadcast T5:ready …` — the banner asked the user to send a transaction already
    /// on the wire, because `nextTransferNumber` only recognised "sent / not sent" while a row can
    /// also be broadcast-and-unmined. Rather than pin that one shape, this generates a bounded
    /// matrix of row sets — 3..6 rows, an overdue row at every position, every sent-prefix length
    /// that position allows, and 0/1/2 broadcasting rows ahead of it — and checks the GENERAL
    /// property the fix promised: whichever transfer `.transferWaiting`/`.transferReady` names,
    /// that row exists and is genuinely actionable (not sent, not already broadcasting).
    @Test func bannerNeverNamesANonActionableTransfer() {
        for count in 3...6 {
            for overdueIndex in 0..<count {
                for sentPrefix in 0...overdueIndex {
                    let eligible = (sentPrefix..<count).filter { $0 != overdueIndex }
                    for broadcastCount in 0...min(2, eligible.count) {
                        let broadcasting = Set(eligible.prefix(broadcastCount))
                        let rows = Self.matrixRows(
                            count: count,
                            sentPrefix: sentPrefix,
                            overdueIndex: overdueIndex,
                            broadcasting: broadcasting
                        )

                        let variant = Self.variant(
                            state: .inProgress(Self.progress(completed: sentPrefix, total: count)),
                            transferRows: rows,
                            hasOverdue: true
                        )

                        if let number = Self.actionableNumber(variant) {
                            let sortedBroadcasting = broadcasting.sorted()
                            let context = "count=\(count) overdue=\(overdueIndex) sentPrefix=\(sentPrefix) broadcasting=\(sortedBroadcasting) number=\(number)"

                            #expect(rows.indices.contains(number - 1), "no such row: \(context)")
                            if rows.indices.contains(number - 1) {
                                #expect(rows[number - 1].status != .sent, "named a sent row: \(context)")
                                #expect(!rows[number - 1].isBroadcasting, "named a broadcasting row: \(context)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Invariant 2: the keep-open ask is gated on the in-session flag alone

    /// Field-caught 2026-08-01 (`MigrationBannerRowTruthTests.aBroadcastRowAloneDoesNotAskTheUserToStay`):
    /// a durable `.broadcast(txid:)` row alone used to raise `.transferSending`, asking the user to
    /// keep the app open for a submission that had already returned success — the tester watched
    /// three minutes of that and read it as a hang ("there is never ending sending of split 1").
    /// `.transferSending` may only come from the in-session `isBroadcastInFlight` flag, never from
    /// row content. This iterates a matrix of states and row shapes — including broadcasting and
    /// preparing rows, exactly the row content that used to leak through — all with the flag held
    /// `false`, and checks `.transferSending` is never produced by any of them.
    @Test func sendingBannerRequiresInFlightContext() {
        let states: [MigrationState] = [
            .notStarted,
            .splitPendingConfirmation,
            .inProgress(Self.progress(completed: 0, total: 6)),
            .inProgress(Self.progress(completed: 0, total: 1, isImmediate: true)),
            .requiresAttention(.invalidTransfer),
            .requiresAttention(.transferExpired),
            .complete
        ]
        let rowConfigs: [[MigrationTransferRow]] = [
            [],
            [Self.row(index: 0, status: .active)],
            [Self.row(index: 0, status: .active, isBroadcasting: true)],
            [Self.row(index: 0, status: .active, isPreparing: true)],
            [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .overdue),
                Self.row(index: 2, status: .active, isBroadcasting: true)
            ]
        ]
        let flagCombos: [(hasOverdue: Bool, isManualDelivery: Bool, isNextTransferDue: Bool)] = [
            (false, false, false),
            (true, false, false),
            (false, true, true)
        ]

        for state in states {
            for rows in rowConfigs {
                for flags in flagCombos {
                    let variant = Self.variant(
                        state: state,
                        transferRows: rows,
                        hasOverdue: flags.hasOverdue,
                        isManualDelivery: flags.isManualDelivery,
                        isNextTransferDue: flags.isNextTransferDue,
                        isBroadcastInFlight: false
                    )

                    let variantDescription = String(describing: variant)
                    let stateDescription = String(describing: state)
                    let rowStatuses = String(describing: rows.map { $0.status })
                    #expect(
                        !Self.isTransferSending(variant),
                        "isBroadcastInFlight was false but got \(variantDescription) for state=\(stateDescription) rows=\(rowStatuses)"
                    )
                }
            }
        }
    }

    // MARK: - Invariant 3: the keep-open spinner never runs without a row that is actually spinning

    /// Guards the spinner-with-no-counterpart class both halves of this pass hit: the overnight
    /// stall (twelve rows the engine called provable, banner spinning, `prove sweeps 0`) and its
    /// mirror, the merely-provable-but-not-due rows that flipped a whole run's banner to
    /// `.preparing` although nothing the user was waiting on was actually blocked (see
    /// `MigrationBannerRowTruthTests.aPendingRowThatIsMerelyProvableDoesNotClaimTheRunIsPreparing`).
    /// Scoped to `.inProgress` with `hasOverdue`/`isManualDelivery`/`isBroadcastInFlight` held
    /// false throughout, so the production branch has exactly two possible answers and the row
    /// predicate below is the exact mirror of `MigrationTransferRow.isInFlight` under that
    /// restriction: `.preparing` if and only if some row (transfer OR preparation) is `isPreparing`
    /// on a row whose own window is open or past (`.active`/`.overdue`) — never a merely-provable
    /// `.pending` row, never `.sent`.
    @Test func preparingBannerMatchesInFlightRows() {
        let preparationOptions: [[MigrationTransferRow]] = [
            [],
            [Self.row(index: 0, status: .active, isPreparing: true)],
            [Self.row(index: 0, status: .active, isPreparing: false)],
            [Self.row(index: 0, status: .pending, isPreparing: true)]
        ]

        for shape1 in Self.preparingRowShapes {
            for preparationRows in preparationOptions {
                Self.assertPreparingInvariant(
                    transferRows: [Self.row(index: 0, status: shape1.status, isPreparing: shape1.isPreparing)],
                    preparationRows: preparationRows
                )
            }

            for shape2 in Self.preparingRowShapes {
                for preparationRows in preparationOptions {
                    Self.assertPreparingInvariant(
                        transferRows: [
                            Self.row(index: 0, status: shape1.status, isPreparing: shape1.isPreparing),
                            Self.row(index: 1, status: shape2.status, isPreparing: shape2.isPreparing)
                        ],
                        preparationRows: preparationRows
                    )
                }
            }
        }
    }

    // MARK: - Invariant 4: the progress counts never drift from the rows

    /// Guards the drift `MigrationBannerRowTruthTests` was written for: "transfer 1 has been done,
    /// transfer 2 ready but smart widget still writes transfer 1" — the banner's `done`/`total` come
    /// from `MigrationProgress` (a MINED count), the timeline's from row positions, and the two used
    /// to disagree for the entire window between a transfer's broadcast and its mine. Fixed at the
    /// source (the idle `.inProgress` case's counts ARE `progress.completedTransfers`/`totalTransfers`,
    /// verbatim); this pins that identity, and — by constructing `progress` FROM the same rows a
    /// timeline would render (completed = sent count, total = row count) — pins that the two
    /// readings never disagree when they are built from the one set of facts a real run would have
    /// produced them from.
    @Test func progressCountsEqualTheRowTruth() {
        for count in 0...6 {
            for sentCount in 0...count {
                let rows = Self.progressMatrixRows(count: count, sentCount: sentCount)
                let progress = Self.progress(completed: sentCount, total: count)

                let maybeVariant = Self.variant(
                    state: .inProgress(progress),
                    transferRows: rows,
                    hasOverdue: false,
                    isManualDelivery: false,
                    isNextTransferDue: false,
                    isBroadcastInFlight: false
                )

                guard let variant = maybeVariant, case let .inProgress(done, total, _, _) = variant else {
                    let maybeVariantDescription = String(describing: maybeVariant)
                    Issue.record("expected .inProgress for count=\(count) sentCount=\(sentCount), got \(maybeVariantDescription)")
                    continue
                }

                #expect(done == progress.completedTransfers)
                #expect(total == progress.totalTransfers)

                let sentRowCount = rows.filter { $0.status == .sent }.count
                #expect(done == sentRowCount, "count=\(count) sentCount=\(sentCount)")
                #expect(total == rows.count, "count=\(count) sentCount=\(sentCount)")
            }
        }
    }

    // MARK: - Invariant 5: the expired banner's bounds name the rows actually marked expired

    /// `.transfersExpired(first:last:)` and the recovery timeline both read `transferRows`, but
    /// nothing before this pinned that the banner's printed bounds are the SAME rows the screen
    /// marks `.expired` — a first/last drawn from the wrong rows would send the user looking for
    /// "Transfers 2-4" against a timeline where a different span is highlighted. Matrix over every
    /// contiguous expired run `[first, last]` a 3..7-row list can hold; asserts the pure
    /// `expiredBounds` behaviour only through `bannerVariant`'s public return value, per MOB-1466
    /// spec — `expiredBounds` itself is a private implementation detail of `MigrationDerivations`.
    @Test func expiredBoundsNameRealExpiredRows() {
        for count in 3...7 {
            for first in 0..<count {
                for last in first..<count {
                    let rows = Self.expiredRunRows(count: count, first: first, last: last)

                    let variant = Self.variant(
                        state: .requiresAttention(.transferExpired),
                        transferRows: rows
                    )

                    #expect(
                        variant == .transfersExpired(first: first + 1, last: last + 1),
                        "count=\(count) first=\(first) last=\(last) got \(String(describing: variant))"
                    )
                }
            }
        }
    }

    // MARK: - Invariant 6: the unknown state commits to no progress claim

    /// MOB-1466 (staleness pass): `.checkingStatus` exists because the app does not yet know the
    /// world's state — it must not draw a progress ring's completion fraction over that admission.
    /// `MigrationCheckingStatusTests.checkingClaimsNoProgressFraction` already pins this fact
    /// against title/info churn in `.checkingStatus`'s own suite, while GROUND_RULES D1/D2's copy
    /// slot fix is mid-flight there (see that file's uncommitted diff moving `.checkingStatus`
    /// on to the shared "Migration Progress" title). This pins the same fact again at the
    /// contradiction layer: a stray `percent` would be exactly the kind of cross-surface claim
    /// (a ring implying progress the app has not established) this suite exists to catch.
    @Test func checkingClaimsNothing() {
        #expect(MigrationBannerVariant.checkingStatus.percent == nil)
    }
}
