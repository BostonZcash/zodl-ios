//
//  KeystoneFirmwareTests.swift
//  zodlTests
//
//  Covers MOB-1510 (Keystone minimum-firmware check): the `Data.keystoneFirmwareVersion()`
//  byte-scan reader, `KeystoneFirmwareVersion`'s `Comparable` conformance, and the
//  `SendConfirmationStore` gate at `.foundPCZT` that blocks below-minimum/unstamped firmware
//  before `createTransactionFromPCZT` ever schedules.
//
//  The reader/Comparable suites are pure and dependency-free, so they run unserialized; see
//  `KeystoneFirmwareGateTests` below for why the gate suite needs more than that.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// MARK: - Data.keystoneFirmwareVersion() reader

@Suite struct KeystoneFirmwareVersionReaderTests {
    private static let key = Array("keystone:fw_version".utf8)

    @Test func stampedVersionAtMinimumParses() {
        var data = Data([0x00, 0x01])
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 3, 0, 1])

        #expect(data.keystoneFirmwareVersion() == KeystoneFirmwareVersion(major: 3, minor: 0, build: 1))
    }

    @Test func stampedVersionBelowMinimumParses() {
        var data = Data()
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 2, 4, 6])

        #expect(data.keystoneFirmwareVersion() == KeystoneFirmwareVersion(major: 2, minor: 4, build: 6))
    }

    @Test func missingKeyReturnsNil() {
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04])

        #expect(data.keystoneFirmwareVersion() == nil)
    }

    @Test func keyPresentButTruncatedValueReturnsNil() {
        var data = Data()
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 3, 0]) // only 2 of the 3 version bytes

        #expect(data.keystoneFirmwareVersion() == nil)
    }

    @Test func keyPresentWithWrongLengthPrefixReturnsNil() {
        var data = Data()
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x04, 3, 0, 0]) // wrong prefix, not postcard's 0x03

        #expect(data.keystoneFirmwareVersion() == nil)
    }

    @Test func multipleOccurrencesFirstValidOneWins() {
        var data = Data()
        // First occurrence: wrong length prefix, invalid.
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x05, 9, 9, 9])
        // Second occurrence: valid.
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 3, 1, 2])

        #expect(data.keystoneFirmwareVersion() == KeystoneFirmwareVersion(major: 3, minor: 1, build: 2))
    }

    @Test func versionBytesAtVeryEndOfDataParses() {
        var data = Data([0xFF])
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 4, 5, 6])

        #expect(data.count == 1 + Self.key.count + 4)
        #expect(data.keystoneFirmwareVersion() == KeystoneFirmwareVersion(major: 4, minor: 5, build: 6))
    }

    @Test func emptyDataReturnsNil() {
        #expect(Data().keystoneFirmwareVersion() == nil)
    }
}

// MARK: - KeystoneFirmwareVersion.Comparable

@Suite struct KeystoneFirmwareVersionComparableTests {
    @Test func lowerMajorIsBelowMinimum() {
        #expect(KeystoneFirmwareVersion(major: 2, minor: 9, build: 9) < KeystoneFirmwareVersion.minimumSupported)
    }

    @Test func minimumIsExactlyThreeZeroOne() {
        #expect(KeystoneFirmwareVersion.minimumSupported == KeystoneFirmwareVersion(major: 3, minor: 0, build: 1))
    }

    @Test func minimumIsNotBelowItself() {
        #expect(!(KeystoneFirmwareVersion.minimumSupported < KeystoneFirmwareVersion.minimumSupported))
    }

    @Test func higherBuildIsAboveMinimum() {
        #expect(KeystoneFirmwareVersion(major: 3, minor: 0, build: 2) > KeystoneFirmwareVersion.minimumSupported)
    }

    @Test func comparisonIsLexicographicOnMajorThenMinorThenBuild() {
        // A higher minor must not be shadowed by comparing major alone.
        #expect(KeystoneFirmwareVersion(major: 2, minor: 99, build: 99) < KeystoneFirmwareVersion(major: 3, minor: 0, build: 0))
        // A higher build must not be shadowed by comparing major/minor alone.
        #expect(KeystoneFirmwareVersion(major: 3, minor: 0, build: 0) < KeystoneFirmwareVersion(major: 3, minor: 0, build: 1))
    }
}

// MARK: - SendConfirmationStore gate

