import CryptoKit
import Foundation

struct KeyboardFnKey: Codable, Equatable, Hashable {
    let page: UInt32
    let usage: UInt32

    static let rightControl = KeyboardFnKey(page: 7, usage: 0xE4)
    static let function = KeyboardFnKey(page: 0xFF, usage: 3)
    var mappingValue: UInt64 { UInt64(page) << 32 | UInt64(usage) }
    var isSupportedSource: Bool { page == 7 && (4...0xE7).contains(usage) && usage != 0x39 }

    var label: String {
        switch usage {
        case 0xE0: return "Left Ctrl"
        case 0xE1: return "Left Shift"
        case 0xE2: return "Left Option"
        case 0xE3: return "Left Command"
        case 0xE4: return "Right Ctrl"
        case 0xE5: return "Right Shift"
        case 0xE6: return "Right Option"
        case 0xE7: return "Right Command"
        case 4...29: return String(UnicodeScalar(65 + usage - 4)!)
        case 30...38: return String(usage - 29)
        case 39: return "0"
        case 40: return "Return"
        case 41: return "Esc"
        case 42: return "Delete"
        case 43: return "Tab"
        case 44: return "Space"
        case 58...69: return "F\(usage - 57)"
        case 0x68...0x73: return "F\(usage - 0x68 + 13)"
        case 79: return "→"
        case 80: return "←"
        case 81: return "↓"
        case 82: return "↑"
        default: return String(format: "HID 0x%02X", usage)
        }
    }
}

/// Identity stays in the local configuration. Neither this token nor its inputs enter logs or exports.
struct KeyboardFnIdentity: Codable, Equatable {
    var vendor: Int
    var product: Int
    var transport: String
    var token: String?

    static func token(for value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct KeyboardFnDevice: Equatable {
    let serviceID: UInt64
    let rawID: UInt64
    let name: String
    let identity: KeyboardFnIdentity
}

struct KeyboardFnProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var identity: KeyboardFnIdentity
    var name: String
    var source = KeyboardFnKey.rightControl
    var enabled = false
    var confirmedBoot: String
    var confirmedService: UInt64
}

struct KeyboardFnRecovery: Codable, Equatable {
    let profileID: UUID
    let boot: String
    let device: KeyboardFnDeviceRecord
    let source: KeyboardFnKey
    let original: [HIDUsageMapping]
    var captureKeys: [KeyboardFnKey]? = nil

    var isCapture: Bool { captureKeys != nil }
    var desiredMappings: [HIDUsageMapping] {
        captureKeys?.map { HIDUsageMapping(source: $0.mappingValue, destination: 0) }
            ?? KeyboardFnPolicy.functionMapping(source)
    }
    var releaseKeys: Set<KeyboardFnKey> { Set(captureKeys ?? [source]) }
}

struct KeyboardFnDeviceRecord: Codable, Equatable {
    let serviceID: UInt64
    let rawID: UInt64
}

struct KeyboardFnConfiguration: Codable, Equatable {
    var schema = 2
    var profiles: [KeyboardFnProfile] = []
    var recovery: [KeyboardFnRecovery] = []
}

enum KeyboardFnFailure: String, Error {
    case permission, unavailable, ambiguous, storage, held, conflict, busy
    case invalidMapping = "invalid_mapping"
    case writeFailed = "write_failed"
    var messageKey: String { "keyboard_fn.error." + rawValue }
}

enum KeyboardFnPolicy {
    static let functionValue = KeyboardFnKey.function.mappingValue

    static func entries(_ mappings: [HIDUsageMapping], source: KeyboardFnKey) -> [HIDUsageMapping] {
        mappings.filter { $0.source == source.mappingValue }
    }

    static func replacing(_ mappings: [HIDUsageMapping], source: KeyboardFnKey,
                          with replacement: [HIDUsageMapping]) -> [HIDUsageMapping] {
        mappings.filter { $0.source != source.mappingValue } + replacement
    }

    static func functionMapping(_ source: KeyboardFnKey) -> [HIDUsageMapping] {
        [HIDUsageMapping(source: source.mappingValue, destination: functionValue)]
    }

    static func entries(_ mappings: [HIDUsageMapping], record: KeyboardFnRecovery) -> [HIDUsageMapping] {
        let sources = Set(record.desiredMappings.map(\.source))
        return mappings.filter { sources.contains($0.source) }
    }

    static func restoringOwned(_ current: [HIDUsageMapping], record: KeyboardFnRecovery) -> [HIDUsageMapping] {
        let owned = Set(record.desiredMappings.filter { desired in
            current.filter { $0.source == desired.source } == [desired]
        }.map(\.source))
        return current.filter { !owned.contains($0.source) } + record.original.filter { owned.contains($0.source) }
    }

    static func matchedDevice(for profile: KeyboardFnProfile, devices: [KeyboardFnDevice],
                              profiles: [KeyboardFnProfile], boot: String) -> KeyboardFnDevice? {
        func candidate(_ value: KeyboardFnProfile) -> KeyboardFnDevice? {
            let candidates = devices.filter { device in
                guard device.identity.vendor == value.identity.vendor,
                      device.identity.product == value.identity.product,
                      device.identity.transport == value.identity.transport else { return false }
                if let token = value.identity.token { return device.identity.token == token }
                return value.confirmedBoot == boot && value.confirmedService == device.serviceID
            }
            let duplicateSavedIdentity = value.identity.token != nil &&
                profiles.filter { $0.identity == value.identity }.count > 1
            if candidates.count == 1 && !duplicateSavedIdentity { return candidates.first }
            // A duplicated identity is usable only after confirmation in this device session.
            return candidates.first { value.confirmedBoot == boot && value.confirmedService == $0.serviceID }
        }
        guard let device = candidate(profile),
              profiles.filter({ candidate($0)?.serviceID == device.serviceID }).count == 1 else { return nil }
        return device
    }
}

protocol KeyboardFnStoring {
    func load() throws -> KeyboardFnConfiguration
    func save(_ configuration: KeyboardFnConfiguration) throws
}

final class KeyboardFnStore: KeyboardFnStoring {
    private let url: URL
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SayAll/KeyboardFn.plist")) { self.url = url }

    func load() throws -> KeyboardFnConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return KeyboardFnConfiguration() }
        var result = try PropertyListDecoder().decode(KeyboardFnConfiguration.self, from: Data(contentsOf: url))
        guard (1...2).contains(result.schema),
              Set(result.profiles.map(\.id)).count == result.profiles.count,
              result.profiles.allSatisfy({ $0.source.isSupportedSource }),
              result.recovery.allSatisfy({ record in
                  record.source.isSupportedSource && (record.captureKeys?.allSatisfy {
                      $0.page == 7 && (4...0xE7).contains($0.usage)
                  } ?? true) && record.captureKeys?.isEmpty != true
              }),
              Set(result.recovery.map { $0.device.serviceID }).count == result.recovery.count
        else { throw KeyboardFnFailure.storage }
        result.schema = 2
        return result
    }

    func save(_ configuration: KeyboardFnConfiguration) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try PropertyListEncoder().encode(configuration)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
