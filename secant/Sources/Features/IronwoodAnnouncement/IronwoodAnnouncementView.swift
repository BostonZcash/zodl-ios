//
//  IronwoodAnnouncementView.swift
//  Zashi
//
//  Created by Michal Fousek on 25.07.2026.
//

// This screen is intentionally minimal. Final copy and artwork for the Ironwood
// announcement are still pending, so this is a placeholder layout built entirely
// from existing design-system pieces (title, body, and the two footer buttons).

import SwiftUI
import ComposableArchitecture

// PLACEHOLDER. This is the Ironwood support article used elsewhere in the app; it is
// about moving funds, not the general Ironwood news. Swap it for the real FAQ/news
// article when that exists.
private let ironwoodAnnouncementFAQURL = "https://support.zodl.com/article/42-moving-your-funds-to-ironwood"

struct IronwoodAnnouncementView: View {
    @Perception.Bindable var store: StoreOf<IronwoodAnnouncement>

    init(store: StoreOf<IronwoodAnnouncement>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .ironwoodAnnouncementTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)

                Text(localizable: .ironwoodAnnouncementBody)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 12)

                Spacer()

                ZashiButton(String(localizable: .ironwoodAnnouncementLearnMore), type: .tertiary) {
                    store.send(.learnMoreTapped)
                }
                .padding(.bottom, 8)

                ZashiButton(String(localizable: .ironwoodAnnouncementContinue)) {
                    store.send(.continueTapped)
                }
                .padding(.bottom, 24)
            }
            .sheet(isPresented: $store.isInAppBrowserOn) {
                if let url = URL(string: ironwoodAnnouncementFAQURL) {
                    InAppBrowserView(url: url)
                }
            }
        }
        .navigationBarHidden(true)
        .screenHorizontalPadding()
        .applyScreenBackground()
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        IronwoodAnnouncementView(store: IronwoodAnnouncement.initial)
    }
}

// MARK: - Store

extension IronwoodAnnouncement {
    @MainActor static let initial = StoreOf<IronwoodAnnouncement>(
        initialState: .initial
    ) {
        IronwoodAnnouncement()
    }
}

// MARK: - Placeholders

extension IronwoodAnnouncement.State {
    static let initial = IronwoodAnnouncement.State()
}
