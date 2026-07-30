//
//  MigrationScheduledStore.swift
//  zodl
//
//  "Migration Scheduled" screen (MOB-1463, Figma S9 · 2630:11282). Terminal success screen shown
//  once a scheduled migration plan has been confirmed: a summary card of what's being transferred
//  and over how long. The coordinator's one production call site (`MigrationCoordFlowCoordinator
//  .transferPlanPostConfirmChain`'s `.scheduled`/`.recreated` case) hydrates `totalAmount`/
//  `sentCount`/`totalCount`/`durationHours` from the just-committed schedule plus
//  `migrationManager.migrationSummary(accountUUID)` (MOB-1458 W-E — closes the MOB-1466 gap this
//  screen used to carry; see that method's doc for the exact source of each field). The coordinator
//  does consume the `doneTapped` delegate (MigrationCoordFlowCoordinator, MOB-1466).
//
//  The "Dust balance remaining" card MOB-1458 (W-E, Figma 3480:7631) put below the summary rows is
//  GONE — the component is no longer valid for this screen. `MigrationComplete`'s own dust card
//  (which owns the lock/migrate-anyway *decision*, Phase 6) was always a separate thing and is
//  unaffected; the two were deliberately never unified, so removing this one leaves it alone.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationScheduled {
    @ObservableState
    struct State: Equatable {
        var totalAmount = Zatoshi.zero
        var sentCount = 0
        var totalCount = 0
        var durationHours = 0

        init(
            totalAmount: Zatoshi = Zatoshi.zero,
            sentCount: Int = 0,
            totalCount: Int = 0,
            durationHours: Int = 0
        ) {
            self.totalAmount = totalAmount
            self.sentCount = sentCount
            self.totalCount = totalCount
            self.durationHours = durationHours
        }
    }

    enum Action: Equatable {
        case delegate(Delegate)
        case doneTapped

        enum Delegate: Equatable {
            case done
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .delegate:
                return .none

            case .doneTapped:
                return .send(.delegate(.done))
            }
        }
    }
}
