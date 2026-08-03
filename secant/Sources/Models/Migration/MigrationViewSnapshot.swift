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

    /// Σ of the transfers the timeline shows as done. Compared against `ironwoodHeld` by
    /// `isPoolFlowSettled` — see there for why they can legitimately differ for a while.
    let movedByDoneTransfers: Zatoshi

    /// How many transfers the timeline shows as done, and out of how many — the checkmark count the
    /// header's numbers have to be consistent with.
    let doneTransfers: Int
    let totalTransfers: Int

    /// The app-open that produced this. `nil` outside a session.
    ///
    /// Freshness is ONE stamp on ONE value now, consumed identically by every observer, rather than
    /// each surface deciding for itself. That is the simplification the single source buys.
    let sessionOrdinal: Int?

    /// Whether this snapshot was produced by the live app-open.
    func isFresh(currentSessionOrdinal: Int?) -> Bool {
        guard let sessionOrdinal, let currentSessionOrdinal else { return false }
        return sessionOrdinal == currentSessionOrdinal
    }

    /// Whether the destination pool has caught up with the checkmarks.
    ///
    /// FALSE IS NORMAL, not an error, and this is the distinction the header has to render honestly.
    /// The engine flips a row to done from its OWN tables the moment a transfer mines; the wallet's
    /// pool balance only moves once a sync writes it. So between those two moments the checkmarks
    /// legitimately lead the balance — which is precisely the "T1 and T2 done but only T1 moved"
    /// report, and it was a timing gap, never a miscount.
    ///
    /// The header uses this to say "still settling" rather than to hide the difference. Hiding it
    /// would be the fifth version of the mistake this whole pass exists to stop.
    var isPoolFlowSettled: Bool {
        ironwoodHeld >= movedByDoneTransfers
    }

    static let empty = MigrationViewSnapshot(
        orchardRemaining: .zero,
        ironwoodHeld: .zero,
        movedByDoneTransfers: .zero,
        doneTransfers: 0,
        totalTransfers: 0,
        sessionOrdinal: nil
    )
}
