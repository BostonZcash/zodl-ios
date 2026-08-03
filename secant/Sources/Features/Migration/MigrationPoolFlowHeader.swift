//
//  MigrationPoolFlowHeader.swift
//  zodl
//
//  ORCHARD → IRONWOOD at the top of the Migration Progress screen, above the transfer timeline
//  (Figma 5139-34627, final): one horizontally-split card — source pool on the left, destination
//  on the right, an arrow between — each side carrying its pool name, its ZEC amount, and (when
//  an exchange rate is known) its fiat value.
//
//  GROUND_RULES R9: a bubble labelled with a pool name may only show the wallet's REAL per-pool
//  balance — "if pool X has Y zec, must use Y" — the same source the home balance sheet reads.
//  Earlier cuts failed in both available directions: the live balance under broadcast-green
//  checkmarks read 55.2-vs-0 in the field, and plan-derived green-sums contradicted the home
//  sheet. The values were never the problem — the GREEN was early. R11 fixed the green, so the
//  real balances render here gate-free: they are passed in, and the component computes nothing.
//
//  No render gate is needed for header/checkmark agreement: R11 makes a green check
//  WALLET-confirmed (a broadcast-but-uncounted row stays the neutral check — see
//  `MigrationTransferTimeline`), so the sync write that turns a row green is the same one that
//  moves the balances shown here. Header and checkmarks move together by construction, not by
//  reconciliation.
//

@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationPoolFlowHeader: View {
    /// Resolved per render and passed to every `.color(_:)` — never a hardcoded `.light`. The
    /// first pool header pinned its bubble fills to light mode while `zFont` resolved text against
    /// the real appearance, which made dark mode unreadable; the token carries both values, the
    /// caller supplies the appearance.
    @Environment(\.colorScheme) private var colorScheme

    /// What is still in Orchard — the wallet's own per-pool balance, passed in (R9).
    let orchardRemaining: Zatoshi
    /// What has landed in Ironwood — same source, same sync write as the green checks (R11).
    let ironwoodHeld: Zatoshi
    /// Fiat line under each ZEC value; nil rate hides BOTH fiat lines (never "$0.00" from a
    /// missing rate).
    let currencyConversion: CurrencyConversion?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            poolColumn(
                name: String(localizable: .migrationPoolOrchard),
                amount: orchardRemaining,
                isSource: true
            )

            Asset.Assets.Icons.arrowRight.image
                .zImage(size: 16, style: Design.Text.tertiary)

            poolColumn(
                name: String(localizable: .migrationPoolIronwood),
                amount: ironwoodHeld,
                isSource: false
            )
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    /// Both columns claim equal flexible width, which pins the arrow between them to the card's
    /// true center regardless of how long either amount renders. The source column leads, the
    /// destination trails, per the frame.
    @ViewBuilder private func poolColumn(name: String, amount: Zatoshi, isSource: Bool) -> some View {
        VStack(alignment: isSource ? .leading : .trailing, spacing: 2) {
            Text(name)
                .zFont(size: 12, style: Design.Text.tertiary)

            // Same formatter as the timeline rows below this card (`MigrationTransferTimeline`),
            // so an amount reads identically in both places.
            Text("\(amount.decimalString()) ZEC")
                .zFont(.semiBold, size: 18, style: Design.Text.primary)

            if let currencyConversion {
                Text(currencyConversion.convert(amount))
                    .zFont(size: 12, style: Design.Text.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: isSource ? .leading : .trailing)
    }
}

// MARK: - Previews

#Preview("Mid-migration") {
    // Ratio picked so 12.45 ZEC reads $6,903.84 — the Figma frame's values.
    MigrationPoolFlowHeader(
        orchardRemaining: Zatoshi(1_245_000_000),
        ironwoodHeld: Zatoshi(0),
        currencyConversion: CurrencyConversion(.usd, ratio: 554.525, timestamp: 0)
    )
    .screenHorizontalPadding()
}

#Preview("No exchange rate") {
    MigrationPoolFlowHeader(
        orchardRemaining: Zatoshi(820_000_000),
        ironwoodHeld: Zatoshi(425_000_000),
        currencyConversion: nil
    )
    .screenHorizontalPadding()
}
