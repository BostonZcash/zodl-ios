//
//  RootInitialization.swift
//  Zashi
//
//  Created by Lukáš Korba on 01.12.2022.
//

import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

/// In this file is a collection of helpers that control all state and action related operations
/// for the `Root` with a connection to the app/wallet initialization and erasure of the wallet.
extension Root {
    enum Constants {
        static let udIsRestoringWallet = "udIsRestoringWallet"
        static let udIsResyncingWallet = "udIsResyncingWallet"
        static let udLeavesScreenOpen = "udLeaves_screen_open"
        static let noAuthenticationWithinXMinutes = 15
    }
    
    enum InitializationAction {
        case appDelegate(AppDelegateAction)
        case checkBackupPhraseValidation
        case checkRestoreWalletFlag(SyncStatus)
        case checkWalletInitialization
        case checkWalletConfig
        case initializeSDK(WalletInitMode)
        case initializeSDKFinished
        case staleWalletDatabaseHealed
        case presentStaleWalletHealedAlert
        case initialSetups
        case initializationFailed(ZcashError)
        case initializationSuccessfullyDone
        case loadedWalletAccounts([WalletAccount])
        case resetZashi
        case resetZashiRequest(Bool)
        case resetZashiRequestCanceled
        case respondToWalletInitializationState(InitializationState)
        case restoreExistingWallet
        case seedValidationResult(Bool)
        case synchronizerStartFailed(ZcashError)
        case registerForSynchronizersUpdate
        case retryStart
        case walletConfigChanged(WalletConfig)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func initializationReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .initialization(.appDelegate(.didFinishLaunching)):
                state.appStartState = .didFinishLaunching
                // TODO: [#704], trigger the review request logic when approved by the team,
                // https://github.com/Electric-Coin-Company/zashi-ios/issues/704
                return .run { send in
                        try await mainQueue.sleep(for: .seconds(0.5))
                        await send(.initialization(.initialSetups))
                    }
                    .cancellable(id: state.DidFinishLaunchingId, cancelInFlight: true)

            case .initialization(.appDelegate(.willEnterForeground)):
                if state.featureFlags.appLaunchBiometric {
                    let now = Date()
                    let before = Date.init(timeIntervalSince1970: TimeInterval(state.lastAuthenticationTimestamp))
                    if let xMinutesAgo = Calendar.current.date(byAdding: .minute, value: -Constants.noAuthenticationWithinXMinutes, to: now),
                       before < xMinutesAgo {
                        state.splashAppeared = false
                    }
                }
                state.appStartState = .willEnterForeground
                // Placed after the biometric re-auth block above so that block's possible
                // `splashAppeared = false` has already landed before the safety gate reads it.
                // The tip survives backgrounding in memory (`sdkSynchronizer.latestState()`),
                // which is what makes this call site immediate rather than waiting for a fresh
                // sync tick to repopulate it via `.synchronizerStateChanged`.
                presentIronwoodAnnouncementIfNeeded(state: &state, tip: sdkSynchronizer.latestState().latestBlockHeight)
                if state.isLockedInKeychainUnavailableState || !sdkSynchronizer.latestState().syncStatus.isPrepared {
                    return .send(.initialization(.initialSetups))
                } else {
                    return .send(.initialization(.retryStart))
                }
                
            case .initialization(.appDelegate(.migrationNotificationTapped(let accountUUID, let isTorFailure))):
                // PHASE 4: a poke was tapped. Open the migration flow — the coordinator's own
                // `onAppear` re-entry routing then lands on whatever screen the run is actually on
                // (status/resume/review), so this does NOT need to know the run's shape.
                //
                // The Tor-failure route has no surface yet (Phase 5) — it falls through to the same
                // flow rather than nowhere, which is the honest degradation: the user still reaches
                // their run, just without the dedicated explanation sheet.
                _ = isTorFailure
                // `accountUUID` names the account the notification was COMPOSED for. Selecting it
                // is Phase 5's cross-account routing; for now a tap opens the flow for whichever
                // account is selected, which is the same account in every single-account case.
                _ = accountUUID
                guard state.featureFlags.migration else { return .none }
                return openMigrationCoordFlow(state: &state)

            case .initialization(.appDelegate(.didEnterBackground)):
                sdkSynchronizer.stop()
                state.bgTask?.setTaskCompleted(success: false)
                state.bgTask = nil
                state.appStartState = .didEnterBackground
                state.isLockedInKeychainUnavailableState = false
                return .merge(
                    .cancel(id: state.CancelStateId),
                    .cancel(id: state.CancelTransactionsStateId)
                )

            case .initialization(.appDelegate(.backgroundTask(let task))):
                let keysPresent: Bool = (try? walletStorage.areKeysPresent()) ?? false
                if state.appStartState == .didFinishLaunching {
                    state.appStartState = .backgroundTask
                    if keysPresent {
                        state.bgTask = task
                        return .none
                    } else {
                        state.isLockedInKeychainUnavailableState = true
                        task.setTaskCompleted(success: false)
                        return .cancel(id: state.DidFinishLaunchingId)
                    }
                } else {
                    state.bgTask = task
                    state.appStartState = .backgroundTask
                    return .run { send in
                        await send(.initialization(.retryStart))
                    }
                }
                
            case .synchronizerStateChanged(let latestState):
                // Must run above the `selectedWalletAccount` guard and the background-task
                // branch below — both early-return, but the announcement gate has to keep
                // evaluating on every sync tick regardless of whether an account is selected
                // (normal on a fresh install) or a background task is in flight (already
                // excluded by `canPresentIronwoodAnnouncement`'s own `bgTask == nil` term).
                presentIronwoodAnnouncementIfNeeded(state: &state, tip: latestState.data.latestBlockHeight)

