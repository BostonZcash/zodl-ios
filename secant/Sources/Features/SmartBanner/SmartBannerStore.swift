//
//  SmartBannerStore.swift
//  modules
//
//  Created by Lukáš Korba on 03.04.2025.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

import MessageUI

@Reducer
struct SmartBanner {
    enum Constants: Equatable {
        static let easeInOutDuration = 0.85
        /// MOB-1466: the MINIMUM time `.checkingStatus` stays on screen once a foreground has
        /// raised it — ABSORBED into the re-derivation, never added on top. A verdict at 2 s shows
        /// checking for 2 s; a verdict at 0.1 s still shows it until 0.5 s.
        ///
        /// MEASURED DOWN from 0.5 s (field, 2026-08-03). The real answer arrived in 130 ms on
        /// broadcast opens — so a 0.5 s floor was showing a spinner for 500 ms to prevent 130 ms of
        /// staleness, ADDING 370 ms of churn to remove less. 0.2 s still forbids a sub-frame flip
        /// while costing almost nothing when the answer is quick; the slow cold-launch path, which
        /// is what this state exists for, is unaffected.
        ///
        /// NOT a delay-before-show. That variant (hold the stale label ~300 ms, show the spinner
        /// only if the answer is late) optimises for sub-300 ms resolution, and the field says that
        /// is not this app: idle held ~3 s before flipping to a sending state, and transitions
        /// arrive in runs (A -> B -> A, A -> B -> C) rather than singly. Showing the truth
        /// immediately and forbidding a sub-half-second flip is the shape that matches what was
        /// actually observed.
        static let migrationCheckingMinimumDwell = 0.2
        static let remindMe2days: TimeInterval = 86_400 * 2
        static let remindMe2weeks: TimeInterval = 86_400 * 14
        static let remindMeMonth: TimeInterval = 86_400 * 30
        static let smartBannerSyncingBlocksThreshold: BlockHeight = 3456
        // Bounded post-restore migration re-poll — every `migrationRepollInterval`, up to
        // `migrationRepollMaxAttempts` times (3s * 40 = 120s total), matching the SDK's own
        // bounded post-restore balance hold. See `postRestoreMigrationRecheckEffect`.
        static let migrationRepollInterval: TimeInterval = 3
        static let migrationRepollMaxAttempts = 40
    }
    
    @ObservableState
    struct State: Equatable {
        enum PriorityContent: Int {
            case priority1 = 0 // disconnected
            case priority2 // syncing error
            case priority3 // restoring
            case priority4 // syncing
            case priority45 // resyncing
            case priority5 // updating balance
            case priority6 // wallet backup
            case priority7 // shielding
            case priority75 // tor
            case priority8 // currency conversion
            case priority9 // auto-shielding
            case priorityMigration = -1 // ironwood migration

            func next() -> PriorityContent {
                // `priorityMigration` (-1) sits outside the walk-down chain — it is only ever
                // triggered explicitly, so walking below `priority1` wraps to `priority9` as before.
                guard rawValue > 0 else { return .priority9 }
                return PriorityContent(rawValue: rawValue - 1) ?? .priority9
            }

            /// Display rank — lower wins. `priorityMigration` slots between `priority2` (sync error)
            /// and `priority3` (restoring): operational alerts outrank migration; migration outranks the rest.
            var rank: Double { self == .priorityMigration ? 1.5 : Double(rawValue) }
        }
        
        var CancelNetworkMonitorId = UUID()
        var CancelStateStreamId = UUID()
        var CancelShieldingProcessorId = UUID()
        var CancelMigrationRepollId = UUID()
        let CancelMigrationStateStreamId = UUID()

        var isScanProgressComplete = false
        var delay = 1.5
        var isOpen = false
        var isShielding = false
        var isShieldingAcknowledged = false
        var isShieldingAcknowledgedAtKeychain = false
        var isSmartBannerSheetPresented = false
        var isSyncTimedOutSheetPresented = false
        var isSyncTimedOutAutoAppeareDisabled = false
        var isWalletBackupAcknowledged = false
        var isWalletBackupAcknowledgedAtKeychain = false
        var lastKnownBlocksRemaining: BlockHeight = -1
        var lastKnownErrorMessage = ""
        /// Whether `lastKnownErrorMessage` describes a server-validation failure
        /// (`ZcashError.isIncompatibleServer`, e.g. `ZCBPEO0011`). Sync can never make progress in
        /// that state, so the Syncing Error sheet offers a route to Server Setup — a generic sync
        /// error gets no such row, since retrying is the right thing to do there.
        var lastKnownErrorIsIncompatibleServer = false
        var lastKnownSyncPercentage = -1.0
        /// Latched result of the last `migrationManager.isIronwoodActivated()` observation, so an
        /// activation-day crossing (or a reorg back below the activation height) is detectable as a
        /// FLIP rather than re-derived on every tick. `nil` until the first observation.
        var lastObservedIronwoodActivation: Bool?
        var messageToBeShared: String?
        var migrationBannerVariant = MigrationBannerVariant.required
        /// MOB-1466: true from the foreground that raised `.checkingStatus` until its minimum dwell
        /// elapses. While set, a resolved variant is HELD (below) rather than applied, so the
        /// checking state cannot flash.
        var isMigrationCheckDwelling = false
        /// The variant that resolved during the dwell, waiting to be applied when it ends. The
        /// companion `Bool` exists because `nil` is itself a meaningful variant (it closes the
        /// banner) and a double optional reads far worse than two fields.
        var heldMigrationVariant: MigrationBannerVariant?
        var hasHeldMigrationVariant = false
        var priorityContent: PriorityContent? = nil
        var priorityContentRequested: PriorityContent? = nil
        var remindMeShieldedPhaseCounter = 0
        var remindMeWalletBackupPhaseCounter = 0
        @Shared(.inMemory(.featureFlags)) var featureFlags: FeatureFlags = .initial
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var spendableBalance = Zatoshi(0)
        var supportData: SupportData?
        var synchronizerStatusSnapshot: SyncStatusSnapshot = .snapshotFor(state: .unprepared)
        var tokenName = "ZEC"
        @Shared(.inMemory(.transactions)) var transactions: IdentifiedArrayOf<TransactionState> = []
        var transparentBalance = Zatoshi(0)
        @Shared(.inMemory(.walletStatus)) var walletStatus: WalletStatus = .none

