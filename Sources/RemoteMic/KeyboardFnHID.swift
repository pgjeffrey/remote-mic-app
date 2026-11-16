import CoreGraphics
import Darwin
import Foundation
import IOKit.hid
import IOKit.hidsystem

protocol KeyboardFnHardware: AnyObject {
    var boot: String { get }
    var permissionGranted: Bool { get }
    var onKey: ((UInt64, KeyboardFnKey, Bool) -> Void)? { get set }
    var unreadyIdentities: [KeyboardFnIdentity] { get }
    func start() throws

    func stop()
    func devices() -> [KeyboardFnDevice]
    func serviceExists(_ id: UInt64) -> Bool
    func mappings(_ id: UInt64) throws -> [HIDUsageMapping]
    func setMappings(_ mappings: [HIDUsageMapping], for id: UInt64) throws
    func pressedKeys(_ rawID: UInt64, matching: Set<KeyboardFnKey>?) throws -> Set<KeyboardFnKey>
    func availableKeys(_ rawID: UInt64) throws -> Set<KeyboardFnKey>
}

extension KeyboardFnHardware {
    var unreadyIdentities: [KeyboardFnIdentity] { [] }
}

/// Only Apple public HID APIs are used. Normal key edges are mapped by macOS itself.
final class KeyboardFnHID: KeyboardFnHardware {
    let boot: String
    var permissionGranted: Bool { CGPreflightListenEventAccess() }
    var onKey: ((UInt64, KeyboardFnKey, Bool) -> Void)?
    private let clientFactory: () -> IOHIDEventSystemClient
    // Service clients retain references into their event-system owner's snapshot.
    private var serviceClientOwner: IOHIDEventSystemClient?
    private let logger: (String) -> Void
    private var discoveryGeneration = 0
    private var lastDiscoverySummary: String?
    private var lastReadyServices: Set<UInt64> = []
    private(set) var unreadyIdentities: [KeyboardFnIdentity] = []
    private var manager: IOHIDManager?
    private var rawDevices: [UInt64: IOHIDDevice] = [:]
    private var openedDevices: [UInt64: IOHIDDevice] = [:]
    private var services: [UInt64: IOHIDServiceClient] = [:]
    private var elements: [UInt64: [IOHIDElement]] = [:]
    private var readersNeedingRefresh: Set<UInt64> = []
    private var lastReadErrors: [UInt64: IOReturn] = [:]

    init(clientFactory: @escaping () -> IOHIDEventSystemClient = {
        IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    }, logger: @escaping (String) -> Void = { AppLogger.shared.write($0) }) {
        self.clientFactory = clientFactory
        self.logger = logger
        var size = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 {
            var bytes = [CChar](repeating: 0, count: size)
            boot = sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0
                ? String(cString: bytes) : ""
        } else { boot = "" }
    }

