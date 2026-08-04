//
//  WalletBalancesPoolCorrectionTests.swift
//  zodlTests
//
//  M3 Part B (MOB-1466): the Home pool-balances sheet must render R11's standard — pools as if
//  every migration transaction the wallet has NOT mined never happened. The SDK's per-pool
//  figures count stored-unmined migration outputs (store-at-prove), so minutes after a plan
//  commits the Ironwood card claims value that has not crossed and the Orchard card has already
//  shed it. The migration surfaces correct this via `inFlightPoolCorrection`; Home showing the
//  UNcorrected numbers next to a Status screen showing corrected ones is the surfaces-disagree
//  contradiction the E2E campaign flagged.
//
//  The correction rides `MigrationViewSnapshot.poolCorrection` — computed in the manager's ONE
//  derivation pass, so Home and the migration surfaces read the same figure at the same clock and
//  can never disagree by construction. Spendability and total figures stay untouched: plan-locked
//  notes genuinely are unspendable, and the two pool deltas cancel inside the shielded total.
//

import Combine
import Foundation
import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct WalletBalancesPoolCorrectionTests {
    /// The core rule: ironwood-located figure sheds the in-flight sum, orchard-located figure
    /// regains it, and every spendability/total figure is exactly what the raw SDK balance says.
    @MainActor @Test func poolFiguresApplyInFlightCorrection() async {
        let store = makeStore(correction: MigrationDerivations.PoolTruthCorrection(
            ironwoodOverstatement: Zatoshi(70),
            orchardUnderstatement: Zatoshi(70)
        ))

        let balance = fullPoolAccountBalance()
        await store.send(.balanceUpdated(balance))

        #expect(store.state.ironwoodPoolBalance == balance.ironwoodBalance.total() - Zatoshi(70))
        #expect(store.state.orchardPoolBalance == balance.orchardBalance.total() + Zatoshi(70))
        // Untouched by the correction: sapling, transparent, spendability, and both totals.
        #expect(store.state.saplingPoolBalance == balance.saplingBalance.total())
        #expect(store.state.transparentBalance == balance.unshielded)
        #expect(store.state.shieldedBalance == balance.shieldedSpendableValue)
        #expect(store.state.shieldedWithPendingBalance == balance.shieldedTotal())
        #expect(store.state.totalBalance == balance.shieldedTotal() + balance.unshielded + balance.awaitingResolution)
    }

    /// The pool-sheet identity survives the correction: the two deltas cancel, so the four
    /// displayed pool cards still sum to the home-screen total.
    @MainActor @Test func poolBalancesStillSumToTotalUnderCorrection() async {
        let store = makeStore(correction: MigrationDerivations.PoolTruthCorrection(
            ironwoodOverstatement: Zatoshi(123),
            orchardUnderstatement: Zatoshi(123)
        ))

        await store.send(.balanceUpdated(fullPoolAccountBalance()))

        let sum = store.state.saplingPoolBalance
            + store.state.orchardPoolBalance
            + store.state.ironwoodPoolBalance
            + store.state.transparentPoolBalance
        #expect(sum == store.state.totalBalance)
    }

    /// An overstatement larger than the SDK's ironwood figure clamps to zero — the sheet never
    /// renders a negative pool. (The mirror of the migration header's own clamp.)
    @MainActor @Test func ironwoodCorrectionClampsAtZero() async {
        let store = makeStore(correction: MigrationDerivations.PoolTruthCorrection(
            ironwoodOverstatement: Zatoshi(1_000_000),
            orchardUnderstatement: Zatoshi(1_000_000)
        ))

        let balance = fullPoolAccountBalance()
        await store.send(.balanceUpdated(balance))

        #expect(store.state.ironwoodPoolBalance == .zero)
        #expect(store.state.orchardPoolBalance == balance.orchardBalance.total() + Zatoshi(1_000_000))
    }

    /// No snapshot (no active migration, or manager not asked yet) means raw SDK figures — the
    /// correction is strictly additive behavior, never a new dependency for the plain path.
    @MainActor @Test func nilSnapshotLeavesFiguresRaw() async {
        let store = makeStore(correction: nil)

        let balance = fullPoolAccountBalance()
        await store.send(.balanceUpdated(balance))

        #expect(store.state.ironwoodPoolBalance == balance.ironwoodBalance.total())
        #expect(store.state.orchardPoolBalance == balance.orchardBalance.total())
    }

    /// The push half: a fresh migration snapshot (prove stored a transaction, a transfer mined)
    /// re-asks for balances, so the corrected pools move on the migration's clock too — not only
    /// when a sync event happens to arrive.
    @MainActor @Test func snapshotEventTriggersBalanceRefresh() async {
        let snapshotSubject = PassthroughSubject<MigrationViewSnapshot?, Never>()
        let account = WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 1, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )

        var state = WalletBalances.State()
        state.$selectedWalletAccount.withLock { $0 = account }

        let store = TestStore(initialState: state) {
            WalletBalances()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            $0.exchangeRate = .noOp
            $0.sdkSynchronizer = .noOp
            var manager = MigrationManagerClient.noOp
            manager.migrationSnapshotEvents = { _ in snapshotSubject.eraseToAnyPublisher() }
            manager.currentMigrationSnapshot = { _ in nil }
            $0.migrationManager = manager
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        // Drain the unconditional refresh onAppear itself sends, so the receive below can only
        // be satisfied by the snapshot-event-driven one.
        await store.receive(\.updateBalances)

        snapshotSubject.send(MigrationViewSnapshot.empty)
        await store.receive(\.updateBalances)

        await store.send(.onDisappear)
    }

    // MARK: - Helpers

    private func fullPoolAccountBalance() -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(spendableValue: Zatoshi(100), changePendingConfirmation: Zatoshi(10), valuePendingSpendability: Zatoshi(20)),
            orchardBalance: PoolBalance(spendableValue: Zatoshi(200), changePendingConfirmation: Zatoshi(30), valuePendingSpendability: Zatoshi(40)),
            ironwoodBalance: PoolBalance(spendableValue: Zatoshi(300), changePendingConfirmation: Zatoshi(50), valuePendingSpendability: Zatoshi(60)),
            unshielded: Zatoshi(5),
            awaitingResolution: Zatoshi(1)
        )
    }

    /// A snapshot whose only meaningful field for these tests is the correction.
    private func snapshot(correction: MigrationDerivations.PoolTruthCorrection) -> MigrationViewSnapshot {
        MigrationViewSnapshot(
            orchardRemaining: .zero,
            ironwoodHeld: .zero,
            poolCorrection: correction,
            movedByDoneTransfers: .zero,
            doneTransfers: 0,
            totalTransfers: 0,
            transfers: [],
            summary: MigrationSummary.zero,
            banner: nil,
            preparations: [],
            planTotal: nil,
            isTorHoldActive: false,
            isSubmitting: false,
            sessionOrdinal: nil,
            asOfSyncedAt: nil
        )
    }

    @MainActor
    private func makeStore(correction: MigrationDerivations.PoolTruthCorrection?) -> TestStoreOf<WalletBalances> {
        let store = TestStore(initialState: WalletBalances.State()) {
            WalletBalances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            var manager = MigrationManagerClient.noOp
            if let correction {
                let built = snapshot(correction: correction)
                manager.currentMigrationSnapshot = { _ in built }
            } else {
                manager.currentMigrationSnapshot = { _ in nil }
            }
            $0.migrationManager = manager
        }
        store.exhaustivity = .off
        return store
    }
}
