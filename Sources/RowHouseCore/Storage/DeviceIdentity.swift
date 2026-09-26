import CryptoKit
import Foundation
import IOKit
import SystemConfiguration

/// Identifies this Mac. The id is derived from the hardware UUID so it survives reinstalls but is
/// never copied to a new Mac by Migration Assistant (which would make two Macs write the same log).
public struct DeviceIdentity: Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static let current: DeviceIdentity = {
        let env = ProcessInfo.processInfo.environment
        let id = env["ROWHOUSE_DEVICE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? derivedID()
        let name = env["ROWHOUSE_DEVICE_NAME"].flatMap { $0.isEmpty ? nil : $0 } ?? computerName()
        return DeviceIdentity(id: id, name: name)
    }()

    private static func derivedID() -> String {
        let seed = (hardwareUUID() ?? fallbackUUID()) + "|" + NSUserName()
        let digest = SHA256.hash(data: Data(seed.utf8))
        return "dev" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    private static func fallbackUUID() -> String {
        let key = "RowHouseFallbackDeviceUUID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return "Mac"
    }
}
