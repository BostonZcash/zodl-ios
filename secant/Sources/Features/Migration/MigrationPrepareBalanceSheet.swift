//
//  MigrationPrepareBalanceSheet.swift
//  zodl
//
//  "Prepare Your Balance" sheet (Figma 5207:16024), presented from the Transfer Plan's collapsed
//  "Split Balance" row via its "Show details" disclosure.
//
//  Why a sheet at all: a run's note-split can be several transactions that must mine in order, and
//  the earlier inline treatment (one timeline row per preparation) put N rows of a mechanism the
//  user did not ask about ahead of the transfers they did. The plan screen keeps ONE collapsed row
//  carrying the split's real total, and everything per-step — count, order, what each is waiting on
//  — moves behind this disclosure.
//
//  Steps show no per-step amount: the engine reports none (see `MigrationPrepareBalanceRow`), so the
//  sheet shows a single honest total in its footer instead of N invented fractions.
//
//  A plain `View`, not a feature — it holds no state and has one exit. Presented through
//  `zashiSheet`, matching `MigrationBroadcastFailureSheetView`.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationPrepareBalanceSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    let steps: [MigrationPrepareBalanceRow]
    /// The whole split's total. `nil` hides the footer row rather than showing a placeholder zero —
    /// the same honesty rule the timeline's amount column follows.
    let amountBeingSplit: Zatoshi?
    let gotItTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localizable: .migrationPrepareTitle))
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.top, 32)
                .padding(.bottom, 8)

            Text(String(localizable: .migrationPrepareBody(steps.count)))
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .padding(.bottom, 20)

            stepsCard
                .padding(.bottom, 24)

            ZashiButton(String(localizable: .migrationGotIt)) {
                gotItTapped()
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }

    // MARK: - Steps card

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localizable: .migrationPrepareStepsTitle))
                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                .padding(.bottom, 16)

            ForEach(Array(steps.enumerated()), id: \.element.id) { position, step in
                stepRow(step, isLast: position == steps.count - 1)
            }

            if let amountBeingSplit {
                Divider()
                    .overlay(Design.Surfaces.strokeTertiary.color(colorScheme))
                    .padding(.top, 4)
                    .padding(.bottom, 12)

                HStack(spacing: 0) {
                    Text(String(localizable: .migrationPrepareAmountBeingSplit))
                        .zFont(size: 14, style: Design.Text.tertiary)

                    Spacer(minLength: 8)

                    Text("\(amountBeingSplit.decimalString()) ZEC")
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                        .strokeBorder(Design.Surfaces.strokeTertiary.color(colorScheme))
                }
        }
    }

    @ViewBuilder private func stepRow(_ step: MigrationPrepareBalanceRow, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                // Field, 2026-08-03: the banner asked "Keep Zodl open" with a spinner while this
                // sheet answered with one quiet word — the keep-open ask had no counterpart where
                // the user went looking for it. A step the app is PROVING right now wears a live
                // spinner in the badge slot (the design's 5139-34627 language: spinner where the
                // number goes); every other state keeps its badge. Spinner strictly for app-work:
                // `.sent` (chain's side) and `.waitsOn`/`.readyToSend` stay static.
                if step.state == .preparing {
                    ZStack {
                        Circle()
                            .fill(Design.Text.primary.color(colorScheme))
                            .frame(width: 24, height: 24)
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.6)
                    }
                    .frame(width: 24, height: 24)
                } else {
                    MigrationStepBadge(number: step.index + 1, style: badgeStyle(for: step.state))
                }

                if !isLast {
                    Rectangle()
                        .fill(Design.Surfaces.strokePrimary.color(colorScheme))
                        .frame(width: 2, height: 20)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localizable: .migrationPrepareTransactionNOfM(step.index + 1, steps.count)))
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                // MOB-1466: `.plan`, not `.inPrefixed` — committal phrasing, matching the Transfer
                // Plan screen this sheet was first built for.
                //
                // NOW CONDITIONAL (field, 2026-08-03). The line used to render unconditionally, on
                // the assumption recorded here that the sheet "only ever opens from the pre-commit
                // Transfer Plan screen" — where every step is still ahead, so a forward ETA is
                // always meaningful. That assumption stopped holding the moment this sheet was also
                // wired behind the Migration Progress screen's disclosure, one day before a
                // screenshot showed "Starts right away" beneath a green checkmark labelled "Done".
                //
                // A finished step has no forward time (`minutesFromNow == nil`) and gets no line.
                // Its trailing "Done" already says everything true about it.
                if let minutesFromNow = step.minutesFromNow {
                    Text(MigrationETA.caption(minutesFromNow: minutesFromNow, phrasing: .plan))
                        .zFont(size: 12, style: Design.Text.tertiary)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 8)

            Text(Self.stateCaption(for: step.state))
                .zFont(size: 12, style: Design.Text.tertiary)
                .multilineTextAlignment(.trailing)
                .padding(.top, 2)
        }
        .padding(.bottom, isLast ? 0 : 4)
    }

    private func badgeStyle(for state: MigrationPrepareBalanceRow.State) -> MigrationStepBadge.Style {
        switch state {
        case .done:
            return .sent
        case .sent:
            // R11/Andrea's ladder: check-shaped because it IS sent, not green because the wallet
            // has not counted it — the same `.neutral` check the timeline's confirming rows wear.
            return .neutral
        case .readyToSend, .preparing:
            return .active
        case .scheduled, .waitsOn:
            // A future turn and a dependency wait are the same visual weight: nothing is
            // happening yet, and nothing needs to.
            return .pending
        case .invalid:
            // The amber exclamation the timeline already uses for invalid/expired rows — the one
            // badge that says "you have to do something", which is exactly this state's meaning.
            return .warning
        }
    }

    /// The trailing status text. `internal static` so it can be table-tested without a view host —
    /// the dependency-list phrasing (singular / "1 & 2" / "1, 2 & 3") is the only real logic here.
    static func stateCaption(for state: MigrationPrepareBalanceRow.State) -> String {
        switch state {
        case .done:
            return String(localizable: .migrationPrepareStateDone)
        case .readyToSend:
            return String(localizable: .migrationPrepareStateReady)
        case .scheduled:
            // The time line under the row's title carries the WHEN ("Starts in ~12 min");
            // this trailing word only names the state.
            return String(localizable: .migrationPrepareStateScheduled)
        case .sent:
            // The shared one-word caption Andrea's ladder gave the whole on-chain span
            // (`migrationStatus.sent`) — one key, every surface.
            return String(localizable: .migrationStatusSent)
        case .preparing:
            return String(localizable: .migrationPrepareStatePreparing)
        case .invalid:
            return String(localizable: .migrationPrepareStateInvalid)
        case .waitsOn(let steps):
            let sorted = steps.sorted()
            guard let last = sorted.last else {
                // "Waits on nothing" is not an actionable state; fall back to the in-flight caption
                // rather than rendering an empty trailing column.
                return String(localizable: .migrationPrepareStatePreparing)
            }
            guard sorted.count > 1 else {
                return String(localizable: .migrationPrepareWaitsOnStep(last))
            }
            let leading = sorted.dropLast().map(String.init).joined(separator: ", ")
            return String(localizable: .migrationPrepareWaitsOnSteps("\(leading) & \(last)"))
        }
    }
}

