import CoreAudio
import Foundation

enum MicrophoneMixerDemandObservation {
    /// Only public HAL input-scope facts are queried. Process identities and
    /// device identifiers are never exported or logged.
    static func inputInUse(deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard let processes: [AudioObjectID] = values(object: AudioObjectID(kAudioObjectSystemObject), address: &address)
        else { return nil }
        var unknown = false
        for process in processes {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard let identifiers: [pid_t] = values(object: process, address: &pidAddress),
                  let identifier = identifiers.first else { unknown = true; continue }
            // Our physical-input capture also makes this process input-active.
            // It must never keep its own virtual-output demand latched on.
            if identifier == ProcessInfo.processInfo.processIdentifier { continue }
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard let running: [UInt32] = values(object: process, address: &runningAddress), let active = running.first
            else { unknown = true; continue }
            guard active != 0 else { continue }
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyDevices,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            guard let devices: [AudioObjectID] = values(object: process, address: &devicesAddress)
            else { unknown = true; continue }
            if devices.contains(deviceID) { return true }
        }
        return unknown ? nil : false
    }

    private static func values<T>(object: AudioObjectID, address: inout AudioObjectPropertyAddress) -> [T]? {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        let stride = MemoryLayout<T>.stride
        guard Int(size) % stride == 0 else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr else { return nil }
        return Array(UnsafeBufferPointer(start: storage.assumingMemoryBound(to: T.self), count: Int(size) / stride))
    }
}
