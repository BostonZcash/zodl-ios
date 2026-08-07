//
//  MigrationSendGateAndArmingTests.swift
//  zodlTests
//
//  MOB-1466 (N1 + N2), field-caught 2026-08-01 on a from-scratch restore.
//
//  Two findings, one shape: THE APP KNOWS WHEN THINGS HAPPENED AND WHEN THEY ARE DUE, AND THE
//  AUTOMATIC LANE DOES NOT ASK.
//
//  N1 — the notification arming derived its send date from `migrationTransfers` alone, which filters
//  to `.transfer`-kind statuses. A note-split PREPARATION's broadcast window contributed nothing.
//  With the run in `splitPendingConfirmation` the arm predicted the first TRANSFER's window — an
//  event that cannot happen until the preparations mine — while preparation 0's window was already
//  open and unpoked. The run moved only because the tester opened the app manually.
//
//  N2 — `runBroadcastSession` broadcast without consulting `sendGate()`. The gate is persisted
//  (`migrationLastSyncCompletedAt`) and therefore CROSS-SESSION by construction, which is the whole
//  point: an observer watching one circuit sees a restore finish and a transfer go out minutes
//  later, and the app having been backgrounded in between hides nothing. Sync→send separation is
//  600 s on mainnet, 180 s on testnet.
//
//  These pin the pure halves — the storage gate's own arithmetic, and the row selection the arm
//  feeds on. The lanes that consume them are integration-shaped and covered by the field sheet.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationSendGateAndArmingTests {
    // MARK: - Fixtures

    private static let clock = MigrationChainClock(tip: 3_000_000)

    private static func storage() -> MigrationGateStorage {
        let suiteName = "MigrationSendGateAndArmingTests.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        return MigrationGateStorage(userDefaults: UserDefaults(suiteName: suiteName)!)
    }

    private static func status(
        id: UInt32,
        kind: MigrationTransactionStatus.Kind,
        state: MigrationTransactionStatus.State,
        scheduledHeight: BlockHeight,
        isReady: Bool = false,
        nextAction: MigrationTransactionStatus.NextAction? = nil
    ) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: kind,
            state: state,
            scheduledHeight: scheduledHeight,
            expiryHeight: nil,
            isReady: isReady,
            nextAction: nextAction,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    /// The arm's own selection rule, extracted verbatim: the earliest row across BOTH lists that
    /// still needs a broadcast.
    private static func nextBroadcast(
        preparations: [MigrationTransferRow],
        transfers: [MigrationTransferRow]
    ) -> MigrationTransferRow? {
        (preparations + transfers)
            .filter { $0.status != MigrationTransferRow.Status.sent && !$0.isBroadcasting }
            // MOB-1466: mirrors the production ordering — a row with no ETA (unknown tip) sorts
            // LAST, so it can never be picked as the soonest.
            .min { ($0.forwardETAMinutes ?? Int.max) < ($1.forwardETAMinutes ?? Int.max) }
    }

    // MARK: - N2: the persisted, cross-session privacy buffer

    /// A fresh wallet that has never completed a sync has nothing to be adjacent TO.
    @Test func aWalletThatNeverSyncedIsAllowedToSend() {
        let gate = Self.storage().sendGate(now: Date(), buffer: 600)
        #expect(gate == .allowed)
    }

    /// THE field sequence, at mainnet's buffer. Restore completes, the app is backgrounded, the user
    /// foregrounds five minutes later and the engine says a broadcast is due. Backgrounding is not
    /// separation: the gate must still hold.
    @Test func aBroadcastFiveMinutesAfterASyncIsHeldOnMainnet() {
        let storage = Self.storage()
        let syncedAt = Date(timeIntervalSince1970: 1_000_000)
        storage.recordSyncCompleted(at: syncedAt)

        let gate = storage.sendGate(now: syncedAt.addingTimeInterval(300), buffer: 600)
        #expect(gate == .waitUntil(syncedAt.addingTimeInterval(600)))
    }

    /// The same sequence on testnet cleared by two minutes — which is why the field run showed no
    /// violation and is exactly why it was not evidence of correctness.
    @Test func theSameSequenceClearsOnTestnetsShorterBuffer() {
        let storage = Self.storage()
        let syncedAt = Date(timeIntervalSince1970: 1_000_000)
        storage.recordSyncCompleted(at: syncedAt)

        #expect(storage.sendGate(now: syncedAt.addingTimeInterval(300), buffer: 180) == .allowed)
    }

    /// The gate opens at the boundary, not after it.
    @Test func theGateOpensExactlyAtTheBuffersExpiry() {
        let storage = Self.storage()
        let syncedAt = Date(timeIntervalSince1970: 1_000_000)
        storage.recordSyncCompleted(at: syncedAt)

        #expect(storage.sendGate(now: syncedAt.addingTimeInterval(599), buffer: 600) != .allowed)
        #expect(storage.sendGate(now: syncedAt.addingTimeInterval(600), buffer: 600) == .allowed)
    }

    /// The stamp is a plain UserDefaults write, so it outlives the process — the property the whole
    /// finding turns on. A gate that only remembered the current session would have answered
    /// "allowed" to the field sequence and been useless.
    @Test func theStampSurvivesAFreshStorageInstance() {
        let suiteName = "MigrationSendGateAndArmingTests.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suiteName)!
        let syncedAt = Date(timeIntervalSince1970: 1_000_000)

        MigrationGateStorage(userDefaults: defaults).recordSyncCompleted(at: syncedAt)

        let reread = MigrationGateStorage(userDefaults: defaults)
        #expect(reread.sendGate(now: syncedAt.addingTimeInterval(60), buffer: 600) == .waitUntil(syncedAt.addingTimeInterval(600)))
    }

    // MARK: - N1: the arm sees the whole run

    /// THE field case. The run is in the split phase: preparation 0's window is open now, the first
    /// transfer's is nearly an hour out and cannot happen until the preparations mine. Arming off
    /// transfers alone pointed at the wrong one.
    @Test func aPreparationsWindowWinsOverALaterTransfersWindow() {
        let preparations = MigrationDerivations.preparationRows(
            statuses: [Self.status(id: 0, kind: .preparation(layer: 0, index: 0), state: .proved, scheduledHeight: 3_000_000)],
            clock: Self.clock
        ) ?? []
        let transfers = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .proved, scheduledHeight: 3_000_100)],
            clock: Self.clock
        ) ?? []

        let next = Self.nextBroadcast(preparations: preparations, transfers: transfers)
        #expect(next?.kind == .splitBalance, "the preparation is what is actually due")
        #expect(next?.forwardETAMinutes == 0)
    }

    /// Once the preparations have mined, the transfer is the next broadcast again — the fix widens
    /// what the arm can see, it does not make preparations win forever.
    @Test func aMinedPreparationYieldsToTheTransfer() {
        let preparations = MigrationDerivations.preparationRows(
            statuses: [
                Self.status(id: 0, kind: .preparation(layer: 0, index: 0), state: .mined(height: 2_999_900), scheduledHeight: 3_000_000)
            ],
            clock: Self.clock
        ) ?? []
        let transfers = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .proved, scheduledHeight: 3_000_100)],
            clock: Self.clock
        ) ?? []

        #expect(Self.nextBroadcast(preparations: preparations, transfers: transfers)?.kind == .transfer)
    }

    /// A row already on the wire needs no send window. Without this clause its ETA — which has by
    /// definition passed — makes it the earliest "pending" row, and the arm schedules a poke one
    /// notification-buffer later for work that is already done.
    @Test func aBroadcastingRowIsNotSomethingToPokeAbout() {
        let preparations = MigrationDerivations.preparationRows(
            statuses: [
                Self.status(id: 0, kind: .preparation(layer: 0, index: 0), state: .broadcast(txid: Data([1])), scheduledHeight: 2_999_000)
            ],
            clock: Self.clock
        ) ?? []
        let transfers = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .proved, scheduledHeight: 3_000_100)],
            clock: Self.clock
        ) ?? []

        let next = Self.nextBroadcast(preparations: preparations, transfers: transfers)
        #expect(next?.kind == .transfer, "the in-flight preparation must not win on its elapsed window")
    }

    /// Nothing left to broadcast is a real answer — the arm retires the poke rather than leaving a
    /// stale one pointing at a finished run.
    @Test func aFullyMinedRunHasNothingToPokeAbout() {
        let preparations = MigrationDerivations.preparationRows(
            statuses: [
                Self.status(id: 0, kind: .preparation(layer: 0, index: 0), state: .mined(height: 2_999_900), scheduledHeight: 3_000_000)
            ],
            clock: Self.clock
        ) ?? []
        let transfers = MigrationDerivations.statusOnlyTransferRows(
            statuses: [
                Self.status(id: 1, kind: .transfer(crossing: 0), state: .mined(height: 2_999_950), scheduledHeight: 3_000_100)
            ],
            clock: Self.clock
        ) ?? []

        #expect(Self.nextBroadcast(preparations: preparations, transfers: transfers) == nil)
    }

    // MARK: - P4: the engine outlook's arming candidate (pure half)

    /// A `.prove` outlook is a sync visit — the buffer separates sends FROM syncs, so no clamp
    /// applies even while the gate is closed.
    @Test func aProveOutlookArmsUnclampedInsideTheBuffer() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let date = MigrationDerivations.outlookCandidateDate(
            outlook: MigrationNextWork(height: 3_000_010, kind: .prove),
            clock: Self.clock,
            now: now,
            sendGate: .waitUntil(now.addingTimeInterval(100_000))
        )
        #expect(date == Self.clock.notificationDate(atHeight: 3_000_010, now: now))
    }

    /// A `.broadcast` outlook inside the buffer is clamped to the gate's expiry — the poke must
    /// not invite a send the gate would refuse.
    @Test func aBroadcastOutlookInsideTheBufferClampsToTheGate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let unclamped = Self.clock.notificationDate(atHeight: 3_000_001, now: now)
        let gateUntil = unclamped.addingTimeInterval(500)
        let date = MigrationDerivations.outlookCandidateDate(
            outlook: MigrationNextWork(height: 3_000_001, kind: .broadcast),
            clock: Self.clock,
            now: now,
            sendGate: .waitUntil(gateUntil)
        )
        #expect(date == gateUntil)
    }

    /// A gate that expires before the window changes nothing — the clamp is a max, not an add.
    @Test func aBroadcastOutlookPastTheGatesExpiryIsUnclamped() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = Self.clock.notificationDate(atHeight: 3_000_100, now: now)
        let date = MigrationDerivations.outlookCandidateDate(
            outlook: MigrationNextWork(height: 3_000_100, kind: .broadcast),
            clock: Self.clock,
            now: now,
            sendGate: .waitUntil(now.addingTimeInterval(1))
        )
        #expect(date == window)
    }

    /// An open gate arms the broadcast outlook at its own window.
    @Test func aBroadcastOutlookWithAnOpenGateArmsAtItsWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let date = MigrationDerivations.outlookCandidateDate(
            outlook: MigrationNextWork(height: 3_000_050, kind: .broadcast),
            clock: Self.clock,
            now: now,
            sendGate: .allowed
        )
        #expect(date == Self.clock.notificationDate(atHeight: 3_000_050, now: now))
    }

    /// `.rebuild`/`.replan` are user-shaped visits: plain candidates, no clamp.
    @Test func userShapedOutlookKindsArmUnclamped() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for kind in [MigrationStepKind.rebuild, MigrationStepKind.replan] {
            let date = MigrationDerivations.outlookCandidateDate(
                outlook: MigrationNextWork(height: 3_000_020, kind: kind),
                clock: Self.clock,
                now: now,
                sendGate: .waitUntil(now.addingTimeInterval(100_000))
            )
            #expect(date == Self.clock.notificationDate(atHeight: 3_000_020, now: now))
        }
    }

    /// No outlook, no candidate — the arm's other three candidates decide alone.
    @Test func aNilOutlookContributesNoCandidate() {
        #expect(
            MigrationDerivations.outlookCandidateDate(
                outlook: nil,
                clock: Self.clock,
                now: Date(timeIntervalSince1970: 1_000_000),
                sendGate: .allowed
            ) == nil
        )
    }
}
