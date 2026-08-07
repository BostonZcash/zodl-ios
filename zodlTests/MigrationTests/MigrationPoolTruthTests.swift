//
//  MigrationPoolTruthTests.swift
//  zodlTests
//
//  R13 Brick 1 (GROUND_RULES R13, ratified 2026-08-03): the loader's first canonical query — the
//  in-flight pool correction that makes the header's bubbles render R11's standard: as if every
//  migration transaction not wallet-mined never happened.
//
//  MOB-1661 pins the current SDK's store-at-broadcast boundary. Proving only advisory-locks the
//  Orchard inputs; it does not move wallet balance between pools. Treating `.proved` as stored made
//  the app add every proved transfer to Orchard while clamping an empty Ironwood subtraction,
//  producing the field report's 174.51665 pool subtotal over a 99.99665 wallet total.
//
//  The structural claim the rest pin: the correction derives from the SAME row set the checkmarks
//  render, keyed by the engine's stable id, and both bubbles move by the same figure — so a green
//  checkmark and its value arrive in the same derivation, and the header can never say "migrated"
//  over a timeline that says otherwise.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationPoolTruthTests {
    // MARK: - Fixtures

    private static func row(
        id: String,
        amount: Zatoshi?,
        status: MigrationTransferRow.Status,
        kind: MigrationTransferRow.Kind = .transfer
    ) -> MigrationTransferRow {
        MigrationTransferRow(
            id: id,
            index: Int(id) ?? 0,
            amount: amount,
            status: status,
            hoursFromNow: 0,
            kind: kind
        )
    }

    private static func status(id: UInt32, state: MigrationTransactionStatus.State) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: .transfer(crossing: Int(id)),
            state: state,
            scheduledHeight: 4_235_000,
            expiryHeight: nil,
            isReady: false,
            nextAction: nil,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    // MARK: - The field bug, replayed

    /// MOB-1661 / build 3.9.0 (6): proved but unbroadcast transfers total 74.57 TAZ. The SDK still
    /// reports all value in Orchard, so the correct adjustment is exactly zero.
    @Test func provedButUnbroadcastTransactionsDoNotCreatePoolSurplus() {
        let rows = [
            Self.row(id: "1", amount: Zatoshi(5_000_000), status: .pending),
            Self.row(id: "2", amount: Zatoshi(200_000_000), status: .pending),
            Self.row(id: "3", amount: Zatoshi(2_000_000), status: .pending),
            Self.row(id: "4", amount: Zatoshi(5_000_000_000), status: .pending),
            Self.row(id: "5", amount: Zatoshi(200_000_000), status: .pending),
            Self.row(id: "6", amount: Zatoshi(2_000_000_000), status: .pending),
            Self.row(id: "7", amount: Zatoshi(50_000_000), status: .pending)
        ]
        let statuses = (1 ... 7).map { Self.status(id: UInt32($0), state: .proved) }

        let correction = MigrationDerivations.inFlightPoolCorrection(rows: rows, statuses: statuses)

        #expect(correction == .none)
    }

    /// Proving advisory-locks source notes. Locked value still belongs to Orchard and must remain
    /// visible in the Migration Progress source bubble until the transaction reaches broadcast.
    @Test func provedAdvisoryLocksRemainInDisplayedOrchardBalance() {
        let unlocked = Zatoshi(2_542_665_000)
        let advisoryLocked = Zatoshi(7_452_000_000)

        let displayed = MigrationDerivations.poolBalancesForDisplay(
            // Production passes `orchardBalance.total()`, which is unlocked + locked.
            orchard: unlocked + advisoryLocked,
            ironwood: .zero,
            correction: .none
        )

        #expect(displayed.orchard == Zatoshi(9_994_665_000))
        #expect(displayed.ironwood == .zero)
    }

    // MARK: - Per-state rules

    /// A wallet-mined (green, `.sent`) transfer is counted by the SDK figure AND belongs there —
    /// no correction, whatever the engine state says.
    @Test func walletMinedContributesNothing() {
        let rows = [Self.row(id: "3", amount: Zatoshi(100_000_000), status: .sent)]
        let statuses = [Self.status(id: 3, state: .mined(height: 4_235_419))]

        #expect(MigrationDerivations.inFlightPoolCorrection(rows: rows, statuses: statuses) == .none)
    }

    /// Broadcast-not-wallet-mined (R11's `.confirming` span) is stored and counted — corrected.
    @Test func confirmingContributes() {
        let rows = [Self.row(id: "4", amount: Zatoshi(100_000_000), status: .confirming)]
        let statuses = [Self.status(id: 4, state: .broadcast(txid: Data(repeating: 0xAB, count: 32)))]

        let correction = MigrationDerivations.inFlightPoolCorrection(rows: rows, statuses: statuses)
        #expect(correction.ironwoodOverstatement == Zatoshi(100_000_000))
    }

    /// ENGINE-mined but not yet in the wallet's own store (the deliberate post-broadcast sync
    /// hold): the row is not `.sent`, the value has not "arrived" by R11's standard — corrected.
    @Test func engineMinedButWalletUnsyncedContributes() {
        let rows = [Self.row(id: "5", amount: Zatoshi(100_000_000), status: .confirming)]
        let statuses = [Self.status(id: 5, state: .mined(height: 4_235_500))]

        let correction = MigrationDerivations.inFlightPoolCorrection(rows: rows, statuses: statuses)
        #expect(correction.ironwoodOverstatement == Zatoshi(100_000_000))
    }

    /// Before broadcast, neither signed nor proved transactions are in wallet pool balances.
    @Test func preBroadcastContributesNothing() {
        let rows = [
            Self.row(id: "6", amount: Zatoshi(100_000_000), status: .pending),
            Self.row(id: "7", amount: Zatoshi(100_000_000), status: .active)
        ]
        let statuses = [
            Self.status(id: 6, state: .awaitingSignature),
            Self.status(id: 7, state: .signed)
        ]

        #expect(MigrationDerivations.inFlightPoolCorrection(rows: rows, statuses: statuses) == .none)
    }

    // MARK: - Degraded-read fallback (statuses == nil)

    /// Cache-served or degraded pass: only `.confirming` rows are KNOWN stored (broadcast, by
    /// construction). A scheduled row that might be proved contributes nothing until the next full
    /// pass — the honest floor, corrected at the post-sweep poke.
    @Test func nilStatusesFallsBackToConfirmingOnly() {
        let rows = [
            Self.row(id: "1", amount: Zatoshi(100_000_000), status: .confirming),
            Self.row(id: "2", amount: Zatoshi(100_000_000), status: .pending)
        ]

        let correction = MigrationDerivations.inFlightPoolCorrection(rows: rows, statuses: nil)
        #expect(correction.ironwoodOverstatement == Zatoshi(100_000_000))
    }

    // MARK: - Exemptions

    /// Splits are intra-Orchard: nothing crosses, so nothing corrects.
    @Test func splitRowsAreExempt() {
        let rows = [Self.row(id: "0", amount: Zatoshi(500_000_000), status: .pending, kind: .splitBalance)]
        let statuses = [Self.status(id: 0, state: .proved)]

        #expect(MigrationDerivations.inFlightPoolCorrection(rows: rows, statuses: statuses) == .none)
    }

    /// An unknown amount (W1 fallback rows) cannot contribute a made-up figure.
    @Test func unknownAmountContributesNothing() {
        let rows = [Self.row(id: "8", amount: nil, status: .confirming)]
        let statuses = [Self.status(id: 8, state: .broadcast(txid: Data(repeating: 0xCD, count: 32)))]

        #expect(MigrationDerivations.inFlightPoolCorrection(rows: rows, statuses: statuses) == .none)
    }

    /// A row with no matching engine status (id join miss) is unknowable — treated as unstored,
    /// never guessed.
    @Test func statusJoinMissContributesNothing() {
        let rows = [Self.row(id: "11", amount: Zatoshi(100_000_000), status: .pending)]
        let statuses = [Self.status(id: 12, state: .proved)]

        #expect(MigrationDerivations.inFlightPoolCorrection(rows: rows, statuses: statuses) == .none)
    }

    // MARK: - Structural invariants

    /// Both bubbles move by the SAME figure — what has not arrived is exactly what has not left.
    /// This is the conservation that lets the header sit over the checkmarks without contradiction.
    @Test func correctionIsSymmetric() {
        let rows = [
            Self.row(id: "1", amount: Zatoshi(150_000_000), status: .confirming),
            Self.row(id: "2", amount: Zatoshi(250_000_000), status: .pending)
        ]
        let statuses = [
            Self.status(id: 1, state: .broadcast(txid: Data(repeating: 0x01, count: 32))),
            Self.status(id: 2, state: .broadcast(txid: Data(repeating: 0x02, count: 32)))
        ]

        let correction = MigrationDerivations.inFlightPoolCorrection(rows: rows, statuses: statuses)
        #expect(correction.ironwoodOverstatement == correction.orchardUnderstatement)
        #expect(correction.ironwoodOverstatement == Zatoshi(400_000_000))
    }

    /// The green flip and the value move are ONE event: the same wallet write that turns a row
    /// `.sent` removes it from the correction set — modeled here as the before/after of a sync.
    @Test func greenFlipAndValueMoveAreOneEvent() {
        let amount = Zatoshi(100_000_000)
        let broadcastTxId = Data(repeating: 0xEE, count: 32)

        let before = MigrationDerivations.inFlightPoolCorrection(
            rows: [Self.row(id: "1", amount: amount, status: .confirming)],
            statuses: [Self.status(id: 1, state: .broadcast(txid: broadcastTxId))]
        )
        let after = MigrationDerivations.inFlightPoolCorrection(
            rows: [Self.row(id: "1", amount: amount, status: .sent)],
            statuses: [Self.status(id: 1, state: .mined(height: 4_235_419))]
        )

        #expect(before.ironwoodOverstatement == amount, "pre-sync: value not yet arrived, bubble corrected")
        #expect(after == .none, "post-sync: green and value arrive together, correction gone")
    }
}
