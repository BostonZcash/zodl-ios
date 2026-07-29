//
//  MigrationCommitPipeline.swift
//  zodl
//
//  Shared commit-lane helpers for the migration flow's "confirm" step (MOB-1496 remediation R8-T1,
//  finding #19): `MigrationTransferPlanStore` (scheduled/manual/recreated plans) and
//  `MigrationReviewTransferStore` (the immediate single-sweep transfer) each drove an independent,
//  byte-identical ~35-line software commit sequence and ~12-line Keystone PCZT-proposal fork —
//  extracted here.
//
//  Both entry points below THROW rather than swallow (finding #4): callers map ANY thrown error to
//  their existing commit-failure surface (`.noteSplitFailed` / `isFailurePresented`).
//
//  MOB-1513 (Lane A2 — send-max immediate migration): the OLD `.immediate` lane above signed+stored
//  an engine-held, single-transfer `MigrationSchedule` here and broadcast it LATER via
//  `MigrationSendingStore`'s `executeNextPendingMigrationTransfer` (the schedule/dust lanes' own
//  delivery mechanism) — `commitSoftware`'s old `MigrationCommitMode.immediate` branch and
//  `MigrationCommitMode` itself are DELETED along with it (the immediate lane is the ONLY caller
//  that ever passed `.immediate`, and `commitSoftware` is `.scheduled`-only now, so the parameter
//  was pure dead weight). The immediate lane's `ImmediateMigrationProposal` (`Synchronizer
//  .proposeImmediateMigration(accountUUID:)`) is an ORDINARY, engine-external proposal instead — no
//  plan-cache staleness, no engine-held schedule to sign+store ahead of time. Two new entry points
//  cover it end to end, mirroring `commitSoftware`/`proposeKeystoneBatch`'s software/Keystone split:
//  - `commitImmediateSoftware`: the actual create+sign+submit (`createAndSubmitProposedTransactions`,
//    already transaction-guarded in `SDKSynchronizerLive`) — called from `MigrationSendingStore
//    .executeNextTransfer`'s immediate-lane branch (the Sending screen's `onAppear` is genuinely
//    where the FIRST and ONLY broadcast attempt happens now, same as every other lane; Review's own
//    confirm has nothing left to pre-commit for the software path).
//  - `commitImmediateKeystone`: the post-signing add-proofs + submit
//    (`createAndSubmitTransactionFromPCZT`) — called from `MigrationCoordFlowCoordinator`'s
//    dedicated immediate-Keystone post-scan step, since a Keystone PCZT can only be finalized once,
//    right after the QR round-trip returns a signature — there is no engine-side "store now,
//    broadcast whenever the Sending screen next appears" indirection available for a proposal that
//    was never stored in the engine to begin with.
//  Both throw on a non-`.success` submit outcome (`MigrationCommitError.immediateSubmitNotSuccessful`)
//  WITHOUT calling `recordImmediateMigration` — never record a sweep that never broadcast. Both treat
//  a `recordImmediateMigration` failure AFTER a successful submit as non-fatal (mirrors the
//  landed-but-unrecorded philosophy above): the broadcast already landed, so a bookkeeping-only
//  failure must never be reported as a submit failure.
//
//  MOB-1513 (B4 — confirm redesign): `commitSoftware` no longer broadcasts ANYTHING. The old chain
//  ran the monolithic `submitNoteSplit` inline (signing + first-prep proving — a one-time,
//  multi-second Orchard proving-key build — + an inline Tor bootstrap + the broadcast, all
//  serialized on the process-wide DB actor, which is exactly the multi-second confirm freeze QA
//  hit), plus `stopSyncBeforeMigrationBroadcast` and the whole broadcast failure-routing block
//  (`MigrationCommitError.splitFailedRouted`, R14-R17 surfaces on the plan screen — all deleted
//  with it). The chain is now sign-only, matching the design's "everything signed at once, splits
//  execute immediately, transfers per offsets": `signAndStoreMigrationSchedule` (the atomic
//  commit: signs EVERYTHING of the run — every transfer AND any note-split preparation layers it
//  needs — straight from the plan cache `schedule`'s own propose call already wrote, with NO
//  proving and NO broadcast) -> `recordCommittedSchedule` -> `reconcile`. The first prep's actual
//  broadcast (prove-at-broadcast, Tor, privacy buffer) happens AFTER navigation, via
//  `MigrationCoordFlowCoordinator`'s post-confirm first-delivery kick over the existing next-due
//  lane — see `runFirstDeliveryKick`'s doc there. NEVER add a `submitNoteSplit` OR a
//  `prepareNoteSplit` call ahead of `signAndStoreMigrationSchedule` here (MOB-1513 F1-A1): the SDK
//  holds ONE proposal-handle slot per account (`MigrationSchedule.proposalHandle`'s doc), and ANY
//  propose/prepare call for that account — `prepareNoteSplit` included — supersedes whatever
//  handle is cached there, including `schedule`'s own. A `prepareNoteSplit` call sandwiched
//  between the propose that minted `schedule` and this commit would invalidate `schedule` before
//  it is ever signed, so every commit needing a split would throw `migrationPlanStale`
//  unconditionally — a bug this file used to have. NEVER add a `submitNoteSplit` call after
//  `signAndStoreMigrationSchedule` either: the successful commit clears the plan cache, so
//  `sign_note_split`'s echo-validation would throw plan-stale.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// Failures `MigrationCommitPipeline`'s own logic raises, distinct from whatever the underlying SDK
/// calls throw — callers that don't care about the payload can still map ANY of these to the same
/// commit-failure surface, exactly as before.
enum MigrationCommitError: Error, Equatable {
    /// MOB-1513: an immediate-lane submit (`createAndSubmitProposedTransactions`/
    /// `createAndSubmitTransactionFromPCZT`) came back as anything other than `.success` — no txid to
    /// record, no partial state to clean up (nothing was stored anywhere by this pipeline).
    case immediateSubmitNotSuccessful
}

