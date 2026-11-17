#pragma once
#include <CoreAudio/CoreAudio.h>
#include <cstdint>
#include <string>

namespace mixer {
AudioDeviceID deviceForUID(const std::string &uid);
bool deviceAlive(AudioDeviceID device);
uint32_t channelCount(AudioDeviceID device, AudioObjectPropertyScope scope);
uint64_t nowNS() noexcept;
}
