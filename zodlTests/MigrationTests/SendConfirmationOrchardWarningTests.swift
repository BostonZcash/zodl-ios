//
//  SendConfirmationOrchardWarningTests.swift
//  zodlTests
//
//  A12/B6 glue: `MigrationManualSendRiskTests` pins the pure predicate, but the predicate being
//  right proves nothing about whether `SendConfirmation` actually threads its own `state.proposal`
//  into `migrationManager.shouldWarnBeforeManualSend` at `.sendTapped`. A documented project lesson
//  is exactly this shape of bug: the pure layer was green while the call-site glue silently
//  discarded the value it was supposed to forward. Passing `nil` (or someone else's proposal) at
//  the call site would still compile, and every `MigrationManualSendRiskTests` case would still
//  pass, because those tests never touch the reducer at all.
//
//  So this drives the real `SendConfirmation` reducer through a `TestStore` and inspects what the
//  manager dependency actually received, rather than trusting that a signature match means the
//  wiring is correct.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SendConfirmationOrchardWarningTests {
    private static func testWalletAccount() -> WalletAccount {
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

    /// THE glue check: `.sendTapped` must hand `state.proposal` — not merely an account id — to
    /// `shouldWarnBeforeManualSend`, and the `true` it answers with must actually reach
    /// `isOrchardWarningPresented`.
    @Test func sendTappedForwardsItsOwnProposalToTheManager() async {
        let capturedProposal = LockIsolated<Proposal?>(nil)

        let initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000, spendsLegacyOrchardFunds: true)
        )
        initialState.$selectedWalletAccount.withLock { $0 = Self.testWalletAccount() }

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        } withDependencies: {
            $0.migrationManager.shouldWarnBeforeManualSend = { _, proposal in
                capturedProposal.setValue(proposal)
                return true
            }
        }

        await store.send(.sendTapped)
        await store.receive(.orchardRiskResolved(true)) {
            $0.isOrchardWarningPresented = true
        }

        #expect(capturedProposal.value != nil)
        #expect(capturedProposal.value?.spendsLegacyOrchardFunds == true)
    }
}
