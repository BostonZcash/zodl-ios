//
//  SDKSynchronizerClient.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.04.2022.
//

import Foundation
@preconcurrency import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import URKit

extension DependencyValues {
    var sdkSynchronizer: SDKSynchronizerClient {
        get { self[SDKSynchronizerClient.self] }
        set { self[SDKSynchronizerClient.self] = newValue }
    }
}

@DependencyClient
struct SDKSynchronizerClient: Sendable {
    enum CreateProposedTransactionsResult: Equatable, Sendable {
        enum GrpcFailureReason: Equatable, Sendable {
            case timeout
        }

        case failure(txIds: [String], code: Int, description: String)
        // No description payload on purpose: transport-level failures carry no server message,
        // and the UI derives its copy from `reason` (timeouts get dedicated localized copy).
        case grpcFailure(txIds: [String], reason: GrpcFailureReason? = nil)
        case partial(txIds: [String], statuses: [String])
        case success(txIds: [String])
    }
    
    let stateStream: @Sendable () -> AnyPublisher<SynchronizerState, Never>
    let eventStream: @Sendable () -> AnyPublisher<SynchronizerEvent, Never>
    let exchangeRateUSDStream: @Sendable () -> AnyPublisher<FiatCurrencyResult?, Never>
    let latestState: @Sendable () -> SynchronizerState
    
    let prepareWith: @Sendable ([UInt8], BlockHeight?, String, String?) async throws -> Initializer.InitializationResult
    let start: @Sendable (_ retry: Bool) async throws -> Void
    let stop: @Sendable () -> Void
    let isSyncing: @Sendable () -> Bool
    let isInitialized: @Sendable () -> Bool

    let importAccount: @Sendable (String, [UInt8]?, Zip32AccountIndex?, AccountPurpose, String, String?, BlockHeight?) async throws -> AccountUUID?
    var deleteAccount: @Sendable (AccountUUID) async throws -> Void

    // MARK: - Migration (Orchard -> Ironwood)
    //
    // The SDK's migration group lives on `Synchronizer` and needs no `prepare()`. Declarations are
    // #1930's verbatim (map §4.1a: already 1:1 with the new SDK); each phase binds the subset it
    // needs — Phase 1 the banner state read, Phase 2 the two propose lanes below.

    /// The account's current migration state — also the reconciliation hub.
    let getMigrationState: @Sendable (AccountUUID) async throws -> MigrationState
    /// The full scheduled-migration schedule for the account's spendable Orchard balance.
    let proposeMigrationTransfers: @Sendable (AccountUUID) async throws -> MigrationSchedule
    /// Proposes the immediate (single-transaction) migration — an ordinary send-max proposal,
    /// engine-external: submit it through the ordinary transfer pipeline, then call
    /// `recordImmediateMigration` after a successful broadcast.
    let proposeImmediateMigration: @Sendable (AccountUUID) async throws -> ImmediateMigrationProposal
    /// Records a broadcast immediate-migration sweep so the platform migration state machine
    /// reports it. Takes the RAW/internal-order txid, not the display-hex form — see
    /// `MigrationCommitPipeline.rawTxId(fromDisplayHex:)`.
    let recordImmediateMigration: @Sendable (AccountUUID, Data) async throws -> Void
    /// Restarts the current migration step, returning the re-created schedule.
    let restartCurrentMigrationStep: @Sendable (AccountUUID) async throws -> MigrationSchedule
    /// The engine's estimate of how many migration runs ("rounds") migrating the account's whole
    /// Orchard balance will take. `nil` when the estimate is unavailable or has no runs.
    let estimateMigrationRunCount: @Sendable (AccountUUID) async throws -> Int?

    // PHASE 3 — the scheduler. Commit, the broadcast loop, and the reads the loop reconciles from.

