//
//  RecoveryPhraseDisplayTests.swift
//  zodlTests
//
//  Created by Michal Fousek on 12.06.2026.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

/// Covers MOB-1363: seed words may be loaded into `RecoveryPhraseDisplay` state only
/// after a successful local authentication, and must be purged from the state again
/// whenever the phrase is hidden.
@Suite struct RecoveryPhraseDisplayTests {
    @MainActor @Test func onAppearDoesNotLoadSeed() async {
        let store = TestStore(
            initialState: .initial
        ) {
            RecoveryPhraseDisplay()
        }
        // `walletStorage` is intentionally left unimplemented: any `exportWallet`
        // call before a successful authentication fails this test.

        await store.send(.onAppear)

        await store.finish()
    }

    @MainActor @Test func revealDeniedWhenAuthenticationFails() async {
        let store = TestStore(
            initialState: .initial
        ) {
            RecoveryPhraseDisplay()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationFailed
        }
        // `walletStorage` is intentionally left unimplemented: any `exportWallet`
        // call after a failed authentication fails this test.

        await store.send(.recoveryPhraseUnhideRequested)

        await store.finish()
    }

    @MainActor @Test func revealLoadsSeedOnlyAfterSuccessfulAuthentication() async {
        let store = TestStore(
            initialState: .initial
        ) {
            RecoveryPhraseDisplay()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.walletStorage.exportWallet = { StoredWallet.placeholder }
        }

        await store.send(.recoveryPhraseUnhideRequested)

        await store.receive(.recoveryPhraseRevealed) {
            $0.birthday = StoredWallet.placeholder.birthday
            $0.birthdayValue = "0"
            $0.phrase = RecoveryPhrase.placeholder
            $0.isRecoveryPhraseHidden = false
        }

        await store.finish()
    }

    @MainActor @Test func hidePurgesSeedFromState() async {
        var revealedState = RecoveryPhraseDisplay.State.initial
        revealedState.birthday = StoredWallet.placeholder.birthday
        revealedState.birthdayValue = "0"
        revealedState.phrase = RecoveryPhrase.placeholder
        revealedState.isRecoveryPhraseHidden = false

        let store = TestStore(
            initialState: revealedState
        ) {
            RecoveryPhraseDisplay()
        }

        await store.send(.hideEverything) {
            $0.birthday = nil
            $0.birthdayValue = nil
            $0.phrase = nil
            $0.isRecoveryPhraseHidden = true
        }

        await store.finish()
    }

    @MainActor @Test func onAppearPurgesSeedFromState() async {
        var revealedState = RecoveryPhraseDisplay.State.initial
        revealedState.birthday = StoredWallet.placeholder.birthday
        revealedState.birthdayValue = "0"
        revealedState.phrase = RecoveryPhrase.placeholder
        revealedState.isRecoveryPhraseHidden = false

        let store = TestStore(
            initialState: revealedState
        ) {
            RecoveryPhraseDisplay()
        }

        await store.send(.onAppear) {
            $0.birthday = nil
            $0.birthdayValue = nil
            $0.phrase = nil
            $0.isRecoveryPhraseHidden = true
        }

        await store.finish()
    }
}