        var areFundsSpendable: Bool {
            isScanProgressComplete && spendableBalance.amount > 0
        }

        var feeStr: String {
            Zatoshi(100_000).decimalString()
        }

        var syncingPercentage: Double {
            lastKnownSyncPercentage >= 0 ? lastKnownSyncPercentage * 0.999 : 0
        }
        
        var remindMeShieldedText: String {
            remindMeShieldedPhaseCounter == 0
            ? String(localizable: .smartBannerHelpRemindMePhase1)
            : remindMeShieldedPhaseCounter == 1
            ? String(localizable: .smartBannerHelpRemindMePhase2)
            : String(localizable: .smartBannerHelpRemindMePhase3)
        }

        var remindMeWalletBackupText: String {
            remindMeWalletBackupPhaseCounter == 0
            ? String(localizable: .smartBannerHelpRemindMePhase1)
            : remindMeWalletBackupPhaseCounter == 1
            ? String(localizable: .smartBannerHelpRemindMePhase2)
            : String(localizable: .smartBannerHelpRemindMePhase3)
        }
        
        init() { }
    }
    
    enum Action: BindableAction, Equatable {
        case binding(BindingAction<SmartBanner.State>)
        case closeAndCleanupBanner
        case closeBanner(Bool)
        case closeSheetTapped
        case onAppear
        case onDisappear
        case evaluatePriority1
        case evaluatePriority2
        case evaluatePriorityMigration
        case migrationVariantLoaded(MigrationBannerVariant?)
        /// The manager's per-account migration-state stream ticked. It reports THAT the state
        /// changed, not what it resolved to, so this re-reads the variant through the same funnel.
        /// Restored in Phase 3 along with the manager's `reconcile()`, which is what feeds it.
        case migrationStateChanged(MigrationState)
        /// Re-read the variant now, from OUTSIDE the banner — sent by `Root` when the migration
        /// flow closes. Complements the stream above rather than duplicating it: `stateEvents`
        /// publishes `MigrationState`, so a pure BALANCE change (funds arriving, or a manual sweep
        /// completing while the state stays `.notStarted`) emits nothing at all.
        case migrationReevaluationRequested
        case migrationVariantUpdated(MigrationBannerVariant?)
        /// MOB-1466: sent by Root on `willEnterForeground`. Raises `.checkingStatus` — but ONLY if
        /// the migration lane already owns the banner, so a wallet with no migration never sprouts
        /// one for half a second.
        case migrationForegroundCheckStarted
        /// The minimum dwell ended; apply whatever resolved meanwhile.
        case migrationCheckDwellElapsed
        case reevaluateMigrationOnActivationFlip
        case evaluatePriority3
        case evaluatePriority4
        case evaluatePriority45
        case evaluatePriority5
        case evaluatePriority6
        case evaluatePriority7
        case evaluatePriority75
        case evaluatePriority8
        case evaluatePriority9
        case networkMonitorChanged(Bool)
        case openBanner
        case openBannerRequest
        case remindMeLaterTapped(State.PriorityContent)
        case reportPrepared
        case reportTapped
        case sendSupportMailFinished
        case shareFinished
        case shieldingProcessorStateChanged(ShieldingProcessorClient.State)
        case smartBannerContentTapped
        case synchronizerStateChanged(RedactableSynchronizerState)
        case transparentBalanceUpdated(Zatoshi)
        case triggerPriority(State.PriorityContent)
        case walletAccountChanged

