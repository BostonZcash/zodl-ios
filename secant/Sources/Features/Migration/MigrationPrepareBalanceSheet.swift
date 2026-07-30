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
//  Steps show no per-step amount: the engine reports none (see `MigrationPreparationStep`), so the
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

    let steps: [MigrationPreparationStep]
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

    @ViewBuilder private func stepRow(_ step: MigrationPreparationStep, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                MigrationStepBadge(number: step.index + 1, style: badgeStyle(for: step.state))

                if !isLast {
                    Rectangle()
                        .fill(Design.Surfaces.strokePrimary.color(colorScheme))
                        .frame(width: 2, height: 20)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localizable: .migrationPrepareTransactionNOfM(step.index + 1, steps.count)))
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                Text(MigrationETA.caption(minutesFromNow: step.minutesFromNow, phrasing: .inPrefixed))
                    .zFont(size: 12, style: Design.Text.tertiary)
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

    private func badgeStyle(for state: MigrationPreparationStep.State) -> MigrationStepBadge.Style {
        switch state {
        case .done:
            return .sent
        case .readyToSend, .preparing:
            return .active
        case .waitsOn:
            return .pending
        }
    }

    /// The trailing status text. `internal static` so it can be table-tested without a view host —
    /// the dependency-list phrasing (singular / "1 & 2" / "1, 2 & 3") is the only real logic here.
    static func stateCaption(for state: MigrationPreparationStep.State) -> String {
        switch state {
        case .done:
            return String(localizable: .migrationPrepareStateDone)
        case .readyToSend:
            return String(localizable: .migrationPrepareStateReady)
        case .preparing:
            return String(localizable: .migrationPrepareStatePreparing)
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
        steps: MigrationPreparationStep.interimLadder(count: 4),
        amountBeingSplit: Zatoshi(1_245_000_000),
        gotItTapped: { }
    )
    .screenHorizontalPadding()
}

/// The design's own step 3 — a dependency naming two predecessors — plus a completed first step.
#Preview("Mixed states") {
    MigrationPrepareBalanceSheet(
        steps: [
            MigrationPreparationStep(id: "0", index: 0, state: .done, minutesFromNow: 0),
            MigrationPreparationStep(id: "1", index: 1, state: .readyToSend, minutesFromNow: 0),
            MigrationPreparationStep(id: "2", index: 2, state: .waitsOn([1, 2]), minutesFromNow: 120),
            MigrationPreparationStep(id: "3", index: 3, state: .waitsOn([3]), minutesFromNow: 180)
        ],
        amountBeingSplit: Zatoshi(1_245_000_000),
        gotItTapped: { }
    )
    .screenHorizontalPadding()
}

#Preview("Unknown total") {
    MigrationPrepareBalanceSheet(
        steps: MigrationPreparationStep.interimLadder(count: 2),
        amountBeingSplit: nil,
        gotItTapped: { }
    )
    .screenHorizontalPadding()
}
