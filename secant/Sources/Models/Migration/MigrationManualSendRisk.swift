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
//  B6 HAS LANDED, so the primary rule is now proposal truth: warn iff a live run exists AND THIS
//  proposal spends legacy Orchard funds (`Proposal.spendsLegacyOrchardFunds`). No more inferring
//  risk from wallet-wide balance — a transparent-only send during a live run with unmigrated
//  Orchard sitting elsewhere is now correctly quiet, because that particular send cannot touch it.
//
//  NIL-PROPOSAL FALLBACK. When no proposal is available to ask, this falls back to the coarser
//  question the app can always answer: is there a live run, and is there still unmigrated Orchard
//  value for SOME send to reach into? That fallback stays conservative rather than wrong — note
//  selection is the SDK's to make, not the user's — and it retires itself: once the run completes,
//  the Orchard balance is zero and the condition can never hold again.
//
//  Deliberately different from the A20 judgement on the server-switch warning, which was ruled
//  QUIET because it fired when the user's action changed nothing. This one fires when the action
//  can change something expensive and irreversible. Over-warning about a plan the user could
//  invalidate is the right side to err on; under-warning costs them the plan.
//
//  HISTORY. Before B6, the SDK could not answer "does THIS proposal spend Orchard?" at all
//  (`Proposal` exposed only a transaction count and a fee), so this predicate had only today's
//  fallback approximation (`hasActiveRun && hasUnmigratedOrchard`) to go on.
//

import Foundation
@preconcurrency import ZcashLightClientKit

enum MigrationManualSendRisk {
    /// Whether to warn before a manual send.
    ///
    /// - Parameters:
    ///   - hasActiveRun: a run is committed and not terminal — there is a plan to invalidate.
    ///   - proposalSpendsOrchard: `Proposal.spendsLegacyOrchardFunds` for THIS send's own built
    ///     proposal, when one is available. Non-nil is authoritative: `hasUnmigratedOrchard` below
    ///     is not consulted.
    ///   - hasUnmigratedOrchard: unlocked Orchard value remains, so SOME send can reach it. Only
    ///     consulted when `proposalSpendsOrchard` is nil — no proposal was available to ask.
    static func shouldWarn(hasActiveRun: Bool, proposalSpendsOrchard: Bool?, hasUnmigratedOrchard: Bool) -> Bool {
        if let proposalSpendsOrchard {
            return hasActiveRun && proposalSpendsOrchard
        }
        return hasActiveRun && hasUnmigratedOrchard
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
