import CryptoKit
import Foundation
import IOKit

/// A stable, anonymous ID for this Mac, used only for the usage count.
///
/// It's a one-way hash of the Mac's hardware UUID (IOPlatformUUID) with an
/// app-specific salt, formatted as a UUID. The same Mac always yields the same
/// ID — reinstalls or wiped preferences don't count as new users — but the ID
/// can't be reversed into the hardware UUID. (Someone who already knows a given
/// Mac's hardware UUID could recompute its ID; nobody can go the other way.)
///
/// If the hardware UUID can't be read, falls back to a random UUID stored in
/// user defaults, so there's always an ID.
enum DeviceID {
    private static let salt = "agxntz.usage-id.v1"

    static let value: String = {
        if let hw = hardwareUUID() {
            return hashedUUID(salt + ":" + hw)
        }
        let key = "installIDFallback"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return property?.takeRetainedValue() as? String
    }

    /// SHA-256 → first 16 bytes, stamped as a version-5-style name-based UUID.
    private static func hashedUUID(_ input: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 (name-based, SHA)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let i = hex.startIndex
        func seg(_ a: Int, _ b: Int) -> Substring { hex[hex.index(i, offsetBy: a)..<hex.index(i, offsetBy: b)] }
        return "\(seg(0, 8))-\(seg(8, 12))-\(seg(12, 16))-\(seg(16, 20))-\(seg(20, 32))"
    }
}
