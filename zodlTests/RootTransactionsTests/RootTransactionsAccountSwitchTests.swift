//
//  RootTransactionsAccountSwitchTests.swift
//  zodlTests
//
//  Switching between the ZODL software account and a Keystone hardware-wallet account left the
//  TRANSACTION HISTORY showing the previous account (balance switched correctly). Root cause:
//  `.fetchTransactionsForTheSelectedAccount`'s `.run` effect (`RootTransactions.swift`) reads the
//  account at DISPATCH time with no cancel id, and `.fetchedTransactions` writes the shared
//  `state.transactions` with no provenance check -- an in-flight fetch for the OLD account can
//  complete AFTER a switch and overwrite the correct list (last-writer-wins). Separately, the
//  Keystone-connect auto-select (`AddHWWalletStore`'s `.loadedWalletAccounts`) wrote
//  `selectedWalletAccount` directly with no refetch/balance reaction at all, and the manual
//  switcher only invalidated Home's mini transaction list, not the "See All" screen's.
//
//  Mirrors `FlexaTests/FlexaSecurityTests.swift`'s established pattern for Root-level tests: a
//  plain `Store` (not `TestStore`) driven with `LockIsolated` spies and polling -- Root's init
//  effects are too heavy for exhaustive `TestStore` assertion. Keeps its own private
//  `waitForRootStore` polling helper and `baseNoOpDependencies` no-op dependency baseline,
//  file-scoped rather than shared, the same way that file keeps its own private
//  `waitForFlexaStore` helper local to itself.
//
//  `.serialized`: constructing/driving `Root.State` touches the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` / `.inMemory(.transactions)` / `.inMemory(.walletAccounts)`
//  keys, same precedent as `FlexaTests/FlexaSecurityTests.swift`, which serializes for the same
//  reason (it also drives a Root store touching this process-global state).
//
//  The only live Keystone-connect completion signal is
//  `.addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .keystoneDeviceReady(.accountImportSucceeded))))`
//  -- see `keystoneAutoSelectImmediatelyRefreshesTransactionsAndBalance` below. Both
//  `.accountHWWalletSelection(.accountImportSucceeded)` arms (`AddKeystoneHWWalletCoordFlow`'s own
//  and `Settings`'s) are defensive/dead wiring, not reachable UI paths -- see
//  `settingsAccountHWWalletSelectionAppliesSwitchReactionsAsDefensiveWiring`'s doc comment for why.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootTransactionsAccountSwitchTests {
    private static func walletAccount(idByte: UInt8, keystone: Bool = false) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: keystone ? "Keystone" : "Zodl",
                keySource: keystone ? String(localizable: .accountsKeystone).lowercased() : nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func tx(id: String) -> TransactionState {
        TransactionState(fee: Zatoshi(10), id: id, status: .received, zecAmount: Zatoshi(100_000))
    }

    /// A distinctive, nonzero balance used by the Keystone-parity tests below to prove
    /// `.home(.walletBalances(.updateBalances))` specifically fired -- `getAccountsBalances` is
    /// ALSO called independently by SmartBanner's own priority evaluation
    /// (`SmartBannerStore.swift:551`), so a raw call-count spy alone can't tell the two apart; only
    /// `walletBalancesState` actually landing this value proves the real round trip happened.
    private static let keystoneBalance = AccountBalance(
        saplingBalance: .zero,
        orchardBalance: PoolBalance(spendableValue: Zatoshi(555_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
        unshielded: .zero
    )

    // MARK: - (a) Provenance guard: a stale fetch for the OLD account must never overwrite

    /// The exact race from the bug report: a fetch dispatched for account A is still in flight when
    /// the user switches to account B; A's payload finally arrives AFTER the switch. It must be
    /// dropped, never applied -- proven by directly injecting the late `.fetchedTransactions` action
    /// while B is already selected, simulating the effect a real in-flight fetch would have
    /// produced once it finally completed.
    @Test func staleFetchFromPreviousAccountIsDroppedAfterSwitch() async {
        let accountA = Self.walletAccount(idByte: 60)
        let accountB = Self.walletAccount(idByte: 61)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountB }
        let currentForB = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "b-tx")])
        initialState.$transactions.withLock { $0 = currentForB }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
        }

        // A's stale payload, arriving after B is already selected.
        let staleForA = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "a-tx")])
        store.send(.fetchedTransactions(accountA.id, staleForA))

        #expect(store.state.transactions == currentForB)
        #expect(store.state.selectedWalletAccount == accountB)
    }

    /// The guard must not be so broad that it drops a legitimate update for the account that IS
    /// currently selected.
    @Test func fetchedTransactionsForTheCurrentlySelectedAccountStillApplies() async {
        let account = Self.walletAccount(idByte: 65)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
        }

        let freshTransactions = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "fresh-tx")])
        store.send(.fetchedTransactions(account.id, freshTransactions))

        #expect(store.state.transactions == freshTransactions)
    }

    // MARK: - (b) Switching cancels the in-flight fetch for the previous account

    /// A slow fetch for account A must be CANCELLED the moment the user switches to B -- the fetch's
    /// own completion effect (a `send`) must never run for A once the switch happens. Proven by
    /// making the mocked `getAllTransactions` closure hang on a cancellable `Task.sleep` for A only,
    /// and observing that cancellation actually reaches it (not just that state stays correct --
    /// that's the provenance-guard test above).
    @Test func switchingAccountsCancelsInFlightFetchForThePreviousAccount() async {
        let accountA = Self.walletAccount(idByte: 62)
        let accountB = Self.walletAccount(idByte: 63)
        let callsStarted = LockIsolated<[AccountUUID]>([])
        let aFetchCompleted = LockIsolated<Bool>(false)
        let aFetchCancelled = LockIsolated<Bool>(false)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountA }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                if let accountUUID {
                    callsStarted.withValue { $0.append(accountUUID) }
                }
                if accountUUID == accountA.id {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        aFetchCompleted.setValue(true)
                    } catch {
                        aFetchCancelled.setValue(true)
                        throw error
                    }
                }
                return []
            }
        }

        store.send(.fetchTransactionsForTheSelectedAccount)
        await waitForRootStore(timeoutNanoseconds: 3_000_000_000) { callsStarted.value.contains(accountA.id) }

        store.send(.home(.walletAccountTapped(accountB)))
        await waitForRootStore(timeoutNanoseconds: 3_000_000_000) { aFetchCancelled.value }

        #expect(aFetchCancelled.value)
        #expect(!aFetchCompleted.value)
    }

    // MARK: - A later fetch dispatch during a sync must not starve an earlier one

    /// Two traps an earlier draft of this test fell into -- both worth naming so they don't come
    /// back:
    ///
    /// 1. A FINITE burst of dispatches is not a valid regression guard. Whichever dispatch is
    ///    LAST has nothing after it to cancel it, so it always survives to completion under both
    ///    the shared-id `cancelInFlight: true` bug and the fix -- asserting only that "a" result
    ///    landed passes either way and proves nothing. The assertion has to be about a SPECIFIC
    ///    earlier dispatch's own result landing, never about any result landing.
    /// 2. A wall-clock window is not safe either. An earlier draft mocked `getAllTransactions` to
    ///    sleep, kept re-dispatching faster than that sleep from a background loop, and asserted
    ///    the result showed up within a fixed time budget. Swift Testing runs suites in parallel,
    ///    and under the load of the full suite that budget can blow even with the fix in place --
    ///    the test needs to tell "never" apart from "eventually", not "fast" apart from "slow".
    ///
    /// This version replaces both the burst and the clock with explicit gates:
    ///  - the mocked `getAllTransactions` hands out a distinct call index per invocation (a
    ///    `LockIsolated<Int>` counter) and returns a transaction identified by that index alone
    ///    (`"fetch-1"`, `"fetch-2"`, ...), recording which indices have STARTED in a
    ///    `LockIsolated<Set<Int>>`;
    ///  - call #1 BLOCKS on a `LockIsolated<Bool>` release flag, polled with the THROWING form of
    ///    `Task.sleep` -- never `try?` here, or a cancellation of this effect would be silently
    ///    swallowed instead of propagating out as the dropped result it needs to be;
    ///  - call #2 (and any later call) returns immediately.
    ///
    /// The sequence: dispatch A, wait for call #1 to start, dispatch B -- the exact moment the
    /// shared-id bug would cancel A -- wait for call #2 to start, and only THEN release call #1.
    /// Under the fix, A survives B untouched and, once released, lands `"fetch-1"`, overwriting
    /// whatever B already wrote; the wait below finds it quickly regardless of machine load, so
    /// giving it a generous budget costs nothing. Under the bug, A was cancelled the instant B was
    /// dispatched, so `"fetch-1"` can NEVER land no matter how long the wait runs -- `"fetch-2"`
    /// lands instead and stays there, which is exactly why the assertion names the id instead of
    /// accepting any result. The pass/fail signal is never-versus-eventually: load can slow the
    /// test down, but it can never flip the verdict.
    @Test func earlierFetchDispatchSurvivesALaterDispatchAndLandsItsOwnResult() async {
        let account = Self.walletAccount(idByte: 69)

        let callIndex = LockIsolated<Int>(0)
        let callsStarted = LockIsolated<Set<Int>>([])
        let releaseFirstCall = LockIsolated<Bool>(false)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { _ in
                let index = callIndex.withValue { value -> Int in
                    value += 1
                    return value
                }
                callsStarted.withValue { $0.insert(index) }

                if index == 1 {
                    // Throwing sleep is load-bearing: if the shared-id bug cancels this effect
                    // the moment dispatch B registers, that cancellation must propagate out of
                    // this closure as a thrown error -- `try?` would swallow it and hang forever.
                    while !releaseFirstCall.value {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                }

                let transaction = TransactionState(
                    fee: Zatoshi(10),
                    id: "fetch-\(index)",
                    status: .received,
                    zecAmount: Zatoshi(100_000)
                )
                return IdentifiedArrayOf<TransactionState>(uniqueElements: [transaction])
            }
        }

        store.send(.fetchTransactionsForTheSelectedAccount)
        await waitForRootStore(timeoutNanoseconds: 5_000_000_000) { callsStarted.value.contains(1) }

        // The exact moment the shared-id/`cancelInFlight` bug would cancel call #1.
        store.send(.fetchTransactionsForTheSelectedAccount)
        await waitForRootStore(timeoutNanoseconds: 5_000_000_000) { callsStarted.value.contains(2) }

        releaseFirstCall.setValue(true)

        // Generous on purpose: under the fix this resolves almost immediately, and under the bug
        // it can never resolve at all, so a wide budget only ever costs time in the broken case.
        await waitForRootStore(timeoutNanoseconds: 10_000_000_000) {
            store.state.transactions.contains { $0.id == "fetch-1" }
        }

        #expect(store.state.transactions.contains { $0.id == "fetch-1" })
    }

    // MARK: - (c) Keystone-connect auto-select parity

    /// `AddHWWalletStore`'s `.loadedWalletAccounts` flips `state.selectedWalletAccount` directly
    /// (no Root-visible "switch" action of its own) immediately before sending
    /// `.accountImportSucceeded` in the same effect -- Root must react to that signal exactly like
    /// the manual switcher: refetch transactions for the NEW account and refresh its balance,
    /// without waiting for the user to dismiss the "Keystone Connected" confirmation screen.
    @Test func keystoneAutoSelectImmediatelyRefreshesTransactionsAndBalance() async {
        let zashiAccount = Self.walletAccount(idByte: 70)
        let keystoneAccount = Self.walletAccount(idByte: 71, keystone: true)
        let requestedAccounts = LockIsolated<[AccountUUID]>([])
        let balanceRequests = LockIsolated<Int>(0)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = zashiAccount }
        initialState.$walletAccounts.withLock { $0 = [zashiAccount] }
        initialState.path = Root.State.Path.addKeystoneHWWalletCoordFlow
        initialState.addKeystoneHWWalletCoordFlowState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State()))
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        guard let keystoneDeviceReadyId = initialState.addKeystoneHWWalletCoordFlowState.path.ids.last else {
            Issue.record("expected a keystoneDeviceReady element id on the Add Keystone HW Wallet path")
            return
        }

        // Mirrors AddHWWalletStore's own `.loadedWalletAccounts`, which writes this SAME shared
        // state directly, immediately before `.accountImportSucceeded` is sent (same `.run` effect)
        // -- by the time Root observes `.accountImportSucceeded`, the switch has already happened.
        initialState.$selectedWalletAccount.withLock { $0 = keystoneAccount }
        initialState.$walletAccounts.withLock { $0 = [zashiAccount, keystoneAccount] }

        let keystoneTx = tx(id: "keystone-tx")
        // Captured as a local first -- `Self.keystoneBalance` is `@MainActor`-isolated (via the
        // enclosing suite), but `getAccountsBalances` below is `@Sendable`.
        let keystoneBalance = Self.keystoneBalance

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            // `getAccountsBalances` is a `let` on `SDKSynchronizerClient`, so it can't be mutated
            // in place like `getAllTransactions` -- replace the whole client via `.mocked(...)`.
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getAllTransactions: { accountUUID in
                    if let accountUUID {
                        requestedAccounts.withValue { $0.append(accountUUID) }
                    }
                    return IdentifiedArrayOf(uniqueElements: [keystoneTx])
                },
                getAccountsBalances: {
                    balanceRequests.withValue { $0 += 1 }
                    return [keystoneAccount.id: keystoneBalance]
                }
            )
        }

        store.send(
            .addKeystoneHWWalletCoordFlow(
                .path(.element(id: keystoneDeviceReadyId, action: .keystoneDeviceReady(.accountImportSucceeded)))
            )
        )

        await waitForRootStore { store.state.transactions.contains { $0.id == "keystone-tx" } }
        // `getAccountsBalances` is ALSO called independently by SmartBanner's own priority
        // evaluation (`SmartBannerStore.swift:551`), so `balanceRequests > 0` alone can't prove
        // `.home(.walletBalances(.updateBalances))` specifically fired -- wait for its OWN
        // observable effect (the balance actually landing in `walletBalancesState`) too.
        await waitForRootStore { store.state.homeState.walletBalancesState.shieldedBalance == keystoneBalance.shieldedSpendableValue }

        #expect(requestedAccounts.value.contains(keystoneAccount.id))
        #expect(!requestedAccounts.value.contains(zashiAccount.id))
        #expect(balanceRequests.value > 0)
        #expect(store.state.homeState.walletBalancesState.shieldedBalance == keystoneBalance.shieldedSpendableValue)
        #expect(store.state.homeState.transactionListState.isInvalidated)
        #expect(store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated)
    }

    // MARK: - Keystone-connect auto-select must reload user metadata before decorating transactions

    /// `.fetchedTransactions` (`RootTransactions.swift`) decorates the fetched list from
    /// `userMetadataProvider.allSwaps()`, not from the SDK -- a transaction whose `zAddress` matches
    /// a swap's `depositAddress` gets its `type`/`swapStatus` rewritten, and every swap-to-ZEC gets a
    /// synthetic row appended. `UserMetadataStorage` holds ONE in-memory state, for whichever account
    /// was loaded last, so without a metadata reload the freshly imported Keystone account's
    /// transactions get decorated with the PREVIOUS (ZODL) account's swap metadata. Proven by making
    /// `allSwaps()` answer with a ZODL swap until the `load` spy fires, then `[]` after -- if the
    /// fetched Keystone transaction lands still decorated with that stale swap, metadata was never
    /// reloaded before the fetch's decoration step ran.
    @Test func keystoneAutoSelectReloadsUserMetadataBeforeDecoratingTheFetchedList() async {
        let zashiAccount = Self.walletAccount(idByte: 76)
        let keystoneAccount = Self.walletAccount(idByte: 77, keystone: true)
        let loadCalled = LockIsolated<Bool>(false)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = zashiAccount }
        initialState.$walletAccounts.withLock { $0 = [zashiAccount] }
        initialState.path = Root.State.Path.addKeystoneHWWalletCoordFlow
        initialState.addKeystoneHWWalletCoordFlowState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State()))
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        guard let keystoneDeviceReadyId = initialState.addKeystoneHWWalletCoordFlowState.path.ids.last else {
            Issue.record("expected a keystoneDeviceReady element id on the Add Keystone HW Wallet path")
            return
        }

        // Mirrors AddHWWalletStore's own `.loadedWalletAccounts`, which writes this SAME shared
        // state directly, immediately before `.accountImportSucceeded` is sent (same `.run` effect)
        // -- by the time Root observes `.accountImportSucceeded`, the switch has already happened.
        initialState.$selectedWalletAccount.withLock { $0 = keystoneAccount }
        initialState.$walletAccounts.withLock { $0 = [zashiAccount, keystoneAccount] }

        // The stale ZODL account's swap -- a swap FROM zec whose deposit address matches the
        // Keystone transaction fetched below, so the decoration would visibly apply if `allSwaps()`
        // were still answering for the previous account instead of the freshly selected one.
        let staleZAddress = "stale-zodl-swap-deposit-address"
        let staleZodlSwap = UMSwapId(
            depositAddress: staleZAddress,
            provider: "near",
            totalFees: 0,
            totalUSDFees: "0",
            lastUpdated: 0,
            fromAsset: SwapConstants.zecAssetIdOnNear,
            toAsset: "near.usdc.usdc",
            exactInput: true,
            status: SwapConstants.success,
            amountOutFormatted: "0"
        )

        let keystoneTxId = "keystone-tx-matching-stale-zodl-swap"
        let keystoneTx = TransactionState(
            zAddress: staleZAddress,
            fee: Zatoshi(10),
            id: keystoneTxId,
            status: .received,
            zecAmount: Zatoshi(100_000)
        )

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { _ in
                IdentifiedArrayOf(uniqueElements: [keystoneTx])
            }
            // Flips the moment `.loadUserMetadata` reloads for the newly selected account --
            // mirrors `UserMetadataStorage` holding a single in-memory state that `load` replaces.
            $0.userMetadataProvider.load = { _ in loadCalled.setValue(true) }
            $0.userMetadataProvider.allSwaps = {
                loadCalled.value ? [] : [staleZodlSwap]
            }
        }

        store.send(
            .addKeystoneHWWalletCoordFlow(
                .path(.element(id: keystoneDeviceReadyId, action: .keystoneDeviceReady(.accountImportSucceeded)))
            )
        )

        await waitForRootStore { store.state.transactions.contains { $0.id == keystoneTxId } }

        guard let landedTransaction = store.state.transactions[id: keystoneTxId] else {
            Issue.record("expected the Keystone transaction to have landed in state.transactions")
            return
        }

        #expect(landedTransaction.type != .swapFromZec)
        #expect(landedTransaction.type != .crossPay)
        // `TransactionState.swapStatus` isn't Optional -- its un-decorated default is `.pending`
        // (see the `tx(id:)` helper above), so "never decorated" reads as still-default here rather
        // than `nil`. The stale swap above uses `SwapConstants.success` (-> `.completed`)
        // specifically so a wrongly-applied decoration would visibly move this off `.pending`.
        #expect(landedTransaction.swapStatus == .pending)
        #expect(store.state.transactions.count == 1)
        #expect(loadCalled.value)
    }

    /// `Settings.Path.accountHWWalletSelection(.accountImportSucceeded)` is DEFENSIVE wiring, not a
    /// live UI path -- `Settings.Path` has no `.keystoneDeviceReady` case at all, and
    /// `SettingsCoordinator.swift` has no handler for `.accountHWWalletSelection(.nextTapped)`, so
    /// `AccountsSelectionView` is a dead end when reached from Settings; `.unlockTapped` (and
    /// therefore `.accountImported`/`.accountImportSucceeded`) is never reachable from that step.
    /// (The SAME is true of `AddKeystoneHWWalletCoordFlow`'s own `.accountHWWalletSelection(.accountImportSucceeded)`
    /// arm above it in `RootCoordinator.swift` -- its `.nextTapped` only ever pushes forward to
    /// `.keystoneDeviceReady`, never fires unlock directly from that step either.) Live coverage of
    /// the Keystone-connect parity fix is `keystoneAutoSelectImmediatelyRefreshesTransactionsAndBalance`
    /// above (`.keystoneDeviceReady(.accountImportSucceeded)`, the one actually-reachable completion
    /// signal). This test still earns its keep as a regression guard for the dead/defensive arm: if
    /// it's ever wired live (or the dead branch is deleted and this one repurposed), the switch
    /// reactions must already be correct here.
    @Test func settingsAccountHWWalletSelectionAppliesSwitchReactionsAsDefensiveWiring() async {
        let zashiAccount = Self.walletAccount(idByte: 72)
        let keystoneAccount = Self.walletAccount(idByte: 73, keystone: true)
        let requestedAccounts = LockIsolated<[AccountUUID]>([])
        let balanceRequests = LockIsolated<Int>(0)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = zashiAccount }
        initialState.$walletAccounts.withLock { $0 = [zashiAccount] }
        initialState.path = Root.State.Path.settings
        initialState.settingsState.path.append(.accountHWWalletSelection(AddKeystoneHWWallet.State()))
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        guard let elementId = initialState.settingsState.path.ids.last else {
            Issue.record("expected an accountHWWalletSelection element id on the Settings path")
            return
        }

        initialState.$selectedWalletAccount.withLock { $0 = keystoneAccount }
        initialState.$walletAccounts.withLock { $0 = [zashiAccount, keystoneAccount] }

        let keystoneTx = tx(id: "keystone-settings-tx")
        // Captured as a local first -- `Self.keystoneBalance` is `@MainActor`-isolated (via the
        // enclosing suite), but `getAccountsBalances` below is `@Sendable`.
        let keystoneBalance = Self.keystoneBalance

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            // `getAccountsBalances` is a `let` on `SDKSynchronizerClient`, so it can't be mutated
            // in place like `getAllTransactions` -- replace the whole client via `.mocked(...)`.
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getAllTransactions: { accountUUID in
                    if let accountUUID {
                        requestedAccounts.withValue { $0.append(accountUUID) }
                    }
                    return IdentifiedArrayOf(uniqueElements: [keystoneTx])
                },
                getAccountsBalances: {
                    balanceRequests.withValue { $0 += 1 }
                    return [keystoneAccount.id: keystoneBalance]
                }
            )
        }

        store.send(
            .settings(
                .path(.element(id: elementId, action: .accountHWWalletSelection(.accountImportSucceeded)))
            )
        )

        await waitForRootStore { store.state.transactions.contains { $0.id == "keystone-settings-tx" } }
        // See the sibling test's comment: `getAccountsBalances` is ALSO called independently by
        // SmartBanner's own priority evaluation, so wait for the update to actually land too.
        await waitForRootStore { store.state.homeState.walletBalancesState.shieldedBalance == keystoneBalance.shieldedSpendableValue }

        #expect(requestedAccounts.value.contains(keystoneAccount.id))
        #expect(balanceRequests.value > 0)
        #expect(store.state.homeState.walletBalancesState.shieldedBalance == keystoneBalance.shieldedSpendableValue)
        #expect(store.state.homeState.transactionListState.isInvalidated)
        #expect(store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated)
        #expect(store.state.path == nil)
    }

    // MARK: - (d) See-All invalidation mirrors Home's on every switch

    @Test func walletAccountSwitchInvalidatesBothHomeAndSeeAllTransactionLists() async {
        let accountA = Self.walletAccount(idByte: 67)
        let accountB = Self.walletAccount(idByte: 68)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountA }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
        }

        store.send(.home(.walletAccountTapped(accountB)))

        #expect(store.state.homeState.transactionListState.isInvalidated)
        #expect(store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated)
        #expect(store.state.selectedWalletAccount == accountB)
    }

    // MARK: - (e) An unchanged fetch result must still clear the loading state

    /// `.fetchedTransactions` (`RootTransactions.swift`) only writes `state.transactions` -- and
    /// that write is the ONLY thing whose downstream `transactionsUpdated` clears `isInvalidated` on
    /// either list -- when the freshly fetched payload differs from what's already there (`if
    /// state.transactions != identifiedArray`). Switching between two accounts that BOTH have no
    /// transactions is exactly the case where the fetch's result (`[]`) equals what's already
    /// sitting in `state.transactions` (also `[]`, left over from account A): nothing gets written,
    /// so without a completion signal on that unchanged branch too, both lists are stuck showing
    /// their loading placeholder forever. This is the real Keystone-connect path: connecting a
    /// Keystone whose wallet also happens to have no transactions yet, right after
    /// `accountSwitchedEffect` has already flipped both flags to `true`.
    @Test func switchingBetweenTwoEmptyAccountsClearsTheLoadingState() async {
        let accountA = Self.walletAccount(idByte: 74)
        let accountB = Self.walletAccount(idByte: 75)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountA }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
        initialState.$transactions.withLock { $0 = [] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { _ in
                []
            }
        }

        store.send(.home(.walletAccountTapped(accountB)))

        await waitForRootStore(timeoutNanoseconds: 3_000_000_000) {
            !store.state.homeState.transactionListState.isInvalidated
                && !store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated
        }

        #expect(!store.state.homeState.transactionListState.isInvalidated)
        #expect(!store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated)
    }

    // MARK: - No-op guard regression

    /// Re-selecting the already-selected account must remain a complete no-op -- no fetch, no
    /// invalidation, no state churn. (Pre-existing guard in `.home(.walletAccountTapped)`; this
    /// guards the refactor around it.)
    @Test func reselectingAlreadySelectedAccountRemainsANoOp() async {
        let account = Self.walletAccount(idByte: 66)
        let existingTransactions = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "existing-tx")])
        let fetchCalls = LockIsolated<Int>(0)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = existingTransactions }
        initialState.homeState.transactionListState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { _ in
                fetchCalls.withValue { $0 += 1 }
                return []
            }
        }

        store.send(.home(.walletAccountTapped(account)))

        // A same-account "switch" must dispatch no effect at all -- give a wrongly-fired async
        // fetch a brief moment to land, then confirm nothing changed.
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(fetchCalls.value == 0)
        #expect(store.state.transactions == existingTransactions)
        #expect(store.state.homeState.transactionListState.isInvalidated == false)
    }
}

/// Shared no-op dependency baseline for every test in this file. Kept as a private, file-scoped
/// helper rather than something shared globally, the same way `FlexaTests/FlexaSecurityTests.swift`
/// keeps its own private `waitForFlexaStore` helper local to that file.
@MainActor
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

@MainActor
private func waitForRootStore(
    timeoutNanoseconds: UInt64 = 15_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for Root transactions/account-switch store state", sourceLocation: sourceLocation)
}
