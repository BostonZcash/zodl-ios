//
//  AccountBalanceExtensions.swift
//  secant
//
//  Created by Michal Fousek on 26.07.2026.
//

import Foundation
@preconcurrency import ZcashLightClientKit

extension AccountBalance {
    /// The spendable value summed across every shielded pool (Sapling, Orchard,
    /// Ironwood). Prefer this over summing pools at call sites — a new shielded
    /// pool then flows through automatically.
    public var shieldedSpendableValue: Zatoshi {
        saplingBalance.spendableValue + orchardBalance.spendableValue + ironwoodBalance.spendableValue
    }

    /// The total value (spendable + pending change + pending spendability) summed
    /// across every shielded pool.
    public func shieldedTotal() -> Zatoshi {
        saplingBalance.total() + orchardBalance.total() + ironwoodBalance.total()
    }

    /// The change pending confirmation, summed across every shielded pool.
    public var shieldedChangePendingConfirmation: Zatoshi {
        saplingBalance.changePendingConfirmation + orchardBalance.changePendingConfirmation
        + ironwoodBalance.changePendingConfirmation
    }

    /// The value pending spendability, summed across every shielded pool.
    public var shieldedValuePendingSpendability: Zatoshi {
        saplingBalance.valuePendingSpendability + orchardBalance.valuePendingSpendability
        + ironwoodBalance.valuePendingSpendability
    }
}
