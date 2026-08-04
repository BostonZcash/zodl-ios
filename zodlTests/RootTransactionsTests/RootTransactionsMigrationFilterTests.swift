//
//  RootTransactionsMigrationFilterTests.swift
//  zodlTests
//
//  M3 Part A (MOB-1466): Activity shows settled history; the Migration Status screen owns the
//  in-flight story. The engine stores a migration transaction into the wallet's own tables at
//  PROVE time — hours or days before its scheduled broadcast — so without the filter the E2E
//  campaign saw eleven phantom "Sending…" rows minutes after committing a plan. The hide rule
//  itself (unmined ∧ preparation/transfer) is table-tested on `TransactionState`
//  (ModelsTests/TransactionStateTests); this file pins the GLUE: `.fetchedTransactions` — the one
//  canonical build every consumer of the shared `$transactions` reads — actually applies it.
//
//  Mirrors `RootTransactionsAccountSwitchTests`' established pattern for Root-level tests: a plain
//  `Store` (not `TestStore`) — Root's init effects are too heavy for exhaustive assertion — with a
//  file-scoped `baseNoOpDependencies` baseline, kept private to this file per that file's own
//  convention. `.serialized` for the same reason as its sibling: `Root.State` touches the
//  process-global `@Shared(.inMemory(...))` keys.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct RootTransactionsMigrationFilterTests {
    private static func walletAccount(idByte: UInt8) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func row(id: String, kind: ZcashTransaction.Overview.ZIP318Kind, minedHeight: BlockHeight?) -> TransactionState {
        var row = TransactionState(fee: Zatoshi(10), id: id, status: .sending, zecAmount: Zatoshi(100))
        row.minedHeight = minedHeight
        row.zip318Kind = kind
        row.timestamp = 1_000
        return row
    }

    /// The canonical list build drops stored-but-unmined migration rows and keeps everything else:
    /// mined migration history, regular unmined sends, and unclassified rows all survive.
    @Test func fetchedTransactionsHidesUnminedMigrationRows() async {
        let account = Self.walletAccount(idByte: 7)
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        let sharedTransactions = initialState.$transactions
        sharedTransactions.withLock { $0 = [] }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
        }

        let payload = IdentifiedArrayOf<TransactionState>(uniqueElements: [
            row(id: "prep-unmined", kind: .preparation, minedHeight: nil),
            row(id: "transfer-unmined", kind: .transfer, minedHeight: nil),
            row(id: "transfer-mined", kind: .transfer, minedHeight: BlockHeight(100)),
            row(id: "regular-unmined", kind: .notClassified, minedHeight: nil)
        ])

        await store.send(.fetchedTransactions(account.id, payload)).finish()

        let ids = Set(sharedTransactions.wrappedValue.map(\.id))
        #expect(ids == Set(["transfer-mined", "regular-unmined"]))
    }
}

private func baseNoOpDependencies(_ values: inout DependencyValues) {
    values.databaseFiles = .noOp
    values.derivationTool = .liveValue
    values.diskSpaceChecker = .mockFullDisk
    values.flexaHandler = .noOp
    values.localAuthentication = .mockAuthenticationSucceeded
    values.mainQueue = .immediate
    values.mnemonic = .mock
    values.readTransactionsStorage.resetZashi = { }
    values.sdkSynchronizer = .noOp
    values.userMetadataProvider.load = { _ in }
    values.walletStorage = .noOp
    values.zcashSDKEnvironment = .testnet
}
