//
//  MigrationSendingStore.swift
//  zodl
//
//  "Sending" / "Sent" screen (MOB-1463, Figma S8 · sending 2618:6858 / sent 2618:6895). Shown while
//  a migration transfer broadcasts — for immediate/manual/plan-first sends, the dust lane, or the
//  S10 "Send now" lane — then flips to a success state once that one transfer has been executed.
//  `onAppear` runs `executeNextPendingMigrationTransfer`, recording a broadcast and scheduling the
//  next background window on success; a failure/`nil` result presents the failure sheet, and
//  `retryTapped` re-runs the same step (MOB-1466).
//
//  MOB-1496 (W5, ZIP-0318 MUST): a background session — and this screen's own executor — may
//  broadcast at most ONE overdue transfer. `totalCount`/`sentCount` remain (the "Send now" push site
//  still configures `totalCount` off the overdue row count, informational only now), but
//  `.transferResult`'s success handler no longer loops back into `executeNextTransfer` — a single
//  success always finishes the screen. Remaining overdue transfers stay scheduled; the next
//  background window (armed by `scheduleNextWindow()` below, per-account fanned-out — MOB-1496 W5
//  §2) picks them up, or the user taps "Send now" again (a separate, explicit decision each time —
//  the CTA is deliberately never disabled after a send). The `closeTapped` / `viewTransactionTapped`
//  delegates are consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  This same screen was reused for the "Migrate anyway" dust lane (MOB-1487) via a dedicated
//  `isDustLane` execution branch (a USK composite, `migrateMigrationDust`, that re-proposed a
//  residual-inclusive schedule from scratch). MOB-1496 (W-B): retired — "Migrate anyway" now rides
//  the SAME immediate (`immediateProposal`)/Keystone-ceremony lanes as the entry-screen migration;
//  the coordinator resolves the proposal (or a propose/unlock failure) BEFORE ever pushing this
//  screen, so there is no dust-specific branch left here at all. `isDustLane` never drove any
//  on-screen copy (MOB-1494 round 4 already unified every lane's wording), so nothing user-visible
//  changes.
//
//  R8-T6 (V8 fix — silence-window wait): `entersViaSendNow` marks the OTHER lane this screen
//  serves — the Status screen's "Send now" CTA (MigrationCoordFlowCoordinator's `.status
//  (.delegate(.sendNow))` push site). That lane no longer stops sync and broadcasts immediately:
//  `onAppear` stops sync FIRST, then reads the app-side `sendGate()` privacy gate — `.allowed`
//  broadcasts exactly like every other lane, but `.waitUntil`/`.syncRequired` enters a WAITING
//  phase (countdown to the gate's clear date, `@Dependency(\.continuousClock)`-driven) instead of
//  broadcasting into a gate that's still closed. Cancel during WAITING nudges Root's gate feed to
//  resume sync and closes without sending anything. The immediate/manual/plan-first/Keystone lanes
//  are UNCHANGED — they never consulted `sendGate()` and still don't (`entersViaSendNow` defaults
//  `false`, so `onAppear` takes the same immediate stop+broadcast path as before for them).
//
//  MOB-1497 (T8, Q3'26 canvas, Figma 3491:11750 vs 3485:6211): `isManualStepLane` marks the
//  manual-delivery per-transfer lane — TransferPlan's `.manual` variant sending its first transfer
//  right after confirm, and each later `MigrationReviewTransfer.State.Mode.manualStep` confirm
//  sending one of the remaining transfers (both threaded by `MigrationCoordFlowCoordinator`, which
//  is the only place that can tell the two `MigrationReviewTransfer` modes apart, since both
//  delegate the same `.confirmed` action). Unlike `entersViaSendNow`, this flag drives no execution
//  difference at all — `onAppear` runs the identical scheduled-transfer executor either way — it
//  only selects the success phase's subtitle (`State.sentSubtitle`): the manual lane reads "...sent
//  to Ironwood.", every other lane (immediate full sweep, "Migrate anyway", and the Status screen's
//  "Send now" resume of an already-scheduled transfer) keeps "...migrated to Ironwood." — all of
//  those still read as part of one larger migration run.
//
//  MOB-1513 (Lane A2 — send-max immediate migration): `immediateProposal`, threaded by the
//  coordinator's `.reviewTransfer(.delegate(.confirmed))` handler for a SOFTWARE immediate-mode
//  confirm (Keystone's immediate lane never reaches this screen mid-broadcast — its actual submit
//  already happened in the coordinator's post-signing step by the time `MigrationSending` is pushed;
//  see `MigrationCoordFlowCoordinator.submitImmediateKeystoneTransaction`), marks the ONLY lane where
//  `onAppear`'s broadcast genuinely completes the whole migration plan in one shot — every other
//  lane's single successful broadcast finishes THIS SCREEN (MOB-1496 W5 above) but the overall
//  migration run may still have more scheduled transfers left; the immediate lane has none by
//  construction (a send-max proposal is exactly one transaction). `executeNextTransfer` derives the
//  account's USK (same hoisted-above-the-broadcast treatment the dust lane's own derivation gets —
//  R9-T4 finding 5) and calls `MigrationCommitPipeline.commitImmediateSoftware`
//  (`createAndSubmitProposedTransactions`, already transaction-guarded in `SDKSynchronizerLive`)
//  instead of `executeNextPendingMigrationTransfer` — the immediate proposal is engine-external, so
//  there is nothing stored in the engine for that call to serve. This deliberately does NOT ride the
//  engine transfers' `MigrationBroadcaster` Tor-first multi-endpoint routing
//  (`executeNextPendingMigrationTransfer`'s own delivery mechanism) — the immediate sweep rides the
//  standard ordinary-send submission path by design (the Tor consent sheet upstream, at Entry/How
//  This Works, still gates the flow before this screen is ever reached, so the user's Tor choice is
//  respected identically either way; only the BROADCAST plumbing underneath differs). Success is
//  still keyed to the actual submit outcome exactly like every other lane, never to `migrationMode`.
//

