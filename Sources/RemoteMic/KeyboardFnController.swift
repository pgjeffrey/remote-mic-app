import AppKit
import Combine
import Foundation

struct KeyboardFnRow: Identifiable, Equatable {
    let id: String
    let profile: KeyboardFnProfile?
    let device: KeyboardFnDevice?
    let status: KeyboardFnStatus
    var name: String { profile?.name ?? device?.name ?? "" }
    var source: KeyboardFnKey { profile?.source ?? .rightControl }
    var enabled: Bool { profile?.enabled ?? false }
}

enum KeyboardFnStatus: Equatable {
    case disabled, enabled, offline, confirmation, waiting, unavailable, recording, identifying, channelUnavailable, recovering
    case failed(KeyboardFnFailure)
    var messageKey: String {
        switch self {
        case .disabled: return "keyboard_fn.status.disabled"
        case .enabled: return "keyboard_fn.status.enabled"
        case .offline: return "keyboard_fn.status.offline"
        case .confirmation: return "keyboard_fn.status.confirmation"
        case .waiting: return "keyboard_fn.status.waiting"
        case .unavailable: return "keyboard_fn.status.unavailable"
        case .channelUnavailable: return "keyboard_fn.status.channel_unavailable"
        case .recovering: return "keyboard_fn.status.recovering"
        case .recording: return "keyboard_fn.status.recording"
        case .identifying: return "keyboard_fn.status.identifying"
        case .failed(let failure): return failure.messageKey
        }
    }
}

/// Main-run-loop owner of the HID mappings and their write-ahead recovery records.
final class KeyboardFnController: ObservableObject {
    @Published private(set) var rows: [KeyboardFnRow] = []
    @Published private(set) var permissionGranted = false
    @Published private(set) var issue: KeyboardFnFailure?
    @Published private(set) var captureRowID: String?
    @Published private(set) var captureIsIdentification = false
    @Published private(set) var capturedKey: KeyboardFnKey?
    @Published private(set) var captureMessageKey: String?

    private let hardware: KeyboardFnHardware
    private let store: KeyboardFnStoring
    private let logger: (String) -> Void
    private(set) var configuration = KeyboardFnConfiguration()
    private var devices: [KeyboardFnDevice] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var suspended = false
    private var terminating = false
    private var restoringAtStartup: Set<UInt64> = []
    private var busyServices: Set<UInt64> = []
    private var suspendedProfiles: Set<UUID> = []
    private var failures: [UUID: KeyboardFnFailure] = [:]
    private var blockedRestores: Set<UInt64> = []
    private var operationID = 0
    private var generation = 0
    private var captureOperationID = 0
    private var captureCandidate: (UInt64, KeyboardFnKey)?
    private var captureDeadline: Date?
    private var capturedDown = false
    private var captureServiceID: UInt64?
    private var sourceDownTimes: [UInt64: (time: UInt64, operation: Int)] = [:]
    private var loadingFailed = false

    var hasProfiles: Bool { !configuration.profiles.isEmpty }

    var allEnabled: Bool {
        !configuration.profiles.isEmpty && configuration.profiles.allSatisfy(\.enabled)
    }

