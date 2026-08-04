//
//  MigrationViewSnapshot.swift
//  Zodl
//
//  THE SINGLE SOURCE OF TRUTH for what a migration looks like right now (MOB-1466).
//
//  WHY THIS EXISTS. The smart banner and the migration screen each derived migration state
//  independently, from the same manager, at different moments. That is two clocks, and two clocks
//  produce exactly what the field reported all week: the banner shows A, the screen has not caught
//  up and shows nothing; the screen resolves to B; back on the banner it is still A until it
//  re-derives. Neither surface is wrong — they are at different points in time, and no amount of
//  per-surface patching fixes that, because there is nothing to fix in either one.
//
//  Lukas's framing, 2026-08-03, and it is the correct one: there is code, logic, persistence and
//  in-memory state that KEEPS the data; the banner and the screen are just renderings of it. One
//  derivation, many observers, and a kick from anywhere to say "recompute".
//
//  THE INVARIANT THIS BUYS, and the reason the pool header waited for it: a header claiming
//  "9.49 ZEC in Ironwood" and a timeline of green checkmarks summing to 9.49 must agree BY
//  CONSTRUCTION, not by both happening to be right. Here they are computed from one read, in one
//  place, at one instant. A third independent deriver would have made that impossible to guarantee
//  no matter how carefully each one was written.
//
//  Validated before building: on the 08-02 field wallet the DONE crossings summed to 949,000,000
//  zatoshi and the Ironwood pool held 949,000,000 — exact. The accounting was never the problem;
//  the *timing* was, and that is what one snapshot removes.
//
//  R9 + R11 (2026-08-03, final): the header's bubbles show `orchardRemaining`/`ironwoodHeld` — the
//  wallet's REAL per-pool balances, the same chain-derived source the home balance sheet reads
//  ("if pool X has Y zec, must use Y"; derived green-sums were rejected for contradicting the home
//  sheet). The 55.2-vs-0 field screenshot that once argued against this was never a data problem —
//  it was a GREEN problem: rows flipped green at broadcast, two phases before the wallet counted
//  them. R11 fixed the green instead: a row renders Done only when the wallet's OWN store has its
//  transaction mined (`.sent` vs `.confirming` in the row derivation), so the checkmarks and the
//  pool balances now move in the same sync write and agree BY CONSTRUCTION — no render gate needed.
//

import Foundation
import ZcashLightClientKit

/// One coherent answer to "what does this migration look like", produced by a single derivation.
///
/// Grows as the banner and the screen migrate onto it — today it carries the pool flow the header
/// needs. Every field must come from the SAME derivation pass; adding one that is fetched
/// separately would reintroduce the second clock this type exists to remove.
struct MigrationViewSnapshot: Equatable, Sendable {
    /// Orchard value still to migrate — the SOURCE bubble.
    let orchardRemaining: Zatoshi

    /// Ironwood value the wallet currently holds — the DESTINATION bubble.
    ///
    /// Read from the wallet's own per-pool balance, NOT inferred from the transfer rows. The two
    /// agreeing is the point; deriving one from the other would make the agreement vacuous and hide
    /// exactly the lag we are trying to surface.
    let ironwoodHeld: Zatoshi

    /// M3 Part B (MOB-1466): the in-flight correction the two bubbles above were ALREADY corrected
    /// by, carried raw so Home's pool sheet can apply the SAME figure to its own SDK-read pool
    /// balances. One derivation, one clock: Home and the migration header move together or not at
    /// all — publishing corrected bubbles here while Home re-derived its own correction would be
    /// the two-clocks shape this type exists to remove.
    let poolCorrection: MigrationDerivations.PoolTruthCorrection

    /// Σ of the transfers the timeline shows as done — and R11 makes "done" mean WALLET-CONFIRMED
    /// (`.sent` rows only; `.confirming` rows are excluded), so this moves in the same sync write
    /// `ironwoodHeld` does. Compared against it by `isPoolFlowSettled`, now trace-only.
    let movedByDoneTransfers: Zatoshi

    /// How many transfers the timeline shows as done (wallet-confirmed, R11), and out of how many —
    /// the checkmark count the header's numbers have to be consistent with.
    let doneTransfers: Int
    let totalTransfers: Int

    /// R13 Brick 2: the transfer rows themselves — THE list every timeline renders, carried here so
    /// the status screen stops pulling `migrationTransfers()` on its own clock (the 30-second pulse
    /// existed precisely because that pull had no push). Stamped with the live submit overlay at
    /// build time; the broadcast session republishes at both edges, so a stale "Sending now" can
    /// never outlive the submit that raised it.
    let transfers: [MigrationTransferRow]

    /// R13 Brick 2: the run's summary (duration estimate, counts, dust) from the SAME pass — the
    /// status screen's `totalDurationHours` and the coordinator's hydrations read it here instead
    /// of a second `migrationSummary()` call at a second moment.
    let summary: MigrationSummary

    /// R13 Brick 2b: the banner's ladder position, decided IN THE SAME PASS as the rows it
    /// describes. The banner's derivation was the last second-pass truth reader — its own mirror
    /// row derivation at its own moment, the original two-clocks shape (R2's "one position, one
    /// value, two renderings" is finally executable: this IS the one value). `nil` means "no
    /// migration banner" (pre-activation, no account, offer held while not caught up, no run).
    let banner: MigrationBannerVariant?

