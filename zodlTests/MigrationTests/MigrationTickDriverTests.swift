//
//  MigrationTickDriverTests.swift
//  zodlTests
//
//  MOB-1466 — the `.tick` phase's DRIVER-side mechanics, exercised against a real
//  `MigrationManagerImpl` with a stubbed SDK rather than the pure decision table
//  (`MigrationStepPlanTests` already pins that a tick's `.broadcast` column matches `.beforeSync`'s).
//  Three properties live only here, in the executor:
//
//   - THE MODE BELT. A tick may broadcast for a `.privateScheduled` run and must not for an
//     `.immediate` one — `.immediate` still gets its one delivery from the open lanes, and ticking
//     it too would send the moment Ironwood activates rather than at the user's chosen pace.
//   - THE SINGLE-FLIGHT LATCH. A `.tick` arriving while another `advance` is in flight must yield
//     (`.skipped`) WITHOUT touching the engine — ticks fire every 30s and must never queue up behind
//     a slower `.beforeSync`/`.afterSync` call, or behind each other. A `.beforeSync`/`.afterSync`
//     caller, by contrast, always waits its turn and runs — an app-open's own driver call must never
//     be silently dropped for arriving mid-tick.
//   - THE PRIVACY-BUFFER FAST PATH. A tick that arrives while the buffer holds must say so cheaply,
//     without spending a per-account engine read to learn what the buffer already knew.
//
//  Arming hygiene (quiet ticks must not re-arm notifications) is pinned here too, at the driver
//  level, per this feature's own spec — arming is `advance`'s business, not Root's.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
import ComposableArchitecture
@testable import zodl_internal

