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
    /// Which destination the coordinator stashed while the Tor bottom sheet is presented — resumed
    /// once the user confirms ("Got it") or swipes the sheet away (identical outcome, using
    /// whatever toggle state is showing at that moment).
    enum PendingTorDestination: Equatable {
        /// Immediate mode: push Review Transfer directly.
        case reviewTransfer
        /// Scheduled mode (from How This Works): continue to the plan.
        ///
        /// PHASE 3: #1930 names this `.permissionChain` because it runs the notification-permission
        /// chain here. Permissions are Phase 4; the destination itself is the same one either way,
        /// so the case keeps its scheduled-lane MEANING and gains the chain in Phase 4.
        case transferPlan
    }

    @Reducer(state: .equatable)
    enum Path {
        case howItWorks(MigrationHowItWorks)
        case reviewTransfer(MigrationReviewTransfer)
        case scheduled(MigrationScheduled)
        case sending(MigrationSending)
        case status(MigrationStatus)
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
        /// The Tor bottom sheet's own state — always present (not optional), toggled on screen via
        /// `isTorSheetPresented`, mirroring the `ServerSetup`/`serverSetupViewBinding` precedent in
        /// `Root` rather than an `@Presents`/`ifLet` destination (there is exactly one sheet, and
        /// `zashiSheet` only takes a `Binding<Bool>` anyway).
        var torSheetState = MigrationTorSheet.State()
        var isTorSheetPresented = false
        /// Non-nil exactly while `isTorSheetPresented` is true — see `PendingTorDestination`.
        var pendingTorDestination: PendingTorDestination?
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init() { }
    }

    enum Action {
        case entry(MigrationEntry.Action)
        /// Terminal: the flow is done (or was backed out of) — `Root` tears it down.
        case flowFinished
        case onAppear
        case path(StackActionOf<Path>)
        /// Pushes a path state that had to be hydrated asynchronously first (the network snapshot
        /// must exist before anything downstream reads it), so the push itself stays synchronous.
        case pushHydratedPathState(Path.State)
        /// Same, for the Status screen — kept separate because re-entry hydrates it from a
        /// different source (rows + summary) than a fresh push.
        case pushHydratedStatus(MigrationStatus.State)
        /// A "Send now" tap finished its broadcast; carries the refreshed rows so Status re-renders
        /// without a second round trip.
        case sendNowCompleted(rows: [MigrationTransferRow])
        /// The Tor sheet's "switch server" escape — `Root` opens Server Setup and tears the flow
        /// down (N6: a manual switch mid-run is a privacy decision, not a silent one).
        case switchServerRequested
        case torSheet(MigrationTorSheet.Action)
        case torSheetPresentationChanged(Bool)
        /// The sheet's state is resolved asynchronously (it needs the run's broadcast endpoint on
        /// the choice surface), so presentation is a two-step: resolve, then present with the
        /// destination to resume once the user confirms.
        case torSheetStateReady(MigrationTorSheet.State, destination: PendingTorDestination)
    }

    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        Scope(state: \.entryState, action: \.entry) {
            MigrationEntry()
        }

        Scope(state: \.torSheetState, action: \.torSheet) {
            MigrationTorSheet()
        }

        Reduce { _, _ in .none }
            .forEach(\.path, action: \.path)
    }
}
