//
//  RestoreWalletAnnouncementFlagTests.swift
//  zodlTests
//
//  Ironwood announcement, workstream 3 — Features/CoordFlows/RestoreWalletCoordFlowCoordinator.swift
//  marks the Ironwood-announcement keychain flag acknowledged up front when a wallet is freshly
//  created (nothing to announce on a brand-new wallet, and creation is immediately followed by the
//  recovery-phrase backup flow — the worst moment to interrupt with the announcement screen), but
//  deliberately leaves the flag untouched when a wallet is restored (a returning user may have
//  missed the announcement, so the one-time screen must remain eligible to show for them).
//
//  RestoreWalletCoordFlow.State is not Equatable (it holds a non-Equatable StackState, and its
//  Action type — referenced via Action-typed AlertState — isn't Equatable either), so TestStore
//  will not compile against it. These tests instead drive a plain Store and read/record state
//  directly after sending actions — the same approach used by AddKeystoneHWWalletCoordFlowTests
//  (see its header comment) and ScanCoordFlowZip321Tests. Initial state is set up before Store
//  creation, never via store.state mutation (get-only on a plain Store).
//
//  Both cases under test perform their walletStorage calls synchronously inside the reducer body,
//  before any returned effect runs, so no polling/waiting is needed after `send`.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RestoreWalletAnnouncementFlagTests {
    @Test func createNewWalletRequestedWritesIronwoodAnnouncementFlagTrueExactlyOnce() async {
        let calls = LockIsolated<[Bool]>([])
        let store = makeStore(initialState: RestoreWalletCoordFlow.State(), flagCalls: calls)

        store.send(.createNewWalletRequested)

        #expect(calls.value == [true])
    }

    @Test func resolveRestoreNeverWritesIronwoodAnnouncementFlag() async {
        var initialState = RestoreWalletCoordFlow.State()
        initialState.birthday = 1_000_000
        let calls = LockIsolated<[Bool]>([])
        let store = makeStore(initialState: initialState, flagCalls: calls)

        store.send(.resolveRestore)

        // Restoring a seed must leave the Ironwood-announcement flag completely untouched — not
        // even written `false` — so the one-time announcement screen remains eligible to show for
        // this returning user. Asserting an empty call list (rather than inspecting the argument
        // of some expected call) is what would catch someone "fixing" this asymmetry later by
        // adding a call here to mirror .createNewWalletRequested.
        #expect(calls.value.isEmpty)
    }

    // MARK: - Helpers

    private func makeStore(
        initialState: RestoreWalletCoordFlow.State,
        flagCalls: LockIsolated<[Bool]>
    ) -> StoreOf<RestoreWalletCoordFlow> {
        Store(initialState: initialState) {
            RestoreWalletCoordFlow()
        } withDependencies: {
            $0.mnemonic = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.importIronwoodAnnouncementFlag = { value in
                flagCalls.withValue { $0.append(value) }
            }
        }
    }
}
