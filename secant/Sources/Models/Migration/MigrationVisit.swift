//
//  MigrationVisit.swift
//  zodl
//
//  What a given app-open is FOR, decided ONCE before any sync starts.
//
//  This is the app half of ZIP 318's session separation. The engine decides WHAT to do next
//  (`MigrationAdvanceStep`) but is explicitly memoryless about sessions — upstream's own words:
//  "enforcing the session separation is the CONSUMER's runtime policy". This type is that policy.
//
//  The rule: a waking session is used EITHER to sync the wallet OR to broadcast a due transfer,
//  never both, so a network observer cannot correlate a wallet's sync traffic with the transactions
//  it broadcasts.
//
//  WHY THIS IS DECIDED BEFORE SYNC STARTS, not by stopping sync afterwards. The app already has a
//  reactive gate (`isMigrationSyncBlocked`) that halts an in-flight sync for a broadcast, and that
//  gate is still there and still useful. But halting is too late for the privacy property: the
//  correlation exists the moment sync CONNECTS, not when it finishes. A session that starts syncing
//  and is then stopped has already produced exactly the traffic the separation is meant to prevent.
//  So the decision moves ahead of `start()`.
//
//  Preparations are deliberately NOT a send visit. Upstream is explicit that a preparation is proved
//  and broadcast at the same wake-up — it anchors to a fresh checkpoint at the tip like an ordinary
//  transaction, so nothing about it is timing-correlated with a pool crossing. Only TRANSFERS, whose
//  broadcast heights are the privacy schedule, earn a broadcast-only session.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// What this app-open is for. See the file header for the rule and why it is decided up front.
enum MigrationVisit: Equatable, Sendable {
    /// At least one account has a proven transfer DUE. This open is a broadcast session: it must
    /// not initiate sync.
    case send
    /// Nothing is due to broadcast. Sync normally; the prove sweep runs when sync reaches the tip.
    case sync
}

extension MigrationVisit {
    /// The wallet-wide decision from every account's advance step.
    ///
    /// Wallet-wide, not per-account, and that is deliberate: sync is a single wallet-level activity,
    /// so if ANY account is mid-broadcast the whole wallet must stay off the wire. A Zodl wallet and
    /// a Keystone wallet run independent plans but share one network identity.
    ///
    /// `nil` entries (an account with no stored run, or a read that failed) simply do not vote.
    static func decide(advanceSteps: [MigrationAdvanceStep?]) -> MigrationVisit {
        let hasDueBroadcast = advanceSteps.contains { step in
            if case .broadcast = step { return true }
            return false
        }
        return hasDueBroadcast ? .send : .sync
    }
}
