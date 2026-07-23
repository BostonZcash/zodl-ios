//
//  AddKeystoneHWWalletCoordFlowTests.swift
//  zodlTests
//
//  Covers the coordinator-level error-handling state added for #1920:
//  - accountImportFailed bubbles up from a path element and shows the failure sheet
//  - cancelFailureTapped hides the sheet and exits the flow
//  - contactSupportTapped routes to mail or share depending on device capability
//  - sendSupportMailFinished / shareFinished clear their respective state
//  (Features/CoordFlows/AddKeystoneHWWalletCoordFlow*.swift)
//
//  AddKeystoneHWWalletCoordFlow.State is not Equatable (it contains a non-Equatable StackState),
//  so these tests drive a plain Store and read state directly after sending actions —
//  the same approach used by ScanCoordFlowZip321Tests. Initial state is set up before
//  Store creation (never via store.state mutation, which is get-only on a plain Store).
//

import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) @MainActor struct AddKeystoneHWWalletCoordFlowTests {

    // MARK: - accountImportFailed from keystoneDeviceReady

    @Test func accountImportFailedShowsFailureSheet() async {
        var initialState = AddKeystoneHWWalletCoordFlow.State()
        initialState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .keystoneDeviceReady(.accountImportFailed("boom")))))

        #expect(store.state.isFailureSheetPresented == true)
        #expect(store.state.errMsg == "boom")
    }

    // MARK: - cancelFailureTapped

    @Test func cancelFailureTappedHidesSheet() async {
        var initialState = AddKeystoneHWWalletCoordFlow.State()
        initialState.isFailureSheetPresented = true
        let store = makeStore(initialState: initialState)

        store.send(.cancelFailureTapped)

        #expect(store.state.isFailureSheetPresented == false)
    }

    // MARK: - contactSupportTapped

    @Test func contactSupportTappedWithMailCapabilitySetsSupportData() async {
        var initialState = AddKeystoneHWWalletCoordFlow.State()
        initialState.isFailureSheetPresented = true
        initialState.canSendMail = true
        initialState.errMsg = "ZRUST0067: rust error"
        let store = makeStore(initialState: initialState)

        store.send(.contactSupportTapped)

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.supportData != nil)
    }

    @Test func contactSupportTappedWithoutMailSetsMessageToBeShared() async {
        var initialState = AddKeystoneHWWalletCoordFlow.State()
        initialState.isFailureSheetPresented = true
        initialState.canSendMail = false
        initialState.errMsg = "ZRUST0067: rust error"
        let store = makeStore(initialState: initialState)

        store.send(.contactSupportTapped)

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.messageToBeShared != nil)
    }

    // MARK: - Mail / share cleanup

    @Test func sendSupportMailFinishedClearsSupportData() async {
        var initialState = AddKeystoneHWWalletCoordFlow.State()
        initialState.supportData = SupportDataGenerator.generate("")
        let store = makeStore(initialState: initialState)

        store.send(.sendSupportMailFinished)

        #expect(store.state.supportData == nil)
    }

    @Test func shareFinishedClearsMessageToBeShared() async {
        var initialState = AddKeystoneHWWalletCoordFlow.State()
        initialState.messageToBeShared = "some message"
        let store = makeStore(initialState: initialState)

        store.send(.shareFinished)

        #expect(store.state.messageToBeShared == nil)
    }

    // MARK: - Helpers

    private func makeStore(
        initialState: AddKeystoneHWWalletCoordFlow.State = AddKeystoneHWWalletCoordFlow.State()
    ) -> StoreOf<AddKeystoneHWWalletCoordFlow> {
        Store(initialState: initialState) {
            AddKeystoneHWWalletCoordFlow()
        } withDependencies: {
            $0.audioServices.systemSoundVibrate = { }
        }
    }
}
