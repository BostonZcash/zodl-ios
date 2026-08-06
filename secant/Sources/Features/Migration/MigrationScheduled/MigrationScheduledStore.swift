//
//  MigrationScheduledStore.swift
//  zodl
//
//  "Migration Scheduled" screen (MOB-1463, Figma S9 · 2630:11282). Terminal success screen shown
//  once a scheduled migration plan has been confirmed: a summary card of what's being transferred
//  and over how long. Hydrated by `MigrationCoordFlowCoordinator.scheduledStateNow(schedule:
//  snapshot:)` — `totalAmount`/`sentCount`/`totalCount`/`durationHours` come from the
//  just-committed (or recovery-rebuilt) schedule's own numbers plus a SYNCHRONOUS read of the
//  published `MigrationViewSnapshot` for cumulative moved value and sent count; the engine is
//  never consulted on this path. Two production call sites build `.scheduled` state this way —
//  `transferPlanPostConfirmChain`'s `.scheduled`/`.recreated` case, and the recovery
//  refresh-stale push (MOB-1466 — closes the async-hydration stall this screen used to carry; see
//  `scheduledStateNow`'s own doc for the exact source of each field). The coordinator does
//  consume the `doneTapped` delegate (MigrationCoordFlowCoordinator, MOB-1466).
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