/// Shared commit-lane pipelines for the migration flow's software- and Keystone-signing paths (see
/// this file's header for the extraction rationale).
enum MigrationCommitPipeline {
    // MARK: - MOB-1513: immediate lane (send-max `ImmediateMigrationProposal`)

    /// The immediate lane's software (USK-signing) submit: derives no new state ahead of time — the
    /// proposal is already in hand, so this IS the whole commit. `createAndSubmitProposedTransactions`
    /// signs and broadcasts in one call (already transaction-guarded in `SDKSynchronizerLive`, so this
    /// never wraps its own guard). On a genuine `.success`, collects the (single, by construction —
    /// a send-max proposal always produces exactly one transaction) txid and calls
    /// `recordImmediateMigration` before returning it — a `recordImmediateMigration` failure AFTER a
    /// successful submit is bookkeeping-only and never turns a landed broadcast into a reported
    /// failure (mirrors the landed-but-unrecorded philosophy in this file's header). On any other
    /// submit outcome, throws `MigrationCommitError.immediateSubmitNotSuccessful` WITHOUT recording
    /// anything — callers map this like any other thrown error to their existing failure surface.
    ///
    /// - Returns: the broadcast transaction's id, in the SDK's display-hex form (`TxId`/
    ///   `toHexStringTxId()` convention) — the same shape `MigrationTransferResult.success(txId:)`
    ///   and `MigrationSending.State.txId` already use everywhere else in this flow.
    static func commitImmediateSoftware(
        proposal: ImmediateMigrationProposal,
        usk: UnifiedSpendingKey,
        accountUUID: AccountUUID,
        sdkSynchronizer: SDKSynchronizerClient
    ) async throws -> String {
        let result = try await sdkSynchronizer.createAndSubmitProposedTransactions(proposal.proposal, usk)
        guard case let .success(txIds) = result, let displayTxId = txIds.first else {
            throw MigrationCommitError.immediateSubmitNotSuccessful
        }
        await recordImmediateMigrationBestEffort(accountUUID: accountUUID, displayTxId: displayTxId, sdkSynchronizer: sdkSynchronizer)
        return displayTxId
    }

    /// Used by the immediate submit path above (and, from Phase 7, by the Keystone one too): the broadcast already landed by the time this
    /// runs (a `displayTxId` in hand), so a `recordImmediateMigration` failure here is bookkeeping
    /// only — logged, never thrown, never turning an already-successful broadcast into a reported
    /// failure (same "landed but unrecorded is still success" precedent this file's header
    /// describes).
    private static func recordImmediateMigrationBestEffort(
        accountUUID: AccountUUID,
        displayTxId: String,
        sdkSynchronizer: SDKSynchronizerClient
    ) async {
        do {
            try await sdkSynchronizer.recordImmediateMigration(accountUUID, rawTxId(fromDisplayHex: displayTxId))
        } catch {
            LoggerProxy.error("[MOB-1513] recordImmediateMigration failed after a successful broadcast (txid \(displayTxId)): \(error)")
        }
    }

    /// Inverts `Data.toHexStringTxId()` (SDK, `Extensions/Data+Zcash.swift`): that display
    /// convention reverses the txid's bytes and THEN hex-encodes them, so recovering the raw/
    /// internal-order `Data` `recordImmediateMigration(accountUUID:txid:)` requires (matching
    /// `TxId.id`) means hex-decoding first and reversing the decoded bytes back — hex-decoding alone
    /// would silently hand the SDK a byte-reversed txid. See `Synchronizer.recordImmediateMigration`'s
    /// own doc for the identical warning from the SDK side. `Data(hexString:)` is the app-wide hex
    /// decoder already used by `VotingCryptoClientLiveKey.swift`.
    private static func rawTxId(fromDisplayHex hex: String) -> Data {
        Data(decodeHex(hex).reversed())
    }

    /// #1930 called the app-wide `Data(hexString:)` here. That extension lives in
    /// `VotingCryptoClientLiveKey.swift`, which is compiled ONLY under `#if VOTING_ENABLED` — so on
    /// an ordinary wallet build it does not exist. Same implementation, byte for byte, kept as a
    /// private static func rather than another `extension Data` so it cannot collide with the voting
    /// one when that flavor IS built.
    private static func decodeHex(_ hexString: String) -> Data {
        var data = Data()
        var hex = hexString
        while hex.count >= 2 {
            let byteString = String(hex.prefix(2))
            hex = String(hex.dropFirst(2))
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            }
        }
        return data
    }
}
