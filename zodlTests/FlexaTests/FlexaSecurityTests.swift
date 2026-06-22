//
//  FlexaSecurityTests.swift
//  zodlTests
//
//  MOB-1352 — Flexa must never derive a local spending key for a Keystone (hardware) account,
//  which has no on-device seed. A Keystone selection must fail closed (block + prompt) before any
//  proposal/seed-export path runs, rather than signing with the wrong key.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: drives a Root store sharing the process-global `selectedWalletAccount` @Shared state.
@Suite(.serialized) @MainActor struct FlexaSecurityTests {
    private enum Const {
        static let commerceSessionId = "commerce-session-id"
        static let recipientAddress = "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE"
    }

    private func walletAccount(keystone: Bool) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: keystone ? 1 : 0, count: 16)),
                name: keystone ? "Keystone" : "Zodl",
                keySource: keystone ? String(localizable: .accountsKeystone).lowercased() : nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func makeFlexaTransaction() -> FlexaTransaction {
        FlexaTransaction(amount: Zatoshi(100_000), address: Const.recipientAddress, commerceSessionId: Const.commerceSessionId)
    }

    /// A Keystone account must be blocked: an alert is shown, nothing is reported sent, and the
    /// proposal/seed-derivation path is never entered.
    @Test func keystoneAccountIsBlockedAndNeverProposes() async {
        let transactionSentCalls = LockIsolated<[(String, String)]>([])
        let alertCalls = LockIsolated<[(String, String)]>([])
        let proposeCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let initialState = Root.State.initial
            initialState.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true) }

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                $0.derivationTool = .liveValue
                $0.flexaHandler = .noOp
                $0.flexaHandler.clearTransactionRequest = { }
                $0.flexaHandler.transactionSent = { commerceSessionId, txId in
                    transactionSentCalls.withValue { $0.append((commerceSessionId, txId)) }
                }
                $0.flexaHandler.flexaAlert = { title, message in
                    alertCalls.withValue { $0.append((title, message)) }
                }
                $0.localAuthentication = .mockAuthenticationSucceeded
                $0.mainQueue = .immediate
                $0.mnemonic = .mock
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.proposeTransfer = { _, _, _, _ in
                    proposeCalls.withValue { $0 += 1 }
                    return .testOnlyFakeProposal(totalFee: 0)
                }
                $0.walletStorage = .noOp
                $0.zcashSDKEnvironment = .testnet
            }

            store.send(.flexaOnTransactionRequest(makeFlexaTransaction()))
            await waitForFlexaStore { alertCalls.withValue { !$0.isEmpty } }

            #expect(transactionSentCalls.withValue { $0.isEmpty })    // nothing signed / reported sent
            #expect(alertCalls.withValue { $0.count } == 1)           // user is prompted (blocked)
            #expect(proposeCalls.withValue { $0 } == 0)               // proposal / seed path never entered
        }
    }
}

@MainActor
private func waitForFlexaStore(
    timeoutNanoseconds: UInt64 = 15_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for Flexa Root store state", sourceLocation: sourceLocation)
}
