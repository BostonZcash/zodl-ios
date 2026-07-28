import SwiftUI
import ComposableArchitecture
import MessageUI

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
    }
}
