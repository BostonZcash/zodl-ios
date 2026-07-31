//
//  MigrationChainClock.swift
//  zodl
//
//  The chain-time frame every migration ETA is measured in: where the chain is RIGHT NOW, and how
//  fast it is actually moving. Both halves come from the SDK's measured estimators
//  (`estimatedMigrationChainTip` / `estimatedMigrationSecondsPerBlock`).
//
//  WHY THE ESTIMATED TIP AND NOT THE SCANNED ONE. Every due-ness decision the SDK makes for the app
//  passes `useEstimatedTip: true` — `hasOverdueMigrationTransfers`, `executeNextPendingMigration
//  Transfer` — because a broadcast session deliberately does not sync, so the scanned tip is stale
//  by construction. The ETAs shown next to those decisions were measured against the SCANNED tip,
//  which is a different clock. On a send visit the two can disagree outright: the row reads
//  "in ~3 hours" while the engine calls the same transfer due and broadcasts it. Same tip for both,
//  no contradiction.
//
//  WHY THE MEASURED RATE AND NOT 75 s. 75 s is Zcash's TARGET spacing, and it stays the fallback
//  here. It is not what any particular chain does over any particular hour — testnet especially can
//  run far off target — and the migration's whole user-facing promise is a schedule measured in
//  hours. An ETA built on a rate that is wrong by a third is wrong by hours.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// Where the chain is and how fast it moves — the pair every forward ETA needs. Carried as ONE
/// value so the two halves cannot drift apart at a call site: a screen measuring a block delta
/// against the estimated tip but converting it at the target rate would be no more consistent than
/// the split it replaces.
struct MigrationChainClock: Equatable, Sendable {
    /// Zcash's target block spacing — the fallback when the wallet has too few scanned blocks to
    /// measure a real rate (the SDK falls back to the same number, and clamps its own measurement
    /// to [5, 150] s).
    static let targetSecondsPerBlock = 75.0

    /// The chain tip this clock reads from — the SDK's estimated tip in production.
    let tip: BlockHeight
    /// Measured wall-clock seconds per block.
    let secondsPerBlock: Double

    /// A chain nothing is known about yet: before the first scan there is no tip to subtract from.
    /// `MigrationETA.minutesFromNow` floors every height against it to "Ready now" rather than
    /// inventing a distance — the same fail-safe-sentinel idiom `isIronwoodActivated()` uses.
    static let unknown = MigrationChainClock(tip: 0)

    init(tip: BlockHeight, secondsPerBlock: Double = targetSecondsPerBlock) {
        self.tip = tip
        // A zero or negative rate would make every future height read as "Ready now" (and a
        // division by it elsewhere read as infinity). The SDK clamps its own measurement, so this
        // only ever fires for a hand-built clock.
        self.secondsPerBlock = secondsPerBlock > 0 ? secondsPerBlock : Self.targetSecondsPerBlock
    }

    /// Wall-clock seconds from now until `height`, floored at zero. An unknown tip (`<= 0`) or a
    /// height at/behind the tip is zero — "now".
    func secondsUntil(height: BlockHeight) -> TimeInterval {
        guard tip > 0, height > tip else { return 0 }
        return Double(height - tip) * secondsPerBlock
    }

    /// `height` as a wall-clock date, relative to `now`. Heights at/behind the tip land on `now`.
    func date(atHeight height: BlockHeight, now: Date) -> Date {
        now.addingTimeInterval(secondsUntil(height: height))
    }
}
