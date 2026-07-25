//
//  KeystoneFirmwareVersion.swift
//  Zashi
//
//  MOB-1510: device firmware stamps `global.proprietary["keystone:fw_version"]` (3 raw bytes)
//  into every signed PCZT; KeystoneSDK 0.8.6 exposes no firmware API of its own.
//

import Foundation

struct KeystoneFirmwareVersion: Equatable, Comparable, Sendable {
    /// Minimum Keystone firmware this app will accept a signature from — set by product
    /// (MOB-1510). Single point of change if the minimum is ever raised. Always enforced — there
    /// is no "0.0.0 disables the check" escape hatch.
    static let minimumSupported = KeystoneFirmwareVersion(major: 3, minor: 0, build: 1)

    let major: Int
    let minor: Int
    let build: Int

    var versionString: String {
        "\(major).\(minor).\(build)"
    }
}

extension KeystoneFirmwareVersion {
    static func < (lhs: KeystoneFirmwareVersion, rhs: KeystoneFirmwareVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.build) < (rhs.major, rhs.minor, rhs.build)
    }
}

extension Data {
    /// Byte-scans a signed PCZT for the key `keystone:fw_version`, postcard's length-prefix byte
    /// for a 3-byte value (`0x03`), and the 3 version bytes that follow (MOB-1510) — interim until
    /// a proper FFI reader exists over the PCZT's parsed proprietary fields. Occurrences are
    /// scanned in order; a truncated or wrong-length-prefix one is skipped, not fatal. `nil` when
    /// no valid occurrence exists.
    func keystoneFirmwareVersion() -> KeystoneFirmwareVersion? {
        let key = Data("keystone:fw_version".utf8)
        var searchRange = startIndex..<endIndex

        while let keyRange = range(of: key, in: searchRange) {
            let lengthPrefixIndex = keyRange.upperBound
            let versionStart = lengthPrefixIndex + 1
            let versionEnd = versionStart + 3
            if versionEnd <= endIndex, self[lengthPrefixIndex] == 0x03 {
                return KeystoneFirmwareVersion(
                    major: Int(self[versionStart]),
                    minor: Int(self[versionStart + 1]),
                    build: Int(self[versionStart + 2])
                )
            }
            searchRange = keyRange.upperBound..<endIndex
        }
        return nil
    }
}
