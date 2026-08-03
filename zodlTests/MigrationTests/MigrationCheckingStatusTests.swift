//
//  MigrationCheckingStatusTests.swift
//  zodlTests
//
//  `MigrationBannerVariant.checkingStatus` — the state that admits the app has not re-established
//  the world yet (MOB-1466).
//
//  WHY THESE TESTS EXIST AS CONTRACT TESTS. Every property pinned here was a deliberate decision
//  that a later reader would otherwise "tidy up" into a bug:
//
//  - `info` is the real checking copy, not a blank placeholder (GROUND_RULES D1, Figma 5679-8225):
//    checking is the SUBTITLE under the standing "Migration Progress" title, so it belongs in
//    `info`, not folded into `title` with an empty `info` and a reserved-blank-line hack. Resist
//    reverting this to `""` — that layout was the pre-D1 workaround, not the design.
//  - grouping with `.preparing`/`.transferSending` for the spinner is a RULE ("the spinner is
//    reserved for states where something is actually spinning"), not a coincidence — here the work
//    is the re-derivation itself.
//
//  STILL OWED, and deliberately not faked here: the reducer-level dwell state machine
//  (raise-on-foreground, hold-during-dwell, apply-after, floor-not-timeout, never-manufacture).
//  Those need a `TestStore` over `SmartBanner`; `MigrationTickDriverTests` is the shape to mirror.
//  Asserting them at this layer would prove nothing about the reducer and would read as coverage
//  that does not exist.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationCheckingStatusTests {
    /// REVERSED 2026-08-03 against Figma 5679-8225, which draws this state WITH the ordinary "More".
    ///
    /// The old assertion (`!showsButton`) encoded my reasoning, not the design's: I argued an unknown
    /// state must offer no action. But "More" opens the migration screen, which is where the answer
    /// is being computed — a destination, not a promised outcome, and valid whichever way the answer
    /// lands. The stale-CTA class this pass removes is "Send now" on a transfer that can no longer be
    /// sent. This was never that.
    @Test func checkingKeepsItsButton() {
        #expect(MigrationBannerVariant.checkingStatus.showsButton)
    }

    /// Every variant offers its action. Written as an enumeration rather than a spot check so that
    /// hiding a button anywhere becomes a deliberate act with a failing test attached.
    @Test func everyVariantOffersItsAction() {
        let actionable: [MigrationBannerVariant] = [
            .required,
            .inProgress(done: 1, total: 4, round: nil, totalRounds: nil),
            .preparing,
            .nextRoundRequired(round: 2, totalRounds: 3),
            .transferWaiting(number: 1, torHold: false),
            .transferSending(number: 1),
            .updatePlan,
            .transfersExpired(first: 1, last: 2),
            .transferReady(number: 1),
            .complete,
            .checkingStatus
        ]

        for variant in actionable {
            #expect(variant.showsButton, "\(variant) must keep its button")
        }
    }

    /// The second line is the checking copy itself (GROUND_RULES D1, Figma 5679-8225): checking is
    /// the SUBTITLE under the standing "Migration Progress" title, not an empty line reserved to
    /// hold the banner's height.
    @Test func checkingSubtitleIsTheCheckingCopy() {
        let info = MigrationBannerVariant.checkingStatus.info

        #expect(info == String(localizable: .migrationBannerCheckingInfo))
        #expect(!info.isEmpty)
    }

    /// It does say something, though — silence would be its own kind of lie. Since GROUND_RULES D1
    /// (Figma 5679-8225), that something is the standing "Migration Progress" title shared with
    /// `.inProgress`/`.preparing` — the checking-specific copy now lives in `info` instead (see
    /// `checkingSubtitleIsTheCheckingCopy`). "Migration Progress" still isn't a fresh offer or a
    /// finished run, so these assertions hold unchanged.
    @Test func checkingStillNamesItself() {
        let title = MigrationBannerVariant.checkingStatus.title

        #expect(!title.isEmpty)
        #expect(title != MigrationBannerVariant.required.title, "must not read as a fresh offer")
        #expect(title != MigrationBannerVariant.complete.title, "must not read as a finished run")
    }

    /// A progress ring would claim a completion fraction the app has not established yet, so the
    /// percent must stay nil — `.inProgress` is the only variant that owns a number.
    @Test func checkingClaimsNoProgressFraction() {
        #expect(MigrationBannerVariant.checkingStatus.percent == nil)
    }

    /// Equatable is what the store's hold-and-apply logic compares on; a variant that failed to
    /// distinguish itself would make the dwell untestable and the flicker trace lie.
    @Test func checkingIsDistinctFromEveryOtherState() {
        #expect(MigrationBannerVariant.checkingStatus != .preparing)
        #expect(MigrationBannerVariant.checkingStatus != .required)
        #expect(MigrationBannerVariant.checkingStatus != .complete)
        #expect(MigrationBannerVariant.checkingStatus == .checkingStatus)
    }
}
