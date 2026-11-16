import Darwin
import Foundation

struct MicrophoneMixerInput: Codable, Identifiable, Equatable {
    var id = UUID()
    var deviceUID = ""
    var name = ""
    var gain = 0.7
    var muted = false
}

struct MicrophoneMixerConfiguration: Codable, Equatable {
    var inputs: [MicrophoneMixerInput] = []
    var masterGain = 0.75
    var restoreOnLaunch = false
    var outputUID = ""

    mutating func validate() {
        var seen = Set<String>()
        inputs = inputs.filter { $0.deviceUID.isEmpty || seen.insert($0.deviceUID).inserted }
        masterGain = Self.validGain(masterGain, fallback: 0.75)
        for index in inputs.indices {
            inputs[index].gain = Self.validGain(inputs[index].gain, fallback: 0.7)
        }
    }

    private static func validGain(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1.5) : fallback
    }
}

struct MicrophoneMixerInputStatus: Decodable {
    let deviceUID: String
    let receiving: Bool
    let connected: Bool
    let peak: Float
    let muted: Bool
}

struct MicrophoneMixerStatus: Decodable {
    var running = false
    var starting = false
    var outputReady = false
    var allReceiving = false
    var anyReceiving = false
    var outputPeak: Float = 0
    var droppedFrames: UInt64 = 0
    var underrunFrames: UInt64 = 0
    var clippedFrames: UInt64 = 0
    var renderCallbacks: UInt64 = 0
    var stopReason = "none"
    var normalStop = true
    var interruptedFrames: UInt64 = 0
    var inputs: [MicrophoneMixerInputStatus] = []
}

struct MicrophoneMixerCaptureDemand {
    private var idleSince: TimeInterval?

    mutating func wantsCapture(armed: Bool, clientInUse: Bool?, capturing: Bool, now: TimeInterval) -> Bool {
        guard armed else { idleSince = nil; return false }
        if clientInUse == true { idleSince = nil; return true }
        guard clientInUse == false, capturing else { idleSince = nil; return false }
        let inactiveAt = idleSince ?? now
        idleSince = inactiveAt
        return now - inactiveAt < 1
    }
}

/// The serial queue owns the dynamic library, handle and every engine call.
/// Loading is limited to the native engine shipped inside this SayAll bundle.
final class MicrophoneMixerEngine: @unchecked Sendable {
    private typealias Create = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
    private typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    private typealias Start = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias Controls = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    private typealias Stop = @convention(c) (OpaquePointer?) -> Void
    private typealias Snapshot = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    private typealias Free = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private struct Functions {
        let library: UnsafeMutableRawPointer
        let create: Create
        let destroy: Destroy
        let start: Start
        let controls: Controls
        let stop: Stop
        let snapshot: Snapshot
        let free: Free
    }

    enum Failure: Error { case unavailable, invalidStatus }
    private struct StartResult: Decodable { let ok: Bool }
    private let queue = DispatchQueue(label: "com.hd838a.RemoteMic.microphone-mixer", qos: .userInitiated)
    private let bundle: Bundle
    private var functions: Functions?
    private var handle: OpaquePointer?

    init(bundle: Bundle = .main) { self.bundle = bundle }

    var available: Bool {
        FileManager.default.fileExists(atPath: libraryURL.path)
    }

    private var libraryURL: URL {
        bundle.bundleURL.appendingPathComponent("Contents/Frameworks/libSayAllMicrophoneMixer.dylib")
    }

    private func load() throws -> Functions {
        if let functions { return functions }
        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else { throw Failure.unavailable }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw Failure.unavailable }
            return unsafeBitCast(pointer, to: type)
        }
        do {
            let loaded = try Functions(
                library: library,
                create: symbol("mm_engine_create", as: Create.self),
                destroy: symbol("mm_engine_destroy", as: Destroy.self),
                start: symbol("mm_engine_start", as: Start.self),
                controls: symbol("mm_engine_controls", as: Controls.self),
                stop: symbol("mm_engine_stop", as: Stop.self),
                snapshot: symbol("mm_engine_snapshot", as: Snapshot.self),
                free: symbol("mm_free_string", as: Free.self)
            )
            functions = loaded
            return loaded
        } catch {
            dlclose(library)
            throw error
        }
    }

    private func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as type: T.Type, functions: Functions) throws -> T {
        guard let pointer else { throw Failure.invalidStatus }
        defer { functions.free(pointer) }
        return try JSONDecoder().decode(type, from: Data(String(cString: pointer).utf8))
    }

    func start(_ configuration: MicrophoneMixerConfiguration, completion: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            var succeeded = false
            do {
                let functions = try self.load()
                if self.handle == nil {
                    self.handle = self.bundle.bundlePath.withCString { functions.create($0) }
                }
                let data = try JSONEncoder().encode(configuration)
                let result = try String(decoding: data, as: UTF8.self).withCString {
                    try self.decode(functions.start(self.handle, $0), as: StartResult.self, functions: functions)
                }
                succeeded = result.ok
            } catch { succeeded = false }
            let value = succeeded
            self.deliver { completion(value) }
        }
    }

    func refresh(completion: @escaping @MainActor (MicrophoneMixerStatus?) -> Void) {
        queue.async {
            var status: MicrophoneMixerStatus? = MicrophoneMixerStatus()
            if let functions = self.functions, let handle = self.handle {
                status = try? self.decode(functions.snapshot(handle), as: MicrophoneMixerStatus.self, functions: functions)
            }
            let value = status
            self.deliver { completion(value) }
        }
    }

    func controls(_ configuration: MicrophoneMixerConfiguration) {
        queue.async {
            guard let functions = self.functions, let data = try? JSONEncoder().encode(configuration) else { return }
            String(decoding: data, as: UTF8.self).withCString { functions.controls(self.handle, $0) }
        }
    }

    func stop(completion: @escaping @MainActor (MicrophoneMixerStatus) -> Void) {
        queue.async {
            var status = MicrophoneMixerStatus()
            if let functions = self.functions {
                functions.stop(self.handle)
                status = (try? self.decode(functions.snapshot(self.handle), as: MicrophoneMixerStatus.self,
                                           functions: functions)) ?? MicrophoneMixerStatus(stopReason: "status_unavailable", normalStop: false)
            }
            let value = status
            self.deliver { completion(value) }
        }
    }

    func shutdown(completion: @escaping @MainActor () -> Void) {
        queue.async {
            if let functions = self.functions {
                functions.destroy(self.handle)
                self.handle = nil
                // OBS registers process-wide Objective-C classes. Keep its library
                // mapped until process exit so delayed runtime work stays valid.
            }
            self.deliver(completion)
        }
    }
    private func deliver(_ completion: @escaping @MainActor () -> Void) {
        // AppKit's terminateLater loop can be nested inside a main-dispatch
        // signal handler. Run-loop blocks remain serviceable in that loop.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { completion() }
        }
    }

}
