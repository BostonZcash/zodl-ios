//
//  MigrationStatusStore.swift
//  zodl
//
//  "Migration Progress" / "Resume Migration" / "Re-scheduling…" screen (MOB-1464, Figma S10 ·
//  progress 2709:3350 / resume 2696:7133 / re-scheduling 2840:3656). `onAppear` loads rows/summary
//  via `migrationTransfers()`/`migrationSummary()` and subscribes `migrationManager.stateEvents(_:)`
//  to refresh rows live (MOB-1466).
//  When this screen is a flow re-entry root (`isFlowRoot`), its back control closes the flow
//  (`.done`) instead of popping — every other delegate is consumed by
//  `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1478 (W7): rows can now carry sub-hour sent recency (`sentMinutesAgo`) and a broadcasting
//  flag (`isBroadcasting`) — both just ride along through `statusLoaded`/`migrationStateChanged`
//  unchanged; the View derives their captions. `.rescheduleConfirmed(first:last:)` is a new
//  presentation reached via the public `rescheduleCompleted` action, landing on this same screen
//  instead of flipping `isRescheduling` back to `.resume`. The reschedule effect itself (SDK
//  reschedule + background-window scheduling) still runs in `MigrationCoordFlowCoordinator`, which
//  today pushes a fresh `TransferPlan` screen on completion instead — wiring it to send
//  `rescheduleCompleted` here is a later phase.
//
//  R8-T6 (V8 fix): the Send-now CTA no longer consults `manager.sendGate()` — the 600s app-side
//  sync<->send privacy gate re-arms on EVERY sync completion, and the SDK re-emits a syncing-
//  >upToDate edge every ~10-30s while foregrounded, so the gate was almost never `.allowed` in
//  normal use (chicken-and-egg: sync only stops AFTER a "Send now" tap). `isSendNowDisabled` is now
//  computed straight off `rows` — an `.overdue` row is the SAME "there's a stalled transfer" signal
//  `reentryRoute`/`statusResumeState` already use to route to this screen's `.resume` presentation
//  in the first place, so due-ness alone (not the gate) governs the CTA. The gate is still
//  enforced — just later, inside the Send-now lane itself (see the D3 paragraph below).
//
//  D3 (Figma 5217:36636 — in-place Send now): tapping "Send now" no longer navigates anywhere.
//  Field report: the tap opened a blocking "Preparing a private send window" screen for minutes —
//  a modal whose only content was a countdown for work the user cannot influence, covering the
//  live timeline that actually answers "what is happening to my money". The design sends IN PLACE
//  instead: after biometrics, this store runs the same two-phase lane the old screen ran — the
//  R8-T6 silence window (stop sync, read `sendGate()`, hold sync stopped behind the
//  `migrationSendWaitActive` fence until the privacy buffer clears), then THE MANAGER'S OWN
//  broadcast session (`runBroadcastSession()`), the same submit the headless drive loop uses. Going
//  through the manager is what makes the in-place render work with no view code: the session marks
//  the account in `broadcastsInFlight` and pokes `stateEvents` at both edges, so the rows this
//  screen already re-derives flip to their "Sending now" spinner for exactly the submit window,
//  and on success the broadcast row progresses to `.confirming` (R11) with no navigation at all.
//  `isSendNowInFlight` disables both CTAs across the whole span. Failure keeps the old lane's
//  PERSISTENT routing (the session classifies + routes internally: Tor-hold indicator, R16
//  endpoint rotation, gate nudges) — `.sendNowFinished`'s reload surfaces `torHoldNote`
//  immediately; the `.resume` presentation's own Send now / Reschedule pair IS the retry surface.
//  MANUAL-DELIVERY accounts keep the old push lane (`.delegate(.sendNow)` -> the coordinator's
//  `MigrationSending` push): `runBroadcastSession` refuses to press Send for a manual account by
//  contract, so the dedicated screen remains the only lane that can serve that tap.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationStatus {
    @ObservableState
    struct State: Equatable {
        enum Presentation: Equatable {
            case progress
            case resume
            /// Post-reschedule confirmation (MOB-1478 W7): entered via `rescheduleCompleted` instead
            /// of flipping back to `.resume`. `first`/`last` are the stalled-range transfer numbers
            /// ("Transfers {first}-{last}") captured from `.resume`'s `stalledNumber`/`rows.count` at
            /// the moment of transition.
            case rescheduleConfirmed(first: Int, last: Int)
        }

        /// Goal #6: the ORCHARD -> IRONWOOD header's data, from the SINGLE derivation the timeline
        /// rows also come from — so the header's Ironwood figure and the checkmarks below it cannot
        /// drift. See `MigrationViewSnapshot`.
        var poolFlow = MigrationViewSnapshot.empty
        /// GOAL #4: the split-detail sheet (Figma 5207-16025), opened by the "Show details" button
        /// on the collapsed Split Balance row (5207-16322). Its steps come from `poolFlow`, so the
        /// sheet is the FOURTH observer of one derivation rather than a fourth reader of the engine.
        var isSplitDetailPresented = false
        var presentation = Presentation.progress
        var rows: IdentifiedArrayOf<MigrationTransferRow> = []
        /// The schedule's total remaining-duration estimate. `nil` when not derivable — a W1
        /// fallback re-entry with no persisted schedule yet (MOB-1513) — never a placeholder `0`;
        /// the `.progress` description omits its duration clause when this is `nil` (see
        /// `MigrationStatusView.description`).
        var totalDurationHours: Int?
        /// Resume header: "Transfer {n} of {m} …".
        var stalledNumber = 0
        var stalledHoursAgo = 0
        /// Visual-only: skeleton captions + disabled spinner button on the resume presentation.
        var isRescheduling = false
        /// True when this screen is the coordinator's re-entry root (both presentations) — its back
        /// control then closes the flow instead of popping.
        var isFlowRoot = false
        /// MOB-1497 (R7 final review, Important-1 — spec §G): true iff the selected account's most
        /// recent broadcast failure was a mid-run Tor hold — carries the Tor-specific line on the
        /// `.resume` presentation (see `MigrationStatusView.torHoldNote`). Loaded both via
        /// `.statusLoaded` (live, re-derived on every load/state-change tick) and the coordinator's
        /// re-entry hydration (`MigrationCoordFlowCoordinator.statusResumeState`/
        /// `statusProgressState`). (Rebased onto R8-T6: `isSendNowDisabled` is COMPUTED off `rows`
        /// now, so this is the one stored per-load flag left here.)
        var isTorHoldActive = false
        /// MOB-1496 (W3): the SDK's post-broadcast privacy buffer
        /// (`sdkSynchronizer.migrationPrivacySyncBufferDuration()`), rounded to whole minutes —
        /// threads the resume footer's "…about %1$lld mins…" copy (`migrationStatusWindowMissedNote`)
        /// off the SDK's real value instead of a hardcoded "10". `0` until `statusLoaded` arrives.
        var syncPrivacyBufferMinutes = 0
        /// MOB-1466: true while the screen is showing CACHED rows and a fresh read is still in
        /// flight — the "Updating…" label. Set only when the cache actually supplied something; a
        /// first-ever visit has nothing to be stale about and keeps the ordinary empty state.
        /// Shown as `updatingNote` — spinner plus "Updating…" — whenever the rows on screen are
        /// not this app-open's answer.
        ///
        /// TWO SOURCES, ONE CLAIM (MOB-1466): the pre-first-frame cached-rows path below, and — new
        /// — a stale SESSION, from the same `isMigrationViewFresh` signal the banner's
        /// `.checkingStatus` reads. Backgrounding on this screen and returning used to show a
        /// confident, stale list: on 08-03 the banner said idle while the list still span a spinner
        /// for work that had finished 5 s earlier. The screen now admits it, in the treatment that
        /// already existed rather than a second one invented alongside it.
        var isUpdating = false
        /// D3: a Send-now is running IN PLACE — armed at `.sendNowAuthenticated` (synchronously,
        /// before any effect, so a double-tap has nothing to double), cleared by
        /// `.sendNowFinished`. Spans BOTH halves of the lane: the silence-window wait (minutes,
        /// when the privacy buffer is live) and the manager's submit itself (~7 s). Deliberately a
        /// stored flag rather than a mirror of `poolFlow.isSubmitting`: the snapshot is hydrated at
        /// re-entry and never refreshed mid-screen, and the snapshot's flag only covers the submit
        /// window anyway — the CTA must stay down for the wait too.
        var isSendNowInFlight = false
        var cancelStateStreamId = UUID()
        /// MOB-1466: the 30s refresh pulse's cancel id — see `onAppear`'s pulse effect.
        var cancelRefreshPulseId = UUID()
        /// D3: the in-place Send-now WAIT half's cancel id — fixed for this instance's lifetime,
        /// same idiom as `cancelStateStreamId` (and as `MigrationSending.State.cancelSendNowWaitId`,
        /// whose lane this replaces for non-manual accounts). Only the WAIT is cancellable: the
        /// submit half, once started, must run to completion whatever the screen does — cancelling
        /// a call that may already have put a transaction on the wire is never safe.
        var cancelSendNowWaitId = UUID()
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        var remainingCount: Int {
            rows.filter { $0.status != .sent }.count
        }

        /// R8-T6 (V8 fix): due-ness alone governs the Send-now CTA now — an `.overdue` row is the
        /// SAME signal `reentryRoute`'s `hasOverdue` check already uses to route to this screen's
        /// `.resume` presentation, so this stays consistent with "why am I even seeing this button"
        /// without a separate gate consult (see this file's header doc for the full V8 writeup).
        /// Computed off `rows` (same idiom as `remainingCount` above) rather than stored, so it
        /// can never go stale between a `statusLoaded`/`migrationStateChanged` refresh and a read.
        var isSendNowDisabled: Bool {
            // Disabled WHILE RESCHEDULING (field-caught 2026-07-31): the reschedule spinner leaves
            // its own button disabled but left this one live, so both CTAs for the same transfer
            // were tappable at once — asking the engine to move a transfer's window and to
            // broadcast it in the same breath. The two race over one transaction, and the loser's
            // outcome is whatever ordering the effects happen to take.
            if isRescheduling { return true }
            // D3: and disabled while an in-place send is already running — the same one-operation-
            // per-transfer rule, now that the tap no longer navigates away. The manager's own
            // `broadcastsInFlight` re-entrancy guard would drop a duplicate session anyway; this
            // keeps the duplicate from ever being asked for (and from re-prompting Face ID).
            if isSendNowInFlight { return true }
            return !rows.contains { $0.status == MigrationTransferRow.Status.overdue }
        }

        /// D3: the mirror of `isSendNowDisabled`'s reschedule arm, pointing the other way — while
        /// an in-place send is running, Reschedule must be down for the same field-caught reason
        /// Send-now is down while rescheduling: two operations racing over one transaction. The
        /// old lane got this exclusion for free by leaving the screen; staying means saying it.
        var isRescheduleDisabled: Bool {
            isSendNowInFlight
        }

        /// MOB-1513 (A2): mirrors `MigrationTransferPlan.State.splitRow` for this post-commit
        /// screen — but COMPLETED (`.sent`) rather than merely ready, since by the time any
        /// Status/Resume/reschedule-confirmed presentation is reachable the note-split has
        /// definitely already broadcast (a precondition of scheduling any transfer at all — see
        /// `MigrationTransferTimeline`'s header doc for the shared-component side of this fix).
        /// `nil` before any rows have loaded. Computed off `rows` (not stored) so it can never
        /// drift from whatever `rows` currently holds — including the coordinator's own re-entry
        /// hydration (`statusResumeState`/`statusProgressState`), which constructs `rows` directly
        /// without going through `.statusLoaded` — and so it doesn't force every
        /// `.statusLoaded`/`.rescheduleCompleted` call site (and every existing exhaustive
        /// `TestStore` assertion) to separately track a parallel stored field.
        /// D14: the run's REAL note-preparation rows — now read from `poolFlow`, NOT from a stored
        /// second copy.
        ///
        /// It WAS a separate stored field, hydrated by its own `migrationPreparationRows` call one
        /// line below the coordinator's snapshot read. Both ultimately call the same manager
        /// function, but at two moments, which is the two-clocks shape this whole pass exists to
        /// remove — and it bit immediately: the collapsed row was built from one copy while the
        /// row's own "· N steps" count and the "Show details" gate read the other. A row that
        /// disagrees with its own step count is worse than either version alone.
        ///
        /// Empty means "no preparation statuses readable", and `splitRows` falls back to the single
        /// synthesized row below — exactly what this screen showed before D14.
        var preparationRows: [MigrationTransferRow] { poolFlow.preparations }

        var splitRows: IdentifiedArrayOf<MigrationTransferRow> {
            // GOAL #4 (field, 2026-08-03): the timeline shows ONE Split Balance row, ALWAYS.
            //
            // It used to return the real per-split rows as soon as the engine had them, so the
            // screen changed shape the moment a migration started: the "Split Balance" summary of
            // Figma 5207-16024 at the start, then abruptly Split 1 / Split 2 / Split 3 as separate
            // timeline entries once splitting began. Lukas's call, and the right one — the split is
            // ONE step in the user's story of the migration, and its parts belong in the sheet, not
            // in the same list as the transfers.
            //
            // The real rows are still the SOURCE: collapsed here so the row's state and ETA stay
            // truthful for a multi-layer split that is genuinely part-way through, rather than
            // falling back to the `.sent` placeholder below (which is only correct when there is no
            // engine data at all).
            if !preparationRows.isEmpty {
                return [
                    Self.collapsedSplitRow(
                        from: preparationRows,
                        transfers: rows,
                        isSubmitting: poolFlow.isSubmitting
                    )
                ]
            }

            guard !rows.isEmpty else { return [] }
            // MOB-1513: `rows` can now be a W1-fallback derivation (no committed schedule — every
            // row's `amount` is `nil` on that path) — the sum stays honest: `nil` (unknown total)
            // if ANY row's amount is, rather than silently treating an unknown row as zero.
            let totalAmount: Zatoshi? = rows.contains { $0.amount == nil }
                ? nil
                : rows.reduce(Zatoshi.zero) { $0 + ($1.amount ?? Zatoshi.zero) }
            return [
                MigrationTransferRow(
                    id: "split-balance",
                    index: 0,
                    amount: totalAmount,
                    status: .sent,
                    hoursFromNow: 0,
                    kind: .splitBalance
                )
            ]
        }

        /// GOAL #4: the per-split engine rows as ONE timeline entry — see `splitRows`.
        ///
        /// AMOUNT is the total being migrated (the transfers' sum), NOT the preparations' sum:
        /// preparations are self-sends that repeatedly re-split the same balance, so adding them
        /// would multiply-count the user's own money. Taken from the transfers keeps the figure
        /// identical before and after splitting starts, which is the point — the number must not
        /// jump when the shape of the list stops changing.
        ///
        /// STATUS is the least-finished part: a split is done only when every part of it is.
        /// ETA is the furthest-out part, for the same reason.
        ///
        /// `isSubmitting` is the collapsed row's THIRD source of truth about itself and deliberately
        /// not derived from `preparations`: no durable row can know a submit call is open — the
        /// engine only writes `.broadcast(txid:)` once it returns. It comes from the snapshot, the
        /// same value the banner's split arm reads, so the row spins for exactly the window the
        /// banner asks the user to stay. See `MigrationTransferRow.isSubmitting`.
        static func collapsedSplitRow(
            from preparations: [MigrationTransferRow],
            transfers: IdentifiedArrayOf<MigrationTransferRow>,
            isSubmitting: Bool
        ) -> MigrationTransferRow {
            let total: Zatoshi? = transfers.isEmpty || transfers.contains { $0.amount == nil }
                ? nil
                : transfers.reduce(Zatoshi.zero) { $0 + ($1.amount ?? Zatoshi.zero) }

            let allSent = preparations.allSatisfy { $0.status == MigrationTransferRow.Status.sent }
            // Field, 2026-08-03 ("took me a while to see why"): the banner said "Keep Zodl open"
            // with a spinner while this collapsed row showed a bare ETA — the PROVING child's
            // in-flight state was dropped by the collapse, so the one row on screen never said
            // why staying mattered, and the user had to open the sheet to find a single quiet
            // "Preparing". The collapse now picks its REPRESENTATIVE child by story priority
            // rather than list order: a child the app is proving RIGHT NOW outranks one merely
            // waiting on the chain (`.confirming`), which outranks one waiting on its schedule —
            // so the collapsed caption and spinner (`isInFlight` = the propagated `isPreparing`)
            // tell the most actionable truth the parts contain, and the banner's keep-open ask
            // has its on-screen counterpart again.
            let proving = preparations.first { $0.isPreparing && $0.status != MigrationTransferRow.Status.sent }
            let confirming = preparations.first { $0.status == MigrationTransferRow.Status.confirming }
            let unfinished = preparations.first { $0.status != MigrationTransferRow.Status.sent }
            let representative = proving ?? confirming ?? unfinished

            return MigrationTransferRow(
                id: "split-balance",
                index: 0,
                amount: total,
                status: allSent ? MigrationTransferRow.Status.sent : (representative?.status ?? MigrationTransferRow.Status.sent),
                hoursFromNow: preparations.map(\.hoursFromNow).max() ?? 0,
                isPreparing: !allSent && proving != nil,
                isSubmitting: isSubmitting,
                kind: MigrationTransferRow.Kind.splitBalance
            )
        }

        init(
            presentation: Presentation = .progress,
            rows: IdentifiedArrayOf<MigrationTransferRow> = [],
            totalDurationHours: Int? = nil,
            stalledNumber: Int = 0,
            stalledHoursAgo: Int = 0,
            isRescheduling: Bool = false,
            isFlowRoot: Bool = false
        ) {
            self.presentation = presentation
            self.rows = rows
            self.totalDurationHours = totalDurationHours
            self.stalledNumber = stalledNumber
            self.stalledHoursAgo = stalledHoursAgo
            self.isRescheduling = isRescheduling
            self.isFlowRoot = isFlowRoot
        }
    }

    enum Action: Equatable {
        /// Flow-root back control: closes the flow instead of popping.
        case closeTapped
        /// Progress CTA and the X close.
        case gotItTapped
        case showSplitDetailTapped
        case splitDetailDismissed
        /// The sheet's presentation BINDING (`$store...sending`) — SwiftUI writes `false` here on
        /// drag-dismiss. Distinct from `splitDetailDismissed` (the sheet's own button) only in who
        /// sends it; both land on the same flag.
        case splitDetailPresentedChanged(Bool)
        case delegate(Delegate)
        /// `migrationManager.stateEvents(_:)` ticked — reloads rows/summary.
        case migrationStateChanged
        case onAppear
        /// The screen left the hierarchy — tears down the two `onAppear` subscriptions (the
        /// `stateEvents` stream and the 30s refresh pulse). The pulse's own comment always said
        /// "cancelled with the screen"; until this action existed, nothing did it, and both
        /// effects kept firing into a path whose element was gone (hundreds of TCA
        /// missing-element warnings per session, field-caught 2026-08-03).
        case onDisappear
        /// MOB-1466: the screen's own 30s wake-up while it is open — re-runs `loadStatus`. Exists
        /// because the `stateEvents` stream is narrower than this screen's truth: ETA captions age
        /// with the wall clock and proof-level row changes alter no `MigrationState`, so neither
        /// ever emits (field-caught 2026-08-02: an open screen sat frozen between transfer windows
        /// until reopened).
        case refreshPulse
        /// Public: the coordinator's reschedule effect (SDK reschedule + first-window scheduling)
        /// finished — lands on `.rescheduleConfirmed` with the refreshed rows/duration instead of
        /// flipping `isRescheduling` back to `.resume`. The coordinator doesn't send this yet (it
        /// still pushes a fresh `TransferPlan` screen on completion) — wiring it up is a later phase;
        /// this action is the store-side surface for it (MOB-1478 W7).
        case rescheduleCompleted(rows: [MigrationTransferRow], totalDurationHours: Int?)
        case rescheduleTapped
        case sendNowTapped
        /// Face ID / Touch ID passed for "Send now" — see `sendNowTapped`. Reschedule has no
        /// equivalent on purpose: it re-reads a window and re-renders, signing and moving nothing.
        case sendNowAuthenticated
        /// D3: the in-place lane's completion, success or not — clears `isSendNowInFlight` and
        /// re-derives the screen so the outcome is visible NOW rather than at the next pulse: a
        /// landed broadcast's row reads `.confirming` off the session's own reconcile, a routed
        /// Tor failure's `torHoldNote` appears off the fresh `isMigrationTorHoldActive` read.
        /// `didBroadcast` is the session's honest verdict (false covers a genuine failure AND the
        /// benign nothing-was-due/raced cases — the reload, not this flag, tells them apart on
        /// screen), carried for the log line and the tests.
        case sendNowFinished(didBroadcast: Bool)
        /// D3: the silence window has been waited out (or was never armed — an `.allowed` gate) —
        /// time to run the manager's broadcast session. Split from the wait so the two halves can
        /// have different lifetimes: the wait is cancellable (leaving the screen mid-wait cancels
        /// the send, the old lane's Cancel semantics), the submit this action starts is not.
        case sendNowWindowCleared
        /// `migrationTransfers()` + `migrationSummary()` + `sdkSynchronizer
        /// .migrationPrivacySyncBufferDuration()` + `manager.isMigrationTorHoldActive()` result.
        /// R8-T6: no longer carries a gate reading — `isSendNowDisabled` is derived from `rows`
        /// itself (see `State.isSendNowDisabled`'s doc).
        case statusLoaded(
            rows: [MigrationTransferRow],
            totalDurationHours: Int?,
            syncPrivacyBufferMinutes: Int,
            isTorHoldActive: Bool
        )

        enum Delegate: Equatable {
            case done
            case reschedule
            case sendNow
        }
    }

    /// MOB-1466: the open screen's re-derivation period — see `onAppear`'s refresh-pulse effect.
    /// Deliberately its OWN constant, not `migrationTickInterval`: the tick loop's `.zero` off
    /// switch must not silence this screen (ETA captions age with the wall clock either way) —
    /// pinned by `thePulseStillFiresWithTheTickLoopSwitchedOff`.
    private static let refreshPulseInterval: Swift.Duration = .seconds(30)

    /// D3, carried over verbatim from `MigrationSending`'s Constants: `.syncRequired` immediately
    /// after our own stop is a settle race (the async SDK teardown hasn't drained `isSyncing()`
    /// yet), not a genuine block — one short, bounded wait before the single re-read.
    private static let sendGateSettleDelay: Swift.Duration = .milliseconds(300)

    @Dependency(\.continuousClock) var continuousClock
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.migrationManager) var migrationManager
    // MOB-1496 (W3): `migrationPrivacySyncBufferDuration()` for the resume footer's minutes copy —
    // hydrated here (the store already reads dependencies) rather than adding a dependency to the
    // View.
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .closeTapped:
                return .send(.delegate(.done))

            case .showSplitDetailTapped:
                state.isSplitDetailPresented = true
                return .none

            case .splitDetailPresentedChanged(let presented):
                state.isSplitDetailPresented = presented
                return .none

            case .splitDetailDismissed:
                state.isSplitDetailPresented = false
                return .none

            case .gotItTapped:
                return .send(.delegate(.done))

            case .delegate:
                return .none

            case .migrationStateChanged:
                return loadStatus(accountUUID: state.selectedWalletAccount?.id)

            case .onAppear:
                let accountUUID = state.selectedWalletAccount?.id
                // PAINT FIRST, THEN LOAD. Field-caught 2026-08-01: tapping the banner gave a blank
                // screen with a spinner for ten seconds and more, because this screen drew nothing
                // until `loadStatus`' async read returned — and the instrument measured that read at
                // 4.75 s on a quiet open and 18.3 s while the prove sweep held the wallet database.
                //
                // Making the read faster does not fix it; the screen would still be blank, just
                // briefly. So it stops waiting: the last rows we derived go in synchronously, right
                // here in the reducer, before the first frame — and `isUpdating` makes the claim
                // honest rather than passing a-moment-ago data off as current.
                //
                // Guarded on `rows.isEmpty` so it never clobbers fresher rows the coordinator's own
                // re-entry hydration already put in state.
                if state.rows.isEmpty, let cached = migrationManager.cachedTransferRows(accountUUID) {
                    state.rows = IdentifiedArrayOf(uniqueElements: cached.transfers)
                    state.isUpdating = true
                }
                return .merge(
                    loadStatus(accountUUID: accountUUID),
                    .publisher {
                        migrationManager.stateEvents(accountUUID)
                            .map { _ in Action.migrationStateChanged }
                    }
                    .cancellable(id: state.cancelStateStreamId, cancelInFlight: true),
                    // MOB-1466 (field-caught 2026-08-02): THE REFRESH PULSE. The event stream
                    // above is real but narrower than this screen's truth — broadcasts poke it
                    // (A13) and coarse-state/balance changes push it, while ETA captions age with
                    // the wall clock and proof-level row changes alter no `MigrationState`, so an
                    // OPEN screen sat frozen between transfer windows until reopened. Every 30s
                    // (the foreground tick loop's own cadence) the screen re-derives instead:
                    // cheap local reads, last-writer-wins by construction (`statusLoaded` replaces
                    // whole rows), and cancelled with the screen. First pulse a full 30s in — the
                    // `loadStatus` above just ran.
                    .run { send in
                        for await _ in continuousClock.timer(interval: MigrationStatus.refreshPulseInterval) {
                            await send(.refreshPulse)
                        }
                    }
                    .cancellable(id: state.cancelRefreshPulseId, cancelInFlight: true)
                )

            case .onDisappear:
                var effects: [Effect<Action>] = [
                    .cancel(id: state.cancelStateStreamId),
                    .cancel(id: state.cancelRefreshPulseId)
                ]
                // D3: leaving the screen mid-Send-now. Only the WAIT half is cancellable — an
                // un-elapsed silence window means nothing has been sent, and leaving is exactly the
                // old lane's Cancel ("nothing broadcasts; nudge Root's gate feed to resume sync").
                // The fence clears SYNCHRONOUSLY here, before the nudge effect can race Root's
                // `.retryStart` into deferring against a fence that is about to drop —
                // `MigrationSending.waitCancelTapped`'s clear-then-nudge ordering, kept. A send
                // already past the wait (the manager session itself) is NOT cancelled: the submit
                // may already be on the wire, and the session's own exit paths reopen the sync
                // gate — the nudge here is then a harmless re-push of the current value.
                if state.isSendNowInFlight {
                    setSendWaitActive(false)
                    effects.append(.cancel(id: state.cancelSendNowWaitId))
                    effects.append(
                        .run { _ in await migrationManager.refreshMigrationSyncGate() }
                    )
                }
                return .merge(effects)

            case .refreshPulse:
                return loadStatus(accountUUID: state.selectedWalletAccount?.id)

            case .rescheduleCompleted(let rows, let totalDurationHours):
                state.presentation = .rescheduleConfirmed(first: state.stalledNumber, last: state.rows.count)
                state.rows = IdentifiedArrayOf(uniqueElements: rows)
                state.totalDurationHours = totalDurationHours
                state.isRescheduling = false
                return .none

            case .rescheduleTapped:
                state.isRescheduling = true
                return .send(.delegate(.reschedule))

            case .sendNowTapped:
                // BIOMETRICS, like every other tap in Zodl that moves money. The transaction was
                // already signed at commit (behind its own Face ID), so this authenticates a
                // BROADCAST rather than a signature — and that is deliberate: the user is tapping a
                // button labelled "Send now", and every other send in the app asks. An exception
                // here would teach people that migration money moves without asking.
                //
                // Honest about what this is NOT: the headless drive loop broadcasts these same
                // pre-signed transactions with no prompt (it has no UI and cannot have one), so this
                // is a CONSENT affordance, not a security boundary against someone holding an
                // unlocked phone. It buys consistency of expectation, which is worth having on its
                // own — but do not let it be mistaken for a control it isn't.
                return localAuthentication.gated(success: .sendNowAuthenticated, cancelled: nil)

            case .sendNowAuthenticated:
                // D3: the fork. A MANUAL-delivery account keeps the old push lane — the manager's
                // broadcast session refuses to press Send for a manual account by contract ("the
                // user asked to press the button themselves"), and here the user IS pressing it,
                // so the only lane that can serve the tap is the dedicated `MigrationSending`
                // screen the coordinator still pushes for this delegate. Every other account sends
                // IN PLACE (Figma 5217:36636): the row spins, the CTA disables, the screen stays.
                if migrationManager.isManualDelivery(state.selectedWalletAccount?.id) {
                    return .send(.delegate(.sendNow))
                }
                // Armed synchronously, before the first effect: the CTA is down from this exact
                // frame, so a double-tap has nothing to double and Face ID cannot be re-prompted
                // for a send that is already running.
                state.isSendNowInFlight = true
                return sendWindowWaitEffect(waitId: state.cancelSendNowWaitId)

            case .sendNowWindowCleared:
                // Belt: a duplicate/late delivery (the wait effect fires exactly once, but this
                // action is the one that MOVES MONEY, so it double-checks) must not start a second
                // session. The flag is only false here if `.sendNowFinished` already ran.
                guard state.isSendNowInFlight else { return .none }
                // NOT cancellable, deliberately: past this point a transaction may be on the wire,
                // and the session must run to its own end whatever the screen does. The manager's
                // session is the SAME submit the headless lane runs — it marks `broadcastsInFlight`
                // (the rows' "Sending now" spinner and the snapshot's `isSubmitting`), pokes
                // `stateEvents` at both edges (this screen's live refresh), classifies + routes a
                // failure for its persistent effects (Tor-hold indicator, R16 rotation), records
                // the broadcast and reconciles on success, and reopens the sync gate on its own
                // failure paths.
                return .run { send in
                    let didBroadcast = await migrationManager.runBroadcastSession()
                    if !didBroadcast {
                        // The session's no-op exits (its own gate re-read refusing on a race, a
                        // step that stopped being `.broadcast`, a duplicate dropped by the
                        // re-entrancy guard) return before ever reaching ITS stop — but OUR wait
                        // half already stopped sync for the silence window, and nothing else would
                        // resume it. The failure paths that did reach a stop nudged already; a
                        // second push of the current gate value is a read+yield, harmless.
                        await migrationManager.refreshMigrationSyncGate()
                    }
                    await send(.sendNowFinished(didBroadcast: didBroadcast))
                }

            case .sendNowFinished(let didBroadcast):
                state.isSendNowInFlight = false
                if !didBroadcast {
                    // WHY nothing went out, for the tester — the on-screen answer is the reload
                    // below: a still-`.overdue` row with the CTA back up (a genuine failure — the
                    // Send now / Reschedule pair is the retry surface), a `.confirming` row
                    // (another lane got there first), or the Tor-hold footer (a routed R15 hold).
                    LoggerProxy.event("[MOB-1466] in-place Send now: session ended with nothing broadcast")
                }
                return loadStatus(accountUUID: state.selectedWalletAccount?.id)

            case .statusLoaded(let rows, let totalDurationHours, let syncPrivacyBufferMinutes, let isTorHoldActive):
                state.isUpdating = false
                state.rows = IdentifiedArrayOf(uniqueElements: rows)
                state.totalDurationHours = totalDurationHours
                state.syncPrivacyBufferMinutes = syncPrivacyBufferMinutes
                state.isTorHoldActive = isTorHoldActive
                return .none
            }
        }
    }

    private func loadStatus(accountUUID: AccountUUID?) -> Effect<Action> {
        .run { send in
            let rows = await migrationManager.migrationTransfers(accountUUID)
            let summary = await migrationManager.migrationSummary(accountUUID)
            let syncPrivacyBufferMinutes = MigrationStatus.syncPrivacyBufferMinutes(
                from: sdkSynchronizer.migrationPrivacySyncBufferDuration()
            )
            let isTorHoldActive = migrationManager.isMigrationTorHoldActive(accountUUID)
            await send(
                .statusLoaded(
                    rows: rows,
                    totalDurationHours: summary.estimatedDurationHours,
                    syncPrivacyBufferMinutes: syncPrivacyBufferMinutes,
                    isTorHoldActive: isTorHoldActive
                )
            )
        }
    }

    // MARK: - D3: the in-place Send-now lane's silence window

    /// The R8-T6 silence window, run in place: stop sync FIRST, then read the app-side privacy
    /// gate — the same order as the old lane's `MigrationSending.resolveSendGate()` (reading
    /// before stopping could catch a stale `.allowed` a moment before our own stop, or race a
    /// DIFFERENT lane's concurrent sync completion) — then hold sync stopped behind the
    /// `migrationSendWaitActive` fence until the gate's clear date passes.
    ///
    /// The stop is `stopStartedSyncForMigrationGate()`, NOT the broadcast lanes'
    /// `stopSyncBeforeMigrationBroadcast()` — the field-caught 2026-08-02 wedge applies to this
    /// wait exactly: an engine idling AT the tip reads `isSyncing() == false`, so the weaker
    /// stop no-ops there while every per-block completion re-stamps the gate and the target date
    /// slides forever out of reach. The gate stop's "started" predicate (`.syncing` OR
    /// `.upToDate`) is the one that actually freezes the clock this wait counts against; its
    /// resume flag (`migrationStoppedSyncForBroadcast`, set only when something genuinely
    /// stopped) is what guarantees Root restarts sync afterwards, on every exit path.
    ///
    /// One pass, deliberately — no re-enter-wait loop like the old screen's `.waitFired` had:
    /// with the fence up nothing re-stamps the gate, so the session's own fresh `sendGate()`
    /// re-read at fire time is `.allowed` in every non-raced run; on the rare race it refuses,
    /// `.sendNowFinished(didBroadcast: false)` re-arms the CTA, and a re-tap is a better answer
    /// than a spinner that can extend itself indefinitely.
    ///
    /// Cancellation (the screen's `.onDisappear`) throws out of the sleep — the `defer` clears
    /// the fence on that path too, and `.sendNowWindowCleared` is then never sent: nothing
    /// broadcasts, which is precisely the old lane's Cancel contract.
    private func sendWindowWaitEffect(waitId: UUID) -> Effect<Action> {
        .run { send in
            await sdkSynchronizer.stopStartedSyncForMigrationGate()
            var gate = await migrationManager.sendGate()
            if gate == MigrationSendGate.syncRequired {
                // Plain `try` (not the old lane's `try?`): the only throw a clock sleep has is
                // cancellation, and swallowing it here would let a just-cancelled task run one
                // more stop — re-pausing the sync that `.onDisappear`'s nudge may already have
                // resumed. Unwinding immediately leaves nothing to undo.
                try await continuousClock.sleep(for: MigrationStatus.sendGateSettleDelay)
                await sdkSynchronizer.stopStartedSyncForMigrationGate()
                gate = await migrationManager.sendGate()
            }

            let target: Date?
            switch gate {
            case MigrationSendGate.allowed:
                target = nil
            case MigrationSendGate.waitUntil(let date):
                target = date
            case MigrationSendGate.syncRequired:
                // Still blocked even after the settle retry — never broadcast into it. No date to
                // wait against, so fall back to the full privacy buffer from now, same as a fresh
                // sync completion would produce (the old lane's exact fallback).
                target = Date().addingTimeInterval(sdkSynchronizer.migrationPrivacySyncBufferDuration())
            }

            if let target {
                setSendWaitActive(true)
                defer { setSendWaitActive(false) }
                let remaining = target.timeIntervalSinceNow
                if remaining > 0 {
                    try await continuousClock.sleep(for: .seconds(remaining))
                }
            }
            await send(.sendNowWindowCleared)
        }
        .cancellable(id: waitId, cancelInFlight: true)
    }

    /// D3 — the same MANDATORY TRACE fence `MigrationSending.setSendWaitActive` sets, same
    /// `@Shared(.inMemory(...))` idiom: while the silence window counts down with sync stopped,
    /// `RootInitialization`'s `.retryStart` proactive section defers (without alerting), so no
    /// foreground trigger can restart sync mid-wait and re-stamp the very gate being waited out.
    /// Set only for the wait; cleared before the session runs (a still-armed fence would defer
    /// the session's own post-failure resume nudge into a strand), on cancellation via the
    /// `defer` above, and — belt — synchronously in `.onDisappear` and by Root's flow-teardown
    /// sites.
    private func setSendWaitActive(_ isActive: Bool) {
        @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
        $migrationSendWaitActive.withLock { $0 = isActive }
    }
}

extension MigrationStatus {
    /// MOB-1496 (W3 review fix C): shared formula for `State.syncPrivacyBufferMinutes` — this
    /// store's own `loadStatus()` and `MigrationCoordFlowCoordinator`'s re-entry hydration
    /// (`statusResumeState`/`statusProgressState`) both compute it from the SDK's raw
    /// `migrationPrivacySyncBufferDuration()`; extracted to one spot so the two can't drift.
    static func syncPrivacyBufferMinutes(from duration: TimeInterval) -> Int {
        Int((duration / 60).rounded())
    }
}
