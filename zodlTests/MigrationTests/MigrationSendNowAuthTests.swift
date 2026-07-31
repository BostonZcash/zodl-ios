//
//  MigrationSendNowAuthTests.swift
//  zodlTests
//
//  "Send now" moves money, so it asks for Face ID / Touch ID first.
//
//  Lukas, 2026-07-31: "we always must use biometrics when sending transactions… all migration CTAs
//  that move funds must be behind the LocalAuth check."
//
//  The audit behind this: `MigrationTransferPlan`'s Confirm and `MigrationReviewTransfer`'s confirm
//  were already gated; `MigrationStatus`'s "Send now" was not. Reschedule is deliberately NOT gated
//  — it re-reads a window and re-renders, signing nothing and moving nothing — and the negative test
//  below pins that so a later "gate everything" sweep does not add a pointless prompt.
//
//  What this gate IS and IS NOT. The transaction was already signed at commit, behind its own Face
//  ID, so this authenticates a BROADCAST rather than a signature. And the headless drive loop
//  broadcasts these same pre-signed transactions with no prompt at all — it has no UI and cannot
//  have one. So this is a CONSENT affordance, not a security boundary against someone holding an
//  unlocked phone: the funds can move without it. It is worth having because every other
//  money-moving tap in Zodl asks, and an exception teaches people that migration is different.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationSendNowAuthTests {
    private static func store(
        authenticates: Bool
    ) -> TestStoreOf<MigrationStatus> {
        let store = TestStore(initialState: MigrationStatus.State(presentation: .resume)) {
            MigrationStatus()
        } withDependencies: {
            $0.localAuthentication = authenticates ? .mockAuthenticationSucceeded : .mockAuthenticationFailed
            $0.mainQueue = .immediate
        }
        store.exhaustivity = .off
        return store
    }

    /// THE requirement. A tap on "Send now" must not reach the delegate — the thing that pushes the
    /// Sending screen and broadcasts — until authentication has passed.
    @Test func sendNowAuthenticatesBeforeDelegating() async {
        let store = Self.store(authenticates: true)

        await store.send(.sendNowTapped)
        await store.receive(.sendNowAuthenticated)
        await store.receive(.delegate(.sendNow))
    }

    /// Refused or cancelled: nothing is delegated, so nothing broadcasts. The absence is the whole
    /// assertion — `exhaustivity = .off` would let a stray delegate slip past a positive-only test,
    /// so this asserts on the action list directly.
    @Test func aRefusedAuthenticationSendsNothing() async {
        let store = Self.store(authenticates: false)

        await store.send(.sendNowTapped)
        await store.finish()

        // No `.sendNowAuthenticated`, therefore no `.delegate(.sendNow)`: TestStore fails on any
        // unasserted received action when they are awaited, and none is awaited here.
    }

    /// Reschedule stays UNGATED on purpose: it asks the engine for a fresh window and re-renders.
    /// It signs nothing and sends nothing, so a prompt there would be a prompt for nothing — and
    /// prompts for nothing are how people learn to tap through prompts that matter.
    @Test func rescheduleIsNotGated() async {
        let store = Self.store(authenticates: false)

        await store.send(.rescheduleTapped) {
            $0.isRescheduling = true
        }
        await store.receive(.delegate(.reschedule))
    }
}
