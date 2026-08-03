//
//  MigrationCacheWarmupTests.swift
//  zodlTests
//
//  MOB-1466 (T8, pre-sweep hydration warm-up). `runProveSweep`'s pre-existing pre-sweep pass
//  (2026-08-02) warmed `bannerVariant`/`migrationTransfers` before flagging work in flight, closing
//  the SmartBanner's own cold-cache stall. The Migration Progress screen's OWN hydration
//  (`statusProgressState`) additionally awaits `migrationSummary` and `migrationPreparationRows` —
//  see `summaryCache`'s doc — which were NOT on that warm-up list. So the sequence launch -> sweep
//  starts -> user taps the SmartBanner "More" before any hydration ever completed still fell
//  through those two guards and waited out proof chunks on the DB actor, once per launch.
//
//  This suite pins the fix: `warmHydrationCaches` now runs all three (transfers, summary,
//  preparation rows) before the sweep's first prove call, for every candidate account.
//
//  THE SHAPE. `runProveSweep`'s warm-up loop and its prove loop are both plain sequential
//  `for`/`await` — no concurrency inside a single call — so by the time the prove closure is
//  entered, every account's warm-up has unconditionally already run. That makes strict ordering
//  provable without an ordered event log: block the prove stub until the test observes it has been
//  entered, snapshot the read counters at that instant (proving the reads already happened), then —
//  simulating the exact banner tap the bug report describes — call all three wrappers AGAIN while
//  still mid-sweep and confirm none of them issues a new SDK read. A wrapper whose cache was never
//  warmed would recompute right there and trip the counter; one whose cache WAS warmed serves the
//  snapshot and leaves the counter untouched.
//
//  `migrationTransfers`/`migrationPreparationRows` share their one underlying SDK read
//  (`migrationTransactionStatuses` — both derive from the engine's live per-transaction statuses,
//  and `migrationState`/`bannerVariant` read it too, so there is no way to split the two into
//  distinct closures in this codebase's actual shape). The "no new read" assertion still fails if
//  EITHER of the two was skipped — a dropped call from the helper always shows up as a fresh read
//  when this test repeats it — so the shared counter does not weaken the proof.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
import ComposableArchitecture
@testable import zodl_internal

// Serialized: installs the wallet-wide candidate account set
// (`@Shared(.inMemory(.selectedWalletAccount))` / `.walletAccounts`) that
// `MigrationDerivations.candidateAccountUUIDs` reads off `MigrationManagerImpl` — the same
// process-global state `MigrationTickDriverTests` serializes its own suite over.
@Suite(.serialized) struct MigrationCacheWarmupTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x42, count: 16))
    /// Testnet NU6.3, mirroring `MigrationTickDriverTests`'s fixture — the tip sits above it, as it
    /// does on any wallet that can see Ironwood at all.
    private static let activationHeight: BlockHeight = 4_134_000
    private static let tip: BlockHeight = 4_200_000

    private static func atTipState() -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = tip
        return state
    }

    private static func account() -> WalletAccount {
        WalletAccount(
            Account(
                id: accountUUID,
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// Installs `accountUUID` as the sole candidate — selected AND the whole wallet-account list —
    /// via the same shared in-memory keys `MigrationManagerImpl.runProveSweep` reads.
    private static func installCandidateAccount() {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        $selectedWalletAccount.withLock { $0 = Self.account() }
        $walletAccounts.withLock { $0 = [Self.account()] }
    }

    /// One ready-to-prove transfer status — enough for `migrationTransfersUntimed`'s W1 fallback
    /// (no committed schedule) to resolve entirely from `MigrationDerivations.statusOnlyTransferRows`
    /// (a non-empty, transfer-kind status list), so `migrationTransfers` produces a non-empty —
    /// therefore cacheable, see `rowsCache`'s "only a non-empty result is worth keeping" doc — row
    /// rather than falling through to a further `migrationProgress` read.
    private static func oneTransferStatus() -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: 1,
            kind: MigrationTransactionStatus.Kind.transfer(crossing: 0),
            state: MigrationTransactionStatus.State.proved,
            scheduledHeight: Self.tip,
            expiryHeight: nil,
            isReady: true,
            nextAction: MigrationTransactionStatus.NextAction.prove,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    private static func someProgress() -> MigrationProgress {
        MigrationProgress(completedTransfers: 0, totalTransfers: 1, remainingOrchard: Zatoshi.zero, nextTransferReadyAtHeight: nil)
    }

    /// Short, repeated real-time polling for a condition driven by a concurrently-running `Task` —
    /// mirrors `MigrationTickDriverTests.waitUntil`, needed here to know the sweep has genuinely
    /// reached (and is parked inside) its first prove call before this test starts inspecting it.
    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// THE regression test — see the file header for the counting/ordering strategy.
    @Test func aMidSweepReadOfAllThreeCachesIsServedWithoutANewSDKCall() async {
        Self.installCandidateAccount()

        let statusReads = LockIsolated<Int>(0)
        let progressReads = LockIsolated<Int>(0)
        let proveEntered = LockIsolated<Bool>(false)
        let releaseProve = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                migrationTransactionStatuses: { _ in
                    statusReads.withValue { $0 += 1 }
                    return [Self.oneTransferStatus()]
                },
                finalizeReadyMigrationTransfers: { _ in
                    proveEntered.setValue(true)
                    while !releaseProve.value {
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    return 0
                },
                getMigrationProgress: { _ in
                    progressReads.withValue { $0 += 1 }
                    return Self.someProgress()
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = MigrationManagerImpl()

            let sweepTask = Task { await manager.runProveSweep() }
            await Self.waitUntil { proveEntered.value }

            // By construction (plain sequential `for`/`await`, no concurrency inside
            // `runProveSweep`), every account's warm-up pass has already run to completion by the
            // time the sweep's first prove call is reachable — this snapshot IS the "before proving
            // starts" instant the fix promises.
            let statusReadsBeforeTap = statusReads.value
            let progressReadsBeforeTap = progressReads.value
            #expect(statusReadsBeforeTap >= 1, "migrationTransfers/migrationPreparationRows must have read live statuses before the sweep could reach its first prove call")
            #expect(progressReadsBeforeTap >= 1, "migrationSummary must have read progress before the sweep could reach its first prove call")

            // The exact scenario from the bug report: the SmartBanner "More" tap opens the
            // Migration Progress screen while the sweep is still proving.
            _ = await manager.migrationTransfers(accountUUID: Self.accountUUID)
            _ = await manager.migrationSummary(accountUUID: Self.accountUUID)
            _ = await manager.migrationPreparationRows(accountUUID: Self.accountUUID)

            #expect(statusReads.value == statusReadsBeforeTap, "a mid-sweep tap must be served from the warmed snapshot, not by re-reading the engine")
            #expect(progressReads.value == progressReadsBeforeTap, "a mid-sweep tap must be served from the warmed snapshot, not by re-reading the engine")

            releaseProve.setValue(true)
            let proved = await sweepTask.value
            #expect(proved == 0, "sanity check — the stubbed prove call itself is untouched by the warm-up, so the sweep still ran to completion")
        }
    }
}