        // Action buttons
        case autoShieldingTapped
        case currencyConversionScreenRequested
        /// The migration banner was tapped — Home forwards it to Root, which opens the flow.
        case migrationScreenRequested
        case currencyConversionTapped
        case serverSwitchRequested
        case shieldFundsTapped
        case torSettingsRequested
        case torSetupScreenRequested
        case torSetupTapped
        case walletBackupTapped
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.networkMonitor) var networkMonitor
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.shieldingProcessor) var shieldingProcessor
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.tokenName = zcashSDKEnvironment.tokenName()
                state.isWalletBackupAcknowledgedAtKeychain = walletStorage.exportWalletBackupAcknowledged()
                state.isWalletBackupAcknowledged = state.isWalletBackupAcknowledgedAtKeychain
                state.isShieldingAcknowledgedAtKeychain = walletStorage.exportShieldingAcknowledged()
                state.isShieldingAcknowledged = state.isShieldingAcknowledgedAtKeychain
                if !state.isSyncTimedOutAutoAppeareDisabled {
                    state.isSyncTimedOutSheetPresented = state.isSyncTimedOut
                    state.isSyncTimedOutAutoAppeareDisabled = state.isSyncTimedOutSheetPresented
                }
                return .merge(
                    .publisher {
                        networkMonitor.networkMonitorStream()
                            .map(Action.networkMonitorChanged)
                            .receive(on: mainQueue)
                    }
                    .cancellable(id: state.CancelNetworkMonitorId, cancelInFlight: true),
                    .publisher {
                        sdkSynchronizer.stateStream()
                            .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                            .map { $0.redacted }
                            .map(Action.synchronizerStateChanged)
                    }
                    .cancellable(id: state.CancelStateStreamId, cancelInFlight: true),
                    .publisher {
                        shieldingProcessor.observe()
                            .map(Action.shieldingProcessorStateChanged)
                    }
                    .cancellable(id: state.CancelShieldingProcessorId, cancelInFlight: true),
                    migrationStateStreamEffect(
                        accountUUID: state.selectedWalletAccount?.id,
                        cancelID: state.CancelMigrationStateStreamId
                    )
                )
                
            case .onDisappear:
                // __LD2 TESTED
                return .merge(
                    .cancel(id: state.CancelNetworkMonitorId),
                    .cancel(id: state.CancelStateStreamId),
                    .cancel(id: state.CancelShieldingProcessorId),
                    // A post-restore migration repoll armed just before leaving Home must not keep
                    // running off-lifecycle — it would otherwise fire its `bannerVariant` hydration
                    // up to 120s after the screen is gone, and — with `CancelStateStreamId` also
                    // torn down above — no later sync transition could end it early either; only
                    // success or the attempt cap could, absent this.
                    .cancel(id: state.CancelMigrationRepollId),
                    .cancel(id: state.CancelMigrationStateStreamId)
                )

            case .binding(\.isShieldingAcknowledged):
                try? walletStorage.importShieldingAcknowledged(state.isShieldingAcknowledged)
                return .none

            case .binding:
                return .none
                
            case .sendSupportMailFinished:
                state.supportData = nil
                return .none
                
            case .shieldingProcessorStateChanged(let shieldingProcessorState):
                if shieldingProcessorState == .succeeded {
                    state.transparentBalance = .zero
                }
                state.isShielding = shieldingProcessorState == .requested
                if (state.isOpen || state.isSmartBannerSheetPresented) && state.priorityContent == .priority7 {
                    var hideEverything = false
                    if case .proposal = shieldingProcessorState {
                        hideEverything = true
                    } else if shieldingProcessorState == .succeeded {
                        hideEverything = true
                    }
                    if hideEverything {
                        return .merge(
                            .send(.closeAndCleanupBanner),
                            .send(.closeSheetTapped)
                        )
                    }
                }
                return .none
                
            case .walletAccountChanged:
                state.remindMeShieldedPhaseCounter = 0
                return .merge(
                    // An account switch must stop a post-restore migration re-poll in flight for the
                    // OLD account outright — the decision belongs to whichever account armed it, and
                    // the walk below (`.evaluatePriority1`) restarts fresh for the newly selected one.
                    .cancel(id: state.CancelMigrationRepollId),
                    // The migration-state subscription is keyed to the ACCOUNT: the old account's
                    // subject never emits again after a switch, so re-subscribe rather than leaving
                    // the banner listening to a dead feed.
                    migrationStateStreamEffect(
                        accountUUID: state.selectedWalletAccount?.id,
                        cancelID: state.CancelMigrationStateStreamId
                    ),
                    .run { send in
                        await send(.closeBanner(true), animation: .easeInOut(duration: Constants.easeInOutDuration))
                        try? await mainQueue.sleep(for: .seconds(1))
                        await send(.evaluatePriority1)
                    }
                )

            case .reportTapped:
                state.isSyncTimedOutSheetPresented = false
                return .run { send in
                    await send(.closeSheetTapped)
                    try? await mainQueue.sleep(for: .seconds(1))
                    await send(.reportPrepared)
                }
                
            case .reportPrepared:
                var supportData = SupportDataGenerator.generate()
                supportData.message =
                """
                code: -2000
                \(state.lastKnownErrorMessage)
                
                \(supportData.message)
                """
                // TCA Store is @MainActor; reducer body always runs on main.
                if MainActor.assumeIsolated({ MFMailComposeViewController.canSendMail() }) {
                    state.supportData = supportData
                } else {
                    state.messageToBeShared = supportData.message
                }
                return .none
                
            case .shareFinished:
                state.messageToBeShared = nil
                return .none
                
            case .networkMonitorChanged(let isConnected):
                if state.priorityContent == .priority1 && isConnected {
                    return .run { send in
                        await send(.closeAndCleanupBanner)
                        try? await mainQueue.sleep(for: .seconds(2))
                        await send(.evaluatePriority2)
                    }
                } else if state.priorityContent != .priority1 && !isConnected {
                    return .send(.triggerPriority(.priority1))
                }
                return .none
                
            case .smartBannerContentTapped:
                if state.priorityContent == .priority7 {
                    state.isShieldingAcknowledgedAtKeychain = walletStorage.exportShieldingAcknowledged()
                    if state.isShieldingAcknowledgedAtKeychain {
                        return .none
                    }
                } else if state.priorityContent == .priority75 {
                    return .send(.torSetupScreenRequested)
                } else if state.priorityContent == .priorityMigration {
                    return .send(.migrationScreenRequested)
                } else if state.priorityContent == .priority8 {
                    return .send(.currencyConversionScreenRequested)
                } else if state.isSyncTimedOut {
                    state.isSyncTimedOutSheetPresented = true
                    return .none
                }
                state.isSmartBannerSheetPresented = true
                return .none
                
            case .closeSheetTapped:
                state.isSmartBannerSheetPresented = false
                return .none

            case .remindMeLaterTapped(let priority):
                if priority == .priority6 {
                    try? walletStorage.importWalletBackupAcknowledged(state.isWalletBackupAcknowledged)
                    state.isWalletBackupAcknowledgedAtKeychain = walletStorage.exportWalletBackupAcknowledged()
                }
                state.isSmartBannerSheetPresented = false
                state.priorityContentRequested = nil
                let now = Date().timeIntervalSince1970
                // wallet backup = priority6
                if priority == .priority6 {
                    if var walletBackupReminder = walletStorage.exportWalletBackupReminder() {
                        walletBackupReminder.occurence += 1
                        walletBackupReminder.timestamp = now
                        try? walletStorage.importWalletBackupReminder(walletBackupReminder)
                    } else {
                        let walletBackupReminder = ReminedMeTimestamp(timestamp: now, occurence: 1)
                        try? walletStorage.importWalletBackupReminder(walletBackupReminder)
                    }
                } else if priority == .priority7 {
                    // shielding = priority7
                    if let account = state.selectedWalletAccount {
                        if var shieldingReminder = walletStorage.exportShieldingReminder(account.vendor.name()) {
                            shieldingReminder.occurence += 1
                            shieldingReminder.timestamp = now
                            try? walletStorage.importShieldingReminder(shieldingReminder, account.vendor.name())
                        } else {
                            let shieldingReminder = ReminedMeTimestamp(timestamp: now, occurence: 1)
                            try? walletStorage.importShieldingReminder(shieldingReminder, account.vendor.name())
                        }
                    }
                }
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(1))
                    await send(.closeBanner(false), animation: .easeInOut(duration: Constants.easeInOutDuration))
                }
                
            case .synchronizerStateChanged(let latestState):
                // Computed as two independent effects and merged, rather than folded into one flow —
                // `syncStatusChangedEffect` below has many early-return branches, and any one of
                // those firing on the same tick as an activation flip must not silently swallow the
                // flip's re-evaluation (a cold-launch tick is exactly where both are likely to
                // coincide: the priority walk racing the first chain-tip fetch is the scenario
                // `ironwoodActivationFlipEffect` exists to correct).
                let activationFlipEffect = ironwoodActivationFlipEffect(state: &state)
                // Snapshot the syncStatus BEFORE `syncStatusChangedEffect` runs, so a genuine
                // transition — of ANY kind, not just the one that may arm a fresh post-restore
                // repoll — can cancel a STALE repoll left over from an EARLIER transition first.
                // `.concatenate` (not a sibling `.merge` entry) guarantees that cancel settles
                // BEFORE `syncStatusEffect` runs, so a tick that re-arms a fresh repoll under the
                // SAME cancel id can never race its own cancellation.
                let previousSyncStatus = state.synchronizerStatusSnapshot.syncStatus
                let syncStatusEffect = syncStatusChangedEffect(state: &state, latestState: latestState)
                guard state.synchronizerStatusSnapshot.syncStatus != previousSyncStatus else {
                    return .merge(activationFlipEffect, syncStatusEffect)
                }
                return .concatenate(
                    .cancel(id: state.CancelMigrationRepollId),
                    .merge(activationFlipEffect, syncStatusEffect)
                )

            case .migrationForegroundCheckStarted:
                // TRAP 3 — never manufacture a banner. `.checkingStatus` replaces the CONTENT of a
                // banner the migration lane is already showing; it does not raise one. Foregrounding
                // a wallet with no migration (never started, or finished) must look exactly as it
                // does today.
                guard state.featureFlags.migration, state.priorityContent == .priorityMigration else {
                    // Traced, because "nothing happened" and "the action never arrived" look
                    // identical on a device and the first field report could not tell them apart.
                    MigrationTrace.event(
                        "banner check SKIPPED — migration flag \(state.featureFlags.migration)"
                        + ", priority \(String(describing: state.priorityContent))"
                    )
                    return .none
                }
                MigrationTrace.event("banner → checkingStatus (foreground; min dwell \(Constants.migrationCheckingMinimumDwell)s)")
                state.migrationBannerVariant = .checkingStatus
                state.isMigrationCheckDwelling = true
                state.hasHeldMigrationVariant = false
                state.heldMigrationVariant = nil
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(Constants.migrationCheckingMinimumDwell))
                    await send(.migrationCheckDwellElapsed)
                }

            case .migrationCheckDwellElapsed:
                // GROUND_RULES R3: the floor may have elapsed, but the state ends ONLY on the
                // session's verdict. If it has not arrived, keep checking and re-poll on the same
                // cadence — a 0.2s banner-local poll that terminates the moment the driver marks
                // the verdict. This is the "floor, not timeout" rule made structural: the old code
                // ended the hold on the timer and the very next pre-verdict answer was the lie.
                guard migrationManager.isMigrationSessionVerdictKnown() else {
                    MigrationTrace.event("banner check dwell elapsed — verdict pending, staying on checking (R3)")
                    return .run { send in
                        try? await mainQueue.sleep(for: .seconds(Constants.migrationCheckingMinimumDwell))
                        await send(.migrationCheckDwellElapsed)
                    }
                }
                state.isMigrationCheckDwelling = false
                MigrationTrace.event(
                    "banner check dwell elapsed — held answer: \(state.hasHeldMigrationVariant ? "yes, applying" : "none yet, staying on checking")"
                )
                guard state.hasHeldMigrationVariant else {
                    // Still nothing back from `bannerVariant`. Stay on `.checkingStatus`: the dwell
                    // is a FLOOR, not a timeout, and reverting to the stale label here would restore
                    // the exact lie this state exists to remove.
                    return .none
                }
                let held = state.heldMigrationVariant
                state.hasHeldMigrationVariant = false
                state.heldMigrationVariant = nil
                return .send(.migrationVariantUpdated(held))

            case .migrationVariantUpdated(let variant):
                // GROUND_RULES R3: while migration OWNS the slot, no variant may replace what is on
                // screen before the session's first engine verdict — a pre-verdict answer is fresh
                // but answers the wrong question (the flicker: idle at +0.5s, "keep open" at +2.5s,
                // both individually true). Hold it and show `.checkingStatus`; the verdict edge
                // (step driver → `markSessionVerdictKnown`) plus the dwell re-poll below release it.
                // Scoped to an owned slot on purpose: the cold walk-down's first claim must keep
                // flowing, or the ladder would stall with no banner and no re-trigger.
                let verdictPending = state.priorityContent == .priorityMigration
                    && !migrationManager.isMigrationSessionVerdictKnown()
                if state.isMigrationCheckDwelling || verdictPending {
                    if verdictPending, state.migrationBannerVariant != .checkingStatus {
                        MigrationTrace.event("banner → checkingStatus (verdict pending — R3)")
                        state.migrationBannerVariant = .checkingStatus
                        state.isMigrationCheckDwelling = true
                        state.heldMigrationVariant = variant
                        state.hasHeldMigrationVariant = true
                        return .run { send in
                            try? await mainQueue.sleep(for: .seconds(Constants.migrationCheckingMinimumDwell))
                            await send(.migrationCheckDwellElapsed)
                        }
                    }
                    // Resolved inside the dwell — hold it. Last write wins, so a burst of updates
                    // collapses to the newest rather than queueing a run of visible flips.
                    state.heldMigrationVariant = variant
                    state.hasHeldMigrationVariant = true
                    return .none
                }
                if let variant {
                    state.migrationBannerVariant = variant
                    if state.priorityContent != .priorityMigration {
                        return .send(.triggerPriority(.priorityMigration))
                    }
                    // Already showing migration — content re-renders from the updated variant
                    // alone; re-triggering would just be rejected by the `openBannerRequest`
                    // rank guard anyway (equal rank), so skip the round trip.
                    return .none
                }
                MigrationTrace.event("migration RELEASED the banner slot — variant became nil")
                if state.priorityContent == .priorityMigration {
                    // Send `.closeBanner(true)` directly rather than `.closeAndCleanupBanner` —
                    // the latter wraps its send in its own `.run`, which only schedules that
                    // nested effect rather than awaiting it, so a second `await send(...)` right
                    // after it would race the close instead of running after it settles.
                    return .run { send in
                        await send(.closeBanner(true), animation: .easeInOut(duration: Constants.easeInOutDuration))
                        await send(.evaluatePriority1)
                    }
                }
                return .none

            case .migrationStateChanged, .reevaluateMigrationOnActivationFlip, .migrationReevaluationRequested:
                // Route an activation-day crossing (or a reorg back below the activation height),
                // and a just-closed migration flow, through the same variant-fetch +
                // `.migrationVariantUpdated` path the sync transitions use, so there is exactly one
                // funnel that raises/lowers the banner. A nil variant closes it (see
                // `.migrationVariantUpdated`) — which is what retires the banner after a manual
                // migration, because a swept account has no unlocked Orchard value left.
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    await send(.migrationVariantUpdated(migrationManager.bannerVariant(accountUUID)))
                }

                // disconnected
            case .evaluatePriority1:
                return .send(.evaluatePriority2)

                // syncing error
            case .evaluatePriority2:
                return .send(.evaluatePriorityMigration)

                // ironwood migration
            case .evaluatePriorityMigration:
                guard state.featureFlags.migration else {
                    return .send(.evaluatePriority3)
                }
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    await send(.migrationVariantLoaded(migrationManager.bannerVariant(accountUUID)))
                }

            case let .migrationVariantLoaded(variant):
                // MOB-1466 (field, 2026-08-03): this path was NOT holding during the dwell, and the
                // hold only ever covered `.migrationVariantUpdated`. So a variant arriving via the
                // priority ladder replaced `.checkingStatus` immediately and the dwell then fired
                // into an empty slot, logging "staying on checking" while the banner had already
                // moved. Instrumentation that lies is worse than none.
                //
                // R3: same verdict gate as `.migrationVariantUpdated`, same owned-slot scope.
                let loadedVerdictPending = state.priorityContent == .priorityMigration
                    && !migrationManager.isMigrationSessionVerdictKnown()
                if state.isMigrationCheckDwelling || loadedVerdictPending {
                    if loadedVerdictPending, state.migrationBannerVariant != .checkingStatus {
                        MigrationTrace.event("banner → checkingStatus (verdict pending — R3)")
                        state.migrationBannerVariant = .checkingStatus
                        state.isMigrationCheckDwelling = true
                        state.heldMigrationVariant = variant
                        state.hasHeldMigrationVariant = true
                        return .run { send in
                            try? await mainQueue.sleep(for: .seconds(Constants.migrationCheckingMinimumDwell))
                            await send(.migrationCheckDwellElapsed)
                        }
                    }
                    state.heldMigrationVariant = variant
                    state.hasHeldMigrationVariant = true
                    return .none
                }
                guard let variant else {
                    // MOB-1466: `nil` conflates "no migration to offer" with "cannot answer YET",
                    // and the walk-down treats both as a firm no — handing the slot to a
                    // lower-priority banner (restoring, then currency conversion) that migration
                    // then evicts seconds later. The manager logs WHY it answered nil on the line
                    // immediately above this one; read them as a pair.
                    //
                    // Goal 1's sync gate WIDENED this window, because "not caught up" outlives every
                    // pre-existing reason for nil. Measuring that is the point of this line.
                    MigrationTrace.event("migration DECLINED the banner slot — walking down to priority3")
                    return .send(.evaluatePriority3)
                }
                state.migrationBannerVariant = variant
                return .send(.triggerPriority(.priorityMigration))

                // restoring
            case .evaluatePriority3:
                if state.walletStatus == .restoring {
                    return .send(.triggerPriority(.priority3))
                }
                return .send(.evaluatePriority4)

                // syncing
            case .evaluatePriority4:
                if state.walletStatus != .restoring && state.lastKnownBlocksRemaining >= Constants.smartBannerSyncingBlocksThreshold {
                    return .send(.triggerPriority(.priority4))
                }
                return .send(.evaluatePriority45)

                // resyncing
            case .evaluatePriority45:
                if state.walletStatus == .resyncing {
                    //return .send(.triggerPriority(.priority45))
                }
                return .send(.evaluatePriority5)

                // updating balance
            case .evaluatePriority5:
                return .send(.evaluatePriority6)

                // wallet backup
            case .evaluatePriority6:
                guard let account = state.selectedWalletAccount, account.vendor == .zcash else {
                    return .send(.evaluatePriority7)
                }
                guard !state.transactions.isEmpty else {
                    return .send(.evaluatePriority7)
                }
                if let storedWallet = try? walletStorage.exportWallet(), !storedWallet.hasUserPassedPhraseBackupTest {
                    if let walletBackupReminder = walletStorage.exportWalletBackupReminder() {
                        state.remindMeWalletBackupPhaseCounter = walletBackupReminder.occurence
                        let now = Date().timeIntervalSince1970

                        if (state.remindMeWalletBackupPhaseCounter == 1 && walletBackupReminder.timestamp + Constants.remindMe2days < now)
                            || (state.remindMeWalletBackupPhaseCounter == 2 && walletBackupReminder.timestamp + Constants.remindMe2weeks < now)
                            || (state.remindMeWalletBackupPhaseCounter > 2 && walletBackupReminder.timestamp + Constants.remindMeMonth < now) {
                            return .send(.triggerPriority(.priority6))
                        }
                    } else {
                        // phase 1
                        return .send(.triggerPriority(.priority6))
                    }
                }
                return .send(.evaluatePriority7)

                // shielding
            case .evaluatePriority7:
                guard let account = state.selectedWalletAccount else {
                    return .none
                }
                if let shieldedReminder = walletStorage.exportShieldingReminder(account.vendor.name()) {
                    state.remindMeShieldedPhaseCounter = shieldedReminder.occurence
                }
                return .run { [remindMeShieldedPhaseCounter = state.remindMeShieldedPhaseCounter] send in
                    if let accountBalance = try? await sdkSynchronizer.getAccountsBalances()[account.id],
                       accountBalance.unshielded >= zcashSDKEnvironment.shieldingThreshold() {
                        await send(.transparentBalanceUpdated(accountBalance.unshielded))
                        
                        if let shieldedReminder = walletStorage.exportShieldingReminder(account.vendor.name()) {
                            let now = Date().timeIntervalSince1970

                            if (remindMeShieldedPhaseCounter == 1 && shieldedReminder.timestamp + Constants.remindMe2days < now)
                                || (remindMeShieldedPhaseCounter == 2 && shieldedReminder.timestamp + Constants.remindMe2weeks < now)
                                || (remindMeShieldedPhaseCounter > 2 && shieldedReminder.timestamp + Constants.remindMeMonth < now) {
                                await send(.triggerPriority(.priority7))
                            }
                        } else {
                            // phase 1
                            await send(.triggerPriority(.priority7))
                        }
                    } else {
                        await send(.evaluatePriority75)
                    }
                }
                
                // tor
            case .evaluatePriority75:
                if walletStorage.exportTorSetupFlag() == nil {
                    return .send(.triggerPriority(.priority75))
                }
                return .send(.evaluatePriority8)

                // currency conversion
            case .evaluatePriority8:
                if let account = state.selectedWalletAccount {
                    if let accountBalance = sdkSynchronizer.latestState().accountsBalances[account.id] {
                        // Pool-agnostic accessor: sums sapling + orchard + ironwood (and any
                        // future shielded pool) instead of hand-summing individual pools.
                        let shielded = accountBalance.shieldedTotal().amount
                        let unshielded = accountBalance.unshielded.amount

                        if shielded + unshielded == 0 {
                            return .send(.evaluatePriority9)
                        }
                    }
                }
                if userStoredPreferences.exchangeRate() == nil {
                    return .send(.triggerPriority(.priority8))
                }
                return .send(.evaluatePriority9)
                
                // auto-shielding
            case .evaluatePriority9:
                return .none
                
            case .triggerPriority(let priority):
                // MOB-1466 data-gathering: which candidate claims the single banner slot, and when.
                // Traced through `MigrationTrace` rather than `LoggerProxy` so it carries the
                // session stamp `[MIG sN +X.XXs]` — that stamp IS the measurement: how long a
                // lower-priority banner held the slot before migration displaced it is the
                // difference between two of these lines, with no new state to keep.
                MigrationTrace.event(
                    "banner slot REQUESTED by \(String(describing: priority))"
                    + " (currently \(state.priorityContent.map { String(describing: $0) } ?? "none"))"
                )
                state.priorityContentRequested = priority
                return .send(.openBannerRequest)

            case .transparentBalanceUpdated(let balance):
                state.transparentBalance = balance
                return .none
                
            case .openBannerRequest:
                guard let priorityContentRequested = state.priorityContentRequested else {
                    return .none
                }
                if let priorityContent = state.priorityContent, priorityContentRequested.rawValue >= priorityContent.rawValue {
                    return .none
                }
                if state.isOpen {
                    return .run { send in
                        await send(.closeBanner(false), animation: .easeInOut(duration: Constants.easeInOutDuration))
                    }
                }
                state.priorityContent = priorityContentRequested
                return .run { [delay = state.delay] send in
                    try? await mainQueue.sleep(for: .seconds(delay))
                    await send(.openBanner, animation: .easeInOut(duration: Constants.easeInOutDuration))
                }
                
            case .closeBanner(let clean):
                state.isOpen = false
                if clean {
                    state.priorityContentRequested = nil
                    state.priorityContent = nil
                }
                return .send(.openBannerRequest)

            case .closeAndCleanupBanner:
                return .run { send in
                    await send(.closeBanner(true), animation: .easeInOut(duration: Constants.easeInOutDuration))
                }

            case .openBanner:
                state.delay = 1.0
                state.isOpen = true
                return .none
                
                // MARK: - Actions
                
            case .autoShieldingTapped:
                return .none
                
            case .currencyConversionScreenRequested:
                return .none

            case .migrationScreenRequested:
                return .none
                
            case .currencyConversionTapped:
                return .send(.smartBannerContentTapped)

            case .torSetupScreenRequested:
                return .none
                
            case .torSettingsRequested:
                state.isSyncTimedOutSheetPresented = false
                return .none

            case .torSetupTapped:
                return .send(.smartBannerContentTapped)

            case .serverSwitchRequested:
                // Reachable from two sheets now — the sync-timeout sheet and the Syncing Error
                // sheet's incompatible-server row — and this navigates away from both, so dismiss
                // whichever is up rather than assuming the origin.
                state.isSyncTimedOutSheetPresented = false
                state.isSmartBannerSheetPresented = false
                return .none

            case .shieldFundsTapped:
                state.isSmartBannerSheetPresented = false
                shieldingProcessor.shieldFunds()
                return .send(.closeAndCleanupBanner)

            case .walletBackupTapped:
                state.isSmartBannerSheetPresented = false
                return .none
            }
        }
    }

    // MARK: - Migration banner: reactive re-checks

    /// Detects an Ironwood activation FLIP and routes it into a banner re-evaluation.
    ///
    /// - First observation (`lastObservedIronwoodActivation == nil`): latches the current value, and
    ///   re-evaluates if already activated — a cold launch where the priority walk raced the first
    ///   chain-tip fetch would otherwise leave the slot decided by a pre-tip `false`.
    /// - Latched flip: activation-day crossing (or a reorg back below the activation height).
    private func ironwoodActivationFlipEffect(state: inout State) -> Effect<Action> {
        // Same gate the priority walk applies in `.evaluatePriorityMigration` — with migration off
        // there is no banner to raise, so don't latch or dispatch anything.
        guard state.featureFlags.migration else { return .none }

        let activated = migrationManager.isIronwoodActivated()

        guard let latch = state.lastObservedIronwoodActivation else {
            state.lastObservedIronwoodActivation = activated
            return activated ? .send(.reevaluateMigrationOnActivationFlip) : .none
        }

        guard activated != latch else {
            return .none
        }
        state.lastObservedIronwoodActivation = activated
        return .send(.reevaluateMigrationOnActivationFlip)
    }

    /// Arms when a restore/resync (`priority3`/`priority45`) transitions to `.upToDate` — the
    /// restored balance can still be invisible to `bannerVariant` for a bounded window after the
    /// SDK reports sync complete (its post-restore hold is bounded/best-effort, ~120s cap), so a
    /// single immediate re-read landing nil is not reliable proof there is nothing to migrate.
    ///
    /// Closes the restoring/syncing banner, re-reads `bannerVariant` once immediately, and — ONLY
    /// if that lands nil AND Ironwood is activated — re-reads every `migrationRepollInterval` up to
    /// `migrationRepollMaxAttempts` times. The first non-nil result (immediate or polled) feeds the
    /// `.migrationVariantUpdated` funnel, whose rank-guarded `openBannerRequest` already displaces a
    /// lower-ranked banner (e.g. currency conversion) — no parallel banner-opening path. If the cap
    /// is reached with no success the loop simply ends — no dispatch — leaving whatever currently
    /// occupies the slot exactly as it stood; a later activation flip or sync transition is still
    /// free to raise migration whenever the manager resolves it.
    ///
    /// Without this, a restore that finishes with migratable Orchard funds shows NO banner until the
    /// next cold start: the walk had already run and moved past migration, and nothing re-ran it.
    ///
    /// PHASE 1 SCOPE: #1930 also fires `migrationManager.reconcile()` on a POLLED success, so its
    /// scheduling/notification machinery catches up on the same trigger. Phase 1 has no schedule and
    /// no notifications to reconcile, so that call is deliberately absent — re-add it here with the
    /// scheduler (Phase 3), not before.
    ///
    /// Cancellation: wrapped in `.cancellable(id:cancelInFlight:)` under the SAME id every time —
    /// `.walletAccountChanged` cancels it on an account switch, `.onDisappear` on leaving Home, and
    /// `.synchronizerStateChanged` ahead of EVERY subsequent sync-status transition — so either a
    /// fresh arm supersedes the stale one, or a transition that doesn't re-arm still tears it down.
    /// The per-account migration-state subscription. Keyed to the ACCOUNT, so an account switch
    /// must re-subscribe (a still-subscribed old account's subject never emits again post-switch).
    private func migrationStateStreamEffect(accountUUID: AccountUUID?, cancelID: UUID) -> Effect<Action> {
        .publisher {
            migrationManager.stateEvents(accountUUID)
                .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                .map(Action.migrationStateChanged)
        }
        .cancellable(id: cancelID, cancelInFlight: true)
    }

    private func postRestoreMigrationRecheckEffect(accountUUID: AccountUUID?, cancelID: UUID) -> Effect<Action> {
        let isIronwoodActivated = migrationManager.isIronwoodActivated()
        return .run { send in
            await send(.closeBanner(true), animation: .easeInOut(duration: Constants.easeInOutDuration))
            if let variant = await migrationManager.bannerVariant(accountUUID) {
                await send(.migrationVariantUpdated(variant))
                return
            }
            guard isIronwoodActivated else {
                await send(.migrationVariantUpdated(nil))
                return
            }
            for _ in 0..<Constants.migrationRepollMaxAttempts {
                try await clock.sleep(for: .seconds(Constants.migrationRepollInterval))
                if let polledVariant = await migrationManager.bannerVariant(accountUUID) {
                    await send(.migrationVariantUpdated(polledVariant))
                    return
                }
            }
        }
        .cancellable(id: cancelID, cancelInFlight: true)
    }

    /// The pre-existing body of `.synchronizerStateChanged`, extracted verbatim except for the two
    /// migration arms in the `.upToDate` case, so it can be merged with `ironwoodActivationFlipEffect`
    /// instead of racing it for the case's single return value.
    private func syncStatusChangedEffect(state: inout State, latestState: RedactableSynchronizerState) -> Effect<Action> {
        let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)

        if let account = state.selectedWalletAccount, let accountBalance = latestState.data.accountsBalances[account.id] {
            // Pool-agnostic accessor: sum sapling + orchard + ironwood (and any future
            // shielded pool) instead of hand-summing individual pools.
            state.spendableBalance = accountBalance.shieldedSpendableValue
        }

        // `SyncStatus.==` returns true for ANY two `.error` values (Synchronizer.swift), so a
        // status comparison alone can never see one error replace another — the sheet would
        // keep showing the first error's text, and its incompatible-server row would linger
        // on an unrelated failure. Compare the rendered message as well for the error case.
        var isDifferentError = false
        if case .error = snapshot.syncStatus {
            isDifferentError = snapshot.message != state.lastKnownErrorMessage
        }

        if snapshot.syncStatus != state.synchronizerStatusSnapshot.syncStatus || isDifferentError {
            state.synchronizerStatusSnapshot = snapshot

            var isSyncing = false
            if case let .syncing(syncProgress, isScanProgressComplete) = snapshot.syncStatus {
                state.lastKnownSyncPercentage = Double(syncProgress)
                state.lastKnownBlocksRemaining = max(
                    0,
                    latestState.data.latestBlockHeight - latestState.data.fullyScannedHeight
                )
                state.isScanProgressComplete = isScanProgressComplete
                isSyncing = true

                if state.priorityContent == .priority2 {
                    return .send(.closeAndCleanupBanner)
                }
            }

            // error syncing check
            switch snapshot.syncStatus {
            case .upToDate:
                state.isSyncTimedOutAutoAppeareDisabled = false
                // Reset the syncing block-count so a re-eval of priority 4 after sync
                // completes (account change, reconnect) doesn't see the last `.syncing`
                // sample (which can still be >= the show threshold if the SDK skipped
                // a final low-remainder update) and spuriously re-show the banner.
                state.lastKnownBlocksRemaining = -1
                if state.featureFlags.migration {
                    // A restore/resync just completed — this gets the BOUNDED-POLL arm rather than a
                    // one-shot re-read, because the recovered balance can still be invisible to
                    // `bannerVariant` for a bounded window after `.upToDate`.
                    if state.priorityContent == .priority3 || state.priorityContent == .priority45 {
                        return postRestoreMigrationRecheckEffect(
                            accountUUID: state.selectedWalletAccount?.id,
                            cancelID: state.CancelMigrationRepollId
                        )
                    }
                    // The migration banner is the one currently showing: re-read it on this
                    // transition so it lowers itself once the wallet no longer has anything to
                    // migrate — whether that is a completed manual migration or an ordinary spend
                    // of the last Orchard funds. Deliberately NOT the close-then-re-read shape used
                    // below: `.migrationVariantUpdated` re-renders an unchanged variant in place,
                    // so skipping the close is what keeps a still-`.required` banner from flickering
                    // shut and open again on every sync completion.
                    if state.priorityContent == .priorityMigration {
                        return .send(.migrationReevaluationRequested)
                    }
                    // The syncing banner must not outlive the sync it narrates: close it, THEN
                    // re-read. Sent from a SINGLE `.run` that awaits the close directly
                    // (`.closeBanner(true)`, not `.closeAndCleanupBanner`) before re-reading: the
                    // latter wraps its send in its own `.run`, which only SCHEDULES that nested
                    // effect, so a second `await send(...)` right after would race the close
                    // instead of following it.
                    if state.priorityContent == .priority4 {
                        return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                            await send(.closeBanner(true), animation: .easeInOut(duration: Constants.easeInOutDuration))
                            await send(.migrationVariantUpdated(migrationManager.bannerVariant(accountUUID)))
                        }
                    }
                    // EVERY remaining slot state — empty, or held by any lower banner. Field-caught
                    // 2026-08-03: on an already-synced wallet the launch ladder ran while the
                    // engine was still stamping its final pass, Goal-1 correctly declined the
                    // offer, the walk-down seated currency conversion (`priority8`) — and this
                    // transition then matched NO arm, so the declined offer was never asked again
                    // for the process lifetime. One re-read through the single funnel: a nil
                    // variant changes nothing (the occupant stays), a real one claims the slot
                    // through the arbiter — the rank guard lets `priorityMigration` (-1) displace
                    // every banner the walk-down can seat. Gated on the cheap latched
                    // `isIronwoodActivated()` so a synced wallet with no migration in its future
                    // pays no manager hydration here.
                    if migrationManager.isIronwoodActivated() {
                        return .send(.migrationReevaluationRequested)
                    }
                } else if state.priorityContent == .priority3
                            || state.priorityContent == .priority45
                            || state.priorityContent == .priority4 {
                    // Migration off (mainnet flavor): the pre-migration close, verbatim. With
                    // migration ON the two arms above already close the banner on this transition.
                    return .send(.closeAndCleanupBanner)
                }
            case .error, .unprepared:
                if state.lastKnownErrorMessage != snapshot.message {
                    state.lastKnownErrorMessage = snapshot.message
                    if case .error(let error) = snapshot.syncStatus {
                        state.lastKnownErrorIsIncompatibleServer = error.toZcashError().isIncompatibleServer
                    } else {
                        state.lastKnownErrorIsIncompatibleServer = false
                    }
                    return .send(.triggerPriority(.priority2))
                }
            default: break
            }

            if let account = state.selectedWalletAccount, let accountBalance = latestState.data.accountsBalances[account.id] {
                if state.priorityContent == .priority7 {
                    if accountBalance.unshielded > zcashSDKEnvironment.shieldingThreshold() {
                        return .send(.transparentBalanceUpdated(accountBalance.unshielded))
                    } else {
                        return .merge(
                            .send(.closeAndCleanupBanner),
                            .send(.closeSheetTapped)
                        )
                    }
                } else if state.transparentBalance < zcashSDKEnvironment.shieldingThreshold() && accountBalance.unshielded > zcashSDKEnvironment.shieldingThreshold() {
                    return .merge(
                        .send(.transparentBalanceUpdated(accountBalance.unshielded)),
                        .send(.triggerPriority(.priority7))
                    )
                }
            }

            // return of restoring/syncing
            let isSyncingHigherPriority = (state.priorityContent?.rawValue ?? 0) > State.PriorityContent.priority4.rawValue
            if isSyncing && (state.priorityContent == nil || isSyncingHigherPriority) {
                if state.walletStatus == .resyncing {
                    //return .send(.triggerPriority(.priority45))
                } else if state.walletStatus == .restoring {
                    return .send(.triggerPriority(.priority3))
                } else if state.lastKnownBlocksRemaining >= Constants.smartBannerSyncingBlocksThreshold {
                    return .send(.triggerPriority(.priority4))
                }
            }
        }

        return .none
    }
}

extension SmartBanner.State {
    var isSyncTimedOut: Bool {
        lastKnownErrorMessage.lowercased().contains("504 gateway timeout")
        || lastKnownErrorMessage.lowercased().contains("tor error: tor: operation timed out at exit")
    }
}