    /// The account's LIVE per-transaction migration statuses — one row per committed migration
    /// transaction (preparation AND transfer kinds), mined-reconciled at every read; `[]` when no
    /// run is stored. Preferred over the persisted schedule's own app-derived state/heights by
    /// `MigrationDerivations.transferRows` for every row it can join by id.
    let migrationTransactionStatuses: @Sendable (AccountUUID) async throws -> [MigrationTransactionStatus]
    /// Pre-signs and persists every transfer of `schedule` in the migration engine (needs the
    /// account's USK). THE commit — one call signs the whole run, preparation layers included,
    /// straight from the plan cache the schedule's own propose already wrote.
    let signAndStoreMigrationSchedule: @Sendable (AccountUUID, MigrationSchedule, UnifiedSpendingKey) async throws -> Void
    /// Broadcasts the next height-due migration transfer, or `nil` when nothing is currently due.
    /// A `nil` return is the SOLE authority on "nothing due" — never second-guess it app-side.
    /// Broadcast-bearing: guarded by the transaction guard in the LiveKey.
    let executeNextPendingMigrationTransfer: @Sendable (
        AccountUUID, MigrationNetworkPrivacyOptions
    ) async throws -> MigrationTransferResult?
    /// Whether the account has a scheduled transfer past its send height but not yet broadcast.
    let hasOverdueMigrationTransfers: @Sendable (AccountUUID) async throws -> Bool
    /// The account's next height-due pending transfer proposal, or `nil` when nothing is pending.
    let rescheduleOverdueMigrationTransfer: @Sendable (AccountUUID) async throws -> MigrationTransferProposal?
    /// DEBUG/QA ONLY — rewrites the committed schedule's transfer heights onto short strides so a
    /// real broadcast run can be exercised without waiting out ZIP 318's privacy delay. Returns the
    /// number of transfers rescheduled. Gate 3 runs on this.
    let debugRescheduleMigrationTransfers: @Sendable (AccountUUID) async throws -> Int
    /// Wallet-scope: whether ordinary sync should currently be paused for a migration privacy gate.
    /// Non-throwing (degrades open on internal failure).
    var isMigrationSyncBlocked: @Sendable () async -> Bool = { false }
    /// Wallet-scope stream of `isMigrationSyncBlocked()`. Root subscribes this to drive the
    /// stop/resume pair — see `stopSyncBeforeMigrationBroadcast()` below.
    var migrationSyncBlockedStream: @Sendable () -> AnyPublisher<Bool, Never> = { Empty().eraseToAnyPublisher() }
    /// The post-broadcast privacy buffer duration (the SDK's own 600 s gate), mirrored app-side by
    /// `MigrationSendGate` on the send side.
    var migrationPrivacySyncBufferDuration: @Sendable () -> TimeInterval = { 0 }
    /// The run's live progress (completed/total transfers), or `nil` when no run is stored. Feeds
    /// the in-progress banner variant and the re-entry route.
    let getMigrationProgress: @Sendable (AccountUUID) async throws -> MigrationProgress?
    /// Whether the account's migration is in an invalid state (spendable Orchard remains but no
    /// scheduled transfer covers it). Read by `reentryRoute`; its recovery SCREEN is Phase 5.
    let hasInvalidMigrationTransfers: @Sendable (AccountUUID) async throws -> Bool
    /// The leftover Orchard balance a migration would not cross, when worth offering a choice
    /// about; `nil` when there is none. Feeds `migrationSummary.dust`.
    let residualAfterMigration: @Sendable (AccountUUID) async throws -> Zatoshi?
    /// Locks every currently-spendable legacy-Orchard note until explicit unlock and returns the
    /// total just locked — the "Lock balance" choice at migration Complete. The SCREEN that offers
    /// it is Phase 6; the member is bound here because the manager (copied whole from #1930) calls
    /// it, and a live binding is safer than a stub that silently no-ops a real lock.
    let lockMigrationResidual: @Sendable (AccountUUID) async throws -> Zatoshi

    let rescanFrom: @Sendable (BlockHeight) async throws -> Void

    let rewind: @Sendable (RewindPolicy) -> AnyPublisher<Void, Error>
    
    var getAllTransactions: @Sendable (AccountUUID?) async throws -> IdentifiedArrayOf<TransactionState>
    var transactionStatesFromZcashTransactions: @Sendable (AccountUUID?, [ZcashTransaction.Overview]) async throws -> IdentifiedArrayOf<TransactionState>
    var getMemos: @Sendable (Data) async throws -> [Memo]
    var txIdExists: @Sendable (String?) async throws -> Bool
    
    let getUnifiedAddress: @Sendable (_ account: AccountUUID) async throws -> UnifiedAddress?
    let getTransparentAddress: @Sendable (_ account: AccountUUID) async throws -> TransparentAddress?
    let getSaplingAddress: @Sendable (_ account: AccountUUID) async throws -> SaplingAddress?
    
    let getAccountsBalances: @Sendable () async throws -> [AccountUUID: AccountBalance]
    
    var wipe: @Sendable () -> AnyPublisher<Void, Error>?
    
