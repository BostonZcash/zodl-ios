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
    /// `isWorkingNow` decides only the SECOND LINE, never the title or the icon, and that is the
    /// whole design (field-caught 2026-08-01). During the note-split phase the engine's answer to
    /// "can you prove something this instant" flips on and off in seconds — schedule-blocked, then
    /// provable, then proved, then waiting for a broadcast window — and a banner that followed it
    /// literally would swap between "Migration Progress · Preparing your balance…" and "Migration
    /// Progress · We'll notify you when to send" every few seconds while the user watched. The run
    /// is preparing throughout; only whether WE need them present changes.
    ///
    /// - `true` — the app can prove or is submitting right now: "Keep Zodl open on active phone
    ///   screen". Leaving costs the user the work.
    /// - `false` — the run is between its own steps (a schedule window, a mining wait): "Preparing
    ///   your balance…". Leaving costs nothing, and there is nothing to SEND, so the idle banner's
    ///   "We'll notify you when to send" would promise the wrong thing.
    case preparing(isWorkingNow: Bool)
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

    var title: String {
        switch self {
        case .required, .nextRoundRequired:
            return String(localizable: .migrationBannerRequiredTitle)
        case .inProgress, .preparing:
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
        case .inProgress(_, _, let round, let totalRounds):
            if let round {
                if let totalRounds {
                    return String(localizable: .migrationBannerIdleInfoRoundTotal(round, totalRounds))
                }
                return String(localizable: .migrationBannerIdleInfoRound(round))
            }
            return String(localizable: .migrationBannerIdleInfo)
        case .preparing(let isWorkingNow):
            return isWorkingNow
                ? String(localizable: .migrationBannerKeepOpenInfo)
                : String(localizable: .migrationBannerPreparingBalanceInfo)
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

    @ViewBuilder private func migrationIcon() -> some View {
        switch variant {
        case .required, .nextRoundRequired:
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
        case .preparing, .transferSending:
            // No static "working" glyph in the catalogue, and a live spinner says the thing both
            // states are asking for (a session is running, keep it running) better than one would.
            // Figma draws `loading-01` here in both frames — an animated spinner is that glyph's
            // whole intent.
            //
            // The spinner stays on for `.preparing(isWorkingNow: false)` too, deliberately. That
            // state is not idle — the RUN is mid-step, it just does not need the user present for
            // this particular one — and swapping the icon every time the engine's provable-now
            // answer flips would be the visual churn this whole pass exists to remove. The second
            // line carries the difference; the icon carries "your migration is moving".
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
