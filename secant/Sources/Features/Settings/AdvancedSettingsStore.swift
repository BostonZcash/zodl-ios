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
        /// DEBUG-only SIGNPOST (retired with SDK PR #1951): the manual "reschedule onto short
        /// strides" lever is gone — schedules are engine-owned, and test-network schedules arrive
        /// compressed at commit time. The row stays so QA learns the new mechanism instead of
        /// hunting for a vanished feature; the tap just presents the explanation.
        case debugMigrationRescheduleTapped
        /// The signpost alert's payload — see `debugMigrationRescheduleTapped`.
        case debugMigrationRescheduleFinished(String)
        case debugResetIronwoodAnnouncementTapped
        case operationAccessCheck(State.Operation)
        case operationAccessGranted(State.Operation)
    }

    @Dependency(\.localAuthentication) var localAuthentication
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
                // Retired with SDK PR #1951: the QA reschedule endpoint is gone — scheduling
                // belongs to the engine, and test-network schedules arrive compressed at commit
                // time (the interim spacing-floor knob on the advance call left the SDK with the
                // librustzcash rebase). The button stays as a signpost so QA learns the new
                // mechanism instead of hunting for a vanished feature; the alert plumbing it
                // reuses is unchanged.
                return .send(.debugMigrationRescheduleFinished(
                    "Retired: schedules are engine-owned now — a fresh testnet run already arrives compressed, and -MigrationFastLane collapses the privacy buffer. There is no manual reschedule."
                ))

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
