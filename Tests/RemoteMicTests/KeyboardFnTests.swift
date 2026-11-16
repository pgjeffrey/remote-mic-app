import Foundation
import IOKit.hid
import IOKit.hidsystem
import Testing
@testable import RemoteMic

final class KeyboardFnTestHardware: KeyboardFnHardware {
    var boot = "boot-one"
    var permissionGranted = true
    var onKey: ((UInt64, KeyboardFnKey, Bool) -> Void)?
    var connected: [KeyboardFnDevice] = []
    var unreadyIdentities: [KeyboardFnIdentity] = []
    var values: [UInt64: [HIDUsageMapping]] = [:]
    var pressed: [UInt64: Set<KeyboardFnKey>] = [:]
    var writes: [(UInt64, [HIDUsageMapping])] = []
    var failWrite = false
    var unreadableDevices: Set<UInt64> = []
    func start() throws {}
    func stop() {}
    func devices() -> [KeyboardFnDevice] { connected }
    func serviceExists(_ id: UInt64) -> Bool { connected.contains { $0.serviceID == id } }
    func mappings(_ id: UInt64) throws -> [HIDUsageMapping] { values[id] ?? [] }
    func setMappings(_ mappings: [HIDUsageMapping], for id: UInt64) throws {
        values[id] = mappings
        writes.append((id, mappings))
        if failWrite { throw KeyboardFnFailure.writeFailed }
    }
    func pressedKeys(_ rawID: UInt64, matching: Set<KeyboardFnKey>?) throws -> Set<KeyboardFnKey> {
        guard permissionGranted else { throw KeyboardFnFailure.permission }
        guard !unreadableDevices.contains(rawID) else { throw KeyboardFnFailure.unavailable }
        return pressed[rawID] ?? []
    }
    func availableKeys(_ rawID: UInt64) throws -> Set<KeyboardFnKey> {
        [.rightControl, KeyboardFnKey(page: 7, usage: 0xE6), KeyboardFnKey(page: 7, usage: 4), KeyboardFnKey(page: 7, usage: 0x39)]
    }
    func edge(_ device: KeyboardFnDevice, _ key: KeyboardFnKey, down: Bool) {
        var keys = pressed[device.rawID] ?? []
        if down { keys.insert(key) } else { keys.remove(key) }
        pressed[device.rawID] = keys
        onKey?(device.rawID, key, down)
    }
}

final class KeyboardFnTestStore: KeyboardFnStoring {
    var value = KeyboardFnConfiguration()
    var failSave = false
    func load() throws -> KeyboardFnConfiguration { value }
    func save(_ configuration: KeyboardFnConfiguration) throws {
        if failSave { throw KeyboardFnFailure.storage }
        value = configuration
    }
}

@Suite("External keyboard Fn mapping", .serialized)
@MainActor
struct KeyboardFnTests {
    let first = KeyboardFnDevice(serviceID: 11, rawID: 1, name: "Test keyboard",
        identity: KeyboardFnIdentity(vendor: 1671, product: 490, transport: "Bluetooth Low Energy", token: "one"))
    let second = KeyboardFnDevice(serviceID: 22, rawID: 2, name: "Test keyboard",
        identity: KeyboardFnIdentity(vendor: 1671, product: 490, transport: "Bluetooth Low Energy", token: "two"))
    let unrelated = HIDUsageMapping(source: 0x7000000E0, destination: 0x7000000E3)

    private func settle(_ milliseconds: Int = 400) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func profile(_ device: KeyboardFnDevice, source: KeyboardFnKey = .rightControl) -> KeyboardFnProfile {
        KeyboardFnProfile(identity: device.identity, name: device.name, source: source, enabled: true,
                          confirmedBoot: "boot-one", confirmedService: device.serviceID)
    }

