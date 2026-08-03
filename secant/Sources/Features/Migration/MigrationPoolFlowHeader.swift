//
//  MigrationPoolFlowHeader.swift
//  Zodl
//
//  ORCHARD → IRONWOOD, at the top of the migration screen (goal #6, MOB-1466).
//
//  WHY. "Transfer 1 · 2 ZEC · done" is text. It tells the user a step finished; it does not show
//  them their money arriving. The only place funds were visibly in two pools was a sheet behind a
//  tap on the home balance — so the screen dedicated to moving funds between pools was the one
//  screen that never showed the pools.
//
//  WHY IT WAITED FOR THE SNAPSHOT. This header makes a claim the timeline also makes: the
//  checkmarks add up to what is in Ironwood. Built as its own reader it would have been a THIRD
//  independent derivation — banner, screen, header — each right at a different instant, which is
//  precisely the failure mode the rest of this work has been unpicking. It reads
//  `MigrationViewSnapshot`, so its number and the checkmarks come from one pass and cannot drift.
//
//  Validated before it was built: on the 08-02 field wallet the DONE crossings summed to
//  949,000,000 zatoshi and the Ironwood pool held 949,000,000 — exact. What the user saw as a
//  miscount was a SETTLING LAG: the engine flips a row done from its own tables the moment a
//  transfer mines, while the wallet's pool balance moves only when a sync writes it. So this header
//  SAYS SO (`isPoolFlowSettled`) rather than hiding the gap or waiting for it — the honest option,
//  and the one consistent with everything else in this pass.
//
//  [needs-design] Figma 5139-33095 carries no pool header; this composition is proposed, not
//  specified. Shapes and spacing follow the surrounding migration screens. Show Andrea.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationPoolFlowHeader: View {
    let snapshot: MigrationViewSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                poolBubble(
                    name: String(localizable: .migrationPoolOrchard),
                    amount: snapshot.orchardRemaining,
                    isSource: true
                )

                Asset.Assets.Icons.arrowRight.image
                    .zImage(size: 16, style: Design.Text.tertiary)

                poolBubble(
                    name: String(localizable: .migrationPoolIronwood),
                    amount: snapshot.ironwoodHeld,
                    isSource: false
                )
            }

            // The lag, named rather than hidden — see the file note. Only while the destination
            // trails the checkmarks; a settled run says nothing extra.
            if !snapshot.isPoolFlowSettled {
                Text(localizable: .migrationStatusUpdating)
                    .zFont(size: 12, style: Design.Text.tertiary)
            }
        }
        .padding(.bottom, 20)
    }

    @ViewBuilder private func poolBubble(name: String, amount: Zatoshi, isSource: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .zFont(size: 12, style: Design.Text.tertiary)

            Text("\(amount.decimalString()) ZEC")
                .zFont(.semiBold, size: 16, style: Design.Text.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12)
                // The destination is the one the user is watching fill, so it carries the emphasis;
                // the source is draining and deliberately reads quieter.
                .fill(isSource
                    ? Design.Surfaces.bgSecondary.color(.light)
                    : Design.Surfaces.bgTertiary.color(.light))
        }
    }
}
