//
//  MigrationBannerNamesTests.swift
//  zodlTests
//
//  WHICH transfer the banner names — "Transfer N is waiting", "Transfer N is ready" (MOB-1466).
//
//  WHY THIS SUITE EXISTS, and why it is a different bug class from every other two-surface
//  disagreement in this pass. From ONE field log line:
//
//      BANNER → transferWaiting(number: 4)
//      ROWS: T1:done T2:done T3:done T4:broadcast T5:ready …
//
//  The timeline captioned T4 "Sent recently", off that same row's `isBroadcasting`. The banner
//  asked the user to send a transaction that was already on the network.
//
//  Every earlier disagreement was TWO CLOCKS: the same question answered at different moments, and
//  `MigrationViewSnapshot` fixed those by construction. This one is TWO VOCABULARIES. Both surfaces
//  read the same row, in the same pass, from the single source — and still contradicted each other,
//  because `nextTransferNumber` recognised two row states (sent / not sent) while the row model has
//  three: sent, SUBMITTED-AWAITING-MINING, and actually waiting on the user. A submitted row is
//  `.active`, so the two-state reading swept it up as "next".
//
//  One source of truth guarantees the readers see the same DATA. It cannot make them draw the same
//  CONCLUSION — that takes the derived judgment being shared too, not just the fields it is
//  computed from. These tests pin the judgment.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationBannerNamesTests {
    private static func progress(completed: Int, total: Int) -> MigrationProgress {
        MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchard: Zatoshi(500_000_000),
            nextTransferReadyAtHeight: 3_000_000,
            isImmediate: false
        )
    }

    private static func row(
        index: Int,
        status: MigrationTransferRow.Status,
        isBroadcasting: Bool = false
    ) -> MigrationTransferRow {
        MigrationTransferRow(
            id: "\(index)",
            index: index,
            amount: Zatoshi(100_000_000),
            status: status,
            hoursFromNow: 0,
            isBroadcasting: isBroadcasting
        )
    }

    private static func variant(
        completed: Int,
        total: Int,
        rows: [MigrationTransferRow],
        hasOverdue: Bool = false,
        isManualDelivery: Bool = false,
        isNextTransferDue: Bool = false
    ) -> MigrationBannerVariant? {
        MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: .inProgress(progress(completed: completed, total: total)),
            hasOverdue: hasOverdue,
            isManualDelivery: isManualDelivery,
            isNextTransferDue: isNextTransferDue,
            orchardBalance: Zatoshi(500_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: rows
        )
    }

    /// THE FIELD CASE. T4 is on the wire; T5 is the first transfer actually waiting on the user.
    @Test func aBroadcastTransferIsNeverTheOneTheBannerNames() {
        let variant = Self.variant(
            completed: 3,
            total: 12,
            rows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .sent),
                Self.row(index: 2, status: .sent),
                Self.row(index: 3, status: .active, isBroadcasting: true),
                Self.row(index: 4, status: .active),
                Self.row(index: 5, status: .pending)
            ],
            hasOverdue: true
        )

        #expect(variant == .transferWaiting(number: 5, torHold: false))
    }

    /// The same rule for the manual-delivery prompt: never offer to send what has already gone out.
    @Test func aBroadcastTransferIsNeverTheOneOfferedAsReady() {
        let variant = Self.variant(
            completed: 1,
            total: 4,
            rows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .active, isBroadcasting: true),
                Self.row(index: 2, status: .active),
                Self.row(index: 3, status: .pending)
            ],
            isManualDelivery: true,
            isNextTransferDue: true
        )

        #expect(variant == .transferReady(number: 3))
    }

    /// Nothing left for the user — every remaining transfer is sent or in flight. The number falls
    /// back to the progress count rather than naming a transfer that needs nothing from anyone.
    @Test func allRemainingInFlightFallsBackToTheProgressCount() {
        let variant = Self.variant(
            completed: 2,
            total: 3,
            rows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .sent),
                Self.row(index: 2, status: .active, isBroadcasting: true)
            ],
            hasOverdue: true
        )

        #expect(variant == .transferWaiting(number: 3, torHold: false))
    }

    /// The ordinary case still names the first unsent row — this must not have been broken by the
    /// skip.
    @Test func withNothingInFlightTheFirstUnsentRowIsNamed() {
        let variant = Self.variant(
            completed: 1,
            total: 4,
            rows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .active),
                Self.row(index: 2, status: .pending),
                Self.row(index: 3, status: .pending)
            ],
            hasOverdue: true
        )

        #expect(variant == .transferWaiting(number: 2, torHold: false))
    }
}
