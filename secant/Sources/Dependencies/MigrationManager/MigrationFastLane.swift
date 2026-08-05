//
//  MigrationFastLane.swift
//  zodl
//
//  HARNESS-ONLY cadence override — never production, never a shipped testnet build.
//
//  Lukas, 2026-08-05: automated E2E migration campaigns should wait for MINED TRANSACTIONS ONLY
//  (~40–75 s on testnet), not for ZIP 318's privacy pacing — "nextStep, do it, instead of wait
//  2 minutes... this way we could simulate end-2-end migration in minutes, not ~2 h". The pacing
//  is the PRODUCT on mainnet and the default everywhere; this lane exists so the simulator
//  harness can compress a campaign's wall clock without changing what the campaign exercises
//  (the driver, R0's credits, the one-clock dispatch, reconcile, the banner pipeline — all run
//  exactly as stock).
//
//  What the lane changes, when active:
//   1. `MigrationManagerImpl.sendGate()` reads a ZERO privacy buffer — the app-side post-sync
//      send spacing collapses, so a due broadcast is deliverable the moment the engine says so.
//   2. The driver's first `.beforeSync` drive of the process runs the SDK's QA-only
//      `debugRescheduleMigrationTransfers` once per account — the committed schedule compresses
//      to QA cadence (first due in ~2 blocks, 4-block strides), so windows arrive in minutes.
//  Both are loudly `[MIG] ⚡ FAST LANE`-logged; a trace without those lines is a stock run.
//
//  THE DOUBLE FENCE — why this can never reach users:
//   1. `#if DEBUG`: Release archives (every TestFlight/App Store build, INCLUDING the testnet
//      flavor Lukas ships) compile `isActive` to a literal `false`; the compiler folds every
//      use site to the stock path and the debug code paths are dead-stripped.
//   2. The `-MigrationFastLane` launch argument: only the simulator harness passes it
//      (`xcrun simctl launch <udid> <bundle-id> -MigrationFastLane`). Xcode runs, device
//      installs, and every human-launched app start have no argument, so even DEBUG builds
//      behave stock unless the harness explicitly asks per launch.
//

import Foundation

/// The harness-only fast-cadence switch — see the file header for the contract and the fence.
enum MigrationFastLane {
    /// `true` only in a DEBUG build whose process was launched with `-MigrationFastLane` —
    /// i.e. only the simulator harness's own launches. Literal `false` in Release.
    static var isActive: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-MigrationFastLane")
        #else
        return false
        #endif
    }
}
