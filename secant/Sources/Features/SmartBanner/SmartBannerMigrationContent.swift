//
//  SmartBannerMigrationContent.swift
//  zodl
//
//  Ironwood migration content for the SmartBanner's `priorityMigration` case (MOB-1464), triggered
//  live via the `.evaluatePriorityMigration` walk step and the `migrationManager.stateEvents(_:)`
//  subscription (MOB-1466 — see SmartBannerStore.swift). `MigrationBannerVariant` is a pure, testable mapping
//  (see MigrationBannerVariantTests); `migrationContent()` mirrors `shieldingContent()`'s structure.
//

import SwiftUI
import ComposableArchitecture

enum MigrationBannerVariant: Equatable {
    case required
    /// The run is committed and IDLE — nothing due, nothing in flight, the next transfer is waiting
    /// for its window. Figma 5139:35439: "Migration Progress" / "We'll notify you when to send".
    ///
    /// MOB-1466 (smart-banner pass): the second line used to be a progress readout ("3 of 12
    /// transfers done · 25% complete"), which appears in no frame and — worse — was wrong in the
    /// window that matters most. `done` is the MINED count, so a transfer that has been broadcast
    /// and is waiting to mine still reads as not done: "0 of 12 · 0% complete" for the whole of the
    /// first transfer's life. The designed line makes a promise the app actually keeps (the window
    /// notifications are armed at every reconcile) instead of a number that lags reality by a
    /// confirmation. `done`/`total` stay on the case — they still drive the progress ring.
    ///
    /// MOB-1511 (W2): `round`/`totalRounds` carry the multi-round context — non-nil only when the
    /// display rule says a round label belongs on the banner (round ≥ 2, or a known total > 1);
    /// `totalRounds` additionally carries the SDK's real run-count estimate — `nil` when the
    /// estimate is unavailable.
    case inProgress(done: Int, total: Int, round: Int?, totalRounds: Int?)
    /// Figma 5139:35270 — the run is PREPARING transfers: one or more transactions are ready to be
    /// proven and this app-open is what proves them. Run-level, not per-transfer, because a single
    /// prove sweep proves the whole run at once (`C5` shows Transfer 1 and Transfer 2 preparing
    /// together).
    ///
    /// Shares its second line with `.transferSending` for a reason: both are the app doing work
    /// that only survives while it is on screen, and "Keep Zodl open on active phone screen" is the
    /// one thing either state needs from the user. Distinct from `.inProgress` above, which is the
    /// opposite — nothing is running, leaving is free, and we will notify.
    ///
    /// Proving is the LONGEST phase of a run and, until this case existed, the phase where the
    /// banner said the least: a run mid-prove rendered `.transferWaiting`'s alert-circle and
    /// "Tap to reschedule or send now", which is an invitation to act on a transfer that cannot
    /// move yet — and, on iOS, an invitation to leave.
    ///
    /// REVERTED to a payload-free case 2026-08-01, hours after gaining one. The `isWorkingNow`
    /// flag existed to give the split phase a calmer non-working state, and it bought that with two
    /// costs the field named immediately: it introduced copy ("Preparing your balance…") that
    /// appears NOWHERE in Figma, and it kept the spinner lit while the timeline one tap away showed
    /// no spinners at all — reintroducing, in a new place, the exact banner-vs-list contradiction
    /// this whole pass exists to remove.
    ///
    /// The measurement it was meant to fix turned out not to need fixing: the transitions it was
    /// smoothing held for 78 s and 12 s in the field, neither anywhere near a flicker. The real
    /// complaint was latency, not churn — see the 18 s blocked reads in the same log.
    ///
    /// The split phase now uses the two DESIGNED states and nothing else: `.preparing` while the
    /// app can genuinely prove or submit, `.inProgress` while it waits. Where the designed
    /// vocabulary is thin, that is a gap to take to the designers, not one to fill by inventing a
    /// string.
    ///
    /// COUNTS RESTORED 2026-08-05 (FIND-6, campaign 7) — and this is NOT the `isWorkingNow`
    /// mistake again, so read before reverting. The payload-free case obeyed "don't invent copy"
    /// and, in the field, violated a rule that outranks it: MONOTONE INFORMATION. A run at
    /// "1 of 11 transfers · 9%" flipped to this variant the moment the next transfer went
    /// prove-pending, and the banner REPLACED the numbers with a numberless spinner — for 12
    /// straight minutes in the marathon session, over the copy "Keep Zodl open". The user watched
    /// known progress vanish and read it as the run breaking ("I don't think this works").
    /// Numbers, once shown, must never be taken back by a lower-information costume.
    ///
    /// So the case carries the same `done`/`total` the `.inProgress` banner shows, and `info`
    /// renders the DESIGNED counts line whenever `done > 0` — both strings already in the catalog,
    /// nothing invented. Before any transfer is done (`done == 0`, the split phase and the first
    /// prove) nothing was ever shown that could regress, and the designed keep-open ask stands
    /// unchanged. The spinner icon stays in both shapes: since FIND-5 the tick lane proves and
    /// serves unconditionally, so work genuinely runs (or is seconds from running) whenever this
    /// variant shows. A designed counts-plus-working frame remains Andrea's to draw
    /// (SMART_BANNER_STATES §8); this is the honest composition of what exists today.
    case preparing(done: Int, total: Int)
    /// MOB-1511 (W2): the post-completion "more funds to migrate" re-offer, round-aware — replaces
    /// the plain `.required` reuse for an acknowledged completion with a pending remainder.
    case nextRoundRequired(round: Int, totalRounds: Int?)
    /// R7 final review, Important-1 (spec §G): `torHold` is true iff the wait is Tor-caused — the
    /// account's persisted Tor-hold indicator (`MigrationManagerClient.routeBroadcastFailure`
    /// maintains it; `MigrationManagerImpl.bannerVariant` threads it through). Carries a
    /// Tor-specific `info` line instead of the generic waiting copy. Defaults `false` so every
    /// pre-existing call site (none of which know about the indicator) is unaffected.
    case transferWaiting(number: Int, torHold: Bool = false)
    /// Figma 5139:34287 — a BROADCAST session in flight. The engine's `next_step` returned
    /// `Broadcast`, so this app-open spends its window on the submission and deliberately does NOT
    /// sync: ZIP 318 wants a wake window used either to sync or to broadcast, never both, so a
    /// network observer cannot correlate the two. Distinct from `.transferWaiting`, which is the
    /// opposite state (nothing in flight, the transfer is blocked on its schedule).
    ///
    /// The "keep the app open" line is not a nicety. With no background lane on iOS, backgrounding
    /// mid-broadcast is exactly what strands it — so the banner asks for the one thing that keeps
    /// the session alive.
    case transferSending(number: Int)
    case updatePlan
    case transfersExpired(first: Int, last: Int)
    case transferReady(number: Int)
    case complete
    /// THE RATIFIED IDLE (Lukas, 2026-08-06 — Figma-parity audit, flow ID): the engine's
    /// `MigrationAdvanceStep.waiting` made visible. "Nothing is actionable right now" (that case's
    /// own SDK doc) ⇒ nothing to do ⇒ `We'll notify you when to send` — `migrationBanner.idleInfo`,
    /// which sat orphaned in the catalog since SP1 waiting for exactly this trigger rule. Figma
    /// `5139:35439` / `10639`: coins-swap glyph (the frame's own icon — GROUND_RULES §3's "alarm
    /// clock" annotation was the looser reading), the standing "Migration Progress" title, the
    /// ordinary More.
    ///
    /// HISTORY, because this copy has been wired once before and reversed: the full-canvas walk
    /// found counts to be Figma's idle DEFAULT (33226/34962/24004) and un-wired the notify line
    /// pending "a product rule for WHEN it replaces counts". That rule now exists — product ruled
    /// `.waiting` has "no other choice" but this state — so the notify line takes the
    /// nothing-actionable arm and the counts family keeps its ACTIVE homes (the split-phase
    /// progress arm, the stalled-run arm, `.preparing` with progress per FIND-6).
    ///
    /// NOT a FIND-6 violation, read before reverting: FIND-6 forbids replacing numbers with a
    /// numberless costume MID-WORK. This is the designed numberless state when nothing runs,
    /// product-ratified, with the full numbers one tap away on C5.
    case idle
    /// MOB-1466 (staleness pass): the banner does not KNOW yet. Every other case on this enum is an
    /// assertion about the world; this is the one that admits the app has not re-established the
    /// world yet, and it exists because iOS foregrounding renders the previous frame.
    ///
    /// THE PROBLEM. Background Zodl on "We'll notify you when to send", return twenty minutes later,
    /// and iOS paints that same sentence before a line of our code runs. `willEnterForeground` DOES
    /// re-derive — it routes to `retryStart`/`initialSetups`, which reach `advance(.beforeSync)` —
    /// but the answer takes seconds (the field saw idle held ~3 s before flipping to a sending
    /// state), and for those seconds the banner states last session's conclusion with full
    /// confidence. The user reads a promise that is no longer true, then watches it silently
    /// rewrite itself. That is the "outdated feeling" reported through the whole first end-to-end
    /// migration, and no amount of speed fixes it: the gap is where knowledge does not exist yet,
    /// not where it is slow to render.
    ///
    /// WHY NOT DISMISS THE BANNER INSTEAD (the other candidate, rejected). Presence/absence is a
    /// LAYOUT event where a label swap is only a paint: closing and reopening reflows everything
    /// below on EVERY foreground, including the majority where nothing changed. It also lies in the
    /// other direction — mid-migration, an absent banner reads as "done, nothing here" — and it
    /// does nothing for cold launch, where there is no banner to dismiss and the same gap exists.
    ///
    /// NOT A REPEAT OF `isWorkingNow`. The `.preparing` note above records a payload reverted for
    /// inventing copy Figma does not contain, and prescribes the remedy: take the gap to the
    /// designers. That is exactly what happened here — the copy below is PROVISIONAL, added on
    /// Lukas's explicit instruction (2026-08-02) and going to Andrea for the real wording. Do not
    /// revert this case on the `isWorkingNow` precedent; it is the sanctioned path, not the same
    /// mistake. Do reword it the moment design answers.
    ///
    /// GROUND_RULES D1: the checking copy is the SECOND LINE under the standing "Migration
    /// Progress" title — Figma 5679-8225 draws it that way, and the blank-line hack that existed
    /// only because the copy sat in the title slot is gone with it. It DOES carry the button: the
    /// same frame draws the ordinary "More", and the design is the authority.
    ///
    /// I shipped it buttonless on the argument that an action offered against an unknown state is the
    /// stale-CTA class this pass exists to remove, and wrote a test asserting it. The argument does
    /// not survive contact with what the button does. "More" opens the migration screen — which is
    /// exactly where the answer is being computed. A stale CTA promises an OUTCOME the app can no
    /// longer deliver ("Send now" on an expired transfer); "More" promises a DESTINATION, and the
    /// destination stays valid whatever the answer turns out to be.
    ///
    /// The layout argument cut the other way too: a banner that loses its button for 700 ms and grows
    /// one back is the same jump the reserved blank second line exists to prevent.
    case checkingStatus