    /// The split's parts, as the engine reports them. Carried here — rather than fetched again by
    /// the sheet — because the "Show details" sheet is the FOURTH observer of this state (banner,
    /// timeline, pool header, sheet) and a fourth independent read is a fourth clock.
    let preparations: [MigrationTransferRow]

    /// Σ of ALL transfer amounts in the plan — a RECONCILIATION figure for the POOLS trace (plan vs
    /// green vs pools), nil when any row's amount is unknown (W1 fallback).
    ///
    /// NOT rendered anywhere (R9, amended 2026-08-03): an earlier cut derived the header's bubbles
    /// from this (X = plan − Σ green), and Lukas rejected it before the first test — "it should not
    /// sum up numbers floating in memory or some 'future values'.. if pool X has Y zec, must use
    /// Y". Bubbles labelled with POOL NAMES must show the same chain-derived values the home
    /// balance sheet shows, or the app contradicts itself between two screens.
    let planTotal: Zatoshi?

    /// R13 Brick 2 (R7 §G): whether the account's most recent broadcast failure was a mid-run Tor
    /// hold — the `.resume` presentation's Tor footer, read in the same pass as everything else.
    let isTorHoldActive: Bool

    /// MOB-1497 (T5) / E2E harness F#9 (2026-08-04): TRUE while a HEADLESS broadcast attempt has
    /// routed `.torFirstRunChoice` (R14) and no surface has resolved the choice. The Status screen
    /// presents the designed first-run Tor sheet from exactly this flag; the banner joins it to
    /// `isTorHoldActive` for its Tor line. Cleared by resolution (`resolveMigrationTorPrompt`), a
    /// landed broadcast (`markHadBroadcast`), or run-end (`clear`). Without this flag the scheduled
    /// lane discarded the routed choice and a Tor-unreachable migration stalled silently forever.
    let needsTorFirstRunChoice: Bool

    /// Whether a migration transaction is ON THE WIRE as this snapshot is taken — see
    /// `MigrationTransferRow.isSubmitting`.
    ///
    /// Lives here rather than being read separately by each surface for the reason everything else
    /// does: the banner says "keep Zodl open" and the timeline spins its row from ONE fact, so they
    /// cannot contradict each other for the ~7 s it is true. The last time these were separate the
    /// banner span a spinner over a list that showed none, which is the complaint that started this
    /// whole pass.
    let isSubmitting: Bool

    /// The app-open that produced this. `nil` outside a session.
    ///
    /// Freshness is ONE stamp on ONE value now, consumed identically by every observer, rather than
    /// each surface deciding for itself. That is the simplification the single source buys.
    let sessionOrdinal: Int?

    /// R13 (refinement 3): when the wallet's store last finished a sync — the AGE of every
    /// wallet-derived fact in this snapshot (`ironwoodHeld`, the `.sent` greens behind
    /// `doneTransfers`). During a deliberate send-visit hold (ZIP-318) the store is frozen by
    /// design; old truth may be shown ONLY labeled with its age, and this is the label's source.
    /// `nil` when no sync has ever completed. Brick 3 renders it; carried from Brick 1 so the
    /// derivation pass is complete before any surface asks.
    let asOfSyncedAt: Date?

    /// Whether this snapshot was produced by the live app-open.
    func isFresh(currentSessionOrdinal: Int?) -> Bool {
        guard let sessionOrdinal, let currentSessionOrdinal else { return false }
        return sessionOrdinal == currentSessionOrdinal
    }

    /// TRACE-ONLY diagnostic (R11 demoted it from render gate): whether the destination pool's
    /// balance covers the Σ of wallet-confirmed transfers.
    ///
    /// Under R11 `movedByDoneTransfers` counts only WALLET-CONFIRMED rows, and `ironwoodHeld` is
    /// the same wallet's balance — both move in the same sync write, so this holds by construction
    /// in the steady state. It can legitimately go false in exactly one honest way: the user SPENT
    /// Ironwood funds mid-migration (the balance is current holdings; the checkmarks are history).
    /// That is also why it must never gate rendering again — a mid-migration spend would have
    /// hidden the header forever. It lives on only in the POOLS trace, where a false reading now
    /// means "spent from Ironwood" rather than "settling lag".
    var isPoolFlowSettled: Bool {
        ironwoodHeld >= movedByDoneTransfers
    }

    /// Whether the split detail is worth offering. A one-part split has no detail to show — the
    /// timeline row already says everything the sheet would.
    var hasSplitDetail: Bool { preparations.count > 1 }

    static let empty = MigrationViewSnapshot(
        orchardRemaining: .zero,
        ironwoodHeld: .zero,
        poolCorrection: MigrationDerivations.PoolTruthCorrection.none,
        movedByDoneTransfers: .zero,
        doneTransfers: 0,
        totalTransfers: 0,
        transfers: [],
        summary: MigrationSummary.zero,
        banner: nil,
        preparations: [],
        planTotal: nil,
        isTorHoldActive: false,
        needsTorFirstRunChoice: false,
        isSubmitting: false,
        sessionOrdinal: nil,
        asOfSyncedAt: nil
    )
}
