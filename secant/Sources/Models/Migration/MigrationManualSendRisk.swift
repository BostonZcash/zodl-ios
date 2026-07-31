//
//  MigrationManualSendRisk.swift
//  zodl
//
//  A12: whether an ordinary manual send should warn that it may spend Orchard funds a scheduled
//  migration is counting on (`SendOrchardWarningSheet`, Figma 5139:23856).
//
//  WHY THE WARNING MATTERS. The migration's whole point is that pool crossings are individually
//  timed and denominated so their amounts are not linkable. A manual send that dips into Orchard
//  crosses the turnstile on the USER's schedule, in the USER's amount — leaking exactly what the
//  migration spends days hiding. Worse, it can spend the very notes the run's pre-signed transfers
//  are built on, invalidating the plan (the condition `runInvalidationSweep` detects afterwards).
//
//  WHAT THIS IS AN APPROXIMATION OF. The precise question is "does THIS proposal spend Orchard?",
//  and the SDK cannot answer it: `Proposal` exposes only `transactionCount()` and
//  `totalFeeRequired()`, with no per-step pool breakdown. That answer is board row B6.
//
//  So this asks the coarser question the app CAN answer: is there a live run, and is there still
//  unmigrated Orchard value for a send to reach into? When both hold, any manual send genuinely may
//  spend Orchard — note selection is the SDK's to make, not the user's — so the warning is
//  conservative rather than wrong. It also retires itself: once the run completes, the Orchard
//  balance is zero and the condition can never hold again.
//
//  Deliberately different from the A20 judgement on the server-switch warning, which was ruled
//  QUIET because it fired when the user's action changed nothing. This one fires when the action
//  can change something expensive and irreversible. Over-warning about a plan the user could
//  invalidate is the right side to err on; under-warning costs them the plan.
//
//  When B6 lands, replace `hasUnmigratedOrchard` with the proposal's own answer — one parameter,
//  one call site, and this file's tests keep their shape.
//

import Foundation
@preconcurrency import ZcashLightClientKit

enum MigrationManualSendRisk {
    /// Whether to warn before a manual send.
    ///
    /// - Parameters:
    ///   - hasActiveRun: a run is committed and not terminal — there is a plan to invalidate.
    ///   - hasUnmigratedOrchard: unlocked Orchard value remains, so a send can reach it.
    static func shouldWarn(hasActiveRun: Bool, hasUnmigratedOrchard: Bool) -> Bool {
        hasActiveRun && hasUnmigratedOrchard
    }

    /// Whether `state` is a run a manual send could damage. A run that has not started cannot be
    /// invalidated, and a complete one has nothing left to protect.
    static func isActiveRun(_ state: MigrationState) -> Bool {
        switch state {
        case .notStarted, .complete:
            return false
        case .splitPendingConfirmation, .inProgress, .requiresAttention:
            return true
        }
    }
}
