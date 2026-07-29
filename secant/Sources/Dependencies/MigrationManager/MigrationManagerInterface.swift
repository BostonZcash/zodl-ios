//
//  MigrationManagerInterface.swift
//  Zodl
//
//  App-side owner of the Orchard -> Ironwood migration. The SDK exposes the migration primitives on
//  `Synchronizer` (see docs/slipstream/migration/API_SURFACE_MAP.md); this client holds everything
//  the SDK deliberately does NOT: the derivations the UI renders, the notification schedule, and the
//  display copy of a committed run.
//
//  PHASE 1 SLICE (docs/slipstream/migration/REBUILD_PLAN.md): only the entry point — "does this
//  wallet have Orchard funds worth migrating, and has Ironwood activated?". Later phases extend this
//  client rather than replacing it; the member set grows per phase, so keep additions in the same
//  shape #1930 already reviewed.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var migrationManager: MigrationManagerClient {
        get { self[MigrationManagerClient.self] }
        set { self[MigrationManagerClient.self] = newValue }
    }
}

@DependencyClient
struct MigrationManagerClient: Sendable {
    /// The migration banner to show for `accountUUID`, or `nil` for "no migration banner". Pure
    /// given the SDK reads it makes — unit-tested as a table via ``MigrationDerivations``.
    var bannerVariant: @Sendable (_ accountUUID: AccountUUID?) async -> MigrationBannerVariant? = { _ in nil }

    /// "Ironwood (NU6.3) has activated on the current network." Gates every migration surface.
    ///
    /// `= { false }` is a required macro default (non-Void, non-throwing return), not a test
    /// fallback: fail-closed is also the right answer for an unknown chain tip.
    var isIronwoodActivated: @Sendable () -> Bool = { false }

    /// The multi-round labels' context — the CURRENT round and the engine's estimated TOTAL
    /// rounds, `nil` when the SDK's estimate is unavailable or has no runs.
    ///
    /// PHASE 2: `round` is hard-wired to 1. #1930 derived it from an app-persisted completed-run
    /// count (`MigrationGateStorage.completedRounds`); that persistence arrives with rounds/residual
    /// in Phase 6, and until a run can be COMMITTED there is no second round to be in.
    var migrationRoundContext: @Sendable (_ accountUUID: AccountUUID?) async -> (round: Int, totalRounds: Int?) = { _ in (1, nil) }

    /// The Orchard balance actually available to migrate — every component of the pool balance
    /// EXCEPT `lockedValue`. See ``PoolBalance/unlockedForMigration``.
    var orchardBalanceToMigrate: @Sendable (_ accountUUID: AccountUUID?) async -> Zatoshi = { _ in .zero }
}
