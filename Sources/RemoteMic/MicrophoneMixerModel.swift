import AppKit
import AVFoundation
import Combine

@MainActor
final class MicrophoneMixerModel: ObservableObject {
    @Published private(set) var configuration: MicrophoneMixerConfiguration
    @Published private(set) var devices: [AudioDeviceInfo] = []
    @Published private(set) var output: AudioDeviceInfo?
    @Published private(set) var status = MicrophoneMixerStatus()
    @Published private(set) var armed = false
    @Published private(set) var busy = false
    @Published private(set) var stateKey = "mixer.state.stopped"
    @Published private(set) var errorKey: String?

    private let engine: MicrophoneMixerEngine
    private let defaults: UserDefaults
    private let outputUID: () -> String
    private let singleMicrophoneActive: () -> Bool
    private let armedChanged: (Bool) -> Void
    private let catalogQueue = DispatchQueue(label: "com.hd838a.RemoteMic.mixer-devices")
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var demand = MicrophoneMixerCaptureDemand()
    private var polling = false
    private var sleeping = false
    private var terminating = false
    private var permissionRequested = false
    private var generation: UInt = 0
    private var captureStartedAt: TimeInterval = 0
    private var nextRecovery: TimeInterval = 0
    private var recoveryAttempts = 0
    private var restored = false
    private static let settingsKey = "microphoneMixerConfiguration"