    @Test func mappingUsesFullWidthFnUsageAndPreservesOtherSources() {
        let original = [unrelated, HIDUsageMapping(source: KeyboardFnKey.rightControl.mappingValue, destination: 4)]
        let applied = KeyboardFnPolicy.replacing(original, source: .rightControl,
                                                with: KeyboardFnPolicy.functionMapping(.rightControl))
        #expect(applied == [unrelated, HIDUsageMapping(source: 0x7000000E4, destination: 0xFF00000003)])
        #expect(KeyboardFnPolicy.replacing(applied, source: .rightControl,
            with: KeyboardFnPolicy.entries(original, source: .rightControl)) == original)
        #expect(!KeyboardFnKey.function.isSupportedSource)
        #expect(!KeyboardFnKey(page: 7, usage: 0x39).isSupportedSource)
        #expect(KeyboardFnKey(page: 7, usage: 4).isSupportedSource)
    }

    @Test func uniqueIdentitiesReconnectAndAmbiguousIdentitiesNeedConfirmation() {
        let p = profile(first)
        #expect(KeyboardFnPolicy.matchedDevice(for: p, devices: [first, second], profiles: [p], boot: "new-boot") == first)
        let twin = KeyboardFnDevice(serviceID: 33, rawID: 3, name: first.name, identity: first.identity)
        #expect(KeyboardFnPolicy.matchedDevice(for: p, devices: [first, twin], profiles: [p], boot: "new-boot") == nil)
        #expect(KeyboardFnPolicy.matchedDevice(for: p, devices: [first, twin], profiles: [p], boot: "boot-one") == first)
        var noIdentity = p
        noIdentity.identity.token = nil
        #expect(KeyboardFnPolicy.matchedDevice(for: noIdentity, devices: [first], profiles: [noIdentity], boot: "new-boot") == nil)
        #expect(KeyboardFnPolicy.matchedDevice(for: noIdentity, devices: [first], profiles: [noIdentity], boot: "boot-one") == first)
    }

    @Test func duplicateSavedProfilesCannotClaimOneDevice() {
        let a = profile(first)
        var b = profile(first)
        #expect(KeyboardFnPolicy.matchedDevice(for: a, devices: [first], profiles: [a, b], boot: "boot-one") == nil)
        b.confirmedService = 22
        let twin = KeyboardFnDevice(serviceID: 22, rawID: 2, name: first.name, identity: first.identity)
        #expect(KeyboardFnPolicy.matchedDevice(for: a, devices: [first, twin], profiles: [a, b], boot: "boot-one") == first)
        #expect(KeyboardFnPolicy.matchedDevice(for: b, devices: [first, twin], profiles: [a, b], boot: "boot-one") == twin)
        #expect(KeyboardFnPolicy.matchedDevice(for: a, devices: [first], profiles: [a, b], boot: "new-boot") == nil)
    }

    @Test func filtersBuiltInVirtualAndRemoteDevices() {
        #expect(KeyboardFnHID.isExternalKeyboard(vendor: 1671, transport: "Bluetooth Low Energy", name: "Keyboard", builtIn: false))
        #expect(!KeyboardFnHID.isExternalKeyboard(vendor: 1671, transport: "USB", name: "Keyboard", builtIn: true))
        #expect(!KeyboardFnHID.isExternalKeyboard(vendor: 0x2717, product: 0x32B8, transport: "Bluetooth", name: "Keyboard", builtIn: false))
        #expect(!KeyboardFnHID.isExternalKeyboard(vendor: 1, transport: "Virtual", name: "Keyboard", builtIn: false))
        #expect(!KeyboardFnHID.isExternalKeyboard(vendor: 1, transport: "USB", name: "Virtual keyboard", builtIn: false))
    }

    @Test func twoKeyboardsApplyIndependentlyAndDisableRestoresOnlyOwnedSource() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first, second]
        hardware.values[11] = [unrelated]
        store.value.profiles = [profile(first), profile(second)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        #expect(controller.rows.filter { $0.status == .enabled }.count == 2)
        let row = try #require(controller.rows.first { $0.device == first })
        controller.disable(rowID: row.id)
        try await settle()
        #expect(hardware.values[11] == [unrelated])
        #expect(hardware.values[22] == KeyboardFnPolicy.functionMapping(.rightControl))
        #expect(store.value.recovery.count == 1)
        controller.disableAll()
        try await settle()
        #expect(store.value.recovery.isEmpty)
        #expect(hardware.values[22] == [])
        controller.stop()
    }

    @Test func changingSourceWaitsForKeyUpAndRestoresBeforeNewMapping() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        store.value.profiles = [profile(first)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        hardware.edge(first, .rightControl, down: true)
        let row = try #require(controller.rows.first)
        controller.save(rowID: row.id, name: "Desk", source: KeyboardFnKey(page: 7, usage: 0xE6))
        try await settle()
        #expect(hardware.writes.count == 1)
        hardware.edge(first, .rightControl, down: false)
        try await settle()
        #expect(hardware.values[11] == [])
        controller.refresh()
        try await settle()
        #expect(hardware.values[11] == KeyboardFnPolicy.functionMapping(KeyboardFnKey(page: 7, usage: 0xE6)))
        controller.disableAll()
        try await settle()
        controller.stop()
    }

    @Test func externalChangesArePreservedOnDisableAndRetryUsesNewBaseline() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        store.value.profiles = [profile(first)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        let external = HIDUsageMapping(source: KeyboardFnKey.rightControl.mappingValue, destination: 77)
        hardware.values[11] = [unrelated, external]
        controller.refresh()
        #expect(controller.rows.first?.status == .failed(.conflict))
        controller.disableAll()
        try await settle()
        #expect(hardware.values[11] == [unrelated, external])
        let row = try #require(controller.rows.first)
        controller.save(rowID: row.id, name: "Test", source: .rightControl)
        try await settle()
        controller.disableAll()
        try await settle()
        #expect(hardware.values[11] == [unrelated, external])
        controller.stop()
    }

    @Test func storageFailureNeverWritesSystemMapping() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        store.value.profiles = [profile(first)]
        store.failSave = true
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        #expect(hardware.writes.isEmpty)
        #expect(controller.rows.first?.status == .failed(.storage))
        controller.stop()
    }

    @Test func partialWriteRetainsRecoveryAndCanBeRestored() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        hardware.values[11] = [unrelated]
        hardware.failWrite = true
        store.value.profiles = [profile(first)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        #expect(store.value.recovery.count == 1)
        hardware.failWrite = false
        controller.disableAll()
        try await settle()
        #expect(hardware.values[11] == [unrelated])
        #expect(store.value.recovery.isEmpty)
        controller.stop()
    }

    @Test func crashRecoveryRestoresBeforeTakingNewSnapshot() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        let p = profile(first)
        store.value.profiles = [p]
        store.value.recovery = [KeyboardFnRecovery(profileID: p.id, boot: hardware.boot,
            device: KeyboardFnDeviceRecord(serviceID: 11, rawID: 1), source: .rightControl, original: [])]
        hardware.values[11] = KeyboardFnPolicy.functionMapping(.rightControl)
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        #expect(hardware.writes.first?.1 == [])
        controller.refresh()
        try await settle()
        #expect(store.value.recovery.first?.original == [])
        controller.disableAll()
        try await settle()
        controller.stop()
    }

    @Test func oldBootRecoveryNeverTouchesNewService() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        store.value.recovery = [KeyboardFnRecovery(profileID: UUID(), boot: "old-boot",
            device: KeyboardFnDeviceRecord(serviceID: 11, rawID: 1), source: .rightControl, original: [])]
        hardware.values[11] = [unrelated]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        #expect(hardware.writes.isEmpty)
        #expect(store.value.recovery.isEmpty)
        controller.stop()
    }

    @Test func recordingAcceptsOnlySelectedDeviceAndWaitsForRelease() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first, second]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        let row = try #require(controller.rows.first { $0.device == first })
        controller.beginRecording(rowID: row.id)
        try await settle()
        #expect(hardware.values[first.serviceID]?.allSatisfy { $0.destination == 0 } == true)
        let key = KeyboardFnKey(page: 7, usage: 0xE6)
        hardware.edge(second, key, down: true)
        hardware.edge(second, key, down: false)
        #expect(controller.capturedKey == nil)
        hardware.edge(first, key, down: true)
        #expect(controller.capturedKey == nil)
        hardware.edge(first, key, down: false)
        #expect(controller.capturedKey == key)
        #expect(controller.captureRowID == nil)
        #expect(store.value.profiles.isEmpty)
        controller.stop()
    }

    @Test func recordingCancelAndMultipleKeysCleanUpWithoutSaving() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        let row = try #require(controller.rows.first)
        controller.beginRecording(rowID: row.id)
        try await settle()
        hardware.edge(first, .rightControl, down: true)
        hardware.edge(first, KeyboardFnKey(page: 7, usage: 4), down: true)
        #expect(controller.captureRowID == nil)
        #expect(controller.captureMessageKey == "keyboard_fn.capture.multiple")
        hardware.edge(first, .rightControl, down: false)
        hardware.edge(first, KeyboardFnKey(page: 7, usage: 4), down: false)
        controller.refresh()
        try await settle()
        controller.beginRecording(rowID: row.id)
        try await settle()
        controller.cancelCapture(reason: "left_keyboard_page")
        #expect(controller.capturedKey == nil)
        #expect(store.value.profiles.isEmpty)
        controller.stop()
    }

    @Test func permissionFailureRecoversWithoutTouchingOtherDevice() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        store.value.profiles = [profile(first)]
        hardware.permissionGranted = false
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        #expect(hardware.writes.isEmpty)
        hardware.permissionGranted = true
        controller.refresh()
        try await settle()
        #expect(controller.rows.first?.status == .enabled)
        controller.disableAll()
        try await settle()
        controller.stop()
    }

    @Test func logsContainOnlyTriggerDurationAndNoOrdinaryKeysOrIdentities() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        store.value.profiles = [profile(first)]
        var logs: [String] = []
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { logs.append($0) })
        controller.start()
        try await settle()
        let count = logs.count
        hardware.edge(first, KeyboardFnKey(page: 7, usage: 4), down: true)
        hardware.edge(first, KeyboardFnKey(page: 7, usage: 4), down: false)
        #expect(logs.count == count)
        hardware.edge(first, .rightControl, down: true)
        hardware.edge(first, .rightControl, down: false)
        #expect(logs.last?.contains("held_ms=") == true)
        #expect(logs.allSatisfy { !$0.contains(first.name) && !$0.contains("boot-one") && !$0.contains("profile_id=") && !$0.contains("raw_id=") })
        controller.disableAll()
        try await settle()
        controller.stop()
    }

    @Test func quittingRestoresMappingsAndRetainsEnabledIntent() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        store.value.profiles = [profile(first)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        let result = await withCheckedContinuation { continuation in
            controller.prepareForTermination { continuation.resume(returning: $0) }
        }
        #expect(result)
        #expect(hardware.values[11] == [])
        #expect(store.value.profiles.first?.enabled == true)
        #expect(store.value.recovery.isEmpty)
        controller.stop()
    }
    @Test func identificationRebindsOnlyAfterLeftShiftRelease() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first, second]
        var old = profile(first)
        old.identity.token = nil
        old.confirmedBoot = "previous-boot"
        old.enabled = false
        store.value.profiles = [old]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        let row = try #require(controller.rows.first { $0.profile?.id == old.id })
        #expect(row.status == .confirmation)
        controller.identify(rowID: row.id)
        let shift = KeyboardFnKey(page: 7, usage: 0xE1)
        hardware.edge(first, shift, down: true)
        #expect(store.value.profiles.first?.confirmedBoot == "previous-boot")
        hardware.edge(first, shift, down: false)
        #expect(store.value.profiles.first?.confirmedService == first.serviceID)
        #expect(controller.rows.first?.device == first)
        #expect(hardware.writes.isEmpty)
        controller.stop()
    }

    @Test func cancellingPendingEnableNeverWritesAndReconnectUsesFreshService() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        store.value.profiles = [profile(first)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        controller.disableAll()
        try await settle()
        #expect(hardware.writes.isEmpty)
        let row = try #require(controller.rows.first)
        controller.save(rowID: row.id, name: "Desk", source: .rightControl)
        try await settle()
        hardware.connected = []
        controller.refresh()
        #expect(store.value.recovery.isEmpty)
        let reconnected = KeyboardFnDevice(serviceID: 99, rawID: 9, name: first.name, identity: first.identity)
        hardware.connected = [reconnected]
        controller.refresh()
        try await settle()
        #expect(store.value.recovery.first?.device.serviceID == 99)
        #expect(hardware.values[99] == KeyboardFnPolicy.functionMapping(.rightControl))
        controller.disableAll()
        try await settle()
        controller.stop()
    }

    @Test func recordingTimesOutWithOneTerminalResultAndNoSavedDraft() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        var logs: [String] = []
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { logs.append($0) })
        controller.start()
        let row = try #require(controller.rows.first)
        controller.beginRecording(rowID: row.id)
        try await settle(15_500)
        controller.refresh()
        #expect(controller.captureRowID == nil)
        #expect(controller.captureMessageKey == "keyboard_fn.capture.timeout")
        #expect(logs.filter { $0.contains("phase=timed_out") }.count == 1)
        #expect(store.value.profiles.isEmpty)
        controller.stop()
    }

    @Test func quittingWaitsForPhysicalRelease() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        store.value.profiles = [profile(first)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        hardware.edge(first, .rightControl, down: true)
        var terminated = false
        controller.prepareForTermination { terminated = $0 }
        try await settle()
        #expect(!terminated)
        #expect(hardware.values[11] == KeyboardFnPolicy.functionMapping(.rightControl))
        hardware.edge(first, .rightControl, down: false)
        try await settle()
        #expect(terminated)
        #expect(hardware.values[11] == [])
        controller.stop()
    }

    @Test func nativeReadersStayIndependentFromRemoteHIDClients() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/RemoteMic/KeyboardFnHID.swift"), encoding: .utf8)
        #expect(source.contains("IOHIDManagerOptions.independentDevices.rawValue"))
        #expect(!source.contains("kIOHIDOptionsTypeSeizeDevice"))
        #expect(!source.contains("CGEvent(keyboardEventSource:"))
    }

    @Test func recordingWorksWhenExclusiveAccessIsUnavailable() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        let row = try #require(controller.rows.first)
        controller.beginRecording(rowID: row.id)
        try await settle()
        #expect(controller.captureRowID == row.id)
        #expect(controller.issue != .busy)
        #expect(store.value.recovery.first?.isCapture == true)
        #expect(hardware.values[first.serviceID]?.allSatisfy { $0.destination == 0 } == true)
        let key = KeyboardFnKey(page: 7, usage: 0xE6)
        hardware.edge(first, key, down: true)
        hardware.edge(first, key, down: false)
        #expect(controller.capturedKey == key)
        controller.cancelCapture()
        controller.refresh()
        try await settle()
        controller.stop()
    }

    @Test func nativeCaptureRestoresAllOwnedKeysAndPreservesExternalEdits() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        let option = KeyboardFnKey(page: 7, usage: 0xE6)
        let originalOption = HIDUsageMapping(source: option.mappingValue, destination: 0x7000000E5)
        hardware.values[11] = [unrelated, originalOption]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        let row = try #require(controller.rows.first)
        controller.beginRecording(rowID: row.id)
        try await settle()
        let external = HIDUsageMapping(source: KeyboardFnKey(page: 7, usage: 4).mappingValue, destination: 0x700000005)
        hardware.values[11] = hardware.values[11]?.filter { $0.source != external.source }
        hardware.values[11]?.append(external)
        controller.cancelCapture()
        try await settle()
        #expect(hardware.values[11]?.contains(unrelated) == true)
        #expect(hardware.values[11]?.contains(originalOption) == true)
        #expect(hardware.values[11]?.contains(external) == true)
        #expect(hardware.values[11]?.contains(where: { $0.destination == 0 }) == false)
        #expect(store.value.recovery.isEmpty)
        controller.stop()
    }

    @Test func captureCrashRecoveryRestoresKeyboardBeforeReapplyingFn() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        let p = profile(first)
        store.value.profiles = [p]
        let keys = try hardware.availableKeys(first.rawID)
        let record = KeyboardFnRecovery(profileID: p.id, boot: hardware.boot,
            device: KeyboardFnDeviceRecord(serviceID: 11, rawID: 1), source: .rightControl, original: [],
            captureKeys: keys.sorted { $0.usage < $1.usage })
        store.value.recovery = [record]
        hardware.values[11] = [unrelated] + record.desiredMappings
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle(700)
        #expect(hardware.writes.first?.1 == [unrelated])
        #expect(hardware.values[11] == [unrelated] + KeyboardFnPolicy.functionMapping(.rightControl))
        #expect(store.value.recovery.first?.isCapture == false)
        #expect(store.value.recovery.first?.original == [])
        controller.disableAll()
        try await settle()
        #expect(hardware.values[11] == [unrelated])
        controller.stop()
    }

    @Test func recordingAnEnabledProfileResumesItsSavedRuleAfterCancel() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        hardware.values[11] = [unrelated]
        store.value.profiles = [profile(first)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        let row = try #require(controller.rows.first)
        controller.beginRecording(rowID: row.id)
        try await settle(700)
        #expect(store.value.recovery.first?.isCapture == true)
        #expect(store.value.recovery.first?.original.contains(where: { $0.destination == KeyboardFnPolicy.functionValue }) == false)
        controller.cancelCapture()
        try await settle(700)
        #expect(hardware.values[11] == [unrelated] + KeyboardFnPolicy.functionMapping(.rightControl))
        #expect(controller.rows.first?.status == .enabled)
        controller.disableAll()
        try await settle()
        controller.stop()
    }

    @Test func everyDiscoveryUsesAFreshEventServiceSnapshot() {
        var clientsCreated = 0
        let hardware = KeyboardFnHID(clientFactory: {
            clientsCreated += 1
            return IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        })
        let beforeFirst = clientsCreated
        _ = hardware.devices()
        let afterFirst = clientsCreated
        _ = hardware.devices()
        #expect(afterFirst == beforeFirst + 1)
        #expect(clientsCreated == afterFirst + 1)
    }

    @Test func connectedKeyboardWithoutAReadyChannelRecoversItsSavedRule() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        store.value.profiles = [profile(first)]
        hardware.unreadyIdentities = [first.identity]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        #expect(controller.rows.first?.status == .channelUnavailable)
        #expect(hardware.writes.isEmpty)
        hardware.unreadyIdentities = []
        hardware.connected = [first]
        controller.refresh()
        try await settle()
        #expect(controller.rows.first?.status == .enabled)
        #expect(hardware.values[11] == KeyboardFnPolicy.functionMapping(.rightControl))
        hardware.connected = []
        controller.refresh()
        #expect(controller.rows.first?.status == .offline)
        #expect(store.value.profiles.first?.enabled == true)
        controller.stop()
    }

    @Test func uncertainUnreadyIdentityDoesNotBindAnotherKeyboard() {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        store.value.profiles = [profile(first)]
        hardware.unreadyIdentities = [second.identity]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        #expect(controller.rows.first?.status == .offline)
        #expect(hardware.writes.isEmpty)
        controller.stop()
    }

    @Test func duplicateProfilesNeedConfirmationWhileTheirChannelIsUnavailable() {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        store.value.profiles = [profile(first), profile(first)]
        hardware.unreadyIdentities = [first.identity]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        #expect(controller.rows.count == 2)
        #expect(controller.rows.allSatisfy { $0.status == .confirmation })
        #expect(hardware.writes.isEmpty)
        controller.stop()
    }

    @Test func unchangedNativeDiscoveryDoesNotRepeatDiagnostics() {
        var logs: [String] = []
        let hardware = KeyboardFnHID(logger: { logs.append($0) })
        _ = hardware.devices()
        _ = hardware.devices()
        _ = hardware.devices()
        #expect(logs.count == 1)
        #expect(logs[0].contains("KEYBOARD_FN HID_SNAPSHOT"))
        #expect(logs[0].contains("external_result=unknown"))
        #expect(!logs[0].contains("registry"))
    }

    @Test func transientReadFailureRecoversWithoutChangingDeviceIdentity() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first, second]
        hardware.unreadableDevices = [first.rawID]
        store.value.profiles = [profile(first), profile(second)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        #expect(hardware.values[first.serviceID] == nil)
        #expect(controller.rows.first(where: { $0.device == second })?.status == .enabled)
        let otherWrites = hardware.writes.filter { $0.0 == second.serviceID }.count
        hardware.unreadableDevices.remove(first.rawID)
        controller.refresh()
        try await settle()
        #expect(controller.rows.first(where: { $0.device == first })?.status == .enabled)
        #expect(hardware.values[first.serviceID] == KeyboardFnPolicy.functionMapping(.rightControl))
        #expect(hardware.writes.filter { $0.0 == second.serviceID }.count == otherWrites)
        controller.disableAll()
        try await settle()
        controller.stop()
    }

    @Test func transientRestoreFailureRecoversWhileRuleStaysDisabled() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        store.value.profiles = [profile(first)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        hardware.unreadableDevices.insert(first.rawID)
        let row = try #require(controller.rows.first)
        controller.disable(rowID: row.id)
        #expect(store.value.recovery.count == 1)
        hardware.unreadableDevices.remove(first.rawID)
        controller.refresh()
        try await settle()
        #expect(store.value.recovery.isEmpty)
        #expect(hardware.values[first.serviceID] == [])
        #expect(store.value.profiles.first?.enabled == false)
        controller.stop()
    }

    @Test func automaticRecoveryWaitsForTheTriggerToBeReleased() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        hardware.unreadableDevices = [first.rawID]
        store.value.profiles = [profile(first)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        hardware.unreadableDevices.remove(first.rawID)
        hardware.edge(first, .rightControl, down: true)
        controller.refresh()
        try await settle()
        #expect(hardware.writes.isEmpty)
        hardware.edge(first, .rightControl, down: false)
        controller.refresh()
        try await settle()
        #expect(controller.rows.first?.status == .enabled)
        controller.disableAll()
        try await settle()
        controller.stop()
    }

    @Test func anotherKeyboardReconnectingDoesNotClearAnExternalMappingConflict() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        store.value.profiles = [profile(first)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        let external = HIDUsageMapping(source: KeyboardFnKey.rightControl.mappingValue, destination: 77)
        hardware.values[first.serviceID] = [external]
        controller.refresh()
        #expect(controller.rows.first?.status == .failed(.conflict))
        hardware.connected.append(second)
        controller.refresh()
        try await settle()
        #expect(hardware.values[first.serviceID] == [external])
        #expect(controller.rows.first(where: { $0.profile != nil })?.status == .failed(.conflict))
        controller.disableAll()
        try await settle()
        controller.stop()
    }

    @Test func unavailableKeyboardShowsOfflineAfterItDisconnects() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        hardware.unreadableDevices = [first.rawID]
        store.value.profiles = [profile(first)]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        try await settle()
        #expect(controller.rows.first?.status == .recovering)
        hardware.connected = []
        controller.refresh()
        #expect(controller.rows.first?.status == .offline)
        controller.stop()
    }

    @Test func unsavedCaptureRestoresAfterATransientReadFailure() async throws {
        let hardware = KeyboardFnTestHardware(), store = KeyboardFnTestStore()
        hardware.connected = [first]
        let controller = KeyboardFnController(hardware: hardware, store: store, logger: { _ in })
        controller.start()
        let row = try #require(controller.rows.first)
        controller.beginRecording(rowID: row.id)
        try await settle()
        #expect(store.value.recovery.first?.isCapture == true)
        hardware.unreadableDevices.insert(first.rawID)
        controller.cancelCapture()
        #expect(store.value.recovery.count == 1)
        hardware.unreadableDevices.remove(first.rawID)
        controller.refresh()
        try await settle()
        #expect(store.value.recovery.isEmpty)
        #expect(store.value.profiles.isEmpty)
        #expect(hardware.values[first.serviceID] == [])
        controller.stop()
    }

}
