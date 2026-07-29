//
//  MigrationCoordFlowCoordinator.swift
//  Zodl
//
//  The migration flow's routing table — see `MigrationCoordFlowStore.swift` for the Phase 3 scope
//  and the two lanes it covers. Each case below is the Phase 3 reduction of the identically-named
//  case in #1930's coordinator; where #1930 does more, the comment says what and which phase
//  restores it.
//
//  WHY THIS FILE IS EXTRACTED CASE-BY-CASE rather than copied whole, unlike the manager and every
//  screen: #1930's coordinator is 2,923 lines whose `Path` enum names five screens this build does
//  not have — `MigrationKeystoneSign` (Phase 7), `MigrationRecovery` (5), `MigrationComplete` (6),
//  `MigrationNotifications` + `MigrationBackgroundDelivery` (4). Copying it whole means deleting
//  ~40% of it or pulling four later phases in at once. The rows below are #1930's own, at its line
//  numbers; everything in its 685-1158 (Keystone) and 1289-1642 (Recovery/Complete) stays out.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension MigrationCoordFlow {
    func coordinatorReduce() -> some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // PHASE 3: #1930 (:379) also arms `migrationManager.setMigrationFlowPresented` here
                // — a guard whose only consumer is the Phase 6 remainder evaluation. Re-entry
                // routing itself IS wired: a flow opened over a committed run lands on its live
                // screen rather than back at the fork.
                guard state.path.isEmpty else { return .none }
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    guard let pathState = await reentryPathState(accountUUID: accountUUID) else { return }
                    await send(.pushHydratedPathState(pathState))
                }

            case .flowFinished:
                return .none

            case .switchServerRequested:
                // Root opens Server Setup and tears this flow down; the coordinator owns no
                // navigation outside its own `path`.
                return .none

            case .pushHydratedPathState(let pathState):
                state.path.append(pathState)
                return .none

            case .pushHydratedStatus(let statusState):
                state.path.append(.status(statusState))
                return .none

                // MARK: - Entry: the one fork (D8/D12)

            case .entry(.dismissRequired):
                // Entry is the flow's ROOT, so SwiftUI `dismiss()` is a no-op here — the coordinator
                // exits the flow instead (mirrors `SendForm.dismissRequired`).
                return .send(.flowFinished)

            case .entry(.delegate(.chose(let mode))):
                state.mode = mode
                migrationManager.setMigrationMode(state.selectedWalletAccount?.id, mode)

                switch mode {
                case .immediate:
                    return torGate(state: &state, destination: .reviewTransfer, usesFullBalanceCopy: true)

                case .privateScheduled:
                    state.path.append(.howItWorks(MigrationHowItWorks.State()))
                    return .none
                }

            case .entry:
                return .none

                // MARK: - HowItWorks -> the same Tor gate the immediate lane uses

            case .path(.element(id: _, action: .howItWorks(.delegate(.continueTapped)))):
                // PHASE 3: #1930 (:477) resolves the Tor choice exactly as below and THEN runs the
                // notification-permission chain (`nextPermissionStepResult`) before the plan.
                // Permissions are Phase 4; the Tor half is here in full, and Phase 4 inserts its
                // chain between this gate and the plan push.
                return torGate(state: &state, destination: .transferPlan, usesFullBalanceCopy: false)

                // MARK: - Tor bottom sheet (#1930 :519-568, verbatim)

            case .torSheet(.delegate(.gotIt)):
                return confirmTorSheet(state: &state)

            case .torSheet(.delegate(.switchServer)):
                // The custom-server variant's "Switch Server" — leave the flow for Server Setup and
                // persist NOTHING for the abandoned attempt: no `setNetworkPrivacyOptions`, no
                // `confirmProvisionalTorChoice`. The snapshot stays PROVISIONAL, so Root's teardown
                // discards it and a re-entry re-rolls.
                state.isTorSheetPresented = false
                state.pendingTorDestination = nil
                return .send(.switchServerRequested)

            case .torSheet:
                return .none

            case .torSheetStateReady(let sheetState, let destination):
                // Presentation-time forming/hydration resolved — show the sheet now.
                state.torSheetState = sheetState
                state.pendingTorDestination = destination
                state.isTorSheetPresented = true
                return .none

            case .torSheetPresentationChanged(let isPresented):
                state.isTorSheetPresented = isPresented
                // `false` covers both an explicit "Got it" (which already ran `confirmTorSheet`, so
                // `pendingTorDestination` is nil and the guard below exits) and a swipe-dismiss,
                // which never routed through `.delegate(.gotIt)` at all.
                guard !isPresented, state.pendingTorDestination != nil else { return .none }

                // R3/R11: a GENUINE swipe-dismiss showing a PROVIDER sheet with the toggle OFF
                // carries no warning-alert confirmation — persisting that OFF choice here would be
                // exactly the unwarned clearnet opt-out R3 forbids. Treat that one combination as a
                // full cancel: nothing persisted, `path` untouched, the flow does not advance.
                // Every other combination (ON, or identity-custom, where R12's disclosure already
                // stood in for the warning) keeps the persist-and-resume semantics.
                if !state.torSheetState.isCustomServer && !state.torSheetState.isTorOn {
                    state.pendingTorDestination = nil
                    return .none
                }
                return confirmTorSheet(state: &state)

                // MARK: - Notifications permission (#1930 :613)

            case .path(.element(id: _, action: .notifications(.delegate(.continued)))):
                // Allowed or skipped, both land here — the plan is next either way.
                state.path.append(.transferPlan(MigrationTransferPlan.State()))
                return .none

                // MARK: - TransferPlan (#1930 :620)

            case .path(.element(id: _, action: .transferPlan(.delegate(.confirmed)))):
                guard case let .transferPlan(planState) = state.path.last else { return .none }

                guard planState.requiresSigning else {
                    // PHASE 3: #1930 additionally forks here on `isExpiredRecoveryReview` (Phase 5).
                    // The remaining `requiresSigning == false` screen is the RESCHEDULED variant,
                    // whose confirm is a plain acknowledgment of an already-committed reschedule —
                    // no re-sign, no terminal screen, straight out ("Got it" per the spec).
                    return .send(.flowFinished)
                }

                return transferPlanPostConfirmChain(
                    variant: planState.variant,
                    schedule: planState.schedule,
                    state: &state
                )

                // MARK: - ReviewTransfer (#1930 :651)

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.confirmed)))):
                // Both `Mode` cases delegate this SAME action, so the element still on top of the
                // path (peeked BEFORE the push — `StackState.append` never pops) is the only place
                // left to tell a manual-STEP confirm apart from an immediate one-shot sweep, which
                // selects the pushed screen's success wording.
                //
                // `totalCount: 1` — a send-max proposal is a single transaction BY CONSTRUCTION
                // (`Proposal.transactionCount() == 1`). The proposal is guaranteed populated for the
                // immediate lane: the guard chain in `MigrationReviewTransferStore.confirmTapped`
                // never reaches this delegate with a nil one.
                let isManualStepLane: Bool
                var immediateProposal: ImmediateMigrationProposal?
                if case .reviewTransfer(let reviewState) = state.path.last, case .manualStep = reviewState.mode {
                    isManualStepLane = true
                } else {
                    isManualStepLane = false
                    if case .reviewTransfer(let reviewState) = state.path.last {
                        immediateProposal = reviewState.immediateProposal
                    }
                }
                state.path.append(
                    .sending(
                        MigrationSending.State(
                            totalCount: 1,
                            isManualStepLane: isManualStepLane,
                            immediateProposal: immediateProposal
                        )
                    )
                )
                return .none

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.closed)))):
                return .send(.flowFinished)

                // MARK: - Status (#1930 :1232 / :1262)

            case .path(.element(id: _, action: .status(.delegate(.sendNow)))):
                // "Send now" on an overdue transfer: push the Sending screen in the manual-step
                // shape, which runs the ordinary broadcast lane. #1930 additionally releases a
                // send-wait hold here (its BG lane's; D2 removed it).
                state.path.append(.sending(MigrationSending.State(totalCount: 1, isManualStepLane: true)))
                return .none

            case .path(.element(id: let id, action: .status(.delegate(.reschedule)))):
                // An overdue transfer the user chose to reschedule rather than send now: ask the
                // engine for a fresh window, then re-render the plan as the RESCHEDULED variant
                // (`requiresSigning == false` — it is already signed; its confirm is an
                // acknowledgment, handled above).
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    guard let accountUUID else { return }
                    _ = try? await sdkSynchronizer.rescheduleOverdueMigrationTransfer(accountUUID)
                    await migrationManager.reconcile()
                    let rows = await migrationManager.migrationTransfers(accountUUID)
                    await send(.sendNowCompleted(rows: rows))
                    _ = id
                }

            case .path(.element(id: _, action: .status(.delegate(.done)))):
                return .send(.flowFinished)

            case .sendNowCompleted(let rows):
                // Re-render whichever Status screen is on top with the refreshed rows, rather than
                // pushing a second one.
                guard case .status(var statusState) = state.path.last, let id = state.path.ids.last else { return .none }
                statusState.rows = IdentifiedArrayOf(uniqueElements: rows)
                state.path[id: id] = .status(statusState)
                return .none

                // MARK: - Sending (#1930 :1161)

            case .path(.element(id: _, action: .sending(.delegate(.closed)))):
                // PHASE 3: #1930 forks on `state.mode` and on whether a Complete screen sits
                // beneath (the dust lane), and acknowledges a genuinely-`.complete` run — both
                // Phase 6. A scheduled run's remaining transfers stay scheduled; the user returns
                // via the banner or a notification (Phase 4).
                return .send(.flowFinished)

            case .path(.element(id: _, action: .sending(.delegate(.viewTransaction)))):
                // Closes the flow the same way; Root routes on to Activity.
                return .send(.flowFinished)

            case .path:
                return .none
            }
        }
    }

    // MARK: - Tor gate

    /// The Tor-choice resolution point, shared by both lanes (#1930 :407 immediate / :477 scheduled
    /// — the two branches are identical apart from the destination and the sheet's copy).
    ///
    /// Skip the sheet iff the app-wide Tor flag is on AND the account's sync server is not
    /// identity-custom. A custom server's snapshot forces clearnet, so skipping straight through
    /// would silently route those users over clearnet with no unavailable-server notice ever shown.
    ///
    /// Detection is `isSyncServerIdentityCustom()` — a SYNCHRONOUS, snapshot-free read — checked
    /// before entering any effect, deliberately NOT the sheet state's own `isCustomServer`, which
    /// requires FORMING first. Order matters on the non-custom branch: `setNetworkPrivacyOptions`
    /// must run BEFORE `formNetworkSnapshot`, because forming BAKES IN whatever is currently
    /// persisted and a later persist does not correct an already-formed snapshot. Detecting via the
    /// sheet state would force a form-before-persist and could silently bake in a stale OFF choice.
    ///
    /// The identity-custom branch persists NOTHING: that sheet offers no choice, so storing its
    /// forced value would overwrite a real stored preference.
    private func torGate(
        state: inout State,
        destination: PendingTorDestination,
        usesFullBalanceCopy: Bool
    ) -> Effect<Action> {
        let accountUUID = state.selectedWalletAccount?.id

        if walletStorage.exportTorSetupFlag() == true {
            guard !migrationManager.isSyncServerIdentityCustom() else {
                return .run { send in
                    let sheetState = await torSheetState(usesFullBalanceCopy: usesFullBalanceCopy, accountUUID: accountUUID)
                    await send(.torSheetStateReady(sheetState, destination: destination))
                }
            }
            migrationManager.setNetworkPrivacyOptions(true)
            return .run { [migrationManager] send in
                await migrationManager.formNetworkSnapshot(accountUUID)
                await send(.pushHydratedPathState(destinationPathState(destination)))
            }
        }
        return .run { send in
            let sheetState = await torSheetState(usesFullBalanceCopy: usesFullBalanceCopy, accountUUID: accountUUID)
            await send(.torSheetStateReady(sheetState, destination: destination))
        }
    }

    /// Forms the run's provisional snapshot and derives the sheet's state from it — presentation-time
    /// forming, so the broadcast endpoint exists on the choice surface the user is shown.
    private func torSheetState(usesFullBalanceCopy: Bool, accountUUID: AccountUUID?) async -> MigrationTorSheet.State {
        await migrationManager.formNetworkSnapshot(accountUUID)
        let snapshot = await migrationManager.networkSnapshot(accountUUID)
        let isCustomServer = Self.isIdentityCustom(snapshot)

        var sheetState = MigrationTorSheet.State(usesFullBalanceCopy: usesFullBalanceCopy)
        sheetState.isCustomServer = isCustomServer
        if isCustomServer {
            sheetState.isTorOn = false
        }
        return sheetState
    }

    /// "Got it" (both the toggle-ON path and the off-warning alert's "Proceed without Tor"), the
    /// custom variant's acknowledge, and swipe-to-dismiss (for every combination except the one
    /// R3/R11 guards) all land here: persist whatever `isTorOn` is showing, dismiss, resume the
    /// stashed destination. A no-op when nothing is pending.
    ///
    /// Does NOT re-form the snapshot: presentation already formed the one the user was shown, and
    /// confirm must not re-roll the endpoint out from under them. `confirmProvisionalTorChoice`
    /// mutates ONLY `useTor` on that already-formed provisional snapshot — skipped entirely for an
    /// identity-custom confirm, whose forced `isTorOn == false` is a circumstance, not a preference.
    private func confirmTorSheet(state: inout State) -> Effect<Action> {
        guard let destination = state.pendingTorDestination else { return .none }
        state.pendingTorDestination = nil
        state.isTorSheetPresented = false

        let isTorOn = state.torSheetState.isTorOn
        let isCustomServer = state.torSheetState.isCustomServer
        let accountUUID = state.selectedWalletAccount?.id

        if !isCustomServer {
            migrationManager.setNetworkPrivacyOptions(isTorOn)
            migrationManager.confirmProvisionalTorChoice(accountUUID, isTorOn)
        }

        return .send(.pushHydratedPathState(destinationPathState(destination)))
    }

    private func destinationPathState(_ destination: PendingTorDestination) -> Path.State {
        switch destination {
        case .reviewTransfer:
            return .reviewTransfer(MigrationReviewTransfer.State(mode: .immediate))
        case .transferPlan:
            // PHASE 4: the permission ask sits BETWEEN the Tor choice and the plan, exactly where
            // #1930 ran `nextPermissionStepResult()`. Either outcome continues — permission is a
            // nice-to-have, never a blocker: without it the flow still works entirely via the
            // app-open reconcile (matrix D2), the user just gets no reminders.
            return .notifications(MigrationNotifications.State(variant: .scheduled))
        }
    }

    /// Identity-custom = the sync endpoint the run pinned is not one of the shipped providers.
    private static func isIdentityCustom(_ snapshot: MigrationNetworkSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.syncProvider == nil
    }

    // MARK: - Post-confirm (#1930 :1689)

    private func transferPlanPostConfirmChain(
        variant: MigrationTransferPlan.State.Variant,
        schedule: MigrationSchedule?,
        state: inout State
    ) -> Effect<Action> {
        let accountUUID = state.selectedWalletAccount?.id
        switch variant {
        case .scheduled, .recreated:
            // PHASE 4 lands the notification arm exactly where #1930 ran
            // `migrationBGScheduler.scheduleFirstWindow()`. The BG half stays gone (D2): a window
            // can be ANNOUNCED ahead of time, never acted on in the background.
            return .run { [migrationManager] send in
                let scheduled = await scheduledState(accountUUID: accountUUID, schedule: schedule)
                await send(.pushHydratedPathState(.scheduled(scheduled)))
                await migrationManager.armNextWindowNotifications(accountUUID)
            }
        case .manual:
            // The manual-delivery run's FIRST transfer — same "sent" wording as every subsequent
            // manual-step confirm.
            state.path.append(.sending(MigrationSending.State(totalCount: 1, isManualStepLane: true)))
            return .run { [migrationManager] _ in
                await migrationManager.armNextWindowNotifications(accountUUID)
            }
        }
    }

    // MARK: - State hydration (#1930 :1777 / :2750 / :2837)

    private func scheduledState(accountUUID: AccountUUID?, schedule: MigrationSchedule?) async -> MigrationScheduled.State {
        let summary = await migrationManager.migrationSummary(accountUUID)
        let newScheduleAmount = schedule?.transfers.reduce(Zatoshi.zero) { $0 + $1.amount } ?? Zatoshi.zero
        return MigrationScheduled.State(
            // `summary.transferred` is only nil on the no-committed-schedule fallback — impossible
            // here, since this hydrates right after `recordCommittedSchedule` has run. `.zero` is
            // the correct additive identity regardless.
            totalAmount: (summary.transferred ?? Zatoshi.zero) + newScheduleAmount,
            sentCount: summary.transfersSent,
            totalCount: summary.transfersTotal,
            durationHours: summary.estimatedDurationHours ?? 0,
            dustAmount: summary.dust
        )
    }

    private func statusResumeState(accountUUID: AccountUUID?, isFlowRoot: Bool) async -> MigrationStatus.State {
        let rows = await migrationManager.migrationTransfers(accountUUID)
        let summary = await migrationManager.migrationSummary(accountUUID)
        let stalledRow = rows.first { $0.status == MigrationTransferRow.Status.overdue }
        var state = MigrationStatus.State(
            presentation: .resume,
            rows: IdentifiedArrayOf(uniqueElements: rows),
            totalDurationHours: summary.estimatedDurationHours,
            stalledNumber: (stalledRow?.index ?? 0) + 1,
            stalledHoursAgo: stalledRow?.hoursFromNow ?? 0,
            isFlowRoot: isFlowRoot
        )
        // Hydrated here rather than left to `onAppear`'s own `.statusLoaded`, so the footer does not
        // read "about 0 mins" for a frame at re-entry.
        state.syncPrivacyBufferMinutes = MigrationStatus.syncPrivacyBufferMinutes(
            from: sdkSynchronizer.migrationPrivacySyncBufferDuration()
        )
        state.isTorHoldActive = migrationManager.isMigrationTorHoldActive(accountUUID)
        return state
    }

    private func statusProgressState(accountUUID: AccountUUID?, isFlowRoot: Bool) async -> MigrationStatus.State {
        let rows = await migrationManager.migrationTransfers(accountUUID)
        let summary = await migrationManager.migrationSummary(accountUUID)
        var state = MigrationStatus.State(
            presentation: .progress,
            rows: IdentifiedArrayOf(uniqueElements: rows),
            totalDurationHours: summary.estimatedDurationHours,
            isFlowRoot: isFlowRoot
        )
        state.syncPrivacyBufferMinutes = MigrationStatus.syncPrivacyBufferMinutes(
            from: sdkSynchronizer.migrationPrivacySyncBufferDuration()
        )
        state.isTorHoldActive = migrationManager.isMigrationTorHoldActive(accountUUID)
        return state
    }

    // MARK: - Re-entry (#1930 :2636)

    /// Maps `migrationManager.reentryRoute()` onto the flow-root screen to append. `.entry` appends
    /// nothing — Entry is the coordinator's own root screen, already showing.
    ///
    /// PHASE 3: `.recovery` (Phase 5) and `.complete` (Phase 6) have no screen in this build. Both
    /// fall through to Entry rather than to a wrong screen: Entry re-derives from live state, so the
    /// worst case is the user sees the fork again, not a lie about their run.
    private func reentryPathState(accountUUID: AccountUUID?) async -> Path.State? {
        switch await migrationManager.reentryRoute() {
        case .statusResume:
            return .status(await statusResumeState(accountUUID: accountUUID, isFlowRoot: true))

        case .statusProgress:
            return .status(await statusProgressState(accountUUID: accountUUID, isFlowRoot: true))

        case .reviewManual(let step, let total):
            return .reviewTransfer(MigrationReviewTransfer.State(mode: .manualStep(number: step, total: total), isFlowRoot: true))

        case .recovery, .complete, .entry:
            return nil
        }
    }
}