    /// True for every variant. Kept as a named property rather than deleted: it is the seam where a
    /// state that genuinely must not offer an action would say so, and its absence is what let the
    /// buttonless `.checkingStatus` above pass for a design decision instead of a deviation from one.
    var showsButton: Bool { true }

    /// Membership test for the preparing SHAPE, payload-blind — what the row-truth tests assert
    /// ("this run reads as PREPARING") without pinning counts those tests are not about. Prefer
    /// this over `== .preparing(...)` anywhere the counts are incidental.
    var isPreparingVariant: Bool {
        if case .preparing = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .required, .nextRoundRequired:
            return String(localizable: .migrationBannerRequiredTitle)
        case .inProgress, .preparing, .checkingStatus, .idle:
            return String(localizable: .migrationBannerProgressTitle)
        case .transferWaiting(let number, _):
            return String(localizable: .migrationBannerWaitingTitle(number))
        case .transferSending(let number):
            return String(localizable: .migrationBannerSendingTitle(number))
        case .updatePlan:
            return String(localizable: .migrationBannerUpdatePlanTitle)
        case .transfersExpired(let first, let last):
            return String(localizable: .migrationBannerExpiredTitle(first, last))
        case .transferReady(let number):
            return String(localizable: .migrationBannerReadyTitle(number))
        case .complete:
            return String(localizable: .migrationBannerCompleteTitle)
        }
    }

    var info: String {
        switch self {
        case .required:
            return String(localizable: .migrationBannerRequiredInfo)
        // RATIFIED 2026-08-06 (Lukas, flow ID) — the rule the old D2-provisional note demanded:
        // engine `.waiting` ⇒ `.idle` ⇒ the designed notify line. Counts stay for the ACTIVE
        // `.inProgress` arms (split-phase progress, stalled runs) and for `.preparing` with
        // progress; the pure nothing-actionable slot belongs to `.idle` below.
        case .idle:
            return String(localizable: .migrationBannerIdleInfo)
        case let .inProgress(done, total, round, totalRounds):
            let percent = total > 0 ? (done * 100) / total : 0
            if let round {
                if let totalRounds {
                    return String(localizable: .migrationBannerProgressRoundCountsInfo(round, totalRounds, done, total))
                }
                return String(localizable: .migrationBannerProgressRoundCountsInfoNoTotal(round, done, total))
            }
            return String(localizable: .migrationBannerProgressCountsInfo(done, total, percent))
        case let .preparing(done, total):
            // FIND-6: monotone information — once real progress exists, the counts line (the same
            // designed string `.inProgress` renders) stays on screen through the preparing phases;
            // the spinner icon alone carries "work is running". Only a run with nothing yet done
            // shows the keep-open ask in this slot, because there are no numbers to take back.
            if done > 0 && total > 0 {
                let percent = (done * 100) / total
                return String(localizable: .migrationBannerProgressCountsInfo(done, total, percent))
            }
            return String(localizable: .migrationBannerKeepOpenInfo)
        case .nextRoundRequired(let round, let totalRounds):
            if let totalRounds {
                return String(localizable: .migrationBannerNextRoundInfoTotal(round, totalRounds))
            }
            return String(localizable: .migrationBannerNextRoundInfo(round))
        case .transferWaiting(_, let torHold):
            return torHold
                ? String(localizable: .migrationFailureTorHoldBannerInfo)
                : String(localizable: .migrationBannerWaitingInfo)
        case .transferSending:
            return String(localizable: .migrationBannerKeepOpenInfo)
        case .updatePlan:
            return String(localizable: .migrationBannerUpdatePlanInfo)
        case .transfersExpired:
            return String(localizable: .migrationBannerExpiredInfo)
        case .transferReady:
            return String(localizable: .migrationBannerReadyInfo)
        case .complete:
            return String(localizable: .migrationBannerCompleteInfo)
        case .checkingStatus:
            // Figma 5679-8225: checking is the SUBTITLE under the standing "Migration Progress"
            // title — GROUND_RULES D1.
            return String(localizable: .migrationBannerCheckingInfo)
        }
    }

    /// "More" everywhere except `transferReady`, which reads "Review".
    var buttonLabel: String {
        switch self {
        case .transferReady, .transferSending:
            return String(localizable: .sendReview)
        default:
            return String(localizable: .generalMore)
        }
    }

    var percent: Int? {
        guard case let .inProgress(done, total, _, _) = self else {
            return nil
        }
        return Int((Double(done) / Double(max(total, 1)) * 100).rounded())
    }
}

