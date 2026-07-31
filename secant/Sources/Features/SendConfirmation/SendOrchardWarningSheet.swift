//
//  SendOrchardWarningSheet.swift
//  zodl
//
//  "This send requires spending Orchard funds" (Figma 5139:23856) — shown over the send
//  Confirmation screen when the built proposal would spend from the Orchard pool while a migration
//  is scheduled.
//
//  Why it exists: the migration's whole point is that pool crossings are individually timed and
//  denominated so their amounts are not linkable. An ordinary manual send that dips into Orchard
//  crosses the turnstile on the user's schedule, in the user's amount — leaking exactly what the
//  migration is spending days hiding. So the user is told before they spend, not after.
//
//  Note the button weights, which are deliberate and inverted from the usual confirm sheet: Cancel
//  is the PRIMARY (dark) button and Send is the destructive one. The design nudges toward backing
//  out; sending anyway stays one tap away, never removed.
//
//  A plain `View`, holding no state — presented through `zashiSheet` by whoever owns the send
//  confirmation, matching `MigrationBroadcastFailureSheetView`.
//
//  PRESENTED by `SendConfirmation`, before authentication rather than after — the sheet asks the
//  user to reconsider WHETHER to send, and asking that after Face ID reads as too late.
//
//  Its trigger is an approximation. The precise question, "does THIS proposal spend Orchard?", is
//  one the SDK cannot answer today (`Proposal` exposes only a transaction count and a fee), so the
//  app asks the coarser one it can: is a run live, and is there unmigrated Orchard left to reach?
//  See `MigrationManualSendRisk` for why over-warning is the right side to err on here — and why
//  that is the opposite call from the server-switch warning (board A20).
//

import SwiftUI

struct SendOrchardWarningSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    let sendAnywayTapped: () -> Void
    let cancelTapped: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(String(localizable: .sendOrchardWarningTitle))
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Text(String(localizable: .sendOrchardWarningBody))
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(String(localizable: .generalSend), type: .destructive2) {
                sendAnywayTapped()
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .generalCancel)) {
                cancelTapped()
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

// MARK: - Previews

#Preview {
    SendOrchardWarningSheet(sendAnywayTapped: { }, cancelTapped: { })
        .screenHorizontalPadding()
}

#Preview("Dark") {
    SendOrchardWarningSheet(sendAnywayTapped: { }, cancelTapped: { })
        .screenHorizontalPadding()
        .preferredColorScheme(.dark)
}
