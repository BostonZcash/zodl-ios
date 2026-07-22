import Testing
@testable import zodl_internal

@Suite struct WalletDatabaseSeedReconcileTests {
    @Test func relevantSeedSkipsWipeAndReprepare() async throws {
        let recorder = CallRecorder()
        let healed = try await Root.reconcileWalletDatabaseWithSeed(
            seedBytes: [1, 2, 3],
            isSeedRelevant: { _ in true },
            wipe: { await recorder.record("wipe") },
            reprepare: { await recorder.record("reprepare") }
        )
        #expect(healed == false)
        let calls = await recorder.calls
        #expect(calls.isEmpty, "wipe/reprepare must never run when the seed is already relevant")
    }

    @Test func irrelevantSeedWipesBeforeRepreparingAndReturnsTrue() async throws {
        let recorder = CallRecorder()
        let healed = try await Root.reconcileWalletDatabaseWithSeed(
            seedBytes: [1, 2, 3],
            isSeedRelevant: { _ in false },
            wipe: { await recorder.record("wipe") },
            reprepare: { await recorder.record("reprepare") }
        )
        #expect(healed == true)
        let calls = await recorder.calls
        #expect(calls == ["wipe", "reprepare"], "wipe must complete before reprepare starts")
    }

    @Test func isSeedRelevantFailureRethrowsAndNeverWipes() async {
        let recorder = CallRecorder()
        await #expect(throws: ReconcileTestError.boom) {
            try await Root.reconcileWalletDatabaseWithSeed(
                seedBytes: [1, 2, 3],
                isSeedRelevant: { _ in throw ReconcileTestError.boom },
                wipe: { await recorder.record("wipe") },
                reprepare: { await recorder.record("reprepare") }
            )
        }
        let calls = await recorder.calls
        #expect(calls.isEmpty, "An indeterminate isSeedRelevant answer must never trigger a wipe")
    }

    @Test func wipeFailureRethrowsAndNeverReprepares() async {
        let recorder = CallRecorder()
        await #expect(throws: ReconcileTestError.boom) {
            try await Root.reconcileWalletDatabaseWithSeed(
                seedBytes: [1, 2, 3],
                isSeedRelevant: { _ in false },
                wipe: { throw ReconcileTestError.boom },
                reprepare: { await recorder.record("reprepare") }
            )
        }
        let calls = await recorder.calls
        #expect(calls.isEmpty, "reprepare must never run when wipe throws")
    }

    @Test func reprepareFailureRethrows() async {
        await #expect(throws: ReconcileTestError.boom) {
            try await Root.reconcileWalletDatabaseWithSeed(
                seedBytes: [1, 2, 3],
                isSeedRelevant: { _ in false },
                wipe: { },
                reprepare: { throw ReconcileTestError.boom }
            )
        }
    }
}

private enum ReconcileTestError: Error, Equatable {
    case boom
}

private actor CallRecorder {
    private(set) var calls: [String] = []
    func record(_ name: String) { calls.append(name) }
}
