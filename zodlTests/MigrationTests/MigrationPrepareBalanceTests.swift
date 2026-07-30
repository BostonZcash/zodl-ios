//
//  MigrationPrepareBalanceTests.swift
//  zodlTests
//
//  Covers the collapsed-split behaviour introduced with the "Prepare Your Balance" sheet
//  (Figma 5207:16024): `MigrationTransferPlan.State.splitRows` / `hasMultiStepSplit` /
//  `splitCaption`, and the sheet's own `stateCaption(for:)` phrasing.
//
//  Worth pinning because this REPLACED a shipped behaviour. D14 rendered one timeline row per
//  preparation transaction; the design collapses them to one. The collapse is what lets the row
//  carry the split's real total again — D14 had to blank the amount column across several rows,
//  since no honest per-preparation amount exists to divide the total into.
//

import ComposableArchitecture
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationPrepareBalanceTests {
    // MARK: - Fixtures

    private static func row(_ index: Int, amount: Zatoshi?) -> MigrationTransferRow {
        MigrationTransferRow(
            id: "\(index)",
            index: index,
            amount: amount,
            status: .pending,
            hoursFromNow: (index + 1) * 6
        )
    }

    private static func state(
        rows: [MigrationTransferRow],
        preparationCount: Int
    ) -> MigrationTransferPlan.State {
        var state = MigrationTransferPlan.State(
            variant: .scheduled,
            rows: IdentifiedArrayOf(uniqueElements: rows),
            totalDurationHours: 36
        )
        state.preparationCount = preparationCount
        return state
    }

    private static let threeRows = [
        row(0, amount: Zatoshi(1_000_000_000)),
        row(1, amount: Zatoshi(200_000_000)),
        row(2, amount: Zatoshi(45_000_000))
    ]

    // MARK: - The collapse

    /// The behaviour D14 got wrong: however many preparation transactions the engine reports, the
    /// plan timeline shows exactly ONE split row.
    @Test(arguments: [1, 2, 4, 9]) func splitCollapsesToOneRowAtAnyPreparationCount(count: Int) {
        let state = Self.state(rows: Self.threeRows, preparationCount: count)
        #expect(state.splitRows.count == 1)
        #expect(state.splitRows.first?.kind == .splitBalance)
    }

    /// The payoff of collapsing: one row can honestly carry the whole split's value.
    @Test func collapsedRowCarriesTheTotalEvenForAMultiStepSplit() {
        let state = Self.state(rows: Self.threeRows, preparationCount: 4)
        #expect(state.splitRows.first?.amount == Zatoshi(1_245_000_000))
    }

    /// Honest-or-nothing: one unknown transfer amount makes the TOTAL unknown, and an unknown total
    /// shows no amount rather than a wrong one.
    @Test func unknownTransferAmountMakesTheTotalUnknown() {
        let rows = [
            Self.row(0, amount: Zatoshi(1_000_000_000)),
            Self.row(1, amount: nil)
        ]
        #expect(Self.state(rows: rows, preparationCount: 1).splitRows.first?.amount == nil)
    }

    /// No schedule yet — nothing to split, so no row at all (not a zero-valued one).
    @Test func noTransfersMeansNoSplitRow() {
        #expect(Self.state(rows: [], preparationCount: 3).splitRows.isEmpty)
    }

    // MARK: - The disclosure gate

    @Test func singleTransactionSplitOffersNoDisclosure() {
        #expect(!Self.state(rows: Self.threeRows, preparationCount: 1).hasMultiStepSplit)
    }

    @Test func multiTransactionSplitOffersTheDisclosure() {
        #expect(Self.state(rows: Self.threeRows, preparationCount: 4).hasMultiStepSplit)
    }

    // MARK: - Caption

    /// A one-transaction split reads exactly as it did before the collapse — no step suffix.
    @Test func singleStepCaptionIsTheBareETA() {
        let state = Self.state(rows: Self.threeRows, preparationCount: 1)
        #expect(state.splitCaption == MigrationETA.caption(minutesFromNow: 0, phrasing: .inPrefixed))
    }

    @Test func multiStepCaptionAppendsTheStepCount() {
        let state = Self.state(rows: Self.threeRows, preparationCount: 4)
        let eta = MigrationETA.caption(minutesFromNow: 0, phrasing: .inPrefixed)
        #expect(state.splitCaption == String(localizable: .migrationPlanSplitBalanceCaption(eta, 4)))
        #expect(state.splitCaption != eta)
    }

    // MARK: - Step state phrasing

    @Test func singleDependencyReadsAsOneStep() {
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([3]))
                == String(localizable: .migrationPrepareWaitsOnStep(3))
        )
    }

    /// The design's own step 3, "Waits on steps 1 & 2" — the case the interim ladder never produces
    /// but real `depends_on` data will.
    @Test func twoDependenciesJoinWithAnAmpersand() {
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([1, 2]))
                == String(localizable: .migrationPrepareWaitsOnSteps("1 & 2"))
        )
    }

    @Test func threeDependenciesUseCommasThenAnAmpersand() {
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([1, 2, 3]))
                == String(localizable: .migrationPrepareWaitsOnSteps("1, 2 & 3"))
        )
    }

    @Test func dependenciesAreSortedBeforeRendering() {
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([3, 1, 2]))
                == MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([1, 2, 3]))
        )
    }

    /// "Waits on nothing" is not an actionable state; it must not render an empty trailing column.
    @Test func emptyDependencyListFallsBackToInFlight() {
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([]))
                == String(localizable: .migrationPrepareStatePreparing)
        )
    }

    @Test func terminalAndInFlightStatesHaveTheirOwnCaptions() {
        #expect(MigrationPrepareBalanceSheet.stateCaption(for: .done) == String(localizable: .migrationPrepareStateDone))
        #expect(MigrationPrepareBalanceSheet.stateCaption(for: .readyToSend) == String(localizable: .migrationPrepareStateReady))
        #expect(MigrationPrepareBalanceSheet.stateCaption(for: .preparing) == String(localizable: .migrationPrepareStatePreparing))
    }

    // MARK: - Interim ladder (provisional data, permanent shape)

    @Test(arguments: [1, 2, 5]) func interimLadderProducesOneStepPerPreparation(count: Int) {
        #expect(MigrationPreparationStep.interimLadder(count: count).count == count)
    }

    /// Guards the sheet against a zero/negative count reaching it as an empty, headerless card.
    @Test(arguments: [0, -3]) func interimLadderNeverProducesAnEmptyList(count: Int) {
        #expect(MigrationPreparationStep.interimLadder(count: count).count == 1)
    }

    @Test func interimLadderLeadsWithAReadyStepThenAnInFlightOne() {
        let steps = MigrationPreparationStep.interimLadder(count: 4)
        #expect(steps[0].state == .readyToSend)
        #expect(steps[1].state == .preparing)
        #expect(steps[2].state == .waitsOn([2]))
        #expect(steps[3].state == .waitsOn([3]))
    }

    @Test func interimLadderIndexesFromZero() {
        let steps = MigrationPreparationStep.interimLadder(count: 3)
        #expect(steps.map(\.index) == [0, 1, 2])
        #expect(Set(steps.map(\.id)).count == 3)
    }
}
