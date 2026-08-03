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
//  D3 (Figma 5217:36636): the thing the gate guards CHANGED — a non-manual account's Send now no
//  longer pushes the Sending screen; the store runs the silence window + the manager's own
//  broadcast session IN PLACE, and only a MANUAL-delivery account still delegates to the
//  coordinator's push (the session refuses to press Send for manual accounts by contract). Every
//  pin above survives, re-arranged onto the new lane: auth still stands between the tap and the
//  thing that broadcasts — which is now `runBroadcastSession`, spied directly here, a stronger pin
//  than the delegate proxy the old arrangement had to settle for.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationSendNowAuthTests {
    /// One overdue row — the state the `.resume` presentation exists for, and what arms the CTA.
    private static var overdueRows: IdentifiedArrayOf<MigrationTransferRow> {
        [MigrationTransferRow(id: "1", index: 0, amount: nil, status: .overdue, hoursFromNow: 0)]
    }

    /// `.testValue` base on purpose: quiet reads, LOUD money movers — an un-stubbed
    /// `runBroadcastSession` reached by any test here is an attempted real submission and fails by
    /// name, which is exactly the canary the refused-auth pin below leans on.
    private static func store(
        authenticates: Bool,
        client: MigrationManagerClient = .testValue,
        exhaustive: Bool = false
    ) -> TestStoreOf<MigrationStatus> {
        var state = MigrationStatus.State(presentation: .resume)
        state.rows = overdueRows
        let store = TestStore(initialState: state) {
            MigrationStatus()
        } withDependencies: {
            $0.localAuthentication = authenticates ? .mockAuthenticationSucceeded : .mockAuthenticationFailed
            $0.mainQueue = .immediate
            $0.migrationManager = client
            $0.sdkSynchronizer = .mocked()
        }
        if !exhaustive {
            store.exhaustivity = .off
        }
        return store
    }

    /// THE requirement, in-place arm — the full pinned chain, EXHAUSTIVELY: tap -> auth ->
    /// window-clear -> the manager session -> finished -> reload, with the manager called exactly
    /// once and `.delegate(.sendNow)` provably never sent (an exhaustive store fails on any
    /// unasserted received action, so the delegate's absence is asserted by the whole test).
    @Test func anAuthenticatedTapOnANonManualAccountSendsInPlace() async {
        let sessionCalls = LockIsolated(0)
        var client = MigrationManagerClient.testValue
        client.isManualDelivery = { _ in false }
        client.runBroadcastSession = {
            sessionCalls.withValue { $0 += 1 }
            return true
        }
        let store = Self.store(authenticates: true, client: client, exhaustive: true)

        await store.send(.sendNowTapped)
        await store.receive(.sendNowAuthenticated) {
            $0.isSendNowInFlight = true
        }
        await store.receive(.sendNowWindowCleared)
        await store.receive(.sendNowFinished(didBroadcast: true)) {
            $0.isSendNowInFlight = false
        }
        // `.sendNowFinished`'s reload — rows come back per the stubbed reads (empty), which is the
        // channel a landed broadcast's `.confirming` row arrives on in production.
        await store.receive(.statusLoaded(rows: [], totalDurationHours: nil, syncPrivacyBufferMinutes: 0, isTorHoldActive: false)) {
            $0.rows = []
        }

        #expect(sessionCalls.value == 1, "one tap, one session — the manager's own re-entrancy guard is the second line, not the first")
    }

    /// The MANUAL-delivery arm: the one account kind that still delegates — `runBroadcastSession`
    /// refuses to press Send for a manual account by contract, so the coordinator's dedicated
    /// Sending-screen push is the only lane that can serve the tap. Auth still gates the delegate,
    /// exactly as it always did.
    @Test func aManualDeliveryAccountStillDelegatesAfterAuth() async {
        var client = MigrationManagerClient.testValue
        client.isManualDelivery = { _ in true }
        let store = Self.store(authenticates: true, client: client)

        await store.send(.sendNowTapped)
        await store.receive(.sendNowAuthenticated)
        await store.receive(.delegate(.sendNow))
    }

    /// Refused or cancelled: nothing runs — no delegate, no session. The `.testValue` base is the
    /// loud half of this pin: if a refused authentication ever reached the submit, the
    /// un-stubbed `runBroadcastSession` fails the test by name.
    @Test func aRefusedAuthenticationSendsNothing() async {
        let store = Self.store(authenticates: false)

        await store.send(.sendNowTapped)
        await store.finish()

        #expect(!store.state.isSendNowInFlight, "a refused auth must not arm the in-flight flag either")
    }

    /// D3: the R8-T6 silence window SURVIVES the modal's death — a `.waitUntil` gate holds the
    /// session un-run (CTA down, nothing broadcast) until the target passes, and only then does
    /// the manager submit. This is the pin that keeps "kill the blocking screen" from quietly
    /// becoming "kill the privacy buffer".
    @Test func aClosedGateHoldsTheSessionUntilTheWindowClears() async {
        let sessionCalls = LockIsolated(0)
        let testClock = TestClock<Swift.Duration>()
        var client = MigrationManagerClient.testValue
        client.isManualDelivery = { _ in false }
        client.sendGate = { .waitUntil(Date(timeIntervalSinceNow: 300)) }
        client.runBroadcastSession = {
            sessionCalls.withValue { $0 += 1 }
            return true
        }
        let store = TestStore(initialState: {
            var state = MigrationStatus.State(presentation: .resume)
            state.rows = Self.overdueRows
            return state
        }()) {
            MigrationStatus()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.mainQueue = .immediate
            $0.continuousClock = testClock
            $0.migrationManager = client
            $0.sdkSynchronizer = .mocked()
        }
        store.exhaustivity = .off

        await store.send(.sendNowTapped)
        await store.receive(.sendNowAuthenticated)
        #expect(store.state.isSendNowInFlight, "the CTA is down for the whole wait, not just the submit")

        // Let the wait effect reach its sleep before advancing the clock — an advance with no
        // suspended sleeper resumes nothing (same real-time yield the refresh-pulse suite uses).
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(sessionCalls.value == 0, "nothing may broadcast while the privacy buffer is live")

        await testClock.advance(by: .seconds(301))
        await store.receive(.sendNowWindowCleared)
        await store.receive(.sendNowFinished(didBroadcast: true))
        #expect(sessionCalls.value == 1, "the session runs exactly once, after the window clears")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// D3: leaving the screen mid-wait cancels the un-started send — the old lane's Cancel
    /// contract ("nothing broadcasts"), now carried by `.onDisappear` since the wait no longer has
    /// a screen of its own to cancel from. Only the WAIT is cancellable; a session already past it
    /// runs to completion (pinned implicitly by the previous test's uncancelled submit).
    @Test func leavingTheScreenMidWaitCancelsTheSend() async {
        let sessionCalls = LockIsolated(0)
        let testClock = TestClock<Swift.Duration>()
        var client = MigrationManagerClient.testValue
        client.isManualDelivery = { _ in false }
        client.sendGate = { .waitUntil(Date(timeIntervalSinceNow: 300)) }
        client.runBroadcastSession = {
            sessionCalls.withValue { $0 += 1 }
            return true
        }
        let store = TestStore(initialState: {
            var state = MigrationStatus.State(presentation: .resume)
            state.rows = Self.overdueRows
            return state
        }()) {
            MigrationStatus()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.mainQueue = .immediate
            $0.continuousClock = testClock
            $0.migrationManager = client
            $0.sdkSynchronizer = .mocked()
        }
        store.exhaustivity = .off

        await store.send(.sendNowTapped)
        await store.receive(.sendNowAuthenticated)
        try? await Task.sleep(nanoseconds: 200_000_000)

        await store.send(.onDisappear)
        await testClock.advance(by: .seconds(600))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(sessionCalls.value == 0, "a wait the user walked away from must never turn into a broadcast")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
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

@Suite(.serialized) @MainActor struct MigrationSendNowMutualExclusionTests {
    /// Field-caught: the reschedule spinner disabled its own button and left "Send now" live, so a
    /// user could ask the engine to move a transfer's window and to broadcast it at the same time.
    /// Two operations, one transaction, and the outcome decided by effect ordering.
    @Test func sendNowIsDisabledWhileRescheduling() {
        var state = MigrationStatus.State(presentation: .resume)
        state.rows = [
            MigrationTransferRow(id: "1", index: 0, amount: nil, status: .overdue, hoursFromNow: 0)
        ]

        #expect(!state.isSendNowDisabled, "an overdue row makes Send now available")

        state.isRescheduling = true
        #expect(state.isSendNowDisabled, "…until a reschedule is in flight for that same transfer")
    }

    /// D3: the same exclusion, pointing the other way — the old lane got it for free by leaving
    /// the screen; staying in place means both CTAs are visible while a send runs, so both must be
    /// down for the run's whole span (wait + submit).
    @Test func bothCTAsAreDisabledWhileAnInPlaceSendRuns() {
        var state = MigrationStatus.State(presentation: .resume)
        state.rows = [
            MigrationTransferRow(id: "1", index: 0, amount: nil, status: .overdue, hoursFromNow: 0)
        ]

        #expect(!state.isSendNowDisabled, "an overdue row makes Send now available")
        #expect(!state.isRescheduleDisabled, "and reschedule with it")

        state.isSendNowInFlight = true
        #expect(state.isSendNowDisabled, "an in-place send disables its own CTA…")
        #expect(state.isRescheduleDisabled, "…and reschedule, which would race it over the same transaction")
    }
}
