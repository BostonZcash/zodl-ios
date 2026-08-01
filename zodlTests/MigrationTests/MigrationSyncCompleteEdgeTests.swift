//
//  MigrationSyncCompleteEdgeTests.swift
//  zodlTests
//
//  The sync-complete edge must run the migration sweeps on a wallet that HAS an account.
//
//  Field-caught 2026-07-31, and the most consequential defect of the session. `Root`'s
//  `.synchronizerStateChanged` case built `migrationReconcileEffect` on the edge into `.upToDate` —
//  prove sweep, reconcile, notification arming — and then returned it from
//  exactly ONE path:
//
//      guard let account = state.selectedWalletAccount else {
//          return migrationReconcileEffect     // the ONLY return that carried it
//      }
//
//  Every later `return` in that case discarded it. So the entire migration edge ran only when NO
//  account was selected — precisely the case with nothing to migrate — and never on a real wallet.
//
//  What that looked like on a device: the engine asked to prove preparation (0,0) at every open,
//  forever; nothing proved it, so nothing was ever broadcast; a committed run sat at 0-of-12 with
//  all four preparations reading "Ready now". A migration that could not take its first step.
//
//  Note what this did NOT look like: an error. No throw, no failed call, no red anything. An effect
//  was constructed and dropped, which is invisible from every angle except the absence of work.
//  Giving the sweeps their callers (board A24/A28) was necessary and not sufficient — the callers
//  existed and their effect was thrown away one line later.
//
//  So the tests below assert the sweeps RUN, on the path that matters (an account IS selected), and
//  do not assert anything about what they return. Reaching them was the whole bug.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationSyncCompleteEdgeTests {
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

    private static func upToDateState() -> RedactableSynchronizerState {
        var state = SynchronizerState.zero
        state.syncStatus = .upToDate
        state.latestBlockHeight = 4_200_000
        return state.redacted
    }

    /// Records which sweeps ran. `reconcile` is included because it is what refreshes the banner
    /// after the sweeps — a run whose proofs land but whose UI never updates is its own bug.
    private struct SweepSpy: Sendable {
        let proveSweeps = LockIsolated(0)
        let reconciles = LockIsolated(0)

        func install(_ values: inout DependencyValues) {
            var client = MigrationManagerClient.noOp
            client.recordSyncCompleted = { }
            client.runProveSweep = { proveSweeps.withValue { $0 += 1 }; return 0 }
            client.reconcile = { reconciles.withValue { $0 += 1 } }
            client.armNextWindowNotifications = { _ in }
            values.migrationManager = client
        }
    }

    // MARK: - The regression

    /// THE test. An account is selected — the ordinary case, and the one that was broken — and sync
    /// reaches the tip. Both must run. (The invalidation sweep used to be pinned here too; both of
    /// its jobs are the engine's now, recorded/promoted on every `migrationAdvanceStep` read.)
    @Test func theSweepsRunWhenAnAccountIsSelected() async {
        let spy = SweepSpy()
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = Self.walletAccount(idByte: 90) }

        let store = Store(initialState: initialState) { Root() } withDependencies: {
            baseMigrationEdgeDependencies(&$0)
            spy.install(&$0)
        }

        store.send(.synchronizerStateChanged(Self.upToDateState()))
        await waitUntil { spy.proveSweeps.value > 0 && spy.reconciles.value > 0 }

        #expect(spy.proveSweeps.value == 1, "the prove sweep is what produces the proofs the engine keeps asking for")
        #expect(spy.reconciles.value == 1, "without reconcile the proofs land and no surface ever says so")
    }

    /// The edge fires ONCE per arrival at the tip, not on every tick while already synced — the
    /// property the `wasSyncUpToDateForMigration` latch exists for. Pinned alongside the fix so
    /// "make sure it runs" cannot quietly become "run it constantly", which would storm the engine
    /// with proving work at the tip.
    @Test func theSweepsDoNotRerunWhileAlreadySynced() async {
        let spy = SweepSpy()
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = Self.walletAccount(idByte: 91) }

        let store = Store(initialState: initialState) { Root() } withDependencies: {
            baseMigrationEdgeDependencies(&$0)
            spy.install(&$0)
        }

        store.send(.synchronizerStateChanged(Self.upToDateState()))
        await waitUntil { spy.proveSweeps.value > 0 }
        store.send(.synchronizerStateChanged(Self.upToDateState()))
        store.send(.synchronizerStateChanged(Self.upToDateState()))
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(spy.proveSweeps.value == 1, "three ticks at the tip, one arrival")
    }

    /// The path that always worked keeps working — no account, still swept. Kept so the fix reads as
    /// "carried to every return" rather than "moved from one return to another".
    @Test func theSweepsStillRunWithNoAccountSelected() async {
        let spy = SweepSpy()
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = nil }

        let store = Store(initialState: initialState) { Root() } withDependencies: {
            baseMigrationEdgeDependencies(&$0)
            spy.install(&$0)
        }

        store.send(.synchronizerStateChanged(Self.upToDateState()))
        await waitUntil { spy.proveSweeps.value > 0 }

        #expect(spy.proveSweeps.value == 1)
    }
}

private func baseMigrationEdgeDependencies(_ values: inout DependencyValues) {
    values.audioServices = AudioServicesClient(systemSoundVibrate: { })
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

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 10_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