    init(
        defaults: UserDefaults = .standard,
        engine: MicrophoneMixerEngine = MicrophoneMixerEngine(),
        outputUID: @escaping () -> String,
        singleMicrophoneActive: @escaping () -> Bool,
        armedChanged: @escaping (Bool) -> Void
    ) {
        self.defaults = defaults
        self.engine = engine
        self.outputUID = outputUID
        self.singleMicrophoneActive = singleMicrophoneActive
        self.armedChanged = armedChanged
        configuration = defaults.data(forKey: Self.settingsKey).flatMap {
            try? JSONDecoder().decode(MicrophoneMixerConfiguration.self, from: $0)
        } ?? MicrophoneMixerConfiguration()
        configuration.validate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = true
                self.pause(reason: "system_sleep")
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = false
                self?.nextRecovery = ProcessInfo.processInfo.systemUptime + 2
                self?.refresh()
            }
        })
        refresh()
    }

    var available: Bool { engine.available }
    var canStart: Bool {
        available && output != nil && !configuration.inputs.isEmpty &&
            configuration.inputs.allSatisfy { !$0.deviceUID.isEmpty } &&
            configuration.inputs.contains { input in devices.contains { $0.uid == input.deviceUID } }
    }

    func refresh() {
        guard !polling, !busy, !sleeping, !terminating else { return }
        polling = true
        let selectedUID = outputUID()
        let version = generation
        catalogQueue.async { [weak self] in
            let outputs = CoreAudioDeviceCatalog.outputDevices()
            let selected = outputs.first {
                $0.uid == selectedUID && [.miRemoteV2ch, .blackHole2ch].contains(VirtualAudioDeviceDiagnosticKind.classify($0))
            }
            let devices = CoreAudioDeviceCatalog.inputDevices().filter {
                $0.uid != selectedUID
            }
            let inUse = selected.flatMap { MicrophoneMixerDemandObservation.inputInUse(deviceID: $0.id) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.engine.refresh { [weak self] snapshot in
                    guard let self else { return }
                    self.polling = false
                    guard version == self.generation, !self.busy, !self.terminating, !self.sleeping else { return }
                    self.devices = devices
                    self.output = selected
                    self.status = snapshot ?? MicrophoneMixerStatus()
                    if self.armed && self.configuration.outputUID != selectedUID {
                        self.stop(reason: "output_changed")
                        self.errorKey = "mixer.error.output_changed"
                        return
                    }
                    if !self.restored {
                        if !self.configuration.restoreOnLaunch || self.configuration.inputs.isEmpty {
                            self.restored = true
                        } else if self.canStart, !self.singleMicrophoneActive() {
                            self.restored = true
                            self.start(source: "launch")
                        }
                    }
                    self.reconcile(inUse: inUse)
                }
            }
        }
    }

    func start(source: String = "user") {
        guard !busy, !terminating else { return }
        restored = true
        generation &+= 1
        log("REQUEST", "phase=requested source=\(source)")
        guard !singleMicrophoneActive() else {
            errorKey = "mixer.error.single_microphone"
            log("REQUEST", "phase=completed result=rejected reason=single_microphone_active")
            return
        }
        guard canStart else {
            errorKey = available ? "mixer.error.selection" : "mixer.error.engine"
            log("REQUEST", "phase=completed result=rejected reason=configuration_unavailable")
            return
        }
        armed = true
        armedChanged(true)
        configuration.outputUID = outputUID()
        errorKey = nil
        nextRecovery = 0
        recoveryAttempts = 0
        demand = MicrophoneMixerCaptureDemand()
        transition("mixer.state.standby", reason: "armed")
        log("REQUEST", "phase=completed result=armed input_count=\(configuration.inputs.count)")
        refresh()
    }

    private func reconcile(inUse: Bool?) {
        guard armed else { return }
        guard output != nil else {
            if status.running { pause(reason: "output_unavailable") }
            else { transition("mixer.state.output_missing", reason: "output_unavailable") }
            errorKey = "mixer.error.output"
            return
        }
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .denied || permission == .restricted {
            stop(reason: "permission_revoked")
            errorKey = "mixer.error.permission"
            return
        }
        let wantsCapture = demand.wantsCapture(armed: armed, clientInUse: inUse,
                                              capturing: status.running, now: ProcessInfo.processInfo.systemUptime)
        guard wantsCapture else {
            if status.running { pause(reason: inUse == nil ? "demand_unknown" : "last_reader_stopped") }
            else { transition(inUse == nil ? "mixer.state.unknown" : "mixer.state.standby", reason: "demand_observed") }
            return
        }
        if permission == .notDetermined {
            requestPermission()
            return
        }
        if status.outputReady {
            recoveryAttempts = 0
            errorKey = nil
            let key = status.anyReceiving
                ? (status.allReceiving ? "mixer.state.running" : "mixer.state.partial")
                : "mixer.state.waiting"
            transition(key, reason: "render_observed")
        } else if !status.starting, ProcessInfo.processInfo.systemUptime >= nextRecovery {
            beginCapture()
        }
    }

    private func requestPermission() {
        guard !permissionRequested else { return }
        permissionRequested = true
        let version = generation
        transition("mixer.state.permission", reason: "permission_requested")
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.permissionRequested = false
                guard version == self.generation, self.armed, !self.terminating else {
                    self.log("PERMISSION", "phase=completed result=ignored reason=stale_generation")
                    return
                }
                self.log("PERMISSION", "phase=completed result=\(granted ? "granted" : "denied")")
                if granted { self.refresh() }
                else { self.stop(reason: "permission_denied"); self.errorKey = "mixer.error.permission" }
            }
        }
    }

    private func beginCapture() {
        guard !busy, armed, canStart else { return }
        busy = true
        generation &+= 1
        let version = generation
        let started = ProcessInfo.processInfo.systemUptime
        captureStartedAt = started
        recoveryAttempts += 1
        nextRecovery = started + min(pow(2, Double(recoveryAttempts)), 30)
        transition("mixer.state.preparing", reason: "reader_active")
        log("CAPTURE", "phase=started result=pending input_count=\(configuration.inputs.count)")
        engine.start(configuration) { [weak self] succeeded in
            guard let self, version == self.generation, !self.terminating else { return }
            self.busy = false
            if succeeded { self.engine.controls(self.configuration) }
            self.log("CAPTURE", "phase=completed result=\(succeeded ? "started" : "failed") elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
            if !succeeded { self.errorKey = "mixer.error.capture" }
            self.refresh()
        }
    }

    func stop(reason: String = "user") {
        restored = true
        armed = false
        armedChanged(false)
        pause(reason: reason)
    }

    private func pause(reason: String) {
        generation &+= 1
        let version = generation
        busy = true
        demand = MicrophoneMixerCaptureDemand()
        transition("mixer.state.stopping", reason: reason)
        log("DRAIN", "phase=requested reason=\(reason)")
        engine.stop { [weak self] status in
            guard let self, version == self.generation, !self.terminating else { return }
            self.busy = false
            self.status = MicrophoneMixerStatus()
            self.log("DRAIN", "phase=completed completion=\(status.normalStop ? "normal" : "forced") interrupted_samples=\(status.interruptedFrames) drain_reason=\(status.stopReason) reason=\(reason)")
            if !status.normalStop { self.errorKey = "mixer.error.interrupted" }
            self.transition(self.armed ? "mixer.state.standby" : "mixer.state.stopped", reason: reason)
        }
    }

    func addInput() {
        guard !armed, !busy else { return }
        configuration.inputs.append(MicrophoneMixerInput())
        save()
    }

    func removeInput(_ id: UUID) {
        guard !armed, !busy else { return }
        configuration.inputs.removeAll { $0.id == id }
        save()
    }

    func selectInput(_ uid: String, id: UUID) {
        guard !armed, !busy, let index = configuration.inputs.firstIndex(where: { $0.id == id }),
              !configuration.inputs.contains(where: { $0.id != id && $0.deviceUID == uid }),
              let device = devices.first(where: { $0.uid == uid }) else { return }
        configuration.inputs[index].deviceUID = uid
        configuration.inputs[index].name = device.name
        save()
    }

    func setGain(_ gain: Double, id: UUID) {
        guard let index = configuration.inputs.firstIndex(where: { $0.id == id }) else { return }
        configuration.inputs[index].gain = gain
        save(updateEngine: true)
    }

    func setMuted(_ muted: Bool, id: UUID) {
        guard let index = configuration.inputs.firstIndex(where: { $0.id == id }) else { return }
        configuration.inputs[index].muted = muted
        save(updateEngine: true)
    }

    func setMasterGain(_ gain: Double) { configuration.masterGain = gain; save(updateEngine: true) }
    func setRestoreOnLaunch(_ enabled: Bool) { configuration.restoreOnLaunch = enabled; save() }

    private func save(updateEngine: Bool = false) {
        configuration.validate()
        guard let data = try? JSONEncoder().encode(configuration) else { errorKey = "mixer.error.save"; return }
        defaults.set(data, forKey: Self.settingsKey)
        if updateEngine, armed, !busy { engine.controls(configuration) }
    }

    func shutdown(completion: @escaping @MainActor () -> Void) {
        terminating = true
        generation &+= 1
        armed = false
        armedChanged(false)
        timer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        engine.stop { [weak self] status in
            self?.log("DRAIN", "phase=completed completion=\(status.normalStop ? "normal" : "forced") interrupted_samples=\(status.interruptedFrames) drain_reason=\(status.stopReason) reason=application_exit")
            self?.engine.shutdown(completion: completion)
        }
    }

    private func transition(_ key: String, reason: String) {
        guard stateKey != key else { return }
        stateKey = key
        if status.outputReady {
            let elapsed = max(0, Int((ProcessInfo.processInfo.systemUptime - captureStartedAt) * 1000))
            log("OUTPUT", "phase=observed result=rendering render_callbacks=\(status.renderCallbacks) " +
                "receiving_input_count=\(status.inputs.filter { $0.receiving }.count) " +
                "dropped_samples=\(status.droppedFrames) elapsed_ms=\(elapsed)")
        }
        log("STATE", "phase=changed state=\(key.replacingOccurrences(of: "mixer.state.", with: "")) reason=\(reason)")
    }

    private func log(_ action: String, _ fields: String) {
        AppLogger.shared.write("MICROPHONE MIXER \(action) operation_id=\(generation) \(fields)")
    }
}
