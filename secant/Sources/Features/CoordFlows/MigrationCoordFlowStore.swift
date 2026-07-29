//
//  MigrationCoordFlowStore.swift
//  Zodl
//
//  Coordinator for the Orchard -> Ironwood migration flow. `MigrationEntry` is the flow's root
//  screen (mirroring `SendCoordFlow`'s `sendFormState`); every other screen lives in `path`.
//
//  PHASE 2 SCOPE (docs/slipstream/migration/REBUILD_PLAN.md). #1930's coordinator is a 2,900-line
//  file covering every phase at once; this is the same skeleton reduced to the two lanes Phase 2
//  ships, with the SAME store shape and case names so later phases re-add their rows rather than
//  reshaping anything:
//
//    Entry --(.immediate)-------> ReviewTransfer --> Sending          (the MANUAL lane, end to end)
//    Entry --(.privateScheduled)-> HowItWorks -----> TransferPlan     (the PRIVACY lane, PREVIEW only)
//
//  Deliberately absent, each landing with the phase that needs it:
//  - the Tor bottom sheet + network snapshot forming (`torSheetState`, `PendingTorDestination`,
//    `formNetworkSnapshot`) — Phase 3, with the N-series network law;
//  - the commit pipeline, Scheduled/Status/Notifications screens and the first-delivery kick —
//    Phase 3/4;
//  - Recovery/Complete and the dust lane — Phases 5/6;
//  - the whole Keystone ceremony (`keystoneSign`/`scan`, `KeystoneSigningContext`,
//    `PendingScheduleStore`, `KeystoneBatchRounds`, the firmware gate) — Phase 7.
//
//  D12 (one fork, one consent): the privacy-vs-manual choice exists ONLY here, at the start.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationCoordFlow {
    @Reducer(state: .equatable)
    enum Path {
        case howItWorks(MigrationHowItWorks)
        case reviewTransfer(MigrationReviewTransfer)
        case sending(MigrationSending)
        case transferPlan(MigrationTransferPlan)
    }

    @ObservableState
    struct State: Equatable {
        var path = StackState<Path.State>()
        var entryState = MigrationEntry.State()
        /// The lane the user picked at the fork. Held here so a later hop in the same run doesn't
        /// need to re-read it. #1930 also persisted it via `migrationManager.setMigrationMode`;
        /// that persistence matters once a run can be COMMITTED (Phase 3) — Phase 2's manual lane
        /// completes inside a single flow presentation.
        var mode: MigrationMode?
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init() { }
    }

    enum Action {
        case entry(MigrationEntry.Action)
        /// Terminal: the flow is done (or was backed out of) — `Root` tears it down.
        case flowFinished
        case onAppear
        case path(StackActionOf<Path>)
    }

    @Dependency(\.migrationManager) var migrationManager

    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        Scope(state: \.entryState, action: \.entry) {
            MigrationEntry()
        }

        Reduce { _, _ in .none }
            .forEach(\.path, action: \.path)
    }
}
