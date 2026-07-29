//
//  MigrationSendingView.swift
//  zodl
//
//  "Sending" / "Sent" screen (MOB-1463, Figma S8 · sending 2618:6858 / sent 2618:6895). `onAppear`
//  drives the store's sequential transfer execution (MOB-1466). The `closeTapped` /
//  `viewTransactionTapped` delegates (`.closed` / `.viewTransaction`) are consumed by
//  `MigrationCoordFlowCoordinator` and `RootCoordinator` respectively (phase 3).
//
//  Also reused for the "Migrate anyway" dust lane (MOB-1487). MOB-1494 (round 4): every lane
//  shows the same "migrated" subtitles (the canvas dropped the "sent" wording), so the view has
//  no per-lane copy switching any more.
//
//  MOB-1497 (T8, Q3'26 canvas): per-lane copy switching is back for exactly one string — the
//  success subtitle now reads `store.sentSubtitle` (`MigrationSending.State`'s own selection
//  between the "sent"/"migrated" wording, keyed off `isManualStepLane`) instead of the hardcoded
//  `migrationSendingSentSubtitleMigrated` key. The title stays the unconditional "Sent!"
//  (`migrationSendingSentTitle`) in every lane.
//
//  R8-T6: a third phase, `.waiting(target:)`, appears only on the Status screen's "Send now" lane
//  (`entersViaSendNow`) — the app-side privacy gate wasn't clear yet, so sync is held stopped and
//  the screen counts down to `target` instead of showing the sending animation. A live countdown
//  (`Text(timerInterval:)`, native SwiftUI — no store-side ticking) plus a Cancel affordance that
//  resumes sync without sending anything.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

import Lottie

struct MigrationSendingView: View {
    private enum Constants {
        static let lottieNameLight = "sending"
        static let lottieNameDark = "sending-dark"
    }

    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<MigrationSending>

    init(store: StoreOf<MigrationSending>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            content
                .navigationBarBackButtonHidden()
                .zashiSheet(isPresented: $store.isFailurePresented) {
                    // PHASE 2: always the GENERIC (`nil`) arm — #1930's R14-R17 classified routes
                    // (`store.failureKind`, "Proceed without Tor", "Broadcast via sync server") and
                    // their Tor off-warning alert arrive with the failure routing in Phase 5. The
                    // sheet itself is #1930's, unchanged; only these inputs are stubbed.
                    MigrationBroadcastFailureSheetView(
                        failureKind: nil,
                        cancelTapped: { store.send(.cancelTapped) },
                        proceedWithoutTorTapped: { },
                        retryTapped: { store.send(.retryTapped) },
                        useSyncServerTapped: { }
                    )
                }
        }
        .onAppear {
            store.send(.onAppear)
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .sending:
            sendingContent
                .screenHorizontalPadding()
                .applyScreenBackground()

        case .success:
            successContent
                .padding(.vertical, 1)
                .screenHorizontalPadding()
                .applySuccessScreenBackground()
        }
    }

    // MARK: - Sending

    @ViewBuilder private var sendingContent: some View {
        VStack(spacing: 0) {
            LottieView(
                animation:
                    .named(colorScheme == .light ? Constants.lottieNameLight : Constants.lottieNameDark)
            )
            .resizable()
            .looping()
            .frame(width: 170, height: 170)

            Text(localizable: .migrationSendingTitle)
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
                .padding(.top, 16)

            Text(localizable: .migrationSendingSubtitleMigrated)
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
        }
    }

    // PHASE 2: #1930's `.waiting` silence-window content is removed with the send-now lane it
    // belongs to (Phase 3). Restore it together with `MigrationSending.State.Phase.waiting`.

    // MARK: - Success

    @ViewBuilder private var successContent: some View {
        VStack(spacing: 0) {
            Spacer()

            Asset.Assets.Illustrations.success1.image
                .resizable()
                .frame(width: 148, height: 148)

            Text(localizable: .migrationSendingSentTitle)
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
                .padding(.top, 16)

            Text(store.sentSubtitle)
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .padding(.top, 8)

            ZashiButton(
                String(localizable: .sendViewTransaction),
                type: .tertiary,
                infinityWidth: false
            ) {
                store.send(.viewTransactionTapped)
            }
            .padding(.top, 16)

            Spacer()

            ZashiButton(String(localizable: .generalClose)) {
                store.send(.closeTapped)
            }
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Previews

#Preview("Sending") {
    NavigationView {
        MigrationSendingView(
            store: StoreOf<MigrationSending>(
                initialState: MigrationSending.State(phase: .sending)
            ) {
                MigrationSending()
            }
        )
    }
}

#Preview("Success") {
    NavigationView {
        MigrationSendingView(
            store: StoreOf<MigrationSending>(
                initialState: MigrationSending.State(phase: .success, txId: "e87f1234567890abcdef6f28b")
            ) {
                MigrationSending()
            }
        )
    }
}

#Preview("Sending + failure sheet") {
    NavigationView {
        MigrationSendingView(
            store: StoreOf<MigrationSending>(
                initialState: MigrationSending.State(phase: .sending, isFailurePresented: true)
            ) {
                MigrationSending()
            }
        )
    }
}
