//
//  MigrationCoordFlowCoordinator.swift
//  Zodl
//
//  The migration flow's routing table — see `MigrationCoordFlowStore.swift` for the Phase 2 scope
//  and the two lanes it covers. Each case below is the Phase 2 reduction of the identically-named
//  case in #1930's coordinator; where #1930 does more, the comment says what and which phase
//  restores it.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension MigrationCoordFlow {
    func coordinatorReduce() -> some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .none

            case .flowFinished:
                return .none

                // MARK: - Entry: the one fork (D8/D12)

            case .entry(.dismissRequired):
                // Entry is the flow's ROOT, so SwiftUI `dismiss()` is a no-op here — the coordinator
                // exits the flow instead (mirrors `SendForm.dismissRequired`).
                return .send(.flowFinished)

            case .entry(.delegate(.chose(let mode))):
                state.mode = mode
                switch mode {
                case .immediate:
                    // The manual lane: straight to Review, which proposes the send-max
                    // `ImmediateMigrationProposal` on its own `onAppear`.
                    //
                    // PHASE 2: #1930 routes through the Tor bottom sheet first (or skips it when the
                    // app-wide Tor flag is on and the sync server is not identity-custom), forming
                    // the run's network snapshot at that choice point. The manual lane submits over
                    // the ORDINARY send pipeline — the accepted divergence recorded in the plan's
                    // Phase 2 "Calls" line — so it has no snapshot to form; the sheet arrives with
                    // the scheduled lane in Phase 3.
                    state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
                    return .none

                case .privateScheduled:
                    state.path.append(.howItWorks(MigrationHowItWorks.State()))
                    return .none
                }

            case .entry:
                return .none

                // MARK: - Privacy lane (PREVIEW only in Phase 2)

            case .path(.element(id: _, action: .howItWorks(.delegate(.continueTapped)))):
                // PHASE 2: #1930 runs the Tor gate and then a permission chain
                // (`nextPermissionStepResult` — notification permission, background delivery) before
                // the plan screen. Notifications are Phase 4 and the Tor sheet Phase 3; the preview
                // itself needs neither.
                state.path.append(.transferPlan(MigrationTransferPlan.State()))
                return .none

            case .path(.element(id: _, action: .transferPlan(.delegate(.confirmed)))):
                // PHASE 2 ends the privacy lane HERE, at the preview — Gate 2's "backing out commits
                // nothing" holds by construction: nothing on this path signs or stores anything (see
                // `MigrationTransferPlan.State.ConfirmIntent`). Phase 3 replaces this with the real
                // commit + the Scheduled screen.
                return .send(.flowFinished)

                // MARK: - Manual lane (complete in Phase 2 — D3)

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.confirmed)))):
                // The proposal is read off the element still on top of the path (peeked BEFORE the
                // push below — `StackState.append` never pops). It is guaranteed populated: the
                // guard chain in `MigrationReviewTransferStore.confirmTapped` never reaches this
                // delegate with a nil proposal. `totalCount: 1` — a send-max proposal is a single
                // transaction BY CONSTRUCTION (`Proposal.transactionCount() == 1`).
                var immediateProposal: ImmediateMigrationProposal?
                if case .reviewTransfer(let reviewState) = state.path.last {
                    immediateProposal = reviewState.immediateProposal
                }
                state.path.append(
                    .sending(
                        MigrationSending.State(
                            totalCount: 1,
                            immediateProposal: immediateProposal
                        )
                    )
                )
                return .none

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.closed)))):
                return .send(.flowFinished)

            case .path(.element(id: _, action: .sending(.delegate(.closed)))):
                // PHASE 2: #1930 forks on `state.mode` and on whether a Complete screen sits
                // beneath (the dust lane), and acknowledges a genuinely-`.complete` run. Neither
                // exists yet — the manual lane's single broadcast IS the whole run, and completion
                // UX is Phase 6.
                return .send(.flowFinished)

            case .path(.element(id: _, action: .sending(.delegate(.viewTransaction)))):
                // Closes the flow the same way; Root routes on to Activity.
                return .send(.flowFinished)

            case .path:
                return .none
            }
        }
    }
}
