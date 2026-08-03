//
//  MigrationCoordFlowSendNowLaneTests.swift
//  zodlTests
//
//  Audit 2026-08-03 (#8): the production Send-now push never set `entersViaSendNow` — the only
//  assignment in the repo was a #Preview — so the R8-T6 silence-window wait (and the app-side
//  `sendGate()` consult the status screen's doc promises happens "later, inside the Send-now
//  lane") was dead code in production, and the push also mislabelled the lane as the
//  manual-delivery step lane. This suite pins the push's arguments so the lane can never silently
//  fall back to preview-only again.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationCoordFlowSendNowLaneTests {
    @Test func theSendNowPushArmsTheSilenceWindowLane() async {
        var initialState = MigrationCoordFlow.State()
        initialState.path.append(.status(MigrationStatus.State(presentation: .resume)))
        let statusID = initialState.path.ids[0]

        let store = TestStore(initialState: initialState) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: statusID, action: .status(.delegate(.sendNow)))))

        guard case let .sending(sendingState)? = store.state.path.last else {
            Issue.record("the Send-now delegate must push the sending screen, got \(String(describing: store.state.path.last))")
            return
        }
        #expect(sendingState.entersViaSendNow, "the push must arm the silence-window lane — the flag was preview-only before")
        #expect(!sendingState.isManualStepLane, "Send-now is not the manual-delivery step lane")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }
}
