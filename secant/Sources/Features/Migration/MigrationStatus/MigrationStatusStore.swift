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
//  enforced — just later, inside `MigrationSendingStore`'s Send-now lane, which shows a
//  silence-window wait (stop sync -> countdown -> broadcast) instead of leaving the CTA disabled.
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
        var cancelStateStreamId = UUID()
        /// MOB-1466: the 30s refresh pulse's cancel id — see `onAppear`'s pulse effect.
        var cancelRefreshPulseId = UUID()
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
            return !rows.contains { $0.status == MigrationTransferRow.Status.overdue }
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
        /// D14: the run's REAL note-preparation rows, from its `.preparation`-kind transaction
        /// statuses (`MigrationManagerClient.migrationPreparationRows`). Non-nil once the
        /// coordinator/`.statusLoaded` path has read them; `nil` means "no preparation statuses
        /// readable", and `splitRows` falls back to the single synthesized row below — exactly what
        /// this screen showed before D14.
        ///
        /// Stored, not computed, because unlike `rows` these do not derive from anything already in
        /// state: they are a separate engine read.
        var preparationRows: [MigrationTransferRow]?

        var splitRows: IdentifiedArrayOf<MigrationTransferRow> {
            // Real rows win whenever we have them: each carries its own state (a split part-way
            // through a multi-layer preparation is genuinely half-done) and its own ETA.
            if let preparationRows, !preparationRows.isEmpty {
                return IdentifiedArrayOf(uniqueElements: preparationRows)
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
                return .merge(
                    .cancel(id: state.cancelStateStreamId),
                    .cancel(id: state.cancelRefreshPulseId)
                )

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
                return .send(.delegate(.sendNow))

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
