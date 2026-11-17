#include "Devices.hpp"
#include "Product.hpp"
#import <Foundation/Foundation.h>
#include <chrono>

namespace mixer {
uint64_t nowNS() noexcept {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

AudioDeviceID deviceForUID(const std::string &uid) {
    if (uid.empty()) return kAudioObjectUnknown;
    CFStringRef value = CFStringCreateWithCString(nullptr, uid.c_str(), kCFStringEncodingUTF8);
    if (!value) return kAudioObjectUnknown;
    AudioDeviceID result = kAudioObjectUnknown;
    AudioObjectPropertyAddress address{kAudioHardwarePropertyTranslateUIDToDevice,
                                      kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(result);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
                                               sizeof(value), &value, &size, &result);
    CFRelease(value);
    return status == noErr ? result : kAudioObjectUnknown;
}

bool deviceAlive(AudioDeviceID device) {
    if (device == kAudioObjectUnknown) return false;
    UInt32 alive = 0, size = sizeof(alive);
    AudioObjectPropertyAddress address{kAudioDevicePropertyDeviceIsAlive,
                                      kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &alive) == noErr && alive != 0;
}

uint32_t channelCount(AudioDeviceID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address{kAudioDevicePropertyStreamConfiguration, scope,
                                      kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr || size < sizeof(AudioBufferList)) return 0;
    std::vector<uint8_t> storage(size);
    auto *list = reinterpret_cast<AudioBufferList *>(storage.data());
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, list) != noErr) return 0;
    uint32_t channels = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) channels += list->mBuffers[i].mNumberChannels;
    return channels;
}

}