                let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)

                // Reconcile migration state on the EDGE into `.upToDate` — never on every tick while
                // already synced, which would storm `reconcile()` at the tip. Piggybacks on this
                // existing `stateStream()` subscription rather than opening a second one.
                // `recordSyncCompleted()` re-keys the app's SEND gate off the same edge: a
                // just-completed sync briefly disables migration sends, which is the app-direction
                // half of the privacy gate (the SDK owns the other direction).
                let didJustReachUpToDate = snapshot.syncStatus == .upToDate && !state.wasSyncUpToDateForMigration
                state.wasSyncUpToDateForMigration = snapshot.syncStatus == .upToDate
                let migrationReconcileEffect: Effect<Action> = didJustReachUpToDate
                    ? .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                        migrationManager.recordSyncCompleted()
                        await migrationManager.reconcile()
                        // PHASE 4: re-arm AFTER reconcile, so the pokes are computed from the rows
                        // reconcile just refreshed. Idempotent — stable per-(case, account) ids mean
                        // a re-arm replaces this account's own pending request, never stacks one.
                        await migrationManager.armNextWindowNotifications(accountUUID)
                    }
                    : .none

                guard let account = state.selectedWalletAccount else {
                    return migrationReconcileEffect
                }
                
                // update flexa balance
                if let accountBalance = latestState.data.accountsBalances[account.id] {
                    // Pool-agnostic accessors: sum sapling + orchard + ironwood (and any future
                    // shielded pool) instead of hand-summing individual pools.
                    let shieldedBalance = accountBalance.shieldedSpendableValue
                    let shieldedWithPendingBalance = accountBalance.shieldedTotal()

                    flexaHandler.updateBalance(shieldedWithPendingBalance, shieldedBalance)
                }

                // handle possible service unavailability
                if case .error(let error) = snapshot.syncStatus, checkUnavailableService(error) {
                    if state.walletStatus != .disconnected {
                        state.alert = AlertState.serviceUnavailable()
                    }
                    state.wasRestoringWhenDisconnected = state.walletStatus == .restoring
                    state.$walletStatus.withLock { $0 = .disconnected }
                } else if case .syncing = snapshot.syncStatus, state.walletStatus == .disconnected {
                    state.$walletStatus.withLock { $0 = state.wasRestoringWhenDisconnected ? .restoring : .none }
                }

                // handle BCGTask
                guard state.bgTask != nil else {
                    return .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus)))
                }
                
                var finishBGTask = false
                var successOfBGTask = false
                
                switch snapshot.syncStatus {
                case .upToDate:
                    successOfBGTask = true
                    finishBGTask = true
                    if state.isRestoringWallet {
                        userDefaults.remove(Constants.udIsRestoringWallet)
                        userDefaults.remove(Constants.udIsResyncingWallet)
                        state.$walletStatus.withLock { $0 = .none }
                    }
                    state.isRestoringWallet = false
                case .stopped, .error:
                    successOfBGTask = false
                    finishBGTask = true
                default: break
                }
                
                if finishBGTask  {
                    LoggerProxy.event("BGTask setTaskCompleted(success: \(successOfBGTask)) from TCA")
                    state.bgTask?.setTaskCompleted(success: successOfBGTask)
                    state.bgTask = nil
                    return .merge(
                        .cancel(id: state.CancelStateId),
                        .cancel(id: state.CancelTransactionsStateId)
                    )
                }

                return .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus)))
                
            case .initialization(.checkRestoreWalletFlag(let syncStatus)):
                if state.isRestoringWallet && syncStatus == .upToDate {
                    state.isRestoringWallet = false
                    userDefaults.remove(Constants.udIsRestoringWallet)
                    userDefaults.remove(Constants.udIsResyncingWallet)
                    state.$walletStatus.withLock { $0 = .none }
                }
                return .none

            case .initialization(.synchronizerStartFailed):
                return .none
                
            // THE OTHER HALF of `SDKSynchronizerClient.stopSyncBeforeMigrationBroadcast()`
            // (matrix B12). A migration broadcast stops sync so the two are not correlated; without
            // this handler that sync never restarts and the wallet sits dead for the session.
            //
            // Resuming is checked INDEPENDENT of `isGenuineChange`, deliberately. Two edges need it:
            //  - a foreground broadcast stopped sync while no `.retryStart` happened to be running,
            //    so `syncDeferredByMigrationGate` was never set;
            //  - a broadcast that failed PRE-FLIGHT (a Tor bootstrap error, say) never reached the
            //    SDK's gate-setting code at all, so no `true -> false` transition will EVER arrive.
            // `migrationStoppedSyncForBroadcast` covers both: it stays set until the next
            // `.migrationSyncGateChanged(false)` from ANY source, which this resumes on rather than
            // letting the dedupe swallow it as "no change".
            //
            // `reconcile()` stays gated on a genuine change — it drives banner/re-entry derivation,
            // an unrelated concern that should not re-run on every re-push.
            case .migrationSyncGateChanged(let isBlocked):
                @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false

                let isGenuineChange = isBlocked != state.lastMigrationSyncGateBlocked
                let shouldResume = !isBlocked && (state.syncDeferredByMigrationGate || migrationStoppedSyncForBroadcast)
                guard isGenuineChange || shouldResume else { return .none }

                state.lastMigrationSyncGateBlocked = isBlocked
                let reconcileEffect: Effect<Action> = isGenuineChange
                    ? .run { [migrationManager] _ in await migrationManager.reconcile() }
                    : .none

                guard shouldResume else { return reconcileEffect }

                state.syncDeferredByMigrationGate = false
                $migrationStoppedSyncForBroadcast.withLock { $0 = false }
                return .merge(
                    reconcileEffect,
                    // A broadcast just landed (or failed) — the next window moved either way.
                    .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                        await migrationManager.armNextWindowNotifications(accountUUID)
                    },
                    .send(.initialization(.retryStart))
                )

            case .initialization(.retryStart):
                if !diskSpaceChecker.hasEnoughFreeSpaceForSync() {
                    state.destinationState.preNotEnoughFreeSpaceDestination = state.destinationState.internalDestination
                    return .send(.destination(.updateDestination(.notEnoughFreeSpace)))
                } else if let preNotEnoughFreeSpaceDestination = state.destinationState.preNotEnoughFreeSpaceDestination {
                    state.destinationState.internalDestination = preNotEnoughFreeSpaceDestination
                    state.destinationState.preNotEnoughFreeSpaceDestination = nil
                }
                // Try the start only if the synchronizer has been already prepared
                guard sdkSynchronizer.latestState().syncStatus.isPrepared else {
                    return .none
                }
                return .run { [state] send in
                    do {
                        try await sdkSynchronizer.start(true)
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() PASSED")
                        }
                        await send(.initialization(.registerForSynchronizersUpdate))
                        await send(.refreshAutomaticServer)
                    } catch {
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() failed \(error.toZcashError())")
                        }
                        await send(.initialization(.synchronizerStartFailed(error.toZcashError())))
                    }
                }
                
            case .initialization(.registerForSynchronizersUpdate):
                let stateStreamEffect = Effect.publisher {
                    sdkSynchronizer.stateStream()
                        .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                        .map { $0.redacted }
                        .map(Root.Action.synchronizerStateChanged)
                }
                .cancellable(id: state.CancelStateId, cancelInFlight: true)

                // Both migration gate feeds funnel into the SAME action under the SAME cancel id, so
                // they start and stop together. The SDK's own stream only transitions on a
                // SUCCESSFUL broadcast and dedupes internally; the app-side feed is what a
                // broadcast-failure site nudges when it stopped sync for a broadcast that never
                // reached a successful outcome. The seed read ahead of the stream is what makes a
                // cold start resume a sync stopped by a broadcast in a previous session.
                let migrationSyncGateEffect = Effect.merge(
                    Effect.concatenate(
                        .run { [sdkSynchronizer] send in
                            await send(.migrationSyncGateChanged(await sdkSynchronizer.isMigrationSyncBlocked()))
                        },
                        Effect.publisher {
                            sdkSynchronizer.migrationSyncBlockedStream()
                                .dropFirst()
                                .map(Root.Action.migrationSyncGateChanged)
                        }
                    ),
                    .run { [migrationManager] send in
                        for await isBlocked in migrationManager.migrationSyncGateFeed() {
                            await send(.migrationSyncGateChanged(isBlocked))
                        }
                    }
                )
                .cancellable(id: state.migrationSyncGateCancelId, cancelInFlight: true)

                if state.bgTask != nil {
                    return .merge(stateStreamEffect, migrationSyncGateEffect)
                } else {
                    return .merge(
                        stateStreamEffect,
                        migrationSyncGateEffect,
                        .send(.home(.smartBanner(.evaluatePriority1)))
                    )
                }

            case .initialization(.checkWalletConfig):
                return .run { send in
                    let walletConfig = await walletConfigProvider.load()
                    await send(.walletConfigLoaded(walletConfig))
                }
                .cancellable(id: state.WalletConfigCancelId, cancelInFlight: true)

            case .walletConfigLoaded(let walletConfig):
                if walletConfig == WalletConfig.initial {
                    return .send(.initialization(.initialSetups))
                } else {
                    return .send(.initialization(.walletConfigChanged(walletConfig)))
                }
                
            case .initialization(.walletConfigChanged(let walletConfig)):
                return .concatenate(
                    .send(.updateStateAfterConfigUpdate(walletConfig)),
                    .send(.initialization(.initialSetups))
                )
                
            case .initialization(.initialSetups):
                if !diskSpaceChecker.hasEnoughFreeSpaceForSync() {
                    state.destinationState.preNotEnoughFreeSpaceDestination = state.destinationState.internalDestination
                    return .send(.destination(.updateDestination(.notEnoughFreeSpace)))
                } else if let preNotEnoughFreeSpaceDestination = state.destinationState.preNotEnoughFreeSpaceDestination {
                    state.destinationState.internalDestination = preNotEnoughFreeSpaceDestination
                    state.destinationState.preNotEnoughFreeSpaceDestination = nil
                }
                // TODO: [#524] finish all the wallet events according to definition, https://github.com/Electric-Coin-Company/zashi-ios/issues/524
                LoggerProxy.event(".appDelegate(.didFinishLaunching)")
                /// We need to fetch data from keychain, in order to be 100% sure the keychain can be read we delay the check a bit
                return .send(.initialization(.checkWalletInitialization))

                /// Evaluate the wallet's state based on keychain keys and database files presence
            case .initialization(.checkWalletInitialization):
                let walletState = Root.walletInitializationState(
                    databaseFiles: databaseFiles,
                    walletStorage: walletStorage,
                    zcashNetwork: zcashSDKEnvironment.network()
                )
                return .send(.initialization(.respondToWalletInitializationState(walletState)))

                /// Respond to all possible states of the wallet and initiate appropriate side effects including errors handling
            case .initialization(.respondToWalletInitializationState(let walletState)):
                switch walletState {
                case .osStatus(let osStatus):
                    state.osStatusErrorState.osStatus = osStatus
                    return .send(.destination(.updateDestination(.osStatusError)))
                case .failed:
                    state.appInitializationState = .failed
                    state.alert = AlertState.walletStateFailed(walletState)
                    return .none
                case .keysMissing:
                    state.appInitializationState = .keysMissing
                    return .send(.destination(.updateDestination(.onboarding)))
                case .filesMissing:
                    state.appInitializationState = .filesMissing
                    state.isRestoringWallet = true
                    userDefaults.setValue(true, Constants.udIsRestoringWallet)
                    state.$walletStatus.withLock { $0 = .restoring }
                    return .concatenate(
                        .send(.initialization(.initializeSDK(.restoreWallet))),
                        .send(.initialization(.checkBackupPhraseValidation))
                    )
                case .initialized:
                    if let isRestoringWallet = userDefaults.objectForKey(Constants.udIsRestoringWallet) as? Bool, isRestoringWallet {
                        state.isRestoringWallet = true
                        state.$walletStatus.withLock { $0 = .restoring }
                        return .concatenate(
                            .send(.initialization(.initializeSDK(.restoreWallet))),
                            .send(.initialization(.checkBackupPhraseValidation))
                        )
                    } else if let isResyncingWallet = userDefaults.objectForKey(Constants.udIsResyncingWallet) as? Bool, isResyncingWallet {
                        state.isRestoringWallet = true
                        state.$walletStatus.withLock { $0 = .resyncing }
                        return .concatenate(
                            .send(.initialization(.initializeSDK(.restoreWallet))),
                            .send(.initialization(.checkBackupPhraseValidation))
                        )
                    }
                    return .concatenate(
                        .send(.initialization(.initializeSDK(.existingWallet))),
                        .send(.initialization(.checkBackupPhraseValidation))
                    )
                case .uninitialized:
                    state.appInitializationState = .uninitialized
                    return .run { send in
                        try await mainQueue.sleep(for: .seconds(0.5))
                        await send(.destination(.updateDestination(.onboarding)))
                    }
                    .cancellable(id: state.CancelId, cancelInFlight: true)
                }
                
                /// Stored wallet is present, database files may or may not be present, trying to initialize app state variables and environments.
                /// When initialization succeeds user is taken to the home screen.
            case .initialization(.initializeSDK(let walletMode)):
                // First prepare wins: a foreground transition (or any other re-entry into the
                // initialization chain) while `prepareWith` is still in flight must not start a
                // second concurrent prepare — see `isInitializingSDK`. Dropping the action is
                // safe: the in-flight effect always ends in one of the terminal actions that
                // clear the latch and drive navigation themselves.
                guard !state.isInitializingSDK else { return .none }
                do {
                    let storedWallet: StoredWallet
                    do {
                        storedWallet = try walletStorage.exportWallet()
                    } catch {
                        return .send(.destination(.updateDestination(.osStatusError)))
                    }
                    let birthday = storedWallet.birthday?.value() ?? zcashSDKEnvironment.latestCheckpoint()
                    try mnemonic.isValid(storedWallet.seedPhrase.value())
                    let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())

                    state.isInitializingSDK = true
                    return .run { send in
                        do {
                            let result: Initializer.InitializationResult
                            do {
                                result = try await sdkSynchronizer.prepareWith(
                                    seedBytes,
                                    // The SDK derives the init flow itself now; a nil birthday tells it
                                    // "brand-new wallet, pick a reorg-safe recent height" (see WalletInitMode).
                                    walletMode == .newWallet ? nil : birthday,
                                    String(localizable: .accountsZashi),
                                    String(localizable: .accountsZashi).lowercased()
                                )
                            } catch ZcashError.initializerSeedMismatch {
                                // The SDK now runs this same integrity check inside
                                // Initializer.initialize and throws instead of returning, for
                                // exactly the case reconcileWalletDatabaseWithSeed below already
                                // exists to heal. Map the throw onto .seedNotRelevant so that
                                // knownStale: true heal still runs unchanged.
                                //
                                // Safe unconditionally: wipe() below leaves no accounts in the
                                // database, so the re-prepare that follows cannot hit this
                                // mismatch again. And prepare() throws before the synchronizer
                                // ever leaves .unprepared (SDKSynchronizer.prepare only advances
                                // status once initialize() returns successfully), so that
                                // re-prepare isn't blocked by prepare's own
                                // `guard status == .unprepared` early-return either.
                                result = .seedNotRelevant
                            }

                            let healed: Bool
                            switch result {
                            case .seedRequired:
                                throw ZcashError.synchronizerNotPrepared
                            case .seedNotRelevant, .success:
                                healed = try await Root.reconcileWalletDatabaseWithSeed(
                                    knownStale: result == .seedNotRelevant,
                                    seedBytes: seedBytes,
                                    isSeedRelevant: { try await sdkSynchronizer.isSeedRelevantToAnyDerivedAccount($0) },
                                    hasSeedDerivedAccount: {
                                        let accounts = try await sdkSynchronizer.walletAccounts()
                                        return accounts.contains { $0.zip32AccountIndex != nil }
                                    },
                                    clearDeviceScopedState: {
                                        Root.clearDeviceScopedWalletState(
                                            userDefaults: userDefaults,
                                            flexaHandler: flexaHandler,
                                            userStoredPreferences: userStoredPreferences,
                                            readTransactionsStorage: readTransactionsStorage
                                        )
                                    },
                                    wipe: {
                                        guard let wipePublisher = sdkSynchronizer.wipe() else {
                                            throw Root.WalletDatabaseHealError.wipeUnavailable
                                        }
                                        for try await _ in wipePublisher.values { }
                                    },
                                    reprepare: {
                                        let reprepareResult = try await sdkSynchronizer.prepareWith(
                                            seedBytes,
                                            birthday,
                                            String(localizable: .accountsZashi),
                                            String(localizable: .accountsZashi).lowercased()
                                        )
                                        guard reprepareResult == .success else {
                                            throw ZcashError.synchronizerNotPrepared
                                        }
                                    }
                                )
                            }
                            if healed {
                                await send(.initialization(.staleWalletDatabaseHealed))
                            }

                            await send(.fetchTransactionsForTheSelectedAccount)
                            /// The TCA spins an async Task in `fetchTransactionsForTheSelectedAccount` and it's needed to run
                            /// before next code here therefore Task is asleep for 0.01s. The purpose is also to not block the main thread
                            /// so await of mainQueue is not used.
                            try? await Task.sleep(nanoseconds: 10_000_000)

                            let walletAccounts = try await sdkSynchronizer.walletAccounts()
                            await send(.initialization(.loadedWalletAccounts(walletAccounts)))
                            await send(.resolveMetadataEncryptionKeys)
                            await send(.loadUserMetadata)

                            try await sdkSynchronizer.start(false)

                            var selectedAccount: WalletAccount?
                            
                            for account in walletAccounts {
                                if account.vendor == .zcash {
                                    selectedAccount = account
                                }
                            }

                            exchangeRate.refreshExchangeRateUSD()

                            if let account = selectedAccount {
                                let addressBookEncryptionKeys = try? walletStorage.exportAddressBookEncryptionKeys()
                                if addressBookEncryptionKeys == nil {
                                    do {
                                        var keys = AddressBookEncryptionKeys.empty
                                        try keys.cacheFor(
                                            seed: seedBytes,
                                            account: account.account,
                                            network: zcashSDKEnvironment.network().networkType
                                        )
                                        try walletStorage.importAddressBookEncryptionKeys(keys)
                                    } catch {
                                        // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                                    }
                                }

                                await send(.initialization(.initializationSuccessfullyDone))
                            } else {
                                await send(.initialization(.initializationSuccessfullyDone))
                            }
                        } catch Root.WalletDatabaseHealError.reprepareFailed {
                            // The stale database was already wiped before re-prepare failed, so
                            // there is no database left to leave the user staring at a dead-end
                            // `initializationFailed` alert for (that only recovers on relaunch).
                            // Recompute wallet-initialization state in-session instead: with the
                            // database gone this resolves to `.filesMissing`, which re-enters the
                            // existing restore path. The latch must drop first or the re-entry's
                            // own `.initializeSDK` would be swallowed by the single-flight guard.
                            await send(.initialization(.initializeSDKFinished))
                            await send(.initialization(.checkWalletInitialization))
                        } catch {
                            await send(.initialization(.initializationFailed(error.toZcashError())))
                        }
                    }
                } catch {
                    return .send(.initialization(.initializationFailed(error.toZcashError())))
                }

            case .initialization(.staleWalletDatabaseHealed):
                state.isRestoringWallet = true
                userDefaults.setValue(true, Constants.udIsRestoringWallet)
                state.$walletStatus.withLock { $0 = .restoring }
                state.isStaleWalletHealedAlertPending = true
                // Covers the third transition point: the destination may have already settled
                // on `.home` before this heal signal arrives (e.g. the new-wallet cascade), in
                // which case neither of the other two hooks (`updateDestination` / the
                // `.phraseDisplay`/`.onboarding` bypass arm) will ever fire again to deliver it.
                if state.destinationState.destination == .home {
                    return presentStaleWalletHealedAlertEffect(cancelId: state.staleWalletHealedAlertCancelId)
                }
                return .none

            case .initialization(.presentStaleWalletHealedAlert):
                // Re-check the destination: the 0.5s wait isn't cancelled by leaving `.home`
                // (only re-entering `.home` reschedules this effect), so a deep link or other
                // navigation during the window must not present the notice over whatever screen
                // is showing now. Leave the flag set so a later return to `.home` re-fires the
                // hook and the notice still gets delivered.
                guard state.isStaleWalletHealedAlertPending, state.destinationState.destination == .home else {
                    return .none
                }
                state.isStaleWalletHealedAlertPending = false
                state.alert = AlertState.staleWalletDatabaseHealed()
                return .none

            case .initialization(.initializeSDKFinished):
                state.isInitializingSDK = false
                return .none

            case .initialization(.initializationSuccessfullyDone):
                state.isInitializingSDK = false
                return .merge(
                    .send(.initialization(.registerForSynchronizersUpdate)),
                    .publisher {
                        autolockHandler.batteryStatePublisher()
                            .map { _ in Root.Action.batteryStateChanged }
                    }
                    .cancellable(id: state.CancelBatteryStateId, cancelInFlight: true),
                    .send(.batteryStateChanged),
                    .send(.observeTransactions),
                    .send(.observeShieldingProcessor),
                    .send(.observeTorInit),
                    .send(.refreshAutomaticServer)
                )
                
            case .initialization(.loadedWalletAccounts(let walletAccounts)):
                state.$walletAccounts.withLock { $0 = walletAccounts }
                if state.selectedWalletAccount == nil {
                    for account in walletAccounts {
                        if account.vendor == .zcash {
                            state.$selectedWalletAccount.withLock { $0 = account }
                            state.$zashiWalletAccount.withLock { $0 = account }
                            break
                        }
                    }
                }
                return .merge(
                    .send(.loadContacts),
                    .send(.loadUserMetadata),
                    .send(.loadSwapAPIAccess)
                )

            case .resolveMetadataEncryptionKeys:
                do {
                    let storedWallet: StoredWallet
                    do {
                        storedWallet = try walletStorage.exportWallet()
                    } catch {
                        return .send(.destination(.updateDestination(.osStatusError)))
                    }
                    try mnemonic.isValid(storedWallet.seedPhrase.value())
                    let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                    
                    return .run { [walletAccounts = state.walletAccounts] send in
                        do {
                            
                            for account in walletAccounts {
                                let userMetadataEncryptionKeys = try? walletStorage.exportUserMetadataEncryptionKeys(account.account)
                                if userMetadataEncryptionKeys == nil {
                                    do {
                                        var keys = UserMetadataEncryptionKeys.empty
                                        try keys.cacheFor(
                                            seed: seedBytes,
                                            account: account.account,
                                            network: zcashSDKEnvironment.network().networkType
                                        )
                                        try walletStorage.importUserMetadataEncryptionKeys(keys, account.account)
                                        await send(.loadUserMetadata)
                                    } catch {
                                        // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                                    }
                                }
                            }
                        }
                    }
                } catch { }
                return .none
                
            case .initialization(.checkBackupPhraseValidation):
                do {
                    let _ = try walletStorage.exportWallet()
                } catch {
                    return .send(.destination(.updateDestination(.osStatusError)))
                }

                state.appInitializationState = .initialized
                let isAtDeeplinkWarningScreen = state.destinationState.destination == .deeplinkWarning

                return .run { send in
                    // Delay the splash overlay dismissal
                    try await mainQueue.sleep(for: .seconds(0.5))
                    if !isAtDeeplinkWarningScreen {
                        await send(.destination(.updateDestination(Root.DestinationState.Destination.home)))
                    }
                }
                .cancellable(id: state.CancelId, cancelInFlight: true)
                
            case .initialization(.resetZashiRequest(let areMetadataPreserved)):
                state.areMetadataPreserved = areMetadataPreserved
                return .send(.initialization(.resetZashi))
                
            case .initialization(.resetZashiRequestCanceled):
                state.alert = nil
                for (id, element) in zip(state.settingsState.path.ids, state.settingsState.path) {
                    if element.is(\.resetZashi) {
                        return .send(.settings(.path(.element(id: id, action: .resetZashi(.deleteCanceled)))))
                    }
                }
                return .none

            case .initialization(.resetZashi):
                guard let wipePublisher = sdkSynchronizer.wipe() else {
                    return .send(.resetZashiSDKFailed)
                }
                return .publisher {
                    wipePublisher
                        .replaceEmpty(with: Void())
                        .map { _ in return Root.Action.resetZashiSDKSucceeded }
                        .replaceError(with: Root.Action.resetZashiSDKFailed)
                        .receive(on: mainQueue)
                }
                .cancellable(id: state.SynchronizerCancelId, cancelInFlight: true)

            case .resetZashiSDKSucceeded:
                state.splashAppeared = true
                state.isRestoringWallet = false
                Root.clearDeviceScopedWalletState(
                    userDefaults: userDefaults,
                    flexaHandler: flexaHandler,
                    userStoredPreferences: userStoredPreferences,
                    readTransactionsStorage: readTransactionsStorage
                )
                if !state.areMetadataPreserved {
                    state.walletAccounts.forEach { account in
                        try? userMetadataProvider.resetAccount(account.account)
                        try? addressBook.resetAccount(account.account)
                        #if VOTING_ENABLED
                        try? votingMetadata.resetAccount(account.account)
                        #endif
                    }
                }
                state.walletAccounts.forEach { account in
                    try? walletStorage.clearEncryptionKeys(account.account)
                }
                state.autoUpdateSwapCandidates.removeAll()
                try? userMetadataProvider.reset()
                #if VOTING_ENABLED
                votingMetadata.reset()
                #endif
                state.$walletStatus.withLock { $0 = .none }
                state.$selectedWalletAccount.withLock { $0 = nil }
                state.$walletAccounts.withLock { $0 = [] }
                state.$zashiWalletAccount.withLock { $0 = nil }
                state.$transactionMemos.withLock { $0 = [:] }
                state.$addressBookContacts.withLock { $0 = .empty }
                state.$transactions.withLock { $0 = [] }
                state.path = nil
                if state.appInitializationState != .keysMissing {
                    state = .initial
                }

                return .send(.resetZashiKeychainRequest)
                
            case .resetZashiKeychainRequest:
                return .run { send in
                    do {
                        try walletStorage.resetZashi()
                        await send(.resetZashiFinishProcessing)
                    } catch WalletStorage.KeychainError.unknown(let osStatus) {
                        await send(.resetZashiKeychainFailed(osStatus))
                    }
                }

            case .resetZashiFinishProcessing:
                do {
                    let areKeysPresent = try walletStorage.areKeysPresent()
                    if areKeysPresent {
                        return .send(.resetZashiKeychainFailedWithCorruptedData("Keychain keys are still present"))
                    }
                } catch WalletStorage.WalletStorageError.alreadyImported {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("alreadyImported"))
                } catch WalletStorage.WalletStorageError.uninitializedAddressBookEncryptionKeys {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("uninitializedAddressBookEncryptionKeys"))
                } catch WalletStorage.WalletStorageError.storageError(let error) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("storageError, \(error.localizedDescription)"))
                } catch WalletStorage.WalletStorageError.unsupportedVersion(let version) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unsupportedVersion \(version)"))
                } catch WalletStorage.WalletStorageError.unsupportedLanguage(let language) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unsupportedLanguage, \(language)"))
                } catch WalletStorage.KeychainError.decoding {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("decoding"))
                } catch WalletStorage.KeychainError.duplicate {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("duplicate"))
                } catch WalletStorage.KeychainError.encoding {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("encoding"))
                } catch WalletStorage.KeychainError.noDataFound {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("noDataFound"))
                } catch WalletStorage.KeychainError.unknown(let osStatus) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unknown, OSStatus \(osStatus)"))
                } catch WalletStorage.WalletStorageError.uninitializedWallet {
                    // this is valid state and what we expect
                } catch {
                    return .send(.resetZashiKeychainFailedWithCorruptedData(error.localizedDescription))
                }

                // TODO: [#1627] validate whether this code makes sense
                // https://github.com/zodl-inc/zodl-ios/issues/1627
