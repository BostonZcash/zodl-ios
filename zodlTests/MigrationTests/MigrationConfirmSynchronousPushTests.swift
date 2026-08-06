//
//  MigrationConfirmSynchronousPushTests.swift
//  zodlTests
//
//  FIELD BUG: the first Confirm tap on a signing transfer plan committed (signed + stored) in
//  well under a second, then the screen sat still — the push to "Migration Scheduled" awaited
//  `migrationSummary`, whose compute path crosses the DB write actor TWICE (`migrationState`'s
//  advance-step read, and `residualAfterMigration`), exactly while the post-commit drive's prove
//  sweep can hold that same actor for seconds per Halo2 chunk. The read-only-reads work never
//  touched either of those two hops, so the stall survived that rebuild intact.
//
//  THE CONTRACT this suite pins: a software `.confirmed` on a signing plan pushes `.scheduled`
//  SYNCHRONOUSLY — the path mutation happens in the reducer handling the delegate itself, built
//  from data already in hand (the just-committed schedule's own numbers, plus a synchronous read
//  of the published snapshot for prior rounds' moved value). The engine is never consulted on the
//  navigation path; that is exactly the shape the `.manual` arm already used. A second contract
//  closes the re-tap window the stall used to invite: once `hasConfirmed` is set, a further
//  `.confirmTapped`/`.retryTapped` is a traced no-op — no auth prompt, no second commit leg.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationConfirmSynchronousPushTests {
    // MARK: - Fixtures

    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x21, count: 16))

    private static func account() -> WalletAccount {
        WalletAccount(
            Account(
                id: accountUUID,
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private static func transfer(id: UInt32, zatoshi: Int64) -> MigrationTransferProposal {
        MigrationTransferProposal(
            id: id,
            amount: Zatoshi(zatoshi),
            anchorHeight: BlockHeight(3_000_000),
            nextExecutableAfterHeight: BlockHeight(3_000_100),
            expiryHeight: BlockHeight(3_000_140)
        )
    }

    /// Two transfers — 100_000_000 + 250_000_000 = 350_000_000 zatoshi — over an estimated 5h.
    private static func schedule() -> MigrationSchedule {
        MigrationSchedule(
            transfers: [
                transfer(id: 0, zatoshi: 100_000_000),
                transfer(id: 1, zatoshi: 250_000_000)
            ],
            estimatedDurationHours: 5,
            proposalHandle: 1,
            preparations: []
        )
    }

    private static func snapshot(movedByDoneTransfers: Zatoshi, totalTransfers: Int) -> MigrationViewSnapshot {
        MigrationViewSnapshot(
            orchardRemaining: .zero,
            ironwoodHeld: .zero,
            poolCorrection: MigrationDerivations.PoolTruthCorrection.none,
            movedByDoneTransfers: movedByDoneTransfers,
            doneTransfers: 0,
            totalTransfers: totalTransfers,
            transfers: [],
            summary: MigrationSummary.zero,
            banner: nil,
            preparations: [],
            planTotal: nil,
            isTorHoldActive: false,
            needsTorFirstRunChoice: false,
            isSubmitting: false,
            sessionOrdinal: 1,
            asOfSyncedAt: nil
        )
    }

    // MARK: - The fix

    /// THE fix. A software `.confirmed` on a signing plan pushes `.scheduled` SYNCHRONOUSLY — the
    /// path mutation happens in the reducer handling the delegate, with the state built from the
    /// in-hand schedule + the published snapshot; no async receive precedes the push.
    @Test func aConfirmedPlanPushesTheScheduledScreenSynchronously() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = nil }

        var planState = MigrationTransferPlan.State(variant: .scheduled, requiresSigning: true)
        planState.schedule = Self.schedule()

        var initialState = MigrationCoordFlow.State.initial
        initialState.path.append(.transferPlan(planState))
        let transferPlanID = initialState.path.ids[0]

        let store = TestStore(initialState: initialState) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            var client = MigrationManagerClient.noOp
            client.currentMigrationSnapshot = { _ in nil }
            client.armNextWindowNotifications = { _ in }
            client.refreshMigrationSnapshot = { _ in }
            $0.migrationManager = client
        }
        store.exhaustivity = .off

        // No `store.receive` before this assertion — the push must already be reflected in the
        // SAME send's resulting state, not arrive later off a queued action.
        await store.send(
            .path(.element(id: transferPlanID, action: .transferPlan(.delegate(.confirmed))))
        ) {
            $0.path.append(.scheduled(MigrationScheduled.State(
                totalAmount: Zatoshi(350_000_000),
                sentCount: 0,
                totalCount: 2,
                durationHours: 5
            )))
        }

        // The trailing effect (window arming + snapshot refresh) is fire-and-forget — it must
        // still be let run to completion so it doesn't leak into a later test.
        await store.finish()
    }

    // MARK: - The builder table

    /// Fresh commit, nil snapshot — schedule-only numbers; nothing has moved before this run.
    @Test func theBuilderUsesScheduleOnlyNumbersWithoutASnapshot() {
        let result = MigrationCoordFlow.scheduledStateNow(schedule: Self.schedule(), snapshot: nil)

        #expect(result == MigrationScheduled.State(
            totalAmount: Zatoshi(350_000_000),
            sentCount: 0,
            totalCount: 2,
            durationHours: 5
        ))
    }

    /// Multi-round: a snapshot carrying a prior round's moved value folds into `totalAmount`
    /// alongside this round's fresh schedule sum.
    @Test func theBuilderFoldsPriorRoundsMovedValueFromTheSnapshot() {
        let priorRoundSnapshot = Self.snapshot(movedByDoneTransfers: Zatoshi(300_000), totalTransfers: 0)
        let result = MigrationCoordFlow.scheduledStateNow(schedule: Self.schedule(), snapshot: priorRoundSnapshot)

        #expect(result == MigrationScheduled.State(
            totalAmount: Zatoshi(300_000) + Zatoshi(350_000_000),
            sentCount: 0,
            totalCount: 2,
            durationHours: 5
        ))
    }

    /// No fresh schedule — the snapshot's own totals stand in, and a prior round's moved value
    /// still folds through. Never a crash, never a negative total.
    @Test func theBuilderFallsBackToSnapshotTotalsWithoutASchedule() {
        let noScheduleSnapshot = Self.snapshot(movedByDoneTransfers: Zatoshi(750_000), totalTransfers: 5)
        let result = MigrationCoordFlow.scheduledStateNow(schedule: nil, snapshot: noScheduleSnapshot)

        #expect(result == MigrationScheduled.State(
            totalAmount: Zatoshi(750_000),
            sentCount: 0,
            totalCount: 5,
            durationHours: 0
        ))
    }

    // MARK: - The latch

    /// The latch: once `hasConfirmed` is set, another confirmTapped is a traced no-op — no auth
    /// prompt, no commit leg, no state change. An exhaustive `send` with no trailing closure IS
    /// the pin: any mutation (e.g. `isConfirming` flipping true on the way into the auth gate)
    /// fails it outright.
    @Test func aCommittedPlanIgnoresAnotherConfirmTap() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }

        var state = MigrationTransferPlan.State(variant: .scheduled, requiresSigning: true)
        state.schedule = Self.schedule()
        state.hasConfirmed = true

        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        }

        await store.send(.confirmTapped)

        await store.finish()
    }
}
