//
//  MultiServerSubmitRoutingTests.swift
//  secantTests
//
//  Created by Michal Fousek on 2026-06-12.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Drives TCA stores that touch the process-global `selectedWalletAccount` @Shared state,
// so the suite is serialized to avoid cross-test races on that storage.
@Suite(.serialized) @MainActor struct MultiServerSubmitSendRoutingTests {
    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func makeStore(
        result: SDKSynchronizerClient.CreateProposedTransactionsResult,
        txIdExists: Bool = false
    ) -> TestStore<SendConfirmation.State, SendConfirmation.Action> {
        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }
        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.derivationTool = .liveValue
        store.dependencies.mainQueue = .immediate
        store.dependencies.mnemonic = .liveValue
        store.dependencies.walletStorage = .noOp
        store.dependencies.zcashSDKEnvironment = .testnet
        store.dependencies.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in result }
        store.dependencies.sdkSynchronizer.txIdExists = { _ in txIdExists }

        return store
    }

    @Test func partialSubmissionRoutesToFailureSupportState() async {
        let firstTxId = Data([0xAA]).toHexStringTxId()
        let secondTxId = Data([0xBB]).toHexStringTxId()
        let statuses = ["accepted by endpoint 1", "rejected by all servers"]
        let store = makeStore(result: .partial(txIds: [firstTxId, secondTxId], statuses: statuses))

        await store.send(.sendTriggered)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.result == .failure)
        #expect(store.state.txIdToExpand == firstTxId)
        #expect(store.state.partialFailureTxIds == [firstTxId, secondTxId])
        #expect(store.state.partialFailureStatuses == statuses)
        #expect(store.state.failedCode == -999)
        #expect(store.state.failedDescription == statuses.joined(separator: ", "))
        #expect(store.state.failureInfo == String(localizable: .sendPartialFailureInfo))
    }

    @Test func allServersRejectedRoutesToPendingWhenTxExistsLocally() async {
        let txId = Data([0xAA]).toHexStringTxId()
        let store = makeStore(result: .grpcFailure(txIds: [txId]), txIdExists: true)

        await store.send(.sendTriggered)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.result == .pending)
        #expect(store.state.txIdToExpand == txId)
        #expect(store.state.pendingDescription == nil)
    }

    @Test func timeoutRoutesToPendingWithTimeoutCopy() async {
        let txId = Data([0xAA]).toHexStringTxId()
        let store = makeStore(
            result: .grpcFailure(
                txIds: [txId],
                description: "Timed out waiting for endpoint response",
                reason: .timeout
            ),
            txIdExists: true
        )

        await store.send(.sendTriggered)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.result == .pending)
        #expect(store.state.txIdToExpand == txId)
        #expect(store.state.pendingDescription == String(localizable: .sendPendingTimeoutInfo))
        #expect(store.state.pendingInfo == String(localizable: .sendPendingTimeoutInfo))
    }

    @Test func onAppearResetsMultiServerSubmissionState() async {
        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.partialFailureTxIds = ["stale"]
        initialState.partialFailureStatuses = ["stale status"]
        initialState.pendingDescription = "stale description"

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }
        store.exhaustivity = .off

        store.dependencies.derivationTool = .liveValue
        store.dependencies.zcashSDKEnvironment = .testnet

        await store.send(.onAppear)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.partialFailureTxIds.isEmpty)
        #expect(store.state.partialFailureStatuses.isEmpty)
        #expect(store.state.pendingDescription == nil)
    }
}

// Serialized for the same reason as above: the PCZT path runs through stores sharing
// process-global state and the audio/zcash environment dependencies.
@Suite(.serialized) @MainActor struct MultiServerSubmitPCZTRoutingTests {
    @Test func pcztSuccessBroadcastsAndResetsPCZTState() async {
        let txId = Data([0xAA]).toHexStringTxId()
        let pcztWithProofs = Pczt([0x10, 0x11])
        let pcztWithSigs = Pczt([0x20, 0x21])
        let createInputs = LockIsolated<[(Pczt, Pczt)]>([])

        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.pczt = Pczt([0x01])
        initialState.pcztWithProofs = pcztWithProofs
        initialState.pcztWithSigs = pcztWithSigs
        initialState.pcztToShare = Pczt([0x02])
        initialState.redactedPcztForSigner = Pczt([0x03])

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }
        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.mainQueue = .immediate
        store.dependencies.zcashSDKEnvironment = .testnet
        store.dependencies.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { proofs, sigs in
            createInputs.withValue { $0.append((proofs, sigs)) }
            return .success(txIds: [txId])
        }

        await store.send(.createTransactionFromPCZT)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        createInputs.withValue { inputs in
            #expect(inputs.count == 1)
            #expect(inputs.first?.0 == pcztWithProofs)
            #expect(inputs.first?.1 == pcztWithSigs)
        }
        #expect(store.state.pczt == nil)
        #expect(store.state.pcztWithProofs == nil)
        #expect(store.state.pcztWithSigs == nil)
        #expect(store.state.pcztToShare == nil)
        #expect(store.state.proposal == nil)
        #expect(store.state.redactedPcztForSigner == nil)
        #expect(store.state.result == .success)
        #expect(store.state.txIdToExpand == txId)
    }

    @Test func pcztPartialRoutesToFailureWithSupportData() async {
        let firstTxId = Data([0xAA]).toHexStringTxId()
        let secondTxId = Data([0xBB]).toHexStringTxId()
        let statuses = ["accepted by endpoint 1", "rejected code: -25"]

        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.pcztWithProofs = Pczt([0x10, 0x11])
        initialState.pcztWithSigs = Pczt([0x20, 0x21])

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }
        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.mainQueue = .immediate
        store.dependencies.zcashSDKEnvironment = .testnet
        store.dependencies.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { _, _ in
            .partial(txIds: [firstTxId, secondTxId], statuses: statuses)
        }

        await store.send(.createTransactionFromPCZT)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.result == .failure)
        #expect(store.state.txIdToExpand == firstTxId)
        #expect(store.state.partialFailureTxIds == [firstTxId, secondTxId])
        #expect(store.state.partialFailureStatuses == statuses)
        #expect(store.state.failedCode == -999)
        #expect(store.state.pcztWithProofs == nil)
        #expect(store.state.pcztWithSigs == nil)
    }
}