//                if state.appInitializationState == .keysMissing && state.onboardingState.isImportingWallet {
//                    state.appInitializationState = .uninitialized
//                    return .cancel(id: SynchronizerCancelId)
//                } else if state.appInitializationState == .keysMissing && state.onboardingState.destination == .createNewWallet {
//                    state.appInitializationState = .uninitialized
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.onboarding(.createNewWalletRequested))
//                    )
//                } else {
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.initialization(.checkWalletInitialization))
//                    )
//                }

                // TODO: [#1627] this might need to be recreated
                // https://github.com/zodl-inc/zodl-ios/issues/1627
//                if state.appInitializationState == .keysMissing && state.onboardingState.destination == .importExistingWallet {
//                    state.appInitializationState = .uninitialized
//                    return .cancel(id: SynchronizerCancelId)
//                } else if state.appInitializationState == .keysMissing && state.onboardingState.destination == .createNewWallet {
//                    state.appInitializationState = .uninitialized
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.onboarding(.createNewWalletRequested))
//                    )
//                } else {
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.initialization(.checkWalletInitialization))
//                    )
//                }
                return .concatenate(
                    .cancel(id: state.SynchronizerCancelId),
                    .send(.initialization(.checkWalletInitialization))
                )

            case .resetZashiKeychainFailedWithCorruptedData(let errMsg):
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeKeychainFailed(errMsg)
                return .cancel(id: state.SynchronizerCancelId)

            case .resetZashiKeychainFailed(let osStatus):
                guard state.maxResetZashiAppAttempts == 0 else {
                    state.maxResetZashiAppAttempts -= 1
                    return .send(.resetZashiKeychainRequest)
                }
                state.maxResetZashiAppAttempts = ResetZashiConstants.maxResetZashiAppAttempts
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeFailed(osStatus)
                return .cancel(id: state.SynchronizerCancelId)

            case .resetZashiSDKFailed:
                guard state.maxResetZashiSDKAttempts == 0 else {
                    state.maxResetZashiSDKAttempts -= 1
                    return .concatenate(
                        .cancel(id: state.SynchronizerCancelId),
                        .send(.initialization(.resetZashi))
                    )
                }
                state.maxResetZashiSDKAttempts = ResetZashiConstants.maxResetZashiSDKAttempts
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeFailed(Int32.max)
                return .cancel(id: state.SynchronizerCancelId)

            case .phraseDisplay(.finishedTapped), .onboarding(.newWalletSuccessfulyCreated):
                state.destinationState.destination = .home
                // This is the second (synchronous, action-round-trip-free) place the destination
                // can land on `.home` — see `presentStaleWalletHealedAlertEffect` (RootStore.swift).
                if state.isStaleWalletHealedAlertPending {
                    return presentStaleWalletHealedAlertEffect(cancelId: state.staleWalletHealedAlertCancelId)
                }
                return .none

            case .onboarding(.createNewWalletTapped):
                if state.appInitializationState == .keysMissing {
                    state.alert = AlertState.existingWallet()
                    return .none
                } else {
                    return .send(.onboarding(.createNewWalletRequested))
                }

            case .initialization(.restoreExistingWallet):
                return .run { send in
                    await send(.onboarding(.dismissDestination))
                    try await mainQueue.sleep(for: .seconds(1))
                    await send(.onboarding(.importExistingWallet))
                }

            case .initialization(.seedValidationResult(let validSeed)):
                if !validSeed {
                    state.alert = AlertState.differentSeed()
                }
                return .none

            case .updateStateAfterConfigUpdate(let walletConfig):
                state.walletConfig = walletConfig
                return .none

            case .initialization(.initializationFailed(let error)):
                state.isInitializingSDK = false
                state.appInitializationState = .failed
                state.alert = AlertState.initializationFailed(error)
                return .none

            default:
                return .none
            }
        }
    }
    
    private func checkUnavailableService(_ error: Error) -> Bool {
        switch error {
        case ZcashError.serviceGetInfoFailed(.timeOut),
            ZcashError.serviceLatestBlockFailed(.timeOut),
            ZcashError.serviceLatestBlockHeightFailed(.timeOut),
            ZcashError.serviceBlockRangeFailed(.timeOut),
            ZcashError.serviceSubmitFailed(.timeOut),
            ZcashError.serviceFetchTransactionFailed(.timeOut),
            ZcashError.serviceFetchUTXOsFailed(.timeOut),
            ZcashError.serviceBlockStreamFailed(.timeOut),
            ZcashError.serviceSubtreeRootsStreamFailed(.timeOut):
            return true
        default: return false
        }
    }

    /// Presents the one-time Ironwood announcement screen once the device hasn't acknowledged
    /// it yet, Ironwood is active on chain, and it is safe to take the screen over. Called from
    /// both `.synchronizerStateChanged` (cold start and the tail of a restore) and
    /// `.appDelegate(.willEnterForeground)` (returning to the foreground, where the tip is
    /// already known in memory from before backgrounding) — together the two cover every moment
    /// the tip or the safety gate can newly satisfy the predicate.
    ///
    /// Each guard below is load-bearing and deliberately ordered:
    /// 1. the in-memory per-session latch short-circuits every call once the gate has already
    ///    "resolved" this session (presented, or found already-acknowledged in the keychain);
    /// 2. the tip/activation check runs before any keychain access — cheap, and it keeps the
    ///    (overwhelmingly common, pre-activation) path from ever touching the keychain. `tip > 0`
    ///    is a deliberate fail-safe: the chain tip is in-memory only and reads `0` before the
    ///    first successful server round-trip, and an unknown tip must count as "not active" —
    ///    never as a false positive that skips straight past activation;
    /// 3. the keychain read happens at most once per session: as soon as it reports
    ///    already-acknowledged, the latch is set so this guard is never evaluated again;
    /// 4. the safety gate is re-checked on every call and deliberately does NOT set the latch on
    ///    failure, so a blocked attempt (e.g. mid-flow) retries on a later tick instead of being
    ///    silently skipped for the rest of the session.
    func presentIronwoodAnnouncementIfNeeded(state: inout Root.State, tip: BlockHeight) {
        guard !state.ironwoodAnnouncementResolved else { return }
        guard tip > 0, tip >= zcashSDKEnvironment.ironwoodActivationHeight() else { return }
        guard walletStorage.exportIronwoodAnnouncementFlag() != true else {
            state.ironwoodAnnouncementResolved = true
            return
        }
        guard state.canPresentIronwoodAnnouncement else { return }
        state.ironwoodAnnouncementResolved = true
        // Assigned directly rather than sending `.destination(.updateDestination(...))`: the
        // two call sites below have several early-return paths of their own, and merging an
        // effect into all of them would be invasive. The two things `updateDestination` adds
        // over a direct assignment — the deeplink-warning guard and the deferred
        // stale-wallet-healed alert hook — are both no-ops here: `canPresentIronwoodAnnouncement`
        // already requires `destination == .home`, so the deeplink-warning screen can't be in
        // play, and the heal hook only fires when the destination is moving TO `.home`, not away
        // from it. There is precedent for a direct assignment in this same file — see
        // `state.destinationState.destination = .home` in the `.phraseDisplay(.finishedTapped)` /
        // `.onboarding(.newWalletSuccessfulyCreated)` arm above.
        state.destinationState.destination = .ironwoodAnnouncement
    }

    // MARK: - PHASE 7: opening the migration flow from OUTSIDE it

    /// The single entry point for every Root-side site that opens (or re-opens) the migration flow:
    /// the banner tap and the notification tap. Both replace `migrationCoordFlowState` wholesale, so
    /// both must run the same defensive teardown first — hence one helper rather than two inline
    /// resets that can drift.
    func openMigrationCoordFlow(state: inout Root.State) -> Effect<Root.Action> {
        let cancelEffect = cancelAbandonedKeystoneMigrationRun(state: state)
        state.migrationCoordFlowState = MigrationCoordFlow.State.initial
        state.path = Root.State.Path.migrationCoordFlow
        return cancelEffect
    }

    /// Cancels the engine run a Keystone BATCH ceremony created, when the flow is being torn down
    /// from OUTSIDE while that ceremony is still live.
    ///
    /// The engine creates a Keystone commit's ENTIRE run — preparations and the schedule's transfers
    /// alike — the moment its PCZTs are built (`proposeNoteSplitPCZTs`, called by
    /// `MigrationCommitPipeline.proposeKeystoneBatch`), and always resumes a stored non-terminal run
    /// on the next attempt, ignoring any newer preview. Wiping `migrationCoordFlowState` while
    /// `pendingKeystoneSigning` is live would strand that run: a later re-entry would silently resume
    /// signing the same, by-then-stale PCZTs instead of proposing a fresh preview.
    ///
    /// `pendingKeystoneSigning` is only ever set once the ceremony actually started, so its presence
    /// here means exactly "a ceremony was begun and never resolved". Cancel via
    /// `restartCurrentMigrationStep`, discarding the fresh schedule it returns — the user re-runs the
    /// ceremony from a fresh preview, the same v1 semantics as the in-flow
    /// `.keystoneScanAbandoned` twin.
    ///
    /// Restricted to `.planCommit`: the immediate lane's `createPCZTFromProposal` is engine-external
    /// and created no run, so cancelling for it would at best be a no-op and at worst restart an
    /// unrelated committed run. Read BEFORE the caller resets the state, and cancelled on the run's
    /// RECORDED owner (`pendingKeystoneSigningAccountUUID`) rather than the currently-selected
    /// account, which can have moved on by the time this runs. Fire-and-forget: a failure just leaves
    /// the stray run for the next attempt to encounter and cancel itself.
    func cancelAbandonedKeystoneMigrationRun(state: Root.State) -> Effect<Root.Action> {
        guard case .planCommit? = state.migrationCoordFlowState.pendingKeystoneSigning,
              let accountUUID = state.migrationCoordFlowState.pendingKeystoneSigningAccountUUID
                ?? state.selectedWalletAccount?.id else {
            return .none
        }

        return .run { [sdkSynchronizer] _ in
            _ = try? await sdkSynchronizer.restartCurrentMigrationStep(accountUUID)
        }
    }
}