extension SmartBannerView {
    @ViewBuilder func migrationContent() -> some View {
        MigrationBannerContentView(variant: store.migrationBannerVariant) {
            store.send(.smartBannerContentTapped)
        }
    }
}

/// Standalone rendering of the `priorityMigration` banner content, extracted from
/// `SmartBannerView.migrationContent()` (MOB-1465) so the DEBUG migration gallery can render every
/// `MigrationBannerVariant` without hosting a live `SmartBannerView` (whose `onAppear` starts real
/// dependency subscriptions). Tints use the Gray ramp (`utility-gray-50`/`-200`), matching the
/// Figma migration-banner tokens — deliberately NOT `SmartBannerView.titleStyle()`/`infoStyle()`,
/// which still use the pre-rebrand Purple ramp. Resolved by MOB-1466 (per-priority gradient, not an
/// app-wide restyle): `SmartBannerView`'s background `LinearGradient` swaps to this same Gray._700
/// → ._950 pair only while `store.priorityContent == .priorityMigration`; every other banner keeps
/// the Purple._700 → ._950 pair unchanged.
struct MigrationBannerContentView: View {
    let variant: MigrationBannerVariant
    let onButtonTap: () -> Void

    private var titleStyle: Color {
        Design.Utility.Gray._50.color(.light)
    }