    init(hardware: KeyboardFnHardware = KeyboardFnHID(), store: KeyboardFnStoring = KeyboardFnStore(),
         logger: @escaping (String) -> Void = { AppLogger.shared.write($0) }) {
        self.hardware = hardware
        self.store = store
        self.logger = logger
        do {
            configuration = try store.load()
            restoringAtStartup = Set(configuration.recovery.map { $0.device.serviceID })
        } catch {
            loadingFailed = true
            issue = .storage
        }
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func start() {
        guard !started else { return }
        started = true
        hardware.onKey = { [weak self] raw, key, down in self?.received(raw: raw, key: key, down: down) }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard let self else { return }
                self.suspended = notification.name == NSWorkspace.willSleepNotification
                self.cancelCapture(reason: "sleep")
                self.restoringAtStartup.formUnion(self.configuration.recovery.map { $0.device.serviceID })
                self.refresh()
            })
        }
    }

    func refresh() {
        let granted = hardware.permissionGranted
        if granted != permissionGranted {
            permissionGranted = granted
            logger("KEYBOARD_FN PERMISSION phase=changed input_monitoring=\(granted)")
            if granted {
                failures = failures.filter { $0.value != .permission }
                blockedRestores.removeAll()
            }
            else { cancelCapture(reason: "permission_revoked") }
        }
        guard !loadingFailed else { return }
        if granted {
            do {
                try hardware.start()
                if issue == .permission || issue == .unavailable { issue = nil }
            }
            catch { issue = (error as? KeyboardFnFailure) ?? .unavailable }
        }
        let previous = devices
        devices = hardware.devices()
        if devices != previous {
            logger("KEYBOARD_FN DISCOVERY phase=changed connected_count=\(devices.count)")
        }
        if captureRowID != nil {
            if let deadline = captureDeadline, Date() >= deadline { cancelCapture(reason: "timeout") }
            if !captureIsIdentification, rows.first(where: { $0.id == captureRowID })?.device.map({ prior in
                !devices.contains(where: { $0.serviceID == prior.serviceID })
            }) == true { cancelCapture(reason: "disconnect") }
            if let candidate = captureCandidate, !devices.contains(where: { $0.rawID == candidate.0 }) {
                cancelCapture(reason: "disconnect")
            }
        }
        recoverKeyStateFailures()
        reconcile()
        publishRows()
    }

    private func recoverKeyStateFailures() {
        guard permissionGranted, !suspended else { return }
        let retryable = failures.filter { $0.value == .unavailable || $0.value == .held }
        for (profileID, failure) in retryable {
            let reference: KeyboardFnDeviceRecord
            let keys: Set<KeyboardFnKey>
            if let record = configuration.recovery.first(where: { $0.profileID == profileID }),
               hardware.serviceExists(record.device.serviceID) {
                guard devices.contains(where: { $0.serviceID == record.device.serviceID && $0.rawID == record.device.rawID }) else { continue }
                reference = record.device
                keys = record.releaseKeys
            } else {
                guard !terminating,
                      let profile = configuration.profiles.first(where: { $0.id == profileID }), profile.enabled,
                      !suspendedProfiles.contains(profileID), let device = matchedDevice(profile) else { continue }
                reference = KeyboardFnDeviceRecord(serviceID: device.serviceID, rawID: device.rawID)
                keys = [profile.source]
            }
            guard !busyServices.contains(reference.serviceID) else { continue }
            do {
                guard try hardware.pressedKeys(reference.rawID, matching: keys).isEmpty else { continue }
                failures[profileID] = nil
                blockedRestores.remove(reference.serviceID)
                logger("KEYBOARD_FN RETRY phase=eligible reason=\(failure.rawValue) key_state=released external_result=unknown")
            } catch {
                // A failed sample remains unknown. The next discovery can refresh its reader.
            }
        }
    }

    private func matchedDevice(_ profile: KeyboardFnProfile) -> KeyboardFnDevice? {
        KeyboardFnPolicy.matchedDevice(for: profile, devices: devices,
                                      profiles: configuration.profiles, boot: hardware.boot)
    }

    private func publishRows() {
        var result: [KeyboardFnRow] = []
        var claimed: Set<UInt64> = []
        let observedIdentities = devices.map(\.identity) + hardware.unreadyIdentities
        for profile in configuration.profiles {
            let device = matchedDevice(profile)
            if let device { claimed.insert(device.serviceID) }
            let recovery = configuration.recovery.first { $0.profileID == profile.id }
            let status: KeyboardFnStatus
            if captureRowID == profile.id.uuidString { status = captureIsIdentification ? .identifying : .recording }
            else if let failure = failures[profile.id], failure != .unavailable { status = .failed(failure) }
            else if !permissionGranted { status = .unavailable }
            else if busyServices.contains(device?.serviceID ?? recovery?.device.serviceID ?? 0) { status = .waiting }
            else if device == nil, profile.identity.token != nil,
                    hardware.unreadyIdentities.filter({ $0 == profile.identity }).count == 1,
                    configuration.profiles.filter({ $0.identity == profile.identity }).count == 1 {
                status = .channelUnavailable
            }
            else if device == nil {
                let uncertain = observedIdentities.contains { identity in
                    if profile.identity.token != nil { return identity == profile.identity }
                    return identity.vendor == profile.identity.vendor &&
                        identity.product == profile.identity.product && identity.transport == profile.identity.transport
                }
                status = uncertain ? .confirmation : .offline
            } else if failures[profile.id] == .unavailable { status = .recovering }
            else if recovery != nil { status = .enabled }
            else { status = profile.enabled ? .waiting : .disabled }
            result.append(KeyboardFnRow(id: profile.id.uuidString, profile: profile, device: device, status: status))
        }
        for device in devices where !claimed.contains(device.serviceID) {
            result.append(KeyboardFnRow(id: "device-\(device.serviceID)", profile: nil, device: device,
                                        status: captureRowID == "device-\(device.serviceID)" ?
                                            (captureIsIdentification ? .identifying : .recording) :
                                            (permissionGranted ? .disabled : .unavailable)))
        }
        if rows != result { rows = result }
    }

    private func commit(_ updated: KeyboardFnConfiguration) throws {
        do { try store.save(updated) }
        catch { throw KeyboardFnFailure.storage }
        configuration = updated
    }

    func save(rowID: String, name: String, source: KeyboardFnKey, enable: Bool = true) {
        guard captureRowID == nil, !terminating, !loadingFailed,
              let row = rows.first(where: { $0.id == rowID }), source.isSupportedSource else { return }
        var updated = configuration
        let profile = row.profile ?? row.device.map {
            KeyboardFnProfile(identity: $0.identity, name: $0.name,
                              confirmedBoot: hardware.boot, confirmedService: $0.serviceID)
        }
        guard var profile else { issue = .unavailable; return }
        if row.profile == nil, let device = row.device,
           configuration.profiles.contains(where: { matchedDevice($0)?.serviceID == device.serviceID }) {
            issue = .ambiguous
            return
        }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        profile.name = trimmed.isEmpty ? (row.device?.name ?? row.name) : trimmed
        profile.source = source
        profile.enabled = enable
        if let index = updated.profiles.firstIndex(where: { $0.id == profile.id }) {
            updated.profiles[index] = profile
        } else { updated.profiles.append(profile) }
        do {
            try commit(updated)
            issue = nil
            failures[profile.id] = nil
            blockedRestores.removeAll()
            logOperation("save", phase: "completed", result: "configuration_saved")
            refresh()
        } catch { issue = .storage; logOperation("save", phase: "failed", result: "storage") }
    }

    func disable(rowID: String) {
        guard let profile = rows.first(where: { $0.id == rowID })?.profile else { return }
        cancelCapture(reason: "disabled")
        var updated = configuration
        updated.profiles = updated.profiles.map { value in
            var value = value
            if value.id == profile.id { value.enabled = false }
            return value
        }
        do {
            try commit(updated)
            failures[profile.id] = nil
            blockedRestores.removeAll()
            issue = nil
            logOperation("disable", phase: "requested", result: "restore_pending")
            refresh()
        } catch { issue = .storage }
    }

    func disableAll() {
        guard !loadingFailed else { issue = .storage; return }
        cancelCapture(reason: "disabled_all")
        var updated = configuration
        updated.profiles = updated.profiles.map { var value = $0; value.enabled = false; return value }
        do {
            try commit(updated)
            failures.removeAll()
            blockedRestores.removeAll()
            issue = nil
            logOperation("disable_all", phase: "requested", result: "restore_pending")
            refresh()
        } catch { issue = .storage }
    }

    func setAllEnabled(_ enabled: Bool) {
        if enabled {
            guard !loadingFailed else { issue = .storage; return }
            cancelCapture(reason: "enabled_all")
            var updated = configuration
            updated.profiles = updated.profiles.map { profile in
                var profile = profile
                profile.enabled = true
                return profile
            }
            do {
                try commit(updated)
                failures.removeAll()
                blockedRestores.removeAll()
                issue = nil
                logOperation("enable_all", phase: "requested", result: "apply_pending")
                refresh()
            } catch { issue = .storage }
        } else {
            disableAll()
        }
    }

    func setEnabled(rowID: String, enabled: Bool) {
        guard let row = rows.first(where: { $0.id == rowID }) else { return }
        if enabled {
            save(rowID: rowID, name: row.name, source: row.source, enable: true)
        } else {
            disable(rowID: rowID)
        }
    }

    private func reconcile() {
        for record in configuration.recovery {
            let service = record.device.serviceID
            guard !busyServices.contains(service) else { continue }
            if record.boot != hardware.boot || !hardware.serviceExists(service) {
                do {
                    try forgetRecovery(service)
                    restoringAtStartup.remove(service)
                    logOperation("recovery", phase: "completed", result: "original_device_session_ended")
                }
                catch { issue = .storage }
                continue
            }
            let profile = configuration.profiles.first { $0.id == record.profileID }
            let captureStillActive = record.isCapture && captureServiceID == service && captureRowID != nil
            let normalRuleChanged = !record.isCapture && (
                suspendedProfiles.contains(record.profileID) || profile?.enabled != true ||
                profile?.source != record.source || profile.flatMap(matchedDevice)?.serviceID != service)
            let shouldRestore = restoringAtStartup.contains(service) || terminating || suspended || !permissionGranted ||
                (record.isCapture && !captureStillActive) || normalRuleChanged || failures[record.profileID] != nil
            if shouldRestore {
                if !blockedRestores.contains(service) { restore(record) }
            }
            else {
                do {
                    let current = try hardware.mappings(service)
                    if KeyboardFnPolicy.entries(current, record: record) != record.desiredMappings {
                        failures[record.profileID] = .conflict
                        logger("KEYBOARD_FN MAPPING phase=changed reason=external_change_preserved external_result=unknown")
                        try forgetRecovery(service)
                    }
                } catch { failures[record.profileID] = (error as? KeyboardFnFailure) ?? .unavailable }
            }
        }
        guard !terminating, !suspended, permissionGranted else { return }
        for profile in configuration.profiles where profile.enabled && failures[profile.id] == nil &&
            !suspendedProfiles.contains(profile.id) {
            guard let device = matchedDevice(profile), !busyServices.contains(device.serviceID),
                  !configuration.recovery.contains(where: { $0.profileID == profile.id || $0.device.serviceID == device.serviceID })
            else { continue }
            apply(profile, to: device)
        }
    }

    private func forgetRecovery(_ serviceID: UInt64) throws {
        var updated = configuration
        updated.recovery.removeAll { $0.device.serviceID == serviceID }
        try commit(updated)
        blockedRestores.remove(serviceID)
        for raw in Array(sourceDownTimes.keys) where !configuration.recovery.contains(where: { $0.device.rawID == raw }) {
            if let began = sourceDownTimes.removeValue(forKey: raw) {
                logger("KEYBOARD_FN TRIGGER operation_id=\(began.operation) phase=cancelled reason=device_session_ended external_result=unknown")
            }
        }
    }

    private func afterRelease(device: KeyboardFnDeviceRecord, keys: Set<KeyboardFnKey>,
                              action: @escaping () throws -> Void, completion: @escaping (KeyboardFnFailure?) -> Void) {
        busyServices.insert(device.serviceID)
        let deadline = Date().addingTimeInterval(8)
        var releasedSince: Date?
        func poll() {
            do {
                if Date() >= deadline { throw KeyboardFnFailure.held }
                let held = try self.hardware.pressedKeys(device.rawID, matching: keys).intersection(keys)
                if held.isEmpty {
                    if let since = releasedSince, Date().timeIntervalSince(since) >= 0.2 {
                        try action()
                        self.busyServices.remove(device.serviceID)
                        completion(nil)
                        self.publishRows()
                        return
                    }
                    if releasedSince == nil { releasedSince = Date() }
                } else { releasedSince = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            } catch {
                self.busyServices.remove(device.serviceID)
                completion((error as? KeyboardFnFailure) ?? .unavailable)
                self.publishRows()
            }
        }
        poll()
    }

    private func apply(_ profile: KeyboardFnProfile, to device: KeyboardFnDevice) {
        operationID += 1
        let operation = operationID
        logger("KEYBOARD_FN APPLY operation_id=\(operation) phase=requested")
        let reference = KeyboardFnDeviceRecord(serviceID: device.serviceID, rawID: device.rawID)
        afterRelease(device: reference, keys: [profile.source], action: {
            // User intent may change while waiting for physical key-up.
            guard !self.terminating, !self.suspended,
                  self.configuration.profiles.contains(profile), !self.suspendedProfiles.contains(profile.id),
                  self.matchedDevice(profile) == device else { throw KeyboardFnFailure.busy }
            let current = try self.hardware.mappings(device.serviceID)
            let original = KeyboardFnPolicy.entries(current, source: profile.source)
            let record = KeyboardFnRecovery(profileID: profile.id, boot: self.hardware.boot, device: reference,
                                             source: profile.source, original: original)
            var updated = self.configuration
            updated.recovery.append(record)
            // Persist the original before changing system state, including partial write failures.
            try self.commit(updated)
            let desired = KeyboardFnPolicy.replacing(current, source: profile.source,
                                                      with: KeyboardFnPolicy.functionMapping(profile.source))
            try self.hardware.setMappings(desired, for: device.serviceID)
        }, completion: { failure in
            if let failure {
                if failure != .busy { self.failures[profile.id] = failure }
                self.logger("KEYBOARD_FN APPLY operation_id=\(operation) phase=failed reason=\(failure.rawValue)")
            } else {
                self.logger("KEYBOARD_FN APPLY operation_id=\(operation) phase=completed result=mapping_readback_verified external_result=unknown")
            }
        })
    }

    private func restore(_ record: KeyboardFnRecovery) {
        operationID += 1
        let operation = operationID
        logger("KEYBOARD_FN RESTORE operation_id=\(operation) phase=requested")
        afterRelease(device: record.device, keys: record.releaseKeys, action: {
            let current = try self.hardware.mappings(record.device.serviceID)
            let restored = KeyboardFnPolicy.restoringOwned(current, record: record)
            if restored != current { try self.hardware.setMappings(restored, for: record.device.serviceID) }
            try self.forgetRecovery(record.device.serviceID)
            self.restoringAtStartup.remove(record.device.serviceID)
        }, completion: { failure in
            if let failure {
                self.failures[record.profileID] = failure
                self.blockedRestores.insert(record.device.serviceID)
                self.logger("KEYBOARD_FN RESTORE operation_id=\(operation) phase=failed reason=\(failure.rawValue) recovery=retained")
            } else {
                self.logger("KEYBOARD_FN RESTORE operation_id=\(operation) phase=completed result=owned_mapping_released external_result=unknown")
                self.reconcile()
            }
        })
    }

    func beginRecording(rowID: String) {
        beginCapture(rowID: rowID, identification: false)
    }

    func identify(rowID: String) {
        beginCapture(rowID: rowID, identification: true)
    }

    private func beginCapture(rowID: String, identification: Bool) {
        cancelCapture(reason: "superseded")
        guard permissionGranted, !terminating, let row = rows.first(where: { $0.id == rowID }) else {
            issue = .permission
            return
        }
        guard identification || row.device != nil else { issue = .unavailable; return }
        operationID += 1
        captureOperationID = operationID
        captureRowID = rowID
        captureIsIdentification = identification
        capturedKey = nil
        issue = nil
        captureMessageKey = "keyboard_fn.capture.preparing"
        captureCandidate = nil
        capturedDown = false
        captureDeadline = Date().addingTimeInterval(15)
        generation += 1
        let token = generation
        if let profile = row.profile { suspendedProfiles.insert(profile.id) }
        logOperation(identification ? "identify" : "record", phase: "requested", result: "waiting_for_release")
        refresh()
        func prepare() {
            guard self.generation == token, self.captureRowID == rowID else { return }
            if let deadline = self.captureDeadline, Date() >= deadline { self.cancelCapture(reason: "timeout"); return }
            if let profile = row.profile, self.configuration.recovery.contains(where: { $0.profileID == profile.id }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: prepare)
                return
            }
            if identification {
                self.capturedDown = true
                self.captureDeadline = Date().addingTimeInterval(15)
                self.captureMessageKey = "keyboard_fn.identify.prompt"
                self.logOperation("identify", phase: "started", result: "listening")
            } else {
                guard let device = row.device else { self.cancelCapture(reason: "disconnect"); return }
                self.prepareNativeCapture(row: row, device: device, generation: token)
            }
        }
        prepare()
    }

    private func prepareNativeCapture(row: KeyboardFnRow, device: KeyboardFnDevice, generation: Int) {
        do {
            let keys = try hardware.availableKeys(device.rawID)
            guard !keys.isEmpty else { throw KeyboardFnFailure.unavailable }
            let reference = KeyboardFnDeviceRecord(serviceID: device.serviceID, rawID: device.rawID)
            afterRelease(device: reference, keys: keys, action: {
                guard self.generation == generation, self.captureRowID == row.id,
                      !self.configuration.recovery.contains(where: { $0.device.serviceID == device.serviceID })
                else { throw KeyboardFnFailure.busy }
                let current = try self.hardware.mappings(device.serviceID)
                let sources = Set(keys.map(\.mappingValue))
                let record = KeyboardFnRecovery(profileID: row.profile?.id ?? UUID(), boot: self.hardware.boot,
                    device: reference, source: row.source, original: current.filter { sources.contains($0.source) },
                    captureKeys: keys.sorted { $0.mappingValue < $1.mappingValue })
                var updated = self.configuration
                updated.schema = 2
                updated.recovery.append(record)
                try self.commit(updated)
                self.captureServiceID = device.serviceID
                try self.hardware.setMappings(current.filter { !sources.contains($0.source) } + record.desiredMappings,
                                              for: device.serviceID)
            }, completion: { failure in
                if let failure {
                    guard self.generation == generation else { return }
                    self.issue = failure
                    self.cancelCapture(reason: "capture_unavailable")
                    self.reconcile()
                } else if self.generation == generation {
                    self.capturedDown = true
                    self.captureDeadline = Date().addingTimeInterval(15)
                    self.captureMessageKey = "keyboard_fn.record.prompt"
                    self.logOperation("record", phase: "started", result: "native_keys_neutralized")
                }
            })
        } catch {
            issue = (error as? KeyboardFnFailure) ?? .unavailable
            cancelCapture(reason: "capture_unavailable")
        }
    }

    private func received(raw: UInt64, key: KeyboardFnKey, down: Bool) {
        if let rowID = captureRowID, capturedDown, let row = rows.first(where: { $0.id == rowID }) {
            let candidateDevices = devices.filter { device in
                if !captureIsIdentification { return row.device?.rawID == device.rawID }
                if let identity = row.profile?.identity {
                    return identity.vendor == device.identity.vendor && identity.product == device.identity.product &&
                        identity.transport == device.identity.transport && !configuration.profiles.contains {
                            $0.id != row.profile?.id && matchedDevice($0)?.serviceID == device.serviceID
                        }
                }
                return row.device?.rawID == device.rawID
            }
            guard candidateDevices.contains(where: { $0.rawID == raw }) else { return }
            if captureIsIdentification && key != KeyboardFnKey(page: 7, usage: 0xE1) { return }
            if down {
                guard captureCandidate == nil else {
                    if captureCandidate?.1 != key { cancelCapture(reason: "multiple_keys") }
                    return
                }
                guard key.isSupportedSource else { cancelCapture(reason: "unsupported_key"); return }
                captureCandidate = (raw, key)
            } else if captureCandidate?.0 == raw && captureCandidate?.1 == key {
                if captureIsIdentification, let device = candidateDevices.first(where: { $0.rawID == raw }),
                   let profile = row.profile {
                    var updated = configuration
                    if let index = updated.profiles.firstIndex(where: { $0.id == profile.id }) {
                        updated.profiles[index].identity = device.identity
                        updated.profiles[index].confirmedBoot = hardware.boot
                        updated.profiles[index].confirmedService = device.serviceID
                    }
                    do { try commit(updated); failures[profile.id] = nil }
                    catch { issue = .storage; cancelCapture(reason: "storage"); return }
                }
                let isIdentification = captureIsIdentification
                finishCapture()
                capturedKey = isIdentification ? nil : key
                captureMessageKey = isIdentification ? "keyboard_fn.identify.completed" : "keyboard_fn.record.completed"
                logOperation(isIdentification ? "identify" : "record", phase: "completed", result: "key_up_observed")
                refresh()
            }
            return
        }
        // Only aggregate the configured trigger's duration. Ordinary key input is never logged.
        guard let record = configuration.recovery.first(where: { !$0.isCapture && $0.device.rawID == raw && $0.source == key }) else { return }
        if down {
            if sourceDownTimes[raw] == nil, !busyServices.contains(record.device.serviceID) {
                operationID += 1
                sourceDownTimes[raw] = (DispatchTime.now().uptimeNanoseconds, operationID)
                logger("KEYBOARD_FN TRIGGER operation_id=\(operationID) phase=started down_observed=true external_result=unknown")
            }
        } else if let began = sourceDownTimes.removeValue(forKey: raw) {
            let elapsed = (DispatchTime.now().uptimeNanoseconds - began.time) / 1_000_000
            logger("KEYBOARD_FN TRIGGER operation_id=\(began.operation) phase=completed down_observed=true up_observed=true held_ms=\(elapsed) external_result=unknown")
        }
    }

    func cancelCapture(reason: String = "cancelled_by_user") {
        guard captureRowID != nil else {
            capturedKey = nil
            captureMessageKey = nil
            return
        }
        let identification = captureIsIdentification
        finishCapture()
        capturedKey = nil
        captureMessageKey = reason == "timeout" ? "keyboard_fn.capture.timeout" :
            reason == "multiple_keys" ? "keyboard_fn.capture.multiple" :
            reason == "unsupported_key" ? "keyboard_fn.capture.unsupported" : nil
        logOperation(identification ? "identify" : "record", phase: reason == "timeout" ? "timed_out" : "cancelled", result: reason)
        reconcile()
    }

    private func finishCapture() {
        generation += 1
        captureServiceID = nil
        captureRowID = nil
        captureDeadline = nil
        captureCandidate = nil
        capturedDown = false
        suspendedProfiles.removeAll()
    }

    func prepareForTermination(completion: @escaping (Bool) -> Void) {
        guard !terminating else { return }
        cancelCapture(reason: "app_quit")
        terminating = true
        blockedRestores.removeAll()
        let deadline = Date().addingTimeInterval(9)
        func poll() {
            self.refresh()
            if self.loadingFailed {
                self.terminating = false
                completion(false)
                return
            }
            if self.configuration.recovery.isEmpty && self.busyServices.isEmpty {
                self.timer?.invalidate()
                self.timer = nil
                self.hardware.stop()
                completion(true)
            } else if Date() >= deadline {
                self.terminating = false
                self.issue = .held
                completion(false)
            } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll) }
        }
        DispatchQueue.main.async(execute: poll)
    }

    /// Last chance for noninteractive termination. Pending records remain durable for next launch.
    func stop() {
        guard started else { return }
        cancelCapture(reason: "app_stop")
        timer?.invalidate()
        timer = nil
        suspended = true
        reconcile()
    }

    private func logOperation(_ action: String, phase: String, result: String) {
        let operation: Int
        if action == "record" || action == "identify" { operation = captureOperationID }
        else { operationID += 1; operation = operationID }
        logger("KEYBOARD_FN \(action.uppercased()) operation_id=\(operation) phase=\(phase) result=\(result)")
    }
}
