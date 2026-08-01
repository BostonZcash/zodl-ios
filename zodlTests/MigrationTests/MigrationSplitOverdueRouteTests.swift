//
//  MigrationSplitOverdueRouteTests.swift
//  zodlTests
//
//  Field-caught 2026-07-31, ~30 seconds after confirming a plan: the banner read "Migration in
//  Progress · 0 of 12" while tapping it landed on the Resume screen saying transfer 1 was overdue,
//  offering an ENABLED "Send now" that nothing could serve.
//
//  Both surfaces read the same state (`splitPendingConfirmation`, `hasOverdue == true`) and told
//  opposite stories, because they ranked the two inputs differently:
//
//    - `bannerVariant` switches on STATE and only consults `hasOverdue` inside `.inProgress`,
//      so the split phase reported progress.
//    - `reentryRoute` checked `hasOverdue` FIRST, ahead of every state arm, so the split phase
//      reported a stall.
//
//  The engine was right and quiet throughout: it never offered a broadcast (no `broadcast due`
//  line in the logs, sync ran normally), because transfer 1's preparation had not mined and the
//  transfer was blocked on dependencies. Overdue by the clock; un-sendable in fact.
//
//  So these tests pin the ranking, not the individual answers: DURING THE SPLIT PHASE, A CLOCK-
//  OVERDUE TRANSFER IS NOT A STALL. The run is progressing exactly as planned; only the
//  preparation it waits on has yet to mine.
//

import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationSplitOverdueRouteTests {
    private static func progress(completed: Int = 0, total: Int = 12) -> MigrationProgress {
        MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchard: Zatoshi(10_000_000_000),
            nextTransferReadyAtHeight: 4_200_000
        )
    }

    private static func route(
        state: MigrationState,
        hasOverdue: Bool,
        hasInvalid: Bool = false
    ) -> MigrationReentryRoute {
        MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: state,
            hasInvalid: hasInvalid,
            hasOverdue: hasOverdue,
            isManualDelivery: false,
            isNextTransferDue: false,
            isCompleteAcknowledged: false,
            progress: progress()
        )
    }

    // MARK: - The reported bug

    /// THE regression test. Split phase + a clock-overdue transfer must resume on PROGRESS, not on
    /// the stalled-transfer Resume screen — there is nothing for the user to unstick.
    @Test func anOverdueTransferDuringTheSplitPhaseIsNotAStall() {
        let route = Self.route(state: .splitPendingConfirmation, hasOverdue: true)

        #expect(route == .statusProgress)
    }

    /// The two surfaces must agree from the same inputs. This is the invariant that was actually
    /// violated — either answer alone is defensible, but a banner saying "in progress" over a
    /// screen saying "overdue, send it now" is never right.
    @Test func theBannerAndTheRouteTellTheSameStory() {
        let state = MigrationState.splitPendingConfirmation
        let banner = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: state,
            hasOverdue: true,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi(10_000_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: []
        )

        // Banner says "running" — asserted on the TITLE, which is the claim the user actually reads,
        // rather than on the case. MOB-1466 (2026-08-01) moved the split phase from `.inProgress` to
        // `.preparing(isWorkingNow:)` without changing that claim by a character, and pinning the
        // case made a behaviour-preserving change look like a regression.
        guard let banner, banner.title == MigrationBannerVariant.inProgress(done: 0, total: 1, round: nil, totalRounds: nil).title else {
            Issue.record("expected the split phase to read as progress, got \(String(describing: banner))")
            return
        }
        // …so the screen behind it must not say "stalled".
        #expect(Self.route(state: state, hasOverdue: true) != .statusResume)
    }

    // MARK: - What must NOT change

    /// Once the preparations have mined and transfers are actually running, an overdue transfer IS
    /// a stall and the Resume screen is exactly right. The fix reorders two checks; it must not
    /// disable one.
    @Test func anOverdueTransferDuringTheTransferPhaseStillResumes() {
        let route = Self.route(state: .inProgress(Self.progress()), hasOverdue: true)

        #expect(route == .statusResume)
    }

    /// An invalid transaction still outranks everything, split phase included: a dead transfer
    /// needs a re-plan whatever else is in flight.
    @Test func anInvalidTransferStillOutranksTheSplitPhase() {
        let route = Self.route(state: .splitPendingConfirmation, hasOverdue: true, hasInvalid: true)

        #expect(route == .recovery(isExpired: false))
    }

    /// The ordinary split phase — nothing overdue — was already routing to progress and must keep
    /// doing so. Pinned so the reorder is provably a no-op for it.
    @Test func theOrdinarySplitPhaseStillRoutesToProgress() {
        let route = Self.route(state: .splitPendingConfirmation, hasOverdue: false)

        #expect(route == .statusProgress)
    }
}
