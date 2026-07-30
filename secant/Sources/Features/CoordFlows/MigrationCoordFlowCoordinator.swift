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

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

// MARK: - PHASE 7: the SDK's own Keystone firmware type

extension ZcashLightClientKit.KeystoneFirmwareVersion {
    /// The dotted `major.minor.build` rendering of the version the Keystone BATCH-signing response
    /// envelope reports, for the migration flow's firmware-gate copy.
    ///
    /// A SEPARATE type from the app's own `KeystoneFirmwareVersion`
    /// (`Features/SendConfirmation/KeystoneFirmwareVersion.swift`), sharing only its bare name —
    /// hence the module qualification here and at every reference below. The two differ in
    /// substance, not merely in module: this one carries the device's RAW triple (the SDK documents
    /// that display offsets are deliberately NOT applied to it), while the app type normalizes a
    /// PCZT stamp through `stampedMajorOffset`. Do not bridge them: the batch protocol has no
    /// PCZT-embedded stamp at all, and the two floors are checked against different sources by
    /// design.
    var versionString: String {
        "\(major).\(minor).\(build)"
    }
}

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

                // MARK: - Sheet presentation bindings

            case .binding(\.isTorSheetPresented):
                // `BindingReducer()` already wrote the flag; forward to the existing action for its
                // side effects (which are real — see its own case). Sending rather than duplicating
                // keeps ONE implementation for both the swipe-dismiss and the programmatic path.
                return .send(.torSheetPresentationChanged(state.isTorSheetPresented))

            case .binding(\.isKeystoneFirmwareGatePresented):
                return .send(.keystoneFirmwareGatePresentationChanged(state.isKeystoneFirmwareGatePresented))

            case .binding:
                return .none

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

            // The flow's terminal closes. `.scheduled(.delegate(.done))` is the commit's own exit —
            // it was MISSING (the screen emitted the delegate, nothing consumed it, so Done was a
            // dead button that stranded the user on the screen). #1930 groups these three; Phase 5
            // adds `.recovery(.delegate(.close))` to the same list.
            case .path(.element(id: _, action: .reviewTransfer(.delegate(.closed)))),
                 .path(.element(id: _, action: .scheduled(.delegate(.done)))):
                return .send(.flowFinished)

                // MARK: - PHASE 7: Keystone ceremony — the two entries (#1930 :685-1158)

            case .path(.element(id: _, action: .transferPlan(.delegate(.keystoneSignRequested(let batch))))):
                // The BATCH lane. `proposeKeystoneBatch` has already run, which means the engine has
                // CREATED AND PERSISTED THE WHOLE RUN — every abandon route below must cancel it.
                state.pendingKeystoneSigning = .planCommit
                state.pendingKeystoneSigningAccountUUID = state.selectedWalletAccount?.id
                state.keystoneBatchApplyInFlight = false
                beginKeystoneCeremony(batch: batch, state: &state)
                return .none

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.keystoneImmediateSignRequested(let unsigned, let redacted))))):
                // The SINGLE-PCZT lane — an ordinary, engine-external proposal. No run was created,
                // so its abandon routes deliberately skip the stray-run cancel.
                state.pendingKeystoneSigning = .immediateReview
                state.pendingKeystoneSigningAccountUUID = state.selectedWalletAccount?.id
                beginImmediateKeystoneCeremony(unsigned: unsigned, redacted: redacted, state: &state)
                return .none

            case .path(.element(id: _, action: .keystoneSign(.delegate(.getSignature)))):
                guard case let .keystoneSign(signState)? = state.path.last else { return .none }
                var scanState = Scan.State.initial
                if signState.redactedSinglePczt != nil {
                    // Single-PCZT ceremony — the PRODUCTION checker: the device echoes the full
                    // signed PCZT as a `zcash-pczt` UR, no batch decode session and no request-id
                    // correlation. Reset the shared BC-UR fountain decoder so a retry ceremony never
                    // inherits a previous session's accumulated frames (`SendConfirmation`
                    // precedent).
                    keystoneHandler.resetQRDecoder()
                    scanState.checkers = [.keystonePCZTScanChecker]
                } else {
                    // The batch scan session needs THIS ceremony's correlation token so
                    // `decodeKeystoneSignBatchPart` can reject a stale or unrelated response.
                    scanState.checkers = [.keystoneMigrationBatchScanChecker]
                    scanState.keystoneBatchRequestId = signState.requestId
                }
                scanState.instructions = String(localizable: .migrationKeystoneScanInstructions)
                scanState.forceLibraryToHide = true
                state.path.append(.scan(scanState))
                return .none

            case .path(.element(id: _, action: .keystoneSign(.delegate(.buildFailed)))):
                // `buildKeystoneSignBatchQRParts` threw — no QR was ever shown, so `.scan` was never
                // pushed either. Deferred for the same reason `.rejected` is: `.forEach` still needs
                // to deliver THIS action to the `keystoneSign` element after this case returns.
                return .send(.keystoneScanAbandoned)

            case .path(.element(id: _, action: .keystoneSign(.delegate(.rejected)))):
                // No-partial-storage invariant: nothing was stored — pop back to the signing source
                // with its state untouched. Deferred pop, same reason as `.buildFailed`.
                return .send(.keystoneSignRejected)

                // MARK: - PHASE 7: Keystone ceremony — the SINGLE-PCZT round-trip (immediate lane)

            case .path(.element(id: _, action: .scan(.foundPCZT(let signedPczt)))):
                // One-shot guard: a duplicate for an in-flight submit is DROPPED, never abandoned.
                guard !state.keystoneImmediateSubmitInFlight else { return .none }

                guard case .immediateReview? = state.pendingKeystoneSigning,
                      case let .keystoneSign(signState)? = state.path.dropLast().last,
                      let accountUUID = state.selectedWalletAccount?.id else {
                    return .send(.keystoneScanAbandoned)
                }

                // This lane's minimum-firmware gate is the PRODUCTION one: the stamp the device
                // writes into every signed PCZT's proprietary fields, checked against the
                // `SendConfirmation` floor. An UNSTAMPED PCZT is necessarily below minimum (the
                // stamp ships since firmware 2.4.6), never merely "unknown" — same reasoning as
                // `SendConfirmation`'s own gate. The batch envelope's version and its separate floor
                // never enter this lane.
                let detectedFirmware = signedPczt.keystoneFirmwareStamp().map(KeystoneFirmwareVersion.fromStamp)
                guard let detectedFirmware, detectedFirmware >= KeystoneFirmwareVersion.minimumSupported else {
                    state.detectedKeystoneFirmwareVersion = detectedFirmware?.versionString
                    state.keystoneFirmwareGateMinimumVersion = KeystoneFirmwareVersion.minimumSupported.versionString
                    state.isKeystoneFirmwareGatePresented = true
                    return .send(.keystoneScanAbandoned)
                }

                // The scanned payload IS the device-signed PCZT — hand it, with the retained
                // unredacted original still on the `keystoneSign` element beneath `scan`, to the
                // proofs+combine+submit step. Armed across the WHOLE leg.
                state.keystoneImmediateSubmitInFlight = true
                if let scanId = state.path.ids.last, case .scan(var scanState) = state.path[id: scanId] {
                    scanState.isKeystoneSigningInProgress = true
                    state.path[id: scanId] = .scan(scanState)
                }
                return submitImmediateKeystoneTransaction(
                    accountUUID: accountUUID,
                    unsignedPczt: signState.pczts.first?.pczt ?? Data(),
                    signedPczt: signedPczt
                )

            case .keystoneImmediateSubmitted(let txId):
                state.keystoneImmediateSubmitInFlight = false
                // The ceremony may have been torn down while this effect was in flight (a reject
                // after a swipe-back off `scan` mid-proving cleared `pendingKeystoneSigning` — the
                // tombstone). The scan/sign elements are gone and the pop below would delete
                // whatever screen the user backed onto. The broadcast DID land, so still surface the
                // success — but push it over the CURRENT top without popping anything.
                guard case .immediateReview? = state.pendingKeystoneSigning else {
                    state.path.append(.sending(MigrationSending.State(phase: .success, txId: txId, totalCount: 1)))
                    return .none
                }
                state.pendingKeystoneSigning = nil
                state.pendingKeystoneSigningAccountUUID = nil
                state.path.removeLast(state.path.last?.is(\.scan) == true ? 2 : 1)
                state.path.append(.sending(MigrationSending.State(phase: .success, txId: txId, totalCount: 1)))
                return .none

            case .keystoneImmediateSubmitFailed:
                state.keystoneImmediateSubmitInFlight = false
                // Same tombstone check as the success twin: the user already walked away from this
                // ceremony, so drop the late failure silently (it is logged at the throw site).
                guard case .immediateReview? = state.pendingKeystoneSigning else { return .none }
                state.pendingKeystoneSigning = nil
                state.pendingKeystoneSigningAccountUUID = nil
                state.path.removeLast(state.path.last?.is(\.scan) == true ? 2 : 1)
                if let reviewId = state.path.ids.last, case .reviewTransfer(var reviewState) = state.path.last {
                    reviewState.isConfirming = false
                    reviewState.isFailurePresented = true
                    reviewState.failureReason = MigrationReviewTransfer.State.FailureReason.commit
                    state.path[id: reviewId] = .reviewTransfer(reviewState)
                    return .none
                }
                state.path.append(.sending(MigrationSending.State(isFailurePresented: true, totalCount: 1)))
                return .none

                // MARK: - PHASE 7: Keystone ceremony — the BATCH round-trip (scheduled lane)

            case .path(.element(id: _, action: .scan(.cancelTapped))):
                // NOT in #1930 — its migration coordinator is the only coordflow that never handled
                // scan-Cancel, so the button was dead there (every sibling coordinator pops:
                // `SignWithKeystone`, `Send`, `SwapAndPay`, `AddKeystoneHWWallet`, `ScanCoordFlow`).
                //
                // Cancel backs out of the CAMERA, not the ceremony: pop only `scan`, landing back on
                // `keystoneSign` with its own Reject / Get Signature intact. Nothing was stored and
                // nothing is in flight (a completed decode has already left this screen), so there is
                // no state to unwind — and abandoning here instead would cancel the engine run over
                // what is really a "wrong QR / let me try again" tap.
                _ = state.path.popLast()
                return .none

            case .path(.element(id: _, action: .scan(.keystoneBatchDecodeFailed))):
                // `decodeKeystoneSignBatchPart` threw on a frame — a stale, mismatched or corrupt
                // response, including the SDK's own request-id-mismatch throw at completion. `.scan`
                // is still the top element here, so this reuses the abandon's pop-2 semantics.
                return .send(.keystoneScanAbandoned)

            case .path(.element(id: _, action: .scan(.foundKeystoneBatchSignatures(let data, let firmwareVersion)))):
                // One-shot guard — see `keystoneBatchApplyInFlight`'s doc. A duplicate for an
                // already in-flight ceremony is DROPPED, never routed through the abandon: nothing
                // went wrong, the first delivery is simply still being applied.
                guard !state.keystoneBatchApplyInFlight else { return .none }

                guard let context = state.pendingKeystoneSigning,
                      case let .keystoneSign(signState)? = state.path.dropLast().last,
                      let accountUUID = state.selectedWalletAccount?.id else {
                    return .send(.keystoneScanAbandoned)
                }

                // The batch lane's gate reads the decode envelope's OWN reported version (there is
                // no PCZT-embedded stamp in this protocol). Below the floor, or no version reported
                // at all, presents the gate sheet and abandons.
                //
                // The gate runs on ROUND 0 ONLY (Android parity): the same physical device signs
                // every round, and gating a later round would make the user scan through every
                // remaining round only to be blocked at the very end. A `nil` rounds state
                // (defensive) gates like round 0.
                let isFirstKeystoneRound = (state.keystoneBatchRounds?.roundIndex ?? 0) == 0
                guard !isFirstKeystoneRound
                    || (firmwareVersion.map { $0 >= MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware } ?? false) else {
                    state.detectedKeystoneFirmwareVersion = firmwareVersion?.versionString
                    state.keystoneFirmwareGateMinimumVersion = MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware.versionString
                    state.isKeystoneFirmwareGatePresented = true
                    return .send(.keystoneScanAbandoned)
                }

                // `applyKeystoneBatchSignatures` does the positional pairing itself, and it is
                // `async throws` — hand off to a `.run` rather than continuing inline. Nothing here
                // touches `state.path`, so it is still exactly `[..., keystoneSign, scan]` when
                // `.keystoneBatchSignaturesApplied` is handled below.
                let unsignedPczts = signState.pczts
                state.keystoneBatchApplyInFlight = true
                if let scanId = state.path.ids.last, case .scan(var scanState) = state.path[id: scanId] {
                    scanState.isKeystoneSigningInProgress = true
                    state.path[id: scanId] = .scan(scanState)
                }
                return .run { [sdkSynchronizer, unsignedPczts, data] send in
                    do {
                        let signed = try await sdkSynchronizer.applyKeystoneBatchSignatures(unsignedPczts, data)
                        await send(
                            .keystoneBatchSignaturesApplied(
                                context: context,
                                accountUUID: accountUUID,
                                unsignedPczts: unsignedPczts,
                                signed: signed
                            )
                        )
                    } catch {
                        // Log before abandoning: a silently-discarded apply failure is exactly what
                        // made #1930's original QA scan loop undiagnosable.
                        LoggerProxy.error("[MOB-1466] Keystone batch signature apply failed: \(error)")
                        await send(.keystoneScanAbandoned)
                    }
                }

            case .keystoneBatchSignaturesApplied(let context, let accountUUID, let unsignedPczts, let signed):
                // The apply landed — clear the one-shot guard. `Scan`'s own intake gate flipped
                // synchronously when THIS action was forwarded to the `scan` element, so no NEW
                // camera frame can start a fresh decode past this point.
                state.keystoneBatchApplyInFlight = false

                // Retained defensively: the live immediate lane rides the single-PCZT round-trip and
                // never arms a batch scan session, so a batch completion cannot carry this context
                // in practice.
                if case .immediateReview = context {
                    return submitImmediateKeystoneTransaction(
                        accountUUID: accountUUID,
                        unsignedPczt: unsignedPczts.first?.pczt ?? Data(),
                        signedPczt: signed.first?.pczt ?? Data()
                    )
                }

                // Tombstone: a reject/abandon can land while THIS apply effect is still in flight.
                // The ceremony is over — a late completion must store NOTHING. Without this guard
                // the nil rounds state below would masquerade as a single-round ceremony and store
                // THIS ROUND'S SLICE as if it were the whole batch: a partial store, the exact
                // invariant rounds exist to prevent. Dropping is safe — the engine still holds the
                // run's transactions awaiting signatures and re-serves them on the next entry.
                guard state.pendingKeystoneSigning != nil else { return .none }

                // Accumulate this round and, if rounds remain, arm the next one instead of storing:
                // the stores run exactly once, over the FULL accumulated batch, after the last round
                // (Android parity). The pop-2 + push keeps the path shape `[..., source,
                // keystoneSign]` constant however many rounds a large migration needs, and the fresh
                // `MigrationKeystoneSign.State` gives the next round its own request id.
                let fullSigned: [MigrationSignedTransferPczt]
                let preparationCount: Int
                if var rounds = state.keystoneBatchRounds {
                    rounds.accumulatedSigned.append(contentsOf: signed)
                    let totalRounds = KeystoneBatchChunking.totalRounds(itemCount: rounds.allPczts.count)
                    let nextRoundIndex = rounds.roundIndex + 1
                    if nextRoundIndex < totalRounds {
                        rounds.roundIndex = nextRoundIndex
                        state.keystoneBatchRounds = rounds
                        let slice = KeystoneBatchChunking.roundSlice(roundIndex: nextRoundIndex, itemCount: rounds.allPczts.count)
                        state.path.removeLast(state.path.last?.is(\.scan) == true ? 2 : 1)
                        state.path.append(
                            .keystoneSign(
                                MigrationKeystoneSign.State(
                                    pczts: Array(rounds.allPczts[slice]),
                                    roundIndex: nextRoundIndex,
                                    totalRounds: totalRounds
                                )
                            )
                        )
                        return .none
                    }
                    preparationCount = rounds.preparationCount
                    state.keystoneBatchRounds = nil
                    fullSigned = rounds.accumulatedSigned
                } else {
                    // Defensive: treat `signed` as the whole batch with no preparations. Every batch
                    // ceremony sets the rounds state, so this is unreachable in practice.
                    preparationCount = 0
                    fullSigned = signed
                }

                // The schedule that was just signed lives on the `.transferPlan` element still
                // beneath `keystoneSign` + `scan` — read it now, before the resume pops past it.
                let schedule = pendingKeystoneSchedule(context: context, depthBelowTop: 2, state: state)
                let split = MigrationCoordFlow.splitKeystoneBatch(fullSigned, preparationCount: preparationCount)

                return storeKeystoneSignedBatch(
                    context: context,
                    accountUUID: accountUUID,
                    schedule: schedule,
                    prepEntries: split.prepEntries,
                    scheduleEntries: split.scheduleEntries
                )

            case .keystoneSigningSubmitted(let context, let pendingScheduleStore):
                return resumeAfterKeystoneSigning(
                    context: context,
                    pendingScheduleStore: pendingScheduleStore,
                    state: &state
                )

                // MARK: - PHASE 7: Keystone ceremony — the two terminal exits

            case .keystoneSignRejected:
                state.pendingKeystoneSigning = nil
                state.pendingKeystoneSigningAccountUUID = nil
                // A reject can land while a post-scan leg is still in flight (the user swipe-backs
                // off `scan` mid-proving and taps Reject — the coordinator-level effects survive the
                // pop). Clear BOTH in-flight guards so the next ceremony starts clean; clearing
                // `pendingKeystoneSigning` above doubles as the tombstone those late completions
                // check. A reject mid-sequence discards the whole capped ceremony, accumulated
                // rounds included (no-partial-storage: nothing was stored).
                state.keystoneBatchApplyInFlight = false
                state.keystoneImmediateSubmitInFlight = false
                state.keystoneBatchRounds = nil
                _ = state.path.popLast()
                return .none

            case .keystoneScanAbandoned:
                // Read BEFORE clearing. A live `pendingKeystoneSigning` on the BATCH lane means a
                // PCZT batch was already proposed for this ceremony — and `proposeNoteSplitPCZTs`
                // CREATED AND PERSISTED THE WHOLE RUN at that moment. The engine always resumes a
                // stored non-terminal run on the next attempt, ignoring any newer preview, so
                // abandoning without cancelling would strand it: a later re-entry would silently
                // resume signing these same, by-then-stale PCZTs.
                //
                // The immediate lane is exempt — its `createPCZTFromProposal` is engine-external and
                // created no run to cancel.
                state.keystoneBatchApplyInFlight = false
                state.keystoneImmediateSubmitInFlight = false
                state.keystoneBatchRounds = nil
                let pendingContext = state.pendingKeystoneSigning
                state.pendingKeystoneSigning = nil
                state.pendingKeystoneSigningAccountUUID = nil
                // The real round-trip's failure guards run with `.scan` on top (pop 2); a build
                // failure or a store failure never pushed `.scan` at all (pop 1).
                state.path.removeLast(state.path.last?.is(\.scan) == true ? 2 : 1)

                guard case .planCommit? = pendingContext, let accountUUID = state.selectedWalletAccount?.id else {
                    return .none
                }
                return .run { [sdkSynchronizer, accountUUID] _ in
                    // Fire-and-forget: a failure here just leaves the stray run for the next attempt
                    // to encounter (and cancel) itself.
                    _ = try? await sdkSynchronizer.restartCurrentMigrationStep(accountUUID)
                }

            case .keystoneFirmwareGatePresentationChanged(let isPresented):
                state.isKeystoneFirmwareGatePresented = isPresented
                if !isPresented {
                    state.detectedKeystoneFirmwareVersion = nil
                    state.keystoneFirmwareGateMinimumVersion = nil
                }
                return .none

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

    // MARK: - PHASE 7: Keystone ceremony (#1930 :2024-2542)

    /// Keystone "cypherpunk" firmware floor for migration BATCH signing: 3.0.2 is the first firmware
    /// that supports this protocol at all — older firmware either cannot sign the batch correctly or
    /// will not report a version in the response envelope, which is why the gate treats "no version
    /// reported" the same as "below floor". Checked directly against
    /// `KeystoneBatchDecodeResult.firmwareVersion`; there is no PCZT-embedded stamp to fall back on
    /// in this protocol.
    ///
    /// Deliberately distinct from — and unrelated to — the single-transaction flow's own floor,
    /// `KeystoneFirmwareVersion.minimumSupported` (`Features/SendConfirmation/`), which reads its
    /// version from a stamp embedded in the signed PCZT bytes. The two `KeystoneFirmwareVersion`
    /// types share a bare name, so every reference to the SDK's is module-qualified.
    static let keystoneMigrationBatchMinimumFirmware = ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 0, build: 2)

    /// Splits an applied batch into its preparation entries and the schedule's own transfers.
    ///
    /// Positional, by `preparationCount`: `proposeKeystoneBatch` built the unsigned array as
    /// preparations-then-transfers, and `applyKeystoneBatchSignatures` echoes ids back positionally,
    /// so the same boundary holds on the signed side. ONLY the schedule half is safe to hand to
    /// `storeSignedMigrationTransactions`, and only the preparation half to `storeSignedNoteSplits`
    /// — each store looks its transactions up by the engine id they already carry.
    ///
    /// Defensive: a `preparationCount` beyond the array (which would mean the SDK broke the
    /// positional contract) clamps rather than trapping.
    static func splitKeystoneBatch(
        _ signed: [MigrationSignedTransferPczt],
        preparationCount: Int
    ) -> (prepEntries: [MigrationSignedTransferPczt], scheduleEntries: [MigrationSignedTransferPczt]) {
        let boundary = min(max(preparationCount, 0), signed.count)
        return (Array(signed[..<boundary]), Array(signed[boundary...]))
    }

    /// Starts the BATCH signing ceremony, capped at `KeystoneBatchChunking.maxItemsPerRound` PCZTs
    /// per animated-QR round trip — the device-safety cap (Android observed a real Keystone OOM on
    /// an oversized batch).
    ///
    /// A batch within the cap is ONE animated QR session over every PCZT. A larger batch signs
    /// across several rounds, each a full self-contained ceremony over its `roundSlice` with a fresh
    /// request id; the applied signatures accumulate in `state.keystoneBatchRounds` and nothing
    /// stores until the last round lands. Within a round, `buildKeystoneSignBatchQRParts` is a
    /// fountain encoder and the SDK decides the frame count.
    private func beginKeystoneCeremony(batch: MigrationKeystoneBatch, state: inout State) {
        let totalRounds = KeystoneBatchChunking.totalRounds(itemCount: batch.pczts.count)
        state.keystoneBatchRounds = KeystoneBatchRounds(
            allPczts: batch.pczts,
            preparationCount: batch.preparationCount
        )
        let slice = KeystoneBatchChunking.roundSlice(roundIndex: 0, itemCount: batch.pczts.count)
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: Array(batch.pczts[slice]),
                    roundIndex: 0,
                    totalRounds: totalRounds
                )
            )
        )
    }

    /// Starts the IMMEDIATE lane's SINGLE-PCZT ceremony — the PRODUCTION `SignWithKeystone`
    /// pipeline: the sign screen computes `urEncoderForPCZT` live over `redacted`, `.getSignature`
    /// pushes a scan session with the production checker, the device echoes the FULL signed PCZT,
    /// and the post-scan step is the proofs+combine `submitImmediateKeystoneTransaction`.
    ///
    /// NEVER the batch bridge. Android draws the same lane boundary (its immediate Keystone lane is
    /// the ordinary single-PCZT pipeline; the batch bridge is scheduled-mode machinery on both
    /// platforms). `pczts` carries the UNREDACTED original under an inert state-side id — the
    /// post-scan submit reads it positionally, and it never reaches the SDK.
    private func beginImmediateKeystoneCeremony(unsigned: Data, redacted: Data, state: inout State) {
        state.keystoneImmediateSubmitInFlight = false
        // The single-PCZT ceremony never chunks — a leftover rounds state from an earlier batch
        // ceremony must not leak into this one (defensive; every ceremony-ending route clears it).
        state.keystoneBatchRounds = nil
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: unsigned)],
                    redactedSinglePczt: redacted
                )
            )
        )
    }

    /// The store sequence for a signed Keystone batch.
    ///
    /// **No preparations:** stores the schedule immediately. Success bookkeeping fires ONLY when the
    /// store actually succeeds — on failure this abandons instead (the honest-failure surface),
    /// rather than landing on the terminal "Migration Scheduled" screen with nothing stored.
    ///
    /// **Preparations present:** stores ONLY the preps now, abandons on their failure (nothing
    /// stored, so nothing to resume), and DEFERS the schedule store into `pendingScheduleStore`.
    ///
    /// The deferral is load-bearing, and the reason is an engine phase-machine trace: a preparation's
    /// own broadcast-success record UNCONDITIONALLY overwrites the run's phase to
    /// `WaitingDenomConfirmations`. A schedule store performed BEFORE that broadcast (which sets
    /// `BroadcastScheduled`) gets silently clobbered the instant the broadcast lands, and the run
    /// then never advances again once the prep mines. Storing right AFTER a successful prep
    /// broadcast is the earliest point provably safe: mining cannot occur in the synchronous window
    /// between "broadcast accepted" and "schedule stored".
    ///
    /// Note the ordering's ORIGINAL premise no longer holds — "the prep store creates the run, so it
    /// must precede the schedule's store" was true of an earlier engine. The run is now created at
    /// PCZT-build time (`proposeNoteSplitPCZTs`), and the two stores are order-independent
    /// per-transaction signature applications over that one run. What still motivates the ordering is
    /// the phase-machine trace above.
    private func storeKeystoneSignedBatch(
        context: KeystoneSigningContext,
        accountUUID: AccountUUID,
        schedule: MigrationSchedule?,
        prepEntries: [MigrationSignedTransferPczt],
        scheduleEntries: [MigrationSignedTransferPczt]
    ) -> Effect<Action> {
        .run { [sdkSynchronizer, migrationManager, context, accountUUID, schedule, prepEntries, scheduleEntries] send in
            guard !prepEntries.isEmpty else {
                do {
                    try await sdkSynchronizer.storeSignedMigrationTransactions(accountUUID, scheduleEntries)
                } catch {
                    LoggerProxy.error("[MOB-1466] Keystone schedule store failed: \(error)")
                    await send(.keystoneScanAbandoned)
                    return
                }
                if let schedule {
                    await migrationManager.recordCommittedSchedule(accountUUID, schedule)
                }
                await migrationManager.reconcile()
                await send(.keystoneSigningSubmitted(context: context, pendingScheduleStore: nil))
                return
            }
            do {
                try await sdkSynchronizer.storeSignedNoteSplits(accountUUID, prepEntries)
            } catch {
                LoggerProxy.error("[MOB-1466] Keystone note-split store failed: \(error)")
                await send(.keystoneScanAbandoned)
                return
            }
            let pendingScheduleStore = PendingScheduleStore(
                accountUUID: accountUUID,
                scheduleEntries: scheduleEntries,
                schedule: schedule
            )
            await send(.keystoneSigningSubmitted(context: context, pendingScheduleStore: pendingScheduleStore))
        }
    }

    /// The immediate lane's post-signing step. An `ImmediateMigrationProposal` is engine-external:
    /// there is no `MigrationSchedule` to store and no engine run this ceremony created. The signed
    /// PCZT is proved and broadcast RIGHT HERE — unlike the software lane, a Keystone-signed PCZT
    /// can only be finalized once, immediately after the signature comes back; there is no
    /// engine-held "signed and stored, broadcast whenever" indirection for a proposal the engine
    /// never held.
    ///
    /// On failure, `.keystoneImmediateSubmitFailed` pops like an abandon but arms the Review
    /// element's commit-failure sheet, so Retry re-runs the whole ceremony from a fresh
    /// PCZT + redact. A "retry just the broadcast" lane would need to persist the already-signed
    /// PCZT bytes across the retry — infrastructure this ceremony does not have for a proposal the
    /// engine never stored.
    private func submitImmediateKeystoneTransaction(
        accountUUID: AccountUUID,
        unsignedPczt: Data,
        signedPczt: Data
    ) -> Effect<Action> {
        .run { [sdkSynchronizer, accountUUID, unsignedPczt, signedPczt] send in
            do {
                let txId = try await MigrationCommitPipeline.commitImmediateKeystone(
                    unsignedPczt: unsignedPczt,
                    signedPczt: signedPczt,
                    accountUUID: accountUUID,
                    sdkSynchronizer: sdkSynchronizer
                )
                await send(.keystoneImmediateSubmitted(txId: txId))
            } catch {
                LoggerProxy.error("[MOB-1466] immediate Keystone post-signing submit failed (proofs/combine/broadcast): \(error)")
                await send(.keystoneImmediateSubmitFailed)
            }
        }
    }

    /// Locates the `MigrationSchedule` that was signed for `context`, read off the `.transferPlan`
    /// element still beneath `keystoneSign` + `scan` at the point the signed PCZTs are about to be
    /// stored. `depthBelowTop` is how many elements sit above it (2 for the real scan round-trip).
    /// `nil` when that element carries no schedule of its own — the caller then skips
    /// `recordCommittedSchedule` rather than persisting nothing.
    private func pendingKeystoneSchedule(
        context: KeystoneSigningContext,
        depthBelowTop: Int,
        state: State
    ) -> MigrationSchedule? {
        switch context {
        case .planCommit:
            guard case let .transferPlan(planState)? = state.path.dropLast(depthBelowTop).last else { return nil }
            return planState.schedule

        case .immediateReview:
            // Unreachable in practice — the call site intercepts `.immediateReview` before ever
            // reaching this function. `MigrationReviewTransfer.State` carries no engine schedule at
            // all; the immediate lane's proposal is engine-external.
            return nil
        }
    }

    /// Pops back to the signing-source element and resumes whichever chain `context` represents.
    ///
    /// The real QR round-trip pushes `scan` on top of `keystoneSign` — 2 elements to unwind. Rather
    /// than trust the caller, this reads the actual top of the path: `.scan` on top pops 2, anything
    /// else pops 1 (a build failure never pushed `scan`).
    private func resumeAfterKeystoneSigning(
        context: KeystoneSigningContext,
        pendingScheduleStore: PendingScheduleStore?,
        state: inout State
    ) -> Effect<Action> {
        state.pendingKeystoneSigning = nil
        state.pendingKeystoneSigningAccountUUID = nil
        // Belt — the last round's store handoff already cleared the rounds state.
        state.keystoneBatchRounds = nil
        state.path.removeLast(state.path.last?.is(\.scan) == true ? 2 : 1)

        state.pendingKeystoneScheduleStore = pendingScheduleStore

        return resumeCommittedMigrationChain(context: context, state: &state)
    }

    /// The shared post-commit resume: a `planCommit` ceremony reaches the IDENTICAL post-commit
    /// routing the software path's `.confirmed` row would.
    private func resumeCommittedMigrationChain(
        context: KeystoneSigningContext,
        state: inout State
    ) -> Effect<Action> {
        switch context {
        case .planCommit:
            guard case let .transferPlan(planState) = state.path.last else { return .none }
            return transferPlanPostConfirmChain(variant: planState.variant, schedule: planState.schedule, state: &state)

        case .immediateReview:
            // Unreachable: `submitImmediateKeystoneTransaction` intercepts `.immediateReview` at the
            // scan round-trip, before `resumeAfterKeystoneSigning` can be reached. Kept for the
            // switch's exhaustiveness — if it ever DID run it would incorrectly push a second
            // broadcast attempt for a transaction that already submitted.
            state.path.append(.sending(MigrationSending.State(totalCount: 1)))
            return .none
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
            durationHours: summary.estimatedDurationHours ?? 0
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
