//
//  MigrationPrepareBalanceRow.swift
//  zodl
//
//  One preparation ("split") transaction, as the "Prepare Your Balance" sheet renders it
//  (Figma 5207:16024).
//
//  A run's note-split is not necessarily ONE transaction: the engine reports several across
//  `preparationLayers`, and a later layer can only be built once an earlier one has mined (its
//  inputs are the notes that layer mints). The Transfer Plan timeline therefore shows a single
//  collapsed "Split Balance" row carrying the whole split's amount, and this model backs the sheet
//  behind its "Show details" disclosure, where each step reports what it is waiting on.
//
//  Steps carry no amount by design — `MigrationTransactionStatus` has none to give, and dividing
//  the total N ways would be invented. The sheet shows one honest "Amount Being Split" total in its
//  footer instead.
//
//  The `State` cases map 1:1 onto the engine's per-transaction view once the FFI for
//  `MigrationState::transaction_statuses` lands (zcash/librustzcash#2867 and the `state` module):
//
//  | engine                                        | here            |
//  |-----------------------------------------------|-----------------|
//  | `MigrationTxState::Mined`                     | `.done`         |
//  | `ready` + `NextAction::Prove` / `.Broadcast`   | `.readyToSend`  |
//  | `MigrationTxState::Broadcast`                 | `.preparing`    |
//  | `Blocker::Dependencies` (+ `depends_on`)      | `.waitsOn([…])` |
//
//  Until that exists, `interimLadder(count:)` supplies a shaped placeholder so the sheet, its copy
//  and its layout can be built and reviewed ahead of the engine work. Only that one function is
//  provisional — the model and the sheet are not.
//

import Foundation

struct MigrationPrepareBalanceRow: Equatable, Identifiable, Sendable {
    /// What this step is doing. Ordered as the sheet reads top to bottom.
    enum State: Equatable, Sendable {
        /// Mined: this step is behind us.
        case done
        /// Built and due — the wallet can act on it now.
        case readyToSend
        /// In flight: broadcast, waiting to mine.
        case preparing
        /// Blocked until the listed steps have mined. Values are the step numbers AS DISPLAYED
        /// (1-based), so the view never re-derives them; empty is treated as `.preparing` by the
        /// caption, since "waits on nothing" is not a state a user can act on.
        case waitsOn([Int])
        /// SDK addendum §3: dead by an observed event — the engine marked this step
        /// `MigrationTransactionStatus.State.invalid`. No chain condition makes it actionable
        /// again; the run needs the attention flow. Distinct from every state above because it is
        /// the only one the user must DO something about, and rendering it as "Preparing" (which is
        /// where it landed before the state existed) would say the opposite.
        case invalid
    }

    var id: String
    /// 0-based position in the run. The sheet displays `index + 1`.
    var index: Int
    var state: State
    /// Minutes from now until this step is expected to become actionable. `0` reads "in ~0 hours",
    /// matching the design's first row.
    var minutesFromNow: Int

    /// A shaped placeholder ladder for `count` steps, pending the real per-transaction statuses:
    /// the first step ready, the second in flight, and each later one waiting on its predecessor —
    /// the shape of a multi-layer split, with none of its real timing.
    ///
    /// The renderer is NOT provisional: `.waitsOn` already takes a set, so a real dependency naming
    /// several predecessors ("Waits on steps 1 & 2", as the design draws step 3) renders correctly
    /// the moment `depends_on` is wired, with no change to the sheet.
    static func interimLadder(count: Int) -> [MigrationPrepareBalanceRow] {
        let total = max(1, count)
        return (0..<total).map { index in
            let state: State
            switch index {
            case 0: state = .readyToSend
            case 1: state = .preparing
            default: state = .waitsOn([index])
            }
            return MigrationPrepareBalanceRow(
                id: "preparation-\(index)",
                index: index,
                state: state,
                minutesFromNow: index * 60
            )
        }
    }
}
