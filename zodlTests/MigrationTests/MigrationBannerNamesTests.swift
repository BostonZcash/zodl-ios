//
//  MigrationBannerNamesTests.swift
//  zodlTests
//
//  WHICH transfer the banner names — "Transfer N is ready" / "Transfer N is sending" (MOB-1466;
//  the waiting flavor retired with THE BANNER MAP, 2026-08-06 — the naming judgment these pin
//  survives on the remaining per-transfer arms). (the `.transferReady` pins were removed
//  2026-08-07 with the manual-tap send surface)
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
        rows: [MigrationTransferRow]
    ) -> MigrationBannerVariant? {
        MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: .inProgress(progress(completed: completed, total: total)),
            orchardBalance: Zatoshi(500_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: rows
        )
    }
}