// MARK: - Previews

#Preview("Four steps") {
    MigrationPrepareBalanceSheet(
        steps: MigrationPrepareBalanceRow.interimLadder(count: 4),
        amountBeingSplit: Zatoshi(1_245_000_000),
        gotItTapped: { }
    )
    .screenHorizontalPadding()
}

/// The design's own step 3 — a dependency naming two predecessors — plus a completed first step.
#Preview("Mixed states") {
    MigrationPrepareBalanceSheet(
        steps: [
            // `nil`, not 0 — a done step states no forward time, and this preview is where that
            // renders: one row with no second line, three with one.
            MigrationPrepareBalanceRow(id: "0", index: 0, state: .done, minutesFromNow: nil),
            MigrationPrepareBalanceRow(id: "1", index: 1, state: .readyToSend, minutesFromNow: 0),
            MigrationPrepareBalanceRow(id: "2", index: 2, state: .waitsOn([1, 2]), minutesFromNow: 120),
            MigrationPrepareBalanceRow(id: "3", index: 3, state: .waitsOn([3]), minutesFromNow: 180)
        ],
        amountBeingSplit: Zatoshi(1_245_000_000),
        gotItTapped: { }
    )
    .screenHorizontalPadding()
}

#Preview("Unknown total") {
    MigrationPrepareBalanceSheet(
        steps: MigrationPrepareBalanceRow.interimLadder(count: 2),
        amountBeingSplit: nil,
        gotItTapped: { }
    )
    .screenHorizontalPadding()
}
