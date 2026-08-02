//
//  MigrationStepPlanTests.swift
//  zodlTests
//
//  The decision table of `MigrationStepPlan`, pinned case by case.
//
//  This suite exists because of a specific failure: the app read the engine's next step in ONE
//  place, branched on `.broadcast`, and discarded the other five answers. Two of them — `.rebuild`
//  and `.requiresAttention` — had no automatic discharge anywhere in the app, so a run whose next
//  step was either of those stopped and stayed stopped across any number of app-opens. Nothing
//  failed, nothing logged, nothing was wrong on any screen; the app simply never did the thing it
//  had been told to do.
//
//  So the tests below are not really about the return values. They are about COVERAGE: every case
//  of `MigrationAdvanceStep`, at both phases, produces an action that some executor honours. The
//  planner's own `switch` has no `default:`, which makes a NEW step a compile error; this suite is
//  the other half — it makes a step that compiles but goes nowhere a test failure.
//

import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationStepPlanTests {
    // MARK: - The two steps that used to deadlock

    /// `.rebuild` had exactly one discharge in the whole app: a button on the Recovery screen. The
    /// planner must name it as work, at the phase where the wallet is at the tip.
    @Test func rebuildIsDischargedAtThePostSyncEdge() {
        #expect(MigrationStepPlan.action(for: .rebuild(id: 7), phase: .afterSync) == .rebuild(id: 7))
    }

    /// Before sync it defers rather than acting: a rebuild re-anchors rows against the CURRENT tip,
    /// so rebuilding from a stale one would rebuild them straight back into staleness.
    @Test func rebuildDefersBeforeSync() {
        #expect(MigrationStepPlan.action(for: .rebuild(id: 7), phase: .beforeSync) == .nothing(.wrongPhase))
    }

    /// `.requiresAttention` gets the CHEAP half of its discharge first — sync and ask again — because
    /// the engine adjudicates against scanned data and the obstruction is often transient. Involving
    /// the user before trying that is how an attention state becomes a support ticket.
    @Test func attentionSyncsAndReAsksBeforeInvolvingTheUser() {
        #expect(MigrationStepPlan.action(for: .requiresAttention(id: 2), phase: .beforeSync) == .resync(id: 2))
    }

    /// …and only escalates once it has survived that sync. This is the pair that makes attention
    /// self-clearing whenever it can be.
    @Test func attentionEscalatesOnlyAfterItSurvivedASync() {
        #expect(
            MigrationStepPlan.action(for: .requiresAttention(id: 2), phase: .afterSync)
                == .escalateAttention(id: 2)
        )
    }

    // MARK: - ZIP 318 session separation, enforced structurally

    /// A broadcast may only happen in a session that has not synced. Enforced by the TABLE rather
    /// than by a caller remembering — a caller that forgets is how the property gets lost.
    @Test func broadcastIsOfferedOnlyBeforeSync() {
        #expect(MigrationStepPlan.action(for: .broadcast(id: 5), phase: .beforeSync) == .broadcast(id: 5))
        #expect(MigrationStepPlan.action(for: .broadcast(id: 5), phase: .afterSync) == .nothing(.wrongPhase))
    }

    /// The mirror: proving needs the commitment tree at the tip, so it only happens after a sync —
    /// and never in a broadcast session, where it would force that session onto the wire.
    @Test func proveIsOfferedOnlyAfterSync() {
        let step = MigrationAdvanceStep.prove(id: 1, kind: .transfer(crossing: 0))

        #expect(MigrationStepPlan.action(for: step, phase: .afterSync) == .prove(id: 1))
        #expect(MigrationStepPlan.action(for: step, phase: .beforeSync) == .nothing(.wrongPhase))
    }

    /// A preparation and a transfer are both simply "prove it" here. The kind decides what may
    /// happen AFTER the proof — a preparation may broadcast at the same wake-up — and that is the
    /// engine's next answer to give, not a fork in this table.
    @Test func bothProveKindsProduceTheSameWork() {
        let preparation = MigrationAdvanceStep.prove(id: 9, kind: .preparation(layer: 0, index: 0))
        let transfer = MigrationAdvanceStep.prove(id: 9, kind: .transfer(crossing: 0))

        #expect(MigrationStepPlan.action(for: preparation, phase: .afterSync) == .prove(id: 9))
        #expect(MigrationStepPlan.action(for: transfer, phase: .afterSync) == .prove(id: 9))
    }

    // MARK: - The quiet answers

    @Test func waitingArmsWakeupsAtBothPhases() {
        #expect(MigrationStepPlan.action(for: .waiting, phase: .beforeSync) == .armWakeups)
        #expect(MigrationStepPlan.action(for: .waiting, phase: .afterSync) == .armWakeups)
    }

    @Test func completeIsTerminalAtBothPhases() {
        #expect(MigrationStepPlan.action(for: .complete, phase: .beforeSync) == .finish)
        #expect(MigrationStepPlan.action(for: .complete, phase: .afterSync) == .finish)
    }

    /// `nil` is the benign "no run was ever committed" answer, and it must be distinguishable from
    /// a deferred step — the two look identical on screen and could not be told apart in a log.
    @Test func noStoredRunIsItsOwnAnswerNotADeferral() {
        #expect(MigrationStepPlan.action(for: nil, phase: .beforeSync) == .nothing(.noRun))
        #expect(MigrationStepPlan.action(for: nil, phase: .afterSync) == .nothing(.noRun))
    }

    // MARK: - Coverage: no step may go nowhere

    /// THE invariant, stated directly: across the two phases, EVERY engine step produces at least
    /// one real action. A step that answers `.nothing` at both phases is a step nothing in the app
    /// will ever discharge — which is precisely the bug this whole file was written against.
    @Test func everyStepIsActionableAtSomePhase() {
        let everyStep: [MigrationAdvanceStep] = [
            .broadcast(id: 1),
            .prove(id: 1, kind: .transfer(crossing: 0)),
            .prove(id: 1, kind: .preparation(layer: 0, index: 0)),
            .rebuild(id: 1),
            .requiresAttention(id: 1),
            .waiting,
            .complete
        ]

        for step in everyStep {
            let before = MigrationStepPlan.action(for: step, phase: .beforeSync)
            let after = MigrationStepPlan.action(for: step, phase: .afterSync)

            let isActionable = !Self.isInert(before) || !Self.isInert(after)
            #expect(isActionable, "\(step) produces no work at either phase — nothing would ever discharge it")
        }
    }

    private static func isInert(_ action: MigrationStepAction) -> Bool {
        if case .nothing = action { return true }
        return false
    }

    // MARK: - The wallet-wide session decision

    /// One account mid-broadcast puts the WHOLE wallet off the wire: a Zodl account and a Keystone
    /// account run independent plans but share one network identity.
    @Test func anyDueBroadcastMakesTheWholeSessionABroadcastSession() {
        #expect(MigrationStepPlan.isBroadcastSession(steps: [.waiting, .broadcast(id: 3)]))
    }

    /// `nil` entries (an account with no run, or a read that failed) do not vote.
    @Test func accountsWithNoRunDoNotVote() {
        #expect(!MigrationStepPlan.isBroadcastSession(steps: [nil, nil]))
        #expect(!MigrationStepPlan.isBroadcastSession(steps: [nil, .prove(id: 1, kind: .preparation(layer: 0, index: 0))]))
    }

    /// The session decision must agree with `MigrationVisit`, which Root still asks separately
    /// before `start()`. Two readings of the same rule in two places is how the "two clocks" class
    /// of bug starts, so they are pinned against each other here.
    @Test func theSessionDecisionAgreesWithMigrationVisit() {
        let cases: [[MigrationAdvanceStep?]] = [
            [],
            [nil],
            [.waiting],
            [.broadcast(id: 1)],
            [.prove(id: 1, kind: .preparation(layer: 0, index: 0)), .broadcast(id: 2)],
            [.rebuild(id: 1), .requiresAttention(id: 2)]
        ]

        for steps in cases {
            let planSaysSend = MigrationStepPlan.isBroadcastSession(steps: steps)
            let visitSaysSend = MigrationVisit.decide(advanceSteps: steps) == .send

            #expect(planSaysSend == visitSaysSend, "disagreement on \(steps)")
        }
    }
}