// Serialized: every test here installs the wallet-wide candidate account set
// (`@Shared(.inMemory(.selectedWalletAccount))` / `.walletAccounts`) that
// `MigrationDerivations.candidateAccountUUIDs` reads off `MigrationManagerImpl` — the same
// process-global state `MigrationSyncCompleteEdgeTests`/`RootMigrationGateRefusalTests` serialize
// their own suites over.
@Suite(.serialized) struct MigrationTickDriverTests {
    // MARK: - Fixtures

    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x07, count: 16))
    /// Testnet NU6.3, mirroring `MigrationBannerEntryTests`'s fixture — the tip sits above it, as it
    /// does on any wallet that can see Ironwood at all.
    private static let activationHeight: BlockHeight = 4_134_000
    private static let tip: BlockHeight = 4_200_000

    private static func activatedState() -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = tip
        return state
    }

    /// `activatedState()` at `.upToDate` — the follow-mode shape the at-tip tick prove keys off.
    /// (`SynchronizerState.zero`'s own status is NOT up-to-date, which is what keeps every other
    /// test in this suite exercising the off-tip column without saying so.)
    private static func atTipState() -> SynchronizerState {
        var state = activatedState()
        state.syncStatus = .upToDate
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
    /// via the same shared in-memory keys `MigrationManagerImpl.advance` reads. Every test calls
    /// this first; `.serialized` (above) is what makes doing so from several tests safe.
    private static func installCandidateAccount() {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        $selectedWalletAccount.withLock { $0 = Self.account() }
        $walletAccounts.withLock { $0 = [Self.account()] }
    }

    /// A freshly-scoped, isolated gate storage (own `UserDefaults` suite, never `.standard`) with
    /// `accountUUID`'s mode pre-set — mirrors `MigrationSendGateAndArmingTests`'s `storage()` helper.
    private static func freshGateStorage(mode: MigrationMode) -> MigrationGateStorage {
        let suiteName = "MigrationTickDriverTests.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let storage = MigrationGateStorage(userDefaults: UserDefaults(suiteName: suiteName)!)
        storage.setMigrationMode(mode, for: accountUUID)
        return storage
    }

    private static func isHeld(_ verdict: MigrationStepVerdict) -> Bool {
        if case .held = verdict { return true }
        return false
    }

    /// `armNextWindowNotifications` — reached by every SUBSTANTIVE verdict below, and by every
    /// `.beforeSync`/`.afterSync` call regardless of verdict (arming there is unconditional,
    /// unchanged by this feature) — has three members with no macro-supplied default, so
    /// `@Dependency(\.userNotifications)` has no test implementation at all. No existing suite
    /// exercises the real `advance(phase:)` end to end (every other one spies on the whole
    /// `migrationManager.advance` closure instead), so there is no established stub to mirror; this
    /// is a plain, fully inert client.
    private static func stubUserNotifications(_ values: inout DependencyValues) {
        values.userNotifications = UserNotificationsClient(
            authorizationStatus: { .authorized },
            requestAuthorization: { true },
            scheduleMigrationNotification: { _, _, _ in },
            cancelMigrationNotifications: { _ in },
            clearDeliveredMigrationNotifications: { }
        )
    }

    /// Short, repeated real-time polling for a condition driven by a concurrently-running `Task` —
    /// mirrors `MigrationSyncCompleteEdgeTests`'s `waitUntil`, needed here to know a blocked
    /// `advance` call has genuinely reached (and is parked inside) its engine read before this test
    /// starts a second, concurrent call and makes claims about what that second call did or didn't do.
    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - The mode belt

    /// An `.immediate` run gets its one delivery from the open lanes — a tick must hold it, and must
    /// never reach the actual submission call to do so.
    @Test func tickHoldsAnImmediateModeRunWithoutInvokingTheBroadcastLane() async {
        Self.installCandidateAccount()
        let submissionCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in .broadcast(id: 9) },
                executeNextPendingMigrationTransfer: { _, _, _ in
                    submissionCalls.withValue { $0 += 1 }
                    return .executed(.success(txId: "should-never-run"))
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .immediate))
            return await manager.advance(phase: .tick)
        }

        #expect(Self.isHeld(verdict), "expected .held for an immediate-mode run, got \(verdict)")
        #expect(submissionCalls.value == 0, "the broadcast lane must never submit for an immediate-mode tick")
    }

    /// The mirror: a `.privateScheduled` run's due transfer is exactly what a tick exists to send.
    @Test func tickBroadcastsAPrivateScheduledRunsDueTransfer() async {
        Self.installCandidateAccount()
        let submissionCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in .broadcast(id: 9) },
                executeNextPendingMigrationTransfer: { _, _, _ in
                    submissionCalls.withValue { $0 += 1 }
                    return .executed(.success(txId: "abcd"))
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))
            return await manager.advance(phase: .tick)
        }

        #expect(verdict == .broadcast(id: 9))
        #expect(submissionCalls.value == 1, "the broadcast lane must submit exactly once")
    }

    // MARK: - The at-tip tick prove (follow-mode liveness)

    /// Slipstream's follow mode pins the wallet at `.upToDate` with no re-firing sync edge, so a
    /// prove that became ready mid-session sat undischarged until the next app-open (ticks
    /// deferred it as wrong-phase, field-caught 2026-08-02). At the tip, the tick now runs the
    /// sweep itself — this is the driver half of `MigrationStepPlanTests`' at-tip column.
    @Test func tickRunsTheProveSweepWhenTheWalletIsAtTheTip() async {
        Self.installCandidateAccount()
        let sweepCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in .prove(id: 4, kind: .transfer(crossing: 0)) },
                finalizeReadyMigrationTransfers: { _ in
                    sweepCalls.withValue { $0 += 1 }
                    return 1
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))
            return await manager.advance(phase: .tick)
        }

        #expect(verdict == .proved(count: 1), "an at-tip tick must run the sweep, got \(verdict)")
        #expect(sweepCalls.value == 1, "the sweep must run exactly once")
    }

    /// Off the tip a tick still defers the prove — proving against a stale tree stays the sync
    /// edge's business, and the sweep must not run at all.
    @Test func tickOffTheTipStillDefersTheProve() async {
        Self.installCandidateAccount()
        let sweepCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in .prove(id: 4, kind: .transfer(crossing: 0)) },
                finalizeReadyMigrationTransfers: { _ in
                    sweepCalls.withValue { $0 += 1 }
                    return 1
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))
            return await manager.advance(phase: .tick)
        }

        #expect(verdict == .deferredToPhase, "an off-tip tick must keep deferring the prove, got \(verdict)")
        #expect(sweepCalls.value == 0, "the sweep must never run off the tip")
    }

    // MARK: - Held accounts must not starve their siblings (audit 2026-08-03, #4)

    private static let secondAccountUUID = AccountUUID(id: [UInt8](repeating: 0x0C, count: 16))

    private static func secondAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: secondAccountUUID,
                name: "Keystone",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(1),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// The starvation shape: the SELECTED account is `.immediate` with a permanently-due
    /// broadcast (the mode belt holds it on every tick), the second account is `.privateScheduled`
    /// with its own due transfer. The first hold used to end the discharge loop — account B's
    /// delivery never ran, on every tick, for as long as A stayed due.
    @Test func aHeldAccountDoesNotStarveTheNextAccountsDelivery() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        $selectedWalletAccount.withLock { $0 = Self.account() }
        $walletAccounts.withLock { $0 = [Self.account(), Self.secondAccount()] }

        let submittedFor = LockIsolated<[AccountUUID]>([])
        let storage = Self.freshGateStorage(mode: .immediate)
        storage.setMigrationMode(.privateScheduled, for: Self.secondAccountUUID)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { accountUUID in
                    accountUUID == Self.secondAccountUUID ? .broadcast(id: 7) : .broadcast(id: 1)
                },
                executeNextPendingMigrationTransfer: { accountUUID, _, _ in
                    submittedFor.withValue { $0.append(accountUUID) }
                    return .executed(.success(txId: "efgh"))
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: storage)
            return await manager.advance(phase: .tick)
        }

        #expect(verdict == .broadcast(id: 7), "the second account's due transfer must discharge past the first's hold, got \(verdict)")
        #expect(submittedFor.value == [Self.secondAccountUUID], "exactly one submission, for the scheduled account")
    }

    // MARK: - A broadcast verdict means a broadcast LANDED (audit 2026-08-03, #5)

    /// `runBroadcastSession` used to return `true` unconditionally — a `.nothingDue` disagreement
    /// (and every failure) read as `.broadcast(id:)` upstream, making a permanently-failing run
    /// indistinguishable in the log from a healthy one.
    @Test func aNothingDueAttemptAnswersHeldNotBroadcast() async {
        Self.installCandidateAccount()

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in .broadcast(id: 9) },
                executeNextPendingMigrationTransfer: { _, _, _ in .nothingDue }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))
            return await manager.advance(phase: .tick)
        }

        guard case .held = verdict else {
            Issue.record("an attempt that submitted nothing must answer .held, got \(verdict)")
            return
        }
    }

    // MARK: - A blocked run arms a wake-up (audit 2026-08-03, #13)

    /// A `.needsUser` verdict has no prove or send window of its own, so the arming pass used to
    /// retire the poke entirely — a backgrounded wallet NEVER learned it was waiting on the user.
    /// The blocker now contributes a near-term poke candidate.
    @Test func aNeedsUserVerdictArmsANearTermPoke() async {
        Self.installCandidateAccount()
        let scheduled = LockIsolated<[(MigrationNotification, Date?)]>([])

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in .requiresAttention(id: 2) },
                migrationTransactionStatuses: { _ in [] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            $0.userNotifications = UserNotificationsClient(
                authorizationStatus: { .authorized },
                requestAuthorization: { true },
                scheduleMigrationNotification: { notification, date, _ in
                    scheduled.withValue { $0.append((notification, date)) }
                },
                cancelMigrationNotifications: { _ in },
                clearDeliveredMigrationNotifications: { }
            )
        } operation: {
            // R0: open-lane drives need a live session — pinned via the seam, never the global trace.
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )
            // `.afterSync` — the phase whose plan escalates surviving attention to `.needsUser`.
            return await manager.advance(phase: .afterSync)
        }

        guard case .needsUser = verdict else {
            Issue.record("attention at .afterSync must escalate to .needsUser, got \(verdict)")
            return
        }
        #expect(scheduled.value.count == 1, "the blocked run must arm exactly one poke")
        if let date = scheduled.value.first?.1 {
            #expect(date.timeIntervalSinceNow < 120, "the blocker poke is near-term, not a window projection")
        } else {
            Issue.record("the blocker poke must carry a date")
        }
    }

    // MARK: - Step-read failure honesty (audit 2026-08-03, P1)

    /// A THROWN engine read must never flatten into `.noRun` — that verdict self-cancels the tick
    /// loop, so one contended read (a prove sweep holding the wallet DB) used to kill the tick
    /// lane for the rest of the session. The honest answer is `.failed`, which the loop survives.
    @Test func aThrowingStepReadAnswersFailedNotNoRun() async {
        Self.installCandidateAccount()

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    struct ReadFailure: Error { }
                    throw ReadFailure()
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))
            return await manager.advance(phase: .tick)
        }

        guard case .failed = verdict else {
            Issue.record("a thrown step read must answer .failed, got \(verdict)")
            return
        }
    }

    // MARK: - Arming scope (audit 2026-08-03, P1)

    /// Every notification cancel the arming pass makes is SCOPED to the account being armed —
    /// the wallet-wide sweep this used to be erased the OTHER account's just-armed poke on every
    /// per-account pass, leaving a two-account wallet with no armed wake-up at all.
    @Test func armingCancelsOnlyTheArmedAccountsScope() async {
        Self.installCandidateAccount()
        let cancelScopes = LockIsolated<[String?]>([])

        _ = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in .waiting },
                migrationTransactionStatuses: { _ in [] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            $0.userNotifications = UserNotificationsClient(
                authorizationStatus: { .authorized },
                requestAuthorization: { true },
                scheduleMigrationNotification: { _, _, _ in },
                cancelMigrationNotifications: { scope in cancelScopes.withValue { $0.append(scope) } },
                clearDeliveredMigrationNotifications: { }
            )
        } operation: {
            // R0: open-lane drives need a live session — pinned via the seam, never the global trace.
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .beforeSync)
        }

        let expectedScope = Data(Self.accountUUID.id).hexEncodedString()
        #expect(!cancelScopes.value.isEmpty, "the arming pass cancels before it arms")
        #expect(
            cancelScopes.value.allSatisfy { $0 == expectedScope },
            "every cancel must carry the armed account's scope, never the wallet-wide nil — got \(cancelScopes.value)"
        )
    }

    // MARK: - The privacy-buffer fast path

    /// A tick that arrives while the buffer holds must say so WITHOUT spending a per-account engine
    /// read — the whole point of checking the buffer first.
    @Test func tickHeldByThePrivacyBufferReadsNoEngineStep() async {
        Self.installCandidateAccount()
        let engineReadCount = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    engineReadCount.withValue { $0 += 1 }
                    return .broadcast(id: 1)
                },
                migrationPrivacySyncBufferDuration: { 600 }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let gateStorage = Self.freshGateStorage(mode: .privateScheduled)
            // A sync "just completed" moments ago — well inside the 600s buffer.
            gateStorage.recordSyncCompleted(at: Date())
            let manager = MigrationManagerImpl(gateStorage: gateStorage)
            return await manager.advance(phase: .tick)
        }

        #expect(Self.isHeld(verdict), "expected .held while the privacy buffer holds, got \(verdict)")
        #expect(engineReadCount.value == 0, "the fast path must return before any per-account engine read")
    }

    // MARK: - Single-flight

    /// A `.tick` arriving mid-advance yields immediately: `.skipped`, and it must never have touched
    /// the engine to make that decision.
    @Test func tickDuringAnInFlightAdvanceSkipsWithoutReadingTheEngine() async {
        Self.installCandidateAccount()
        let engineReadCount = LockIsolated<Int>(0)
        let firstReadStarted = LockIsolated<Bool>(false)
        let releaseFirstRead = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    engineReadCount.withValue { $0 += 1 }
                    firstReadStarted.setValue(true)
                    while !releaseFirstRead.value {
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    return .waiting
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            // R0: open-lane drives need a live session — pinned via the seam, never the global trace.
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )

            let firstTask = Task { await manager.advance(phase: .beforeSync) }
            await Self.waitUntil { firstReadStarted.value }

            let tickVerdict = await manager.advance(phase: .tick)
            #expect(tickVerdict == .skipped)
            #expect(engineReadCount.value == 1, "a skipped tick must not read the engine at all")

            releaseFirstRead.setValue(true)
            _ = await firstTask.value
        }
    }

    /// The mirror: a `.beforeSync`/`.afterSync` caller arriving mid-advance WAITS its turn (FIFO)
    /// rather than skipping, and actually runs once the in-flight call releases the latch.
    @Test func beforeSyncDuringAnInFlightAdvanceWaitsThenRuns() async {
        Self.installCandidateAccount()
        let engineReadCount = LockIsolated<Int>(0)
        let firstReadStarted = LockIsolated<Bool>(false)
        let releaseFirstRead = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    let thisRead = engineReadCount.withValue { count -> Int in
                        count += 1
                        return count
                    }
                    if thisRead == 1 {
                        firstReadStarted.setValue(true)
                        while !releaseFirstRead.value {
                            try? await Task.sleep(nanoseconds: 5_000_000)
                        }
                    }
                    return .waiting
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            // R0: open-lane drives need a live session — pinned via the seam, never the global
            // trace. The two lanes hold INDEPENDENT credits, so both first drives run under one
            // ordinal and the FIFO property stays the thing this test pins.
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )

            let firstTask = Task { await manager.advance(phase: .beforeSync) }
            await Self.waitUntil { firstReadStarted.value }

            let secondTask = Task { await manager.advance(phase: .afterSync) }
            // The second call must be genuinely PARKED, not running concurrently — prove it has not
            // read the engine a moment later, mirroring `MigrationSyncCompleteEdgeTests`'
            // `theSweepsDoNotRerunWhileAlreadySynced`'s identical real-time "still hasn't" check.
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(engineReadCount.value == 1, "the second call must be parked behind the latch, not running concurrently")

            releaseFirstRead.setValue(true)
            let firstVerdict = await firstTask.value
            let secondVerdict = await secondTask.value

            #expect(firstVerdict == .idle)
            #expect(secondVerdict == .idle)
            #expect(engineReadCount.value == 2, "the second call must run its own engine read once the first released the latch")
        }
    }

    // MARK: - Arming hygiene

    /// A quiet tick verdict must not re-arm notifications — arming reflects the run's ROWS, and a
    /// quiet tick changed none of them. `migrationSyncWakeups` is called from nowhere but
    /// `armNextWindowNotifications`, so counting it is a direct proxy for "did arming run".
    @Test func consecutiveQuietTicksDoNotReArmNotifications() async {
        Self.installCandidateAccount()
        let armingProbeCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in .waiting },
                migrationSyncWakeups: { _ in
                    armingProbeCalls.withValue { $0 += 1 }
                    return []
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))

            let first = await manager.advance(phase: .tick)
            let second = await manager.advance(phase: .tick)
            let third = await manager.advance(phase: .tick)

            #expect(first == .idle)
            #expect(second == .idle)
            #expect(third == .idle)
            #expect(armingProbeCalls.value == 0, "a quiet tick verdict must skip arming entirely")
        }
    }

    // MARK: - stateEvents liveness (the progress screen reloads live)

    /// A tick-phase broadcast must poke `stateEvents` the same way `runBroadcastSession` already
    /// does for an open — proving a screen subscribed to it reloads live while the tick's headless
    /// submission is in flight, not only after the driver returns.
    @Test func tickBroadcastPokesStateEventsLive() async {
        Self.installCandidateAccount()

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in .broadcast(id: 3) },
                executeNextPendingMigrationTransfer: { _, _, _ in .executed(.success(txId: "abcd")) }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))

            let received = LockIsolated<[MigrationState]>([])
            let cancellable = manager.stateEvents(accountUUID: Self.accountUUID).sink { state in
                received.withValue { $0.append(state) }
            }

            _ = await manager.advance(phase: .tick)

            #expect(!received.value.isEmpty, "a subscriber must see at least one emission during/after the tick broadcast")
            cancellable.cancel()
        }
    }
}