// `SendConfirmation.State` carries `@Shared(.inMemory(...))` process-global storage (address book
// contacts, feature flags, wallet accounts). `.serialized` only orders this suite's own tests — it
// does NOT prevent other suites from running in parallel with it — so each test also binds a fresh
// in-memory store via `withDependencies { $0.defaultInMemoryStorage = InMemoryStorage() }`, which is
// what actually isolates this suite from cross-suite races on that storage.
@Suite(.serialized) @MainActor struct KeystoneFirmwareGateTests {
    private func makeStore() -> TestStore<SendConfirmation.State, SendConfirmation.Action> {
        let initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )

        return TestStore(initialState: initialState) {
            SendConfirmation()
        } withDependencies: {
            $0.mainQueue = .immediate
            // `KeystoneHandlerClient` provides only `liveValue` (no `testValue`), so the override
            // must happen in this construction-time closure: mutating `store.dependencies`
            // afterward would read (and fail on) the missing test value before the override is
            // ever applied. Same idiom as `AddKeystoneHWWalletTests.swift`'s `readyToScanTapped`
            // test.
            $0.keystoneHandler.resetQRDecoder = { }
        }
    }

    private func signedPczt(firmware: (major: Int, minor: Int, build: Int)?) -> Pczt {
        var data = Data()
        if let firmware {
            data.append(contentsOf: Array("keystone:fw_version".utf8))
            data.append(contentsOf: [0x03, UInt8(firmware.major), UInt8(firmware.minor), UInt8(firmware.build)])
        }
        return Pczt(data)
    }

    // Below-minimum firmware in two shapes — a clearly-old version and the boundary case one build
    // below the 3.0.1 minimum — both must still be blocked and must never schedule
    // `createTransactionFromPCZT`.
    @Test(arguments: [(2, 4, 6), (3, 0, 0)])
    func belowMinimumFirmwarePresentsUpdateScreen(major: Int, minor: Int, build: Int) async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()
            let pczt = signedPczt(firmware: (major, minor, build))

            await store.send(.foundPCZT(pczt)) {
                $0.isKeystoneCodeFound = true
                $0.detectedKeystoneFirmware = KeystoneFirmwareVersion(major: major, minor: minor, build: build)
            }
            await store.receive(.keystoneFirmwareUpdateRequired)
            // No further action arrives: `createTransactionFromPCZT` is never scheduled. An
            // exhaustive `TestStore` fails on any unasserted action, so reaching `finish()`
            // cleanly here IS the "never schedules" assertion.
            await store.finish()

            #expect(store.state.pcztWithSigs == nil)
        }
    }

    @Test func atMinimumFirmwareProceedsUnchanged() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()
            let pczt = signedPczt(firmware: (3, 0, 1))

            await store.send(.foundPCZT(pczt)) {
                $0.isKeystoneCodeFound = true
                $0.pcztWithSigs = pczt
            }
            await store.receive(.keystoneFirmwareAccepted)
            // `createTransactionFromPCZT`'s own guard bails with no state change: `pcztWithProofs`
            // was never set, so this proves scheduling happened without needing to mock the
            // synchronizer.
            await store.receive(.createTransactionFromPCZT)
            await store.finish()

            #expect(store.state.detectedKeystoneFirmware == nil)
        }
    }

    @Test func unstampedFirmwarePresentsUpdateScreenWithNilDetectedVersion() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()
            let pczt = signedPczt(firmware: nil)

            await store.send(.foundPCZT(pczt)) {
                $0.isKeystoneCodeFound = true
            }
            await store.receive(.keystoneFirmwareUpdateRequired)
            await store.finish()

            #expect(store.state.detectedKeystoneFirmware == nil)
            #expect(store.state.pcztWithSigs == nil)
        }
    }

    @Test func closeClearsStateForRescan() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()
            let pczt = signedPczt(firmware: (2, 4, 6))

            await store.send(.foundPCZT(pczt)) {
                $0.isKeystoneCodeFound = true
                $0.detectedKeystoneFirmware = KeystoneFirmwareVersion(major: 2, minor: 4, build: 6)
            }
            await store.receive(.keystoneFirmwareUpdateRequired)

            // The reset now lives in the coordinators, not here: they pop this path element before
            // this reducer would see the action. Covered by `KeystoneFirmwareCoordFlowTests`.
            await store.send(.keystoneFirmwareUpdateCloseTapped)
            await store.finish()
        }
    }
}