    var switchToEndpoint: @Sendable (LightWalletEndpoint) async throws -> Void
    
    // Proposals
    var proposeTransfer: @Sendable (AccountUUID, Recipient, Zatoshi, Memo?) async throws -> Proposal
    /// Creates the proposal's transactions via the SDK `Broadcaster` and submits them to the
    /// endpoints chosen by the user's connection mode (Automatic -> all known servers,
    /// Manual -> the selected server). See `selectedSubmissionEndpoints`.
    var createAndSubmitProposedTransactions: @Sendable (Proposal, UnifiedSpendingKey) async throws -> CreateProposedTransactionsResult
    var proposeShielding: @Sendable (AccountUUID, Zatoshi, Memo, TransparentAddress?) async throws -> Proposal?
    
    var isSeedRelevantToAnyDerivedAccount: @Sendable ([UInt8]) async throws -> Bool
    
    var refreshExchangeRateUSD: @Sendable () -> Void
    
    var evaluateBestOf: @Sendable ([LightWalletEndpoint], Double, UInt64, Int, NetworkType) async -> [LightWalletEndpoint] = { _,_,_,_,_ in [] }

    var walletAccounts: @Sendable () async throws -> [WalletAccount] = { [] }
    
    var estimateBirthdayHeight: @Sendable (Date) -> BlockHeight = { _ in BlockHeight(0) }
    var estimateTimestamp: @Sendable (BlockHeight) -> TimeInterval? = { _ in nil }

    // PCZT
    var createPCZTFromProposal: @Sendable (AccountUUID, Proposal) async throws -> Pczt
    var addProofsToPCZT: @Sendable (Pczt) async throws -> Pczt
    /// PCZT variant of `createAndSubmitProposedTransactions`.
    var createAndSubmitTransactionFromPCZT: @Sendable (Pczt, Pczt) async throws -> CreateProposedTransactionsResult
    var urEncoderForPCZT: @Sendable (Pczt) -> UREncoder?
    var redactPCZTForSigner: @Sendable (Pczt) async throws  -> Pczt
    
    // Search
    var fetchTxidsWithMemoContaining: @Sendable (String) async throws -> [Data]
    
    // UA with custom receivers
    var getCustomUnifiedAddress: @Sendable (AccountUUID, Set<ReceiverType>) async throws -> UnifiedAddress?
    
    // Tor
    var torEnabled: @Sendable (Bool) async throws -> Void
    var exchangeRateEnabled: @Sendable (Bool) async throws -> Void
    var isTorSuccessfullyInitialized: @Sendable () async -> Bool?
    var httpRequestOverTor: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    
    var debugDatabaseSql: @Sendable (String) -> String = { _ in "" }
    
    var getSingleUseTransparentAddress: @Sendable (AccountUUID) async throws -> SingleUseTransparentAddress = { _ in
        SingleUseTransparentAddress(address: "", gapPosition: 0, gapLimit: 0)
    }
    var checkSingleUseTransparentAddresses: @Sendable (AccountUUID) async throws -> TransparentAddressCheckResult = { _ in .notFound }
    var updateTransparentAddressTransactions: @Sendable (String) async throws -> TransparentAddressCheckResult = { _ in .notFound }
    var fetchUTXOsByAddress: @Sendable (String, AccountUUID) async throws -> TransparentAddressCheckResult = { _, _ in .notFound }
    var enhanceTransactionBy: @Sendable (String) async throws -> Void

    var getTreeState: @Sendable (_ height: UInt64) async throws -> Data
}

extension SDKSynchronizerClient {
    /// Stops an in-flight sync ahead of a migration broadcast, so the broadcast is not correlated
    /// with the wallet's ordinary sync traffic. EVERY broadcast-performing call site in the app
    /// calls this first — the SDK's own during-sync throw is an advisory backstop, not the guard.
    ///
    /// The `migrationStoppedSyncForBroadcast` flag is the OTHER half of the pair and the reason
    /// this must never ship alone (matrix B12): `RootInitialization`'s `.migrationSyncGateChanged`
    /// handler consumes it to guarantee sync resumes once the SDK's post-broadcast privacy gate
    /// clears — including the edge where the broadcast fails pre-flight and the gate never blocks
    /// at all. Set only when this call ACTUALLY stopped something; never when already idle, or the
    /// resume half would fire against a sync nobody paused.
    func stopSyncBeforeMigrationBroadcast() async {
        guard isSyncing() else { return }
        stop()
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = true }
    }
}

