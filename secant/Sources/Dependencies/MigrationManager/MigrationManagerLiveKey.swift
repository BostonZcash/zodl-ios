//
//  MigrationManagerLiveKey.swift
//  Zodl
//
//  PHASE 1 SLICE (docs/slipstream/migration/REBUILD_PLAN.md): the migration entry point only —
//  activation gate + migratable Orchard balance + the `.notStarted` banner arm. Later phases add
//  their own arms to `MigrationDerivations.bannerVariant` and their own members here.
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension PoolBalance {
    /// The migratable portion of this pool's balance — every component of `total()` EXCEPT
    /// `lockedValue`. A locked residual (the "Lock balance" choice at migration Complete) has
    /// already been deliberately taken out of migration, so it must not count toward "more to
    /// migrate" or re-trigger the `.required` banner — unlike `total()`, which correctly keeps
    /// locked funds in the account's overall balance.
    var unlockedForMigration: Zatoshi {
        spendableValue + changePendingConfirmation + valuePendingSpendability
    }
}

/// The pure derivations the migration UI renders. Kept free of dependencies so each arm is a table
/// that can be unit-tested directly.
enum MigrationDerivations {
    /// Which migration banner (if any) belongs on screen.
    ///
    /// Phase 1 implements the entry point: pre-activation there is never a banner, and a wallet with
    /// no stored run shows `.required` exactly when it holds migratable Orchard funds. The remaining
    /// `MigrationState` arms land with the phases that make them reachable (progress in Phase 3,
    /// attention in Phase 5, completion/rounds in Phase 6) — until then a run in flight shows no
    /// banner, which is correct for a build that cannot yet create one.
    /// - Parameter isSeedBacked: PHASE 2 (docs/slipstream/migration/REBUILD_PLAN.md) — `false` for a
    ///   Keystone (hardware) account. The migration surface is gated to seed-backed accounts until
    ///   Phase 7 adds the Keystone batch-signing ceremony: without it the manual lane's software
    ///   commit (`MigrationCommitPipeline.commitImmediateSoftware`, which derives a USK) cannot
    ///   complete, and an entry point into a lane that always fails is worse than no entry point.
    ///   DELETE this parameter with Phase 7 — it is a scope fence, not a product rule.
    static func bannerVariant(
        isIronwoodActivated: Bool,
        isSeedBacked: Bool,
        state: MigrationState,
        orchardBalance: Zatoshi
    ) -> MigrationBannerVariant? {
        guard isIronwoodActivated, isSeedBacked else { return nil }

        switch state {
        case .notStarted:
            return orchardBalance > Zatoshi.zero ? MigrationBannerVariant.required : nil
        case .splitPendingConfirmation, .inProgress, .requiresAttention, .complete:
            return nil
        }
    }
}

extension MigrationManagerClient: DependencyKey {
    static let liveValue: MigrationManagerClient = Self.live()

    static func live() -> Self {
        let impl = MigrationManagerImpl()

        return Self(
            bannerVariant: { await impl.bannerVariant(accountUUID: $0) },
            isIronwoodActivated: { impl.isIronwoodActivated() },
            migrationRoundContext: { await impl.migrationRoundContext(accountUUID: $0) },
            orchardBalanceToMigrate: { await impl.orchardBalanceToMigrate(accountUUID: $0) }
        )
    }
}

private struct MigrationManagerImpl: Sendable {
    @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount?
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    /// True once the chain tip has reached NU6.3 on the current network. A zero tip means "not
    /// synced far enough to know" and reads as not activated — fail-closed, so no migration surface
    /// appears before the wallet can substantiate it.
    func isIronwoodActivated() -> Bool {
        let tip = sdkSynchronizer.latestState().latestBlockHeight
        return tip > 0 && tip >= zcashSDKEnvironment.ironwoodActivationHeight()
    }

    func migrationRoundContext(accountUUID: AccountUUID?) async -> (round: Int, totalRounds: Int?) {
        guard let accountUUID else { return (1, nil) }
        let totalRounds = (try? await sdkSynchronizer.estimateMigrationRunCount(accountUUID)) ?? nil
        return (1, totalRounds)
    }

    func orchardBalanceToMigrate(accountUUID: AccountUUID?) async -> Zatoshi {
        guard let accountUUID else { return .zero }

        guard let balances = try? await sdkSynchronizer.getAccountsBalances(),
              let balance = balances[accountUUID] else {
            return .zero
        }

        return balance.orchardBalance.unlockedForMigration
    }

    func bannerVariant(accountUUID: AccountUUID?) async -> MigrationBannerVariant? {
        guard let accountUUID else { return nil }
        // PHASE 2 scope fence — see `MigrationDerivations.bannerVariant`'s `isSeedBacked` doc.
        // Fail-closed on an unresolvable account: no account, no migration surface.
        guard let account = selectedWalletAccount, account.id == accountUUID,
              account.vendor != WalletAccount.Vendor.keystone else { return nil }
        // Short-circuit BEFORE the async reads: pre-activation there is no banner to derive, and
        // both reads are pure, so exiting early only saves work.
        guard isIronwoodActivated() else { return nil }
        guard let state = try? await sdkSynchronizer.getMigrationState(accountUUID) else { return nil }

        let balance = await orchardBalanceToMigrate(accountUUID: accountUUID)

        return MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            isSeedBacked: true,
            state: state,
            orchardBalance: balance
        )
    }
}