    func start() throws {
        guard manager == nil else { return }
        guard permissionGranted, !boot.isEmpty else { throw KeyboardFnFailure.permission }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 1,
                                               kIOHIDDeviceUsageKey: 6] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            throw KeyboardFnFailure.permission
        }
        self.manager = manager
    }

    private static let inputCallback: IOHIDValueCallback = { context, result, _, value in
        guard result == kIOReturnSuccess, let context else { return }
        let owner = Unmanaged<KeyboardFnHID>.fromOpaque(context).takeUnretainedValue()
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        var rawID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &rawID)
        let key = KeyboardFnKey(page: IOHIDElementGetUsagePage(element), usage: IOHIDElementGetUsage(element))
        guard key.page == 7 else { return }
        owner.onKey?(rawID, key, IOHIDValueGetIntegerValue(value) != 0)
    }

    deinit { stop() }

    func stop() {
        for device in openedDevices.values { closeReader(device) }
        openedDevices.removeAll()
        if let manager {
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        rawDevices.removeAll()
        services.removeAll()
        serviceClientOwner = nil
        unreadyIdentities.removeAll()
        elements.removeAll()
        readersNeedingRefresh.removeAll()
        lastReadErrors.removeAll()
    }

    func devices() -> [KeyboardFnDevice] {
        // Simple clients keep a service snapshot. Reconnecting replaces the service,
        // so each discovery needs a new owner as well as new service references.
        let freshClient = clientFactory()
        let allServices = IOHIDEventSystemClientCopyServices(freshClient) as? [IOHIDServiceClient] ?? []
        services = Dictionary(allServices.compactMap { service in
            (IOHIDServiceClientGetRegistryID(service) as? NSNumber).map { ($0.uint64Value, service) }
        }, uniquingKeysWith: { first, _ in first })
        serviceClientOwner = freshClient
        unreadyIdentities.removeAll()
        guard let manager else {
            reportDiscovery("result=manager_unavailable ready_count=0", readyServices: [])
            return []
        }
        let allRaw = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        var discovered: [KeyboardFnDevice] = []
        var externalCount = 0
        var missingServiceCount = 0
        var ambiguousServiceCount = 0
        var unsupportedLayoutCount = 0
        var failedOpenCount = 0
        var openErrors: Set<UInt32> = []
        var observedRawIDs: Set<UInt64> = []
        rawDevices.removeAll()
        elements.removeAll()
        for raw in allRaw {
            func property(_ key: String) -> Any? { IOHIDDeviceGetProperty(raw, key as CFString) }
            let vendor = (property(kIOHIDVendorIDKey) as? NSNumber)?.intValue ?? 0
            let product = (property(kIOHIDProductIDKey) as? NSNumber)?.intValue ?? 0
            let transport = property(kIOHIDTransportKey) as? String ?? ""
            let name = property(kIOHIDProductKey) as? String ?? ""
            guard Self.isExternalKeyboard(vendor: vendor, product: product, transport: transport, name: name,
                                           builtIn: (property("Built-In") as? NSNumber)?.boolValue ?? false)
            else { continue }
            externalCount += 1
            let physicalID = property("PhysicalDeviceUniqueID") as? String
            let serial = property(kIOHIDSerialNumberKey) as? String
            var identity = KeyboardFnIdentity(vendor: vendor, product: product, transport: transport,
                                              token: KeyboardFnIdentity.token(for: physicalID ?? serial))
            let rawService = IOHIDDeviceGetService(raw)
            var rawID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(rawService, &rawID) == KERN_SUCCESS else {
                unreadyIdentities.append(identity)
                missingServiceCount += 1
                continue
            }
            observedRawIDs.insert(rawID)
            let candidates = services.filter { id, service in
                let page = (IOHIDServiceClientCopyProperty(service, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue
                let usage = (IOHIDServiceClientCopyProperty(service, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue
                return page == 1 && usage == 6 && Self.isDescendant(id, of: rawID)
            }
            guard candidates.count == 1, let candidate = candidates.first else {
                unreadyIdentities.append(identity)
                if candidates.isEmpty { missingServiceCount += 1 }
                else { ambiguousServiceCount += 1 }
                continue
            }
            let unique = physicalID
                ?? (IOHIDServiceClientCopyProperty(candidate.value, "PhysicalDeviceUniqueID" as CFString) as? String)
                ?? serial
            identity.token = KeyboardFnIdentity.token(for: unique)
            var reader = openedDevices[rawID] ?? raw
            if readersNeedingRefresh.remove(rawID) != nil {
                if let previous = openedDevices.removeValue(forKey: rawID) { closeReader(previous) }
                guard let replacement = IOHIDDeviceCreate(kCFAllocatorDefault, rawService) else {
                    unreadyIdentities.append(identity)
                    failedOpenCount += 1
                    openErrors.insert(UInt32(bitPattern: kIOReturnNoDevice))
                    continue
                }
                reader = replacement
            }
            // IOHIDDeviceGetValue requires elements belonging to the same reader object.
            let keyElements = IOHIDDeviceCopyMatchingElements(reader,
                [kIOHIDElementUsagePageKey: 7] as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
            let inputElements = keyElements.filter { IOHIDElementGetType($0).rawValue <= kIOHIDElementTypeInput_ScanCodes.rawValue }
            guard inputElements.contains(where: { IOHIDElementGetUsage($0) == 4 }),
                  inputElements.contains(where: { IOHIDElementGetUsage($0) == 29 }) else {
                unreadyIdentities.append(identity)
                unsupportedLayoutCount += 1
                continue
            }
            if openedDevices[rawID] == nil {
                let result = IOHIDDeviceOpen(reader, IOOptionBits(kIOHIDOptionsTypeNone))
                guard result == kIOReturnSuccess else {
                    unreadyIdentities.append(identity)
                    failedOpenCount += 1
                    openErrors.insert(UInt32(bitPattern: result))
                    continue
                }
                IOHIDDeviceRegisterInputValueCallback(reader, Self.inputCallback, Unmanaged.passUnretained(self).toOpaque())
                IOHIDDeviceScheduleWithRunLoop(reader, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                openedDevices[rawID] = reader
            }
            rawDevices[rawID] = reader
            elements[rawID] = inputElements
            discovered.append(KeyboardFnDevice(serviceID: candidate.key, rawID: rawID, name: name, identity: identity))
        }
        for id in Array(openedDevices.keys) where rawDevices[id] == nil {
            if let device = openedDevices.removeValue(forKey: id) { closeReader(device) }
        }
        readersNeedingRefresh.formIntersection(observedRawIDs)
        lastReadErrors = lastReadErrors.filter { observedRawIDs.contains($0.key) }
        let errorCodes = openErrors.isEmpty ? "none" : openErrors.sorted().map(String.init).joined(separator: ",")
        reportDiscovery(
            "result=snapshot raw_count=\(allRaw.count) external_count=\(externalCount) " +
                "ready_count=\(discovered.count) unready_count=\(unreadyIdentities.count) " +
                "service_missing=\(missingServiceCount) service_ambiguous=\(ambiguousServiceCount) " +
                "layout_unsupported=\(unsupportedLayoutCount) open_failed=\(failedOpenCount) " +
                "open_error_domain=iokit open_error_codes=\(errorCodes)",
            readyServices: Set(discovered.map(\.serviceID))
        )
        return discovered.sorted { $0.serviceID < $1.serviceID }
    }

    private func reportDiscovery(_ summary: String, readyServices: Set<UInt64>) {
        discoveryGeneration += 1
        let topologyChanged = lastReadyServices != readyServices
        guard lastDiscoverySummary != summary || topologyChanged else { return }
        lastDiscoverySummary = summary
        lastReadyServices = readyServices
        logger("KEYBOARD_FN HID_SNAPSHOT generation=\(discoveryGeneration) phase=completed " +
               "\(summary) topology_changed=\(topologyChanged) external_result=unknown")
    }

    private func closeReader(_ device: IOHIDDevice) {
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    static func isExternalKeyboard(vendor: Int, product: Int = 0, transport: String, name: String, builtIn: Bool) -> Bool {
        guard !builtIn, ["USB", "Bluetooth", "Bluetooth Low Energy"].contains(transport),
              !(vendor == 0x2717 && product == 0x32B8) else { return false }
        let lower = name.lowercased()
        return !["remote", "virtual", "karabiner", "consumer"].contains(where: lower.contains)
    }

    private static func isDescendant(_ id: UInt64, of parentID: UInt64) -> Bool {
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        for _ in 0..<16 {
            var current: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &current)
            if current == parentID { return true }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
            IOObjectRelease(entry)
            entry = parent
        }
        return false
    }

    func serviceExists(_ id: UInt64) -> Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard entry != 0 else { return false }
        IOObjectRelease(entry)
        return true
    }

    func mappings(_ id: UInt64) throws -> [HIDUsageMapping] {
        guard let service = services[id] else { throw KeyboardFnFailure.unavailable }
        guard let value = IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) else { return [] }
        guard let rows = value as? [[String: NSNumber]],
              rows.allSatisfy({ $0.count == 2 && HIDUsageMapping(property: $0) != nil })
        else { throw KeyboardFnFailure.invalidMapping }
        return rows.compactMap(HIDUsageMapping.init(property:))
    }

    func setMappings(_ mappings: [HIDUsageMapping], for id: UInt64) throws {
        guard let service = services[id], IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString,
                                                                       mappings.map(\.property) as CFArray)
        else { throw KeyboardFnFailure.writeFailed }
        guard try self.mappings(id) == mappings else { throw KeyboardFnFailure.writeFailed }
    }

    func pressedKeys(_ rawID: UInt64, matching: Set<KeyboardFnKey>?) throws -> Set<KeyboardFnKey> {
        guard permissionGranted else { throw KeyboardFnFailure.permission }
        guard let raw = rawDevices[rawID], let elements = elements[rawID], !elements.isEmpty
        else { throw KeyboardFnFailure.unavailable }
        let selected = elements.filter { matching?.contains(KeyboardFnKey(page: 7, usage: IOHIDElementGetUsage($0))) ?? true }
        if let matching {
            let available = Set(selected.map { KeyboardFnKey(page: 7, usage: IOHIDElementGetUsage($0)) })
            guard matching.isSubset(of: available) else { throw KeyboardFnFailure.unavailable }
        }
        var pressed: Set<KeyboardFnKey> = []
        let output = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { output.deallocate() }
        for element in selected {
            let result = IOHIDDeviceGetValue(raw, element, output)
            guard result == kIOReturnSuccess else {
                readersNeedingRefresh.insert(rawID)
                if lastReadErrors[rawID] != result {
                    lastReadErrors[rawID] = result
                    logger("KEYBOARD_FN KEY_STATE phase=failed error_domain=iokit error_code=\(UInt32(bitPattern: result)) recovery=reader_refresh_pending")
                }
                throw KeyboardFnFailure.unavailable
            }
            if IOHIDValueGetIntegerValue(output.pointee.takeUnretainedValue()) != 0 {
                pressed.insert(KeyboardFnKey(page: 7, usage: IOHIDElementGetUsage(element)))
            }
        }
        if lastReadErrors.removeValue(forKey: rawID) != nil {
            logger("KEYBOARD_FN KEY_STATE phase=completed result=readable external_result=unknown")
        }
        return pressed
    }

    func availableKeys(_ rawID: UInt64) throws -> Set<KeyboardFnKey> {
        guard permissionGranted, let elements = elements[rawID], !elements.isEmpty else { throw KeyboardFnFailure.unavailable }
        return Set(elements.map { KeyboardFnKey(page: 7, usage: IOHIDElementGetUsage($0)) }
            .filter { (4...0xE7).contains($0.usage) })
    }
}