    private var infoStyle: Color {
        Design.Utility.Gray._200.color(.light)
    }

    var body: some View {
        HStack(spacing: 0) {
            migrationIcon()
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(variant.title)
                    .zFont(.medium, size: 14, color: titleStyle)

                Text(variant.info)
                    .zFont(.medium, size: 12, color: infoStyle)
            }

            Spacer()

            // `showsButton` is `true` for every variant today — the buttonless checking was
            // reversed 2026-08-03 against Figma 5679-8225; see the property's own doc for the seam.
            if variant.showsButton {
                ZashiButton(
                    variant.buttonLabel,
                    type: .ghost,
                    infinityWidth: false
                ) {
                    onButtonTap()
                }
                .environment(\.colorScheme, .light)
            }
        }
    }

    @ViewBuilder private func migrationIcon() -> some View {
        switch variant {
        case .required, .nextRoundRequired, .idle:
            // `.idle` joins the coins-swap group per its Figma frames (35439/10639) — nothing is
            // spinning, so the spinner rule below excludes it by construction.
            Asset.Assets.Icons.coinsSwap.image
                .zImage(size: 20, color: titleStyle)
        case .inProgress:
            // DELIBERATE DEVIATION from Figma 5139:35439, which draws `coins-swap-02` here — the
            // same glyph `.required` uses. A committed, idle run and a run that has not started
            // would then be distinguishable only by their second line, and "in progress looks
            // exactly like not started" is the confusion class MOB-1513 (B4) already fixed once (a
            // `.splitting` variant that shared `.required`'s title). The ring says "started, this
            // far in" in the same 20pt slot. One line to revert if design disagrees.
            migrationProgressRing()
        case .preparing, .transferSending, .checkingStatus:
            // `.checkingStatus` joins these two because it satisfies the same rule stated below —
            // something IS actually spinning. Here the work is the re-derivation itself
            // (`advance(.beforeSync)`), which is running for exactly as long as this state shows.
            //
            // No static "working" glyph in the catalogue, and a live spinner says the thing both
            // states are asking for (a session is running, keep it running) better than one would.
            // Figma draws `loading-01` here in both frames — an animated spinner is that glyph's
            // whole intent.
            //
            // The spinner is now reserved for states where something is ACTUALLY spinning. A banner
            // spinner over a timeline with no spinners is a contradiction the user can see in two
            // taps, and it was reported as one within the hour.
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: titleStyle))
                .frame(width: 20, height: 20)
        case .transferWaiting, .updatePlan, .transfersExpired:
            Asset.Assets.Icons.alertCircleOutline.image
                .zImage(size: 20, color: titleStyle)
        case .transferReady, .complete:
            Asset.Assets.infoCircle.image
                .zImage(size: 20, color: titleStyle)
        }
    }

    @ViewBuilder private func migrationProgressRing() -> some View {
        let percent = variant.percent ?? 0

        ZStack {
            Circle()
                .stroke(titleStyle.opacity(0.3), lineWidth: 2)

            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(titleStyle, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
    }
}
