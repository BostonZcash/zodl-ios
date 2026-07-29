import SwiftUI
import ComposableArchitecture
import MessageUI
// The debug reschedule captures an `AccountUUID`, which the pinned SDK does not declare
// `Sendable`; every other store that captures one imports it this way.
@preconcurrency import ZcashLightClientKit

@Reducer
struct AdvancedSettings {
    @ObservableState
    struct State: Equatable {
        enum Operation: Equatable {
            case chooseServer
            case disconnectHWWallet
            case exportPrivateData
            case exportTaxFile
            case recoveryPhrase
            case resetZashi
            case resyncWallet
            case torSetup
        }
        
        var isEnoughFreeSpaceMode = true
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        /// DEBUG-only result of the migration stride reschedule, shown as a plain alert.
        @Presents var alert: AlertState<Action>?

        var isKeystoneConnected: Bool {
            for account in walletAccounts {
                if account.vendor == .keystone {
                    return true
                }
            }
            
            return false
        }

        init() { }
    }

    enum Action: Equatable {
        case alert(PresentationAction<Action>)
        /// DEBUG-only (Gate 3): rewrites the committed migration schedule's transfer heights onto
        /// SHORT strides — first due in ~2 blocks, then ~4-block steps — so a real broadcast run can
        /// be exercised without waiting out ZIP-318's multi-hour privacy delay. Production windows
        /// are a ~6 h exponential mean; without this a scheduled run is untestable in one sitting.
        case debugMigrationRescheduleTapped
        case debugMigrationRescheduleFinished(String)
        case debugResetIronwoodAnnouncementTapped
        case operationAccessCheck(State.Operation)
        case operationAccessGranted(State.Operation)
    }

    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .alert:
                return .none

            case .debugMigrationRescheduleTapped:
                guard let accountUUID = state.selectedWalletAccount?.id else {
                    return .send(.debugMigrationRescheduleFinished("No account selected."))
                }
                return .run { [sdkSynchronizer, migrationManager, accountUUID] send in
                    do {
                        let count = try await sdkSynchronizer.debugRescheduleMigrationTransfers(accountUUID)
                        // Reconcile so the rows/banner pick the new heights up, then re-arm the
                        // pokes against them — otherwise the notifications would still point at the
                        // ORIGINAL windows, hours away.
                        await migrationManager.reconcile()
                        await migrationManager.armNextWindowNotifications(accountUUID)
                        await send(.debugMigrationRescheduleFinished("Rescheduled \(count) transfer(s) onto short strides."))
                    } catch {
                        await send(.debugMigrationRescheduleFinished(error.toZcashError().localizedDescription))
                    }
                }

            case .debugMigrationRescheduleFinished(let message):
                state.alert = AlertState {
                    TextState("Migration reschedule")
                } actions: {
                    ButtonState(role: .cancel) { TextState("OK") }
                } message: {
                    TextState(message)
                }
                return .none

            case .debugResetIronwoodAnnouncementTapped:
                // Debug-only row, compiled out of the App Store build (see AdvancedSettingsView).
                // Clears the Ironwood-announcement keychain flag so the one-time announcement
                // screen can be retriggered for testing. That flag deliberately survives app
                // deletion and wallet reset, so without this affordance the screen could never be
                // seen again on a device that already acknowledged it. This only writes the
                // keychain — Root separately observes this same action to clear its in-memory
                // "already shown this session" latch, without which the reset wouldn't take
                // effect until the next app launch. No biometric gate: this destroys nothing.
                try? walletStorage.importIronwoodAnnouncementFlag(false)
                return .none

            case .operationAccessCheck(let operation):
                switch operation {
                case .chooseServer, .torSetup:
                    return .send(.operationAccessGranted(operation))
                case .recoveryPhrase, .exportPrivateData, .exportTaxFile, .resetZashi, .disconnectHWWallet, .resyncWallet:
                    return .run { send in
                        if await localAuthentication.authenticate() {
                            await send(.operationAccessGranted(operation))
                        }
                    }
                }
                
            case .operationAccessGranted:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}
