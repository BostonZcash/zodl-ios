//
//  MigrationETA.swift
//  zodl
//
//  Central forward-looking relative-time helper for the Orchard -> Ironwood migration surfaces
//  (MOB-1513 B3). Every screen that captions a PENDING/active transfer's ETA — Transfer Plan,
//  Migration Status/Progress, Resume — routes through this one type so the granularity (Ready now /
//  in ~N mins / in ~N hours) stays consistent.
//
//  Root cause it replaces: the row builders converted a transfer's execution height to a relative
//  time via `sdkSynchronizer.estimateTimestamp(height)`, which snaps to the nearest BUNDLED
//  CHECKPOINT at-or-below the height and returns `nil` for any height beyond the newest shipped
//  checkpoint (all FUTURE migration heights). A `nil` timestamp floored to `0` hours, which the
//  caption rendered as the hardcoded "~10 mins" fallback (`migrationPlanEtaFirst`) on every row. A
//  block delta is precise regardless of checkpoint staleness — the same correction
//  `MigrationCoordFlowCoordinator.liveStalledHoursAgo` already applied for the BACKWARD
//  ("N hours ago") direction. Android parity: `MigrationDurationFormat.kt` does the same
//  `(toHeight − fromHeight) × BLOCK_INTERVAL`.
//
//  P3: the frame that delta is measured in moved into `MigrationChainClock` — the SDK's estimated
//  tip and MEASURED block rate, rather than the scanned tip and a fixed 75 s. See that type's
//  header for why each half matters.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// A pending transfer's forward ETA, bucketed into the three granularities the migration surfaces
/// render. PAST labels ("Sent Nh ago", "Overdue Nh ago") are NOT modelled here — they keep their
/// own backward-looking timestamp lookups.
enum MigrationETA: Equatable, Sendable {
    case readyNow
    case minutes(Int)
    case hours(Int)

    /// Minutes-from-now for a transfer's scheduled execution height, via a block delta measured in
    /// `clock`'s frame: `(scheduledHeight − tip) × secondsPerBlock ÷ 60`, floored, never negative.
    ///
    /// P3: the tip and the rate now travel together in `MigrationChainClock` — see that type for
    /// why both are read from the SDK's measured estimators rather than the scanned tip and a
    /// hardcoded 75 s. An unknown tip or a height at/below it still yields `0`, the same
    /// fail-safe-sentinel idiom `isIronwoodActivated()` / `liveStalledHoursAgo` use: an unknown tip
    /// is not a low one, so it must not be subtracted from.
    static func minutesFromNow(scheduledHeight: BlockHeight, clock: MigrationChainClock) -> Int {
        max(0, Int((clock.secondsUntil(height: scheduledHeight) / 60).rounded(.down)))
    }

    /// Buckets a minutes-from-now value into the display granularity: `<= 0` -> Ready now, `1..<60`
    /// -> minutes, `>= 60` -> hours (floored).
    static func bucketed(minutesFromNow minutes: Int) -> MigrationETA {
        guard minutes > 0 else { return .readyNow }
        return minutes < 60 ? .minutes(minutes) : .hours(minutes / 60)
    }

    /// Whether a caption uses the Transfer Plan scheduled variant's "in ~…" phrasing or the bare
    /// "~…" phrasing every other forward surface uses (Transfer Plan manual/recreated, Migration
    /// Status/Progress, Resume).
    enum Phrasing: Equatable, Sendable {
        case inPrefixed
        case bare
    }

    /// The localized forward-ETA caption for `minutesFromNow`, bucketed then rendered under the
    /// requested phrasing. The single caption formatter every forward surface calls — see this
    /// type's header for why one shared formatter matters.
    static func caption(minutesFromNow minutes: Int, phrasing: Phrasing) -> String {
        switch bucketed(minutesFromNow: minutes) {
        case .readyNow:
            return String(localizable: .migrationPlanReadyNow)
        case .minutes(let mins):
            return phrasing == .inPrefixed
                ? String(localizable: .migrationPlanEtaMinsIn(mins))
                : String(localizable: .migrationPlanEtaMins(mins))
        case .hours(let hrs):
            return phrasing == .inPrefixed
                ? String(localizable: .migrationPlanEtaHoursIn(hrs))
                : String(localizable: .migrationPlanEtaHours(hrs))
        }
    }
}
