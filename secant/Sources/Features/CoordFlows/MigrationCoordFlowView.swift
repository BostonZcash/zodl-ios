//
//  MigrationCoordFlowView.swift
//  Zodl
//
//  NavigationStack for the Orchard -> Ironwood migration flow. `MigrationEntry` is the root screen;
//  every other migration screen is pushed onto `path` by the coordinator.
//
//  PHASE 2: #1930's coordinator-owned sheets (the Tor bottom sheet, the Keystone minimum-firmware
//  gate) and its expired-recovery alert are absent along with the phases that own them — see
//  `MigrationCoordFlowStore.swift`. The structure is otherwise #1930's verbatim.
//

import SwiftUI
import ComposableArchitecture

struct MigrationCoordFlowView: View {
    @Perception.Bindable var store: StoreOf<MigrationCoordFlow>

    init(store: StoreOf<MigrationCoordFlow>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                MigrationEntryView(
                    store:
                        store.scope(
                            state: \.entryState,
                            action: \.entry
                        )
                )
            } destination: { store in
                switch store.case {
                case let .howItWorks(store):
                    MigrationHowItWorksView(store: store)
                case let .reviewTransfer(store):
                    MigrationReviewTransferView(store: store)
                case let .scheduled(store):
                    MigrationScheduledView(store: store)
                case let .sending(store):
                    MigrationSendingView(store: store)
                case let .status(store):
                    MigrationStatusView(store: store)
                case let .transferPlan(store):
                    MigrationTransferPlanView(store: store)
                }
            }
            .zashiSheet(
                isPresented: Binding(
                    get: { store.isTorSheetPresented },
                    set: { store.send(.torSheetPresentationChanged($0)) }
                )
            ) {
                MigrationTorSheetView(store: store.scope(state: \.torSheetState, action: \.torSheet))
            }
        }
        .applyScreenBackground()
        .onAppear {
            store.send(.onAppear)
        }
    }
}

// MARK: - Placeholders

extension MigrationCoordFlow.State {
    static var initial: MigrationCoordFlow.State { MigrationCoordFlow.State() }
}

extension MigrationCoordFlow {
    @MainActor static let placeholder = StoreOf<MigrationCoordFlow>(
        initialState: .initial
    ) {
        MigrationCoordFlow()
    }
}

#Preview {
    NavigationView {
        MigrationCoordFlowView(store: MigrationCoordFlow.placeholder)
    }
}