import Foundation//
//  PHASE 2 SCOPE (docs/slipstream/migration/REBUILD_PLAN.md): copied from #1930 and pruned to the
//  IMMEDIATE (manual) lane only — the one Phase 2 ships. Removed, each marked inline where it stood:
//  the engine/scheduled broadcast branch, the send-now gate-check + `.waiting` silence window, the
//  R14-R17 broadcast-failure routing, the Tor off-warning alert, and the BG scheduler (dead by D2).
//  Phase 3 restores them from #1930 together with Root's sync-gate machinery they depend on.
//  Everything retained is verbatim.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationSending {
    @ObservableState
    struct State: Equatable {
        enum Phase: Equatable {
            case sending
            case success
        }

        var phase = Phase.sending
        /// Failure sheet presented over the sending phase.
        var isFailurePresented = false
        /// The most recently broadcast transfer's tx id (wires up View Transaction).
        var txId = ""
        /// MOB-1496 (W5, ZIP-0318): informational only — `onAppear` always executes AT MOST ONE
        /// transfer regardless of this value (the "send now" push site still configures it off the
        /// overdue row count, but `.transferResult`'s success handler no longer loops against it).
        /// Coordinator-configured.
        var totalCount = 1
        /// 0 before a send, 1 after — this screen never executes more than one transfer (MOB-1496 W5).
        var sentCount = 0
        /// MOB-1497 (T8, Q3'26 canvas): the manual-delivery per-transfer lane — see this file's
        /// header doc. Coordinator-configured; defaults to false so every other lane keeps today's
        /// "migrated" success wording (`sentSubtitle` below).
        var isManualStepLane = false
        /// MOB-1513: the immediate lane's send-max proposal — see this file's header doc. Non-`nil`
        /// for a SOFTWARE immediate-mode confirm OR software "Migrate anyway" (MOB-1496 W-B); `nil`
        /// for every other lane (scheduled/manual/Keystone), which keeps today's
        /// `executeNextPendingMigrationTransfer` behavior unchanged.
        var immediateProposal: ImmediateMigrationProposal?
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        /// MOB-1497 (T8): the success phase's subtitle localization — `isManualStepLane` reads
        /// "...sent to Ironwood.", every other lane keeps "...migrated to Ironwood." See
        /// `isManualStepLane`'s doc for which lanes land in each bucket.
        var sentSubtitle: String {
            isManualStepLane
                ? String(localizable: .migrationSendingSentSubtitleTransfer)
                : String(localizable: .migrationSendingSentSubtitleMigrated)
        }

        init(
            phase: Phase = .sending,
            isFailurePresented: Bool = false,
            txId: String = "",
            totalCount: Int = 1,
            sentCount: Int = 0,
            isManualStepLane: Bool = false,
            immediateProposal: ImmediateMigrationProposal? = nil
        ) {
            self.phase = phase
            self.isFailurePresented = isFailurePresented
            self.txId = txId
            self.totalCount = totalCount
            self.sentCount = sentCount
            self.isManualStepLane = isManualStepLane
            self.immediateProposal = immediateProposal
        }
    }

    enum Action: BindableAction, Equatable {
        /// The screen's one transfer has been successfully broadcast (MOB-1496 W5: never more than
        /// one, regardless of `totalCount`).
        case allTransfersSent
        case binding(BindingAction<State>)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        case closeTapped
        case delegate(Delegate)
        case onAppear
        /// Failure sheet: dismiss, then re-run the failed step.
        case retryTapped
        /// `executeNextPendingMigrationTransfer` result for the current step; `nil` on a stub/no-op.
        case transferResult(MigrationTransferResult?)
        case viewTransactionTapped

        enum Delegate: Equatable {
            case closed
            case viewTransaction
        }
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .allTransfersSent:
                state.phase = .success
                return .none

            case .binding:
                return .none

            case .cancelTapped:
                state.isFailurePresented = false
                return .none

            case .closeTapped:
                return .send(.delegate(.closed))

            case .delegate:
                return .none

            case .onAppear:
                // MOB-1496 (W-B): a screen pushed ALREADY showing a failure (the "Migrate anyway"
                // propose/unlock-failure fallback — see `MigrationCoordFlowCoordinator`'s
                // `.complete(.delegate(.migrateAnyway))` handler) has nothing to execute — the
                // failure already happened before this screen ever appeared; an explicit Retry is
                // the only way out. Every production push in every other lane defaults
                // `isFailurePresented` to `false`, so this is a no-op for them.
                guard !state.isFailurePresented else { return .none }
                // MOB-1513 (R10): a screen pushed ALREADY in `.success` (the Keystone immediate lane —
                // its broadcast happens in the coordinator BEFORE this screen is pushed) has nothing to
                // execute either — re-running the executor here hit the engine's "nothing pending" path
                // and popped the failure sheet over the success screen (the QA-reported bogus error).
                if case .success = state.phase { return .none }
                return executeNextTransfer(account: state.selectedWalletAccount, immediateProposal: state.immediateProposal)

            case .retryTapped:
                state.isFailurePresented = false
                return executeNextTransfer(account: state.selectedWalletAccount, immediateProposal: state.immediateProposal)

            case .transferResult(let result):
                switch result {
                case .success(let txId):
                    state.txId = txId
                    state.sentCount += 1

                    // MOB-1496 (W5, ZIP-0318 MUST): a single successful broadcast always finishes
                    // this screen — never chain into another `executeNextTransfer` call, regardless
                    // of `totalCount` (the "send now" push site's overdue-row count is informational
                    // only now). Remaining overdue transfers stay scheduled; the next background
                    // window (armed by `scheduleNextWindow()` below) or a separate, explicit "Send
                    // now" tap picks them up.
                    //
                    // PHASE 2: #1930 additionally ran `recordTransferBroadcast` (the app-side sent
                    // record the SDK no longer retains), `migrationBGScheduler.scheduleNextWindow()`
                    // and `reconcile()` here. The first and third are the SCHEDULED lane's
                    // persistence/refresh and land with Phase 3; the BG scheduler is dead by D2. The
                    // immediate lane records itself through `recordImmediateMigration` inside
                    // `MigrationCommitPipeline.commitImmediateSoftware`, so nothing is lost here.
                    return .send(.allTransfersSent)

                case .networkError, .invalidNote, .expired, nil:
                    state.isFailurePresented = true
                    return .none
                }

            case .viewTransactionTapped:
                return .send(.delegate(.viewTransaction))
            }
        }
    }

    /// This is `MigrationCommitPipeline.commitImmediateSoftware`'s ONLY foreground executor with
    /// failure UX (R7-T3 §6 disposition): the immediate lane and the scheduled lane share this SAME
    /// broadcast `do`/`catch` below, so the classify-then-route wiring covers both without any
    /// separate treatment. `ZcashError.migrationRecordFailedAfterBroadcast` means the broadcast DID
    /// land and only recording failed (the engine self-heals later) — routed to a success-like
    /// result so the UX doesn't offer a needless retry or imply failure for something that worked;
    /// `txId` is a placeholder (the error carries no payload to recover the real one from). Untouched
    /// by R7-T3's classification (MOB-1497): a landed broadcast is never a failure to route.
    ///
    /// R9-T4 (MOB-1497 review remediation, finding 5): the immediate lane's USK derivation is
    /// hoisted ABOVE the broadcast `do`/`catch` below, in its own `do`/`catch` — see the hoist's
    /// inline comment for the full rationale. A derivation failure sends the SAME
    /// `.transferResult(nil)` the broadcast `do`/`catch`'s generic catch sends for an unrouted
    /// failure, but WITHOUT ever calling `routeBroadcastFailure` or `refreshMigrationSyncGate`: no
    /// broadcast was attempted, so neither applies.
    ///
    /// R7-T3 (MOB-1497): every failure path below — the transport-outcome switch's failure branch AND
    /// the generic catch — classifies+routes (R9-T2: via `migrationManager.routeBroadcastFailure(_:
    /// result:/error:)`, the single classify -> route entry point) before sending its existing outcome
    /// action. A `nil` route (an unclassified failure — `.invalidNote`/`.expired`/
    /// `.networkError(retryable: false)`, or the "no account" guard above/the hoisted derivation
    /// failure, none of which reach the SDK call at all) keeps today's behavior byte-for-byte: only
    /// `.transferResult` is sent. A non-nil route ADDITIONALLY sends `.broadcastFailureRouted(route)`
    /// FIRST — the existing `.transferResult`/`isFailurePresented = true` handling is otherwise
    /// unchanged, so `state.failureKind` is always set before the sheet appears.
    ///
    /// Deliberately NO `[migrationManager]` capture on the `.run` below (unlike the reducer's own
    /// `.transferResult` success handler): the hoisted-derivation early-return guard inside this
    /// SAME closure must reach `send(.transferResult(nil))` without ever resolving
    /// `migrationManager` — an explicit capture evaluates (and, in a test with no override for ANY
    /// member, traps) at closure-CREATION time, before the guard even runs. Implicit capture defers
    /// resolution to the first line that actually touches `migrationManager`, exactly where the
    /// guard needs it to.
    private func executeNextTransfer(
        account: WalletAccount?,
        immediateProposal: ImmediateMigrationProposal?
    ) -> Effect<Action> {
        guard let account else {
            return .run { send in await send(.transferResult(nil)) }
        }

        return .run { send in
            // MOB-1513: the immediate lane's USK derivation is pre-broadcast LOCAL work (keychain
            // export + derivation, `MigrationSpendingKeyDerivation.deriveUSK`) — hoisted ABOVE the
            // broadcast `do`/`catch` below so a failure here can never reach `routeBroadcastFailure`:
            // `MigrationBroadcastFailureClass.classify(error:)`'s default arm assumes every throw it
            // sees is a post-Tor-bootstrap connect/submit failure (see that type's doc), which a
            // keychain/derivation error is not. `stopSyncBeforeMigrationBroadcast()` stays below,
            // unchanged, so a hoisted failure here also never nudges `refreshMigrationSyncGate()` —
            // sync was never stopped for this attempt. `immediateProposal` is `nil` for every lane
            // except a software immediate-mode confirm (see `State.immediateProposal`'s doc), so
            // this is a no-op everywhere else.
            let immediateUSK: UnifiedSpendingKey?
            if immediateProposal != nil {
                guard account.vendor != WalletAccount.Vendor.keystone, let zip32AccountIndex = account.zip32AccountIndex else {
                    await send(.transferResult(nil))
                    return
                }
                do {
                    immediateUSK = try MigrationSpendingKeyDerivation.deriveUSK(
                        zip32AccountIndex: zip32AccountIndex,
                        walletStorage: walletStorage,
                        mnemonic: mnemonic,
                        derivationTool: derivationTool,
                        networkType: zcashSDKEnvironment.network().networkType
                    )
                } catch {
                    await send(.transferResult(nil))
                    return
                }
            } else {
                immediateUSK = nil
            }

            // MOB-1496 (R8-T4, #3): tracks whether `stopSyncBeforeMigrationBroadcast()` actually ran
            // THIS attempt — only a stop that was never followed by a successful broadcast needs the
            // nudge (see `migrationManager.refreshMigrationSyncGate`'s doc); the guards above (no
            // account / hoisted USK derivation) return before ever stopping sync, so they must not
            // nudge.
            do {
                let result: MigrationTransferResult?
                if let immediateProposal, let immediateUSK {
                    // MOB-1513: no `migrationNetworkOptions` read here by design — the immediate
                    // lane's `createAndSubmitProposedTransactions` is the ordinary-send submission
                    // path (endpoint selection via `userStoredPreferences.automaticServerSelection()`),
                    // not the engine transfers' `MigrationNetworkPrivacyOptions`/Tor-first
                    // `MigrationBroadcaster` routing — see this file's header doc for the accepted
                    // divergence.
                    //
                    // PHASE 2: #1930 additionally called `stopSyncBeforeMigrationBroadcast()` here
                    // "consistent with every other foreground migration broadcast lane". Dropped
                    // deliberately: that stop is only safe alongside Root's
                    // `.migrationSyncGateChanged` resume machinery (Phase 3) — without it a stopped
                    // sync would never restart. This lane submits through the ORDINARY send pipeline,
                    // exactly like the regular Send flow, which does not stop sync either. Restore
                    // both together in Phase 3, never the stop alone.
                    let txId = try await MigrationCommitPipeline.commitImmediateSoftware(
                        proposal: immediateProposal,
                        usk: immediateUSK,
                        accountUUID: account.id,
                        sdkSynchronizer: sdkSynchronizer
                    )
                    result = MigrationTransferResult.success(txId: txId)
                } else {
                    // PHASE 2: #1930's ENGINE (scheduled) lane —
                    // `migrationNetworkOptions` -> `stopSyncBeforeMigrationBroadcast` ->
                    // `executeNextPendingMigrationTransfer` — lands with Phase 3, together with the
                    // network law (N-series) and Root's sync-gate resume machinery. Phase 2 only
                    // ever pushes this screen with a non-nil `immediateProposal`, so this branch is
                    // unreachable; it fails visibly rather than silently reporting a phantom send.
                    result = nil
                }
                await send(.transferResult(result))
            } catch ZcashError.migrationRecordFailedAfterBroadcast(_) {
                // The broadcast DID land; only recording failed — treated as landed (like `.success`),
                // so no nudge either.
                await send(.transferResult(MigrationTransferResult.success(txId: "")))
            } catch {
                // PHASE 2: #1930 additionally classified+routed the failure
                // (`routeBroadcastFailure` -> `.broadcastFailureRouted`, the R14-R17 surfaces) and
                // nudged the sync gate. Both land with Phase 3/5; the generic failure sheet below
                // is what #1930 itself falls back to for an unclassified failure.
                LoggerProxy.error("[migration] immediate broadcast failed: \(error)")
                await send(.transferResult(nil))
            }
        }
    }

    // PHASE 2: #1930's send-now gate-check / silence-window machinery (`Constants`,
    // `resolveSendGate`, `resolveSendGateEffect`, `waitEffect`, `setSendWaitActive`) is removed
    // with the `.waiting` phase it served — that lane belongs to the scheduled migration and
    // lands with Phase 3, alongside Root's sync-gate resume machinery it depends on.
}
