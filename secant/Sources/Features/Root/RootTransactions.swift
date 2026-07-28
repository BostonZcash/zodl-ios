//
//  RootTransactions.swift
//  Zashi
//
//  Created by Lukáš Korba on 29.01.2025.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension Root {
    func transactionsReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .observeTransactions:
                return .merge(
                    .publisher {
                        sdkSynchronizer.eventStream()
                            .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                            .compactMap {
                                if case SynchronizerEvent.foundTransactions(let transactions, _) = $0 {
                                    return Root.Action.foundTransactions(transactions)
                                } else if case SynchronizerEvent.minedTransaction(let transaction) = $0 {
                                    return Root.Action.minedTransaction(transaction)
                                }
                                return nil
                            }
                    }
                    .cancellable(id: state.CancelEventId, cancelInFlight: true),
                    .publisher {
                        sdkSynchronizer.stateStream()
                            .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                            .map {
                                if $0.syncStatus == .upToDate {
                                    return Root.Action.fetchTransactionsForTheSelectedAccount
                                }
                                return Root.Action.noChangeInTransactions
                            }
                    }
                    .cancellable(id: state.CancelTransactionsStateId, cancelInFlight: true),
                    .send(.fetchTransactionsForTheSelectedAccount)
                )
                
            case .noChangeInTransactions:
                return .none
                
            case .foundTransactions:
                return .send(.fetchTransactionsForTheSelectedAccount)
                
            case .minedTransaction:
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .fetchTransactionsForTheSelectedAccount:
                guard let accountUUID = state.selectedWalletAccount?.id else {
                    return .none
                }
                // This id exists so an account switch can cancel whatever fetch is still running
                // for the account just left (see `accountSwitchedEffect` in `RootCoordinator.swift`,
                // which explicitly `.cancel`s this id before sending a fresh fetch for the new
                // account). `cancelInFlight` is deliberately NOT used here: during a sync,
                // `sdkSynchronizer.eventStream()` is throttled to one event per 0.2s and every
                // `foundTransactions`/`minedTransaction` re-dispatches this action (see above) -- on
                // a wallet where `getAllTransactions` takes longer than that 0.2s interval,
                // `cancelInFlight` would cancel every one of those fetches before it could complete,
                // starving `.fetchedTransactions` for the whole sync. Letting concurrent fetches for
                // the same account run to completion is harmless: the `.fetchedTransactions`
                // provenance guard below still drops any payload for an account other than the one
                // currently selected.
                return .run { send in
                    if let transactions = try? await sdkSynchronizer.getAllTransactions(accountUUID) {
                        await send(.fetchedTransactions(accountUUID, transactions))
                    }
                }
                .cancellable(id: state.CancelTransactionsFetchId)

            case .fetchedTransactions(let accountUUID, var transactions):
                // Load-bearing provenance guard -- drop a payload that belongs to an account other
                // than the one currently selected. Closes the race even when the cancel id above
                // misses (the fetch's own effect completed anyway): during sync, BOTH accounts'
                // wallet-wide `eventStream`/`stateStream` events can dispatch a fetch, and a slow one
                // for the account that was JUST switched away from can still land after the switch.
                // Never merge/reconcile a stale payload -- always drop it whole.
                guard accountUUID == state.selectedWalletAccount?.id else {
                    return .none
                }
                let mempoolHeight = sdkSynchronizer.latestState().latestBlockHeight + 1

                // Resolve Swaps
                let allSwaps = userMetadataProvider.allSwaps()
                
                // Swaps From ZEC and CrossPays
                let swapsFromZecAndCrossPays = allSwaps.filter {
                    $0.fromAsset == SwapConstants.zecAssetIdOnNear
                }
                
                swapsFromZecAndCrossPays.forEach { swap in
                    if let transaction = transactions.filter({ $0.zAddress == swap.depositAddress }).first {
                        transactions[id: transaction.id]?.type = swap.exactInput ? .swapFromZec : .crossPay
                        transactions[id: transaction.id]?.swapStatus = swap.swapStatus
                    }
                }

                // Swaps To ZEC
                let swapsToZec = allSwaps.filter {
                    $0.toAsset == SwapConstants.zecAssetIdOnNear
                }

                var mixedTransactions = transactions

                swapsToZec.forEach { swap in
                    mixedTransactions.append(
                        TransactionState(
                            depositAddress: swap.depositAddress,
                            timestamp: TimeInterval(swap.lastUpdated / 1000),
                            zecAmount: swap.amountOutFormatted.localeString ?? swap.amountOutFormatted,
                            swapStatus: swap.swapStatus
                        )
                    )
                }

                // Sort all transactions
                let sortedTransactions = mixedTransactions
                    .sorted { lhs, rhs in
                        if let lhsTimestamp = lhs.timestamp, let rhsTimestamp = rhs.timestamp {
                            return lhsTimestamp > rhsTimestamp
                        } else {
                            return lhs.transactionListHeight(mempoolHeight) > rhs.transactionListHeight(mempoolHeight)
                        }
                    }
                
                let identifiedArray = IdentifiedArrayOf<TransactionState>(uniqueElements: sortedTransactions)

                // Update transactions
                if state.transactions != identifiedArray {
                    state.$transactions.withLock {
                        $0 = identifiedArray
                    }
                    return .send(.home(.smartBanner(.evaluatePriority6)))
                }
                // The fetch still completed even though its result is identical to what's already in
                // `state.transactions` -- most commonly when switching between two accounts that both
                // have no transactions. The write above is skipped in that case, so nothing downstream
                // of the shared `$transactions` publisher fires. Both transaction lists' own
                // `transactionsUpdated` is what clears their `isInvalidated` flag (set by
                // `accountSwitchedEffect` in `RootCoordinator.swift` on every switch), so without
                // sending it here directly, an unchanged-but-completed fetch would leave them stuck
                // showing their loading placeholder forever.
                //
                // Only worth sending while a list is actually still showing that placeholder. A
                // steady sync re-dispatches this fetch every 0.2s and usually yields an unchanged
                // list, and `transactionsUpdated` re-runs each store's derived-state recomputation
                // -- which on the See All screen, with a search term active, includes an SDK memo
                // query. Nothing is waiting on the signal once both flags are already clear.
                guard state.homeState.transactionListState.isInvalidated
                    || state.transactionsCoordFlowState.transactionsManagerState.isInvalidated else {
                    return .none
                }
                return .merge(
                    .send(.home(.transactionList(.transactionsUpdated))),
                    .send(.transactionsCoordFlow(.transactionsManager(.transactionsUpdated)))
                )

            default: return .none
            }
        }
    }
}
