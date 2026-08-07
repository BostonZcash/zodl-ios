//
//  MigrationPoolTruthTests.swift
//  zodlTests
//
//  MOB-1661: displayed pool balances come only from the SDK's wallet summary. Migration engine
//  states describe pending work; using them to infer pool movement caused exact transfer-sized
//  regressions while a transaction was Sent but not yet Done.
//

import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationPoolTruthTests {
    /// Proving advisory-locks source notes without moving them out of Orchard. Production passes
    /// `orchardBalance.total()`, so the complete pool value must remain visible.
    @Test func provedAdvisoryLocksRemainInDisplayedOrchardBalance() {
        let unlocked = Zatoshi(2_542_665_000)
        let advisoryLocked = Zatoshi(7_452_000_000)

        let displayed = MigrationDerivations.poolBalancesForDisplay(
            orchard: unlocked + advisoryLocked,
            ironwood: .zero
        )

        #expect(displayed.orchard == Zatoshi(9_994_665_000))
        #expect(displayed.ironwood == .zero)
    }

    /// Field regression: with transfers 1–5 Done, the wallet summary reported 7.22845 Orchard and
    /// 2.77 Ironwood. Transfer 6 entering Sent must not temporarily reverse its 2 ZEC movement.
    @Test func sentTransferDoesNotRegressCompletedPoolValue() {
        let orchard = Zatoshi(722_845_000)
        let ironwood = Zatoshi(277_000_000)

        let displayed = MigrationDerivations.poolBalancesForDisplay(
            orchard: orchard,
            ironwood: ironwood
        )

        #expect(displayed.orchard == orchard)
        #expect(displayed.ironwood == ironwood)
        #expect(displayed.orchard + displayed.ironwood == Zatoshi(999_845_000))
    }

    /// Original field report: a 99.99665 TAZ Orchard wallet must not gain the sum of proved or
    /// broadcast plan rows. No transfer-status input exists in this display policy.
    @Test func pendingMigrationCannotCreatePoolSurplus() {
        let walletOrchard = Zatoshi(9_999_665_000)

        let displayed = MigrationDerivations.poolBalancesForDisplay(
            orchard: walletOrchard,
            ironwood: .zero
        )

        #expect(displayed.orchard == walletOrchard)
        #expect(displayed.orchard + displayed.ironwood == walletOrchard)
    }
}
