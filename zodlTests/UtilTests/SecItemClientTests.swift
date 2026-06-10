//
//  SecItemClientTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 12.04.2022.
//

import Testing
import Foundation
import Security
@testable import zodl_internal

extension WalletStorage.KeychainError {
    var debugValue: String {
        switch self {
        case .decoding: return "decoding"
        case .duplicate: return "duplicate"
        case .encoding: return "encoding"
        case .noDataFound: return "noDataFound"
        case .unknown: return "unknown"
        }
    }
}

@Suite struct SecItemClientTests {
    @Test func secItemAdd_KeychainErrorDuplicate() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecDuplicateItem },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        let error = #expect(throws: WalletStorage.KeychainError.self) {
            try walletStorage.setData(Data(), forKey: "")
        }

        #expect(
            error?.debugValue == WalletStorage.KeychainError.duplicate.debugValue,
            "SecItemClient: error must be .duplicate but it's \(String(describing: error))."
        )
    }

    @Test func secItemAdd_KeychainErrorUnknown() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecCoreFoundationUnknown },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        let error = #expect(throws: WalletStorage.KeychainError.self) {
            try walletStorage.setData(Data(), forKey: "")
        }

        #expect(
            error?.debugValue == WalletStorage.KeychainError.unknown(0).debugValue,
            "SecItemClient: error must be .unknown but it's \(String(describing: error))."
        )
    }

    @Test func secItemUpdate_KeychainErrorNoDataFound() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecItemNotFound },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        let error = #expect(throws: WalletStorage.KeychainError.self) {
            try walletStorage.updateData(Data(), forKey: "")
        }

        #expect(
            error?.debugValue == WalletStorage.KeychainError.noDataFound.debugValue,
            "SecItemClient: error must be .noDataFound but it's \(String(describing: error))."
        )
    }

    @Test func secItemUpdate_KeychainErrorUnknown() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecCoreFoundationUnknown },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        let error = #expect(throws: WalletStorage.KeychainError.self) {
            try walletStorage.updateData(Data(), forKey: "")
        }

        #expect(
            error?.debugValue == WalletStorage.KeychainError.unknown(0).debugValue,
            "SecItemClient: error must be .unknown but it's \(String(describing: error))."
        )
    }

    @Test func secItemDelete_Succeeded() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in noErr }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        #expect(throws: Never.self) {
            try walletStorage.deleteData(forKey: "")
        }
    }

    @Test func secItemDelete_Failed() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecCoreFoundationUnknown }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        #expect(throws: (any Error).self) {
            try walletStorage.deleteData(forKey: "")
        }
    }
}
