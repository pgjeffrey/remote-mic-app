#include "include/MixerBridge.h"
#include "Devices.hpp"
#include "HALOutput.hpp"
#include "Product.hpp"
#include <obs.h>
#include <obs-module.h>
#include <media-io/audio-io.h>
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <set>
#include <vector>
#include <thread>
#include <chrono>
#include <util/base.h>

namespace {
NSString *ns(const std::string &value) { return [NSString stringWithUTF8String:value.c_str()] ?: @""; }
char *json(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data) return strdup("{\"ok\":false,\"error\":\"状态编码失败\"}");
    char *out = static_cast<char *>(malloc(data.length + 1));
    if (!out) return nullptr;
    memcpy(out, data.bytes, data.length);
    out[data.length] = 0;
    return out;
}
NSDictionary *configuration(const char *text) {
    if (!text || !*text) return nil;
    NSString *string = [NSString stringWithUTF8String:text];
    if (!string) return nil;
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
float number(id value, float fallback) {
    if (![value isKindOfClass:NSNumber.class]) return fallback;
    float result = [value floatValue];
    return std::isfinite(result) ? std::clamp(result, 0.0f, 2.0f) : fallback;
}
bool fresh(uint64_t timestamp, uint64_t now, uint64_t age = 2000000000ULL) {
    return timestamp && now >= timestamp && now - timestamp < age;
}
void uiTask(obs_task_t task, void *parameter, bool wait) {
    if ([NSThread isMainThread]) { task(parameter); return; }
    dispatch_semaphore_t completion = wait ? dispatch_semaphore_create(0) : nullptr;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        task(parameter);
        if (completion) dispatch_semaphore_signal(completion);
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
    if (completion) dispatch_semaphore_wait(completion, DISPATCH_TIME_FOREVER);
}
struct Channel {
    std::string uid;
    obs_source_t *source = nullptr;
    std::atomic<uint64_t> lastCapture{0}, lastCaptureEnd{0};
    std::atomic<float> peak{0}, gain{0.7f};
    std::atomic<bool> muted{false};
};
void inputAudio(void *context, obs_source_t *, const audio_data *data, bool) {
    auto &channel = *static_cast<Channel *>(context);
    float peak = 0;
    for (unsigned plane = 0; plane < 2; ++plane) {
        if (!data->data[plane]) continue;
        const auto *samples = reinterpret_cast<const float *>(data->data[plane]);
        for (uint32_t frame = 0; frame < data->frames; ++frame)
            if (std::isfinite(samples[frame])) peak = std::max(peak, std::abs(samples[frame]));
    }
    if (channel.muted.load(std::memory_order_relaxed)) peak = 0;
    else peak *= channel.gain.load(std::memory_order_relaxed);
    channel.peak.store(peak, std::memory_order_relaxed);
    if (data->frames) {
        channel.lastCapture.store(mixer::nowNS(), std::memory_order_relaxed);
        channel.lastCaptureEnd.store(data->timestamp + uint64_t(data->frames) * 1000000000ULL / mixer::sampleRate);
    }
}
}

struct MMEngine {
    std::string bundlePath;
    bool initialized = false, connected = false, running = false;
    obs_scene_t *scene = nullptr;
    std::vector<std::unique_ptr<Channel>> channels;
    mixer::AudioPipe pipe;
    mixer::HALOutput output;
    std::atomic<uint64_t> lastMix{0}, lastMixEnd{0};
    std::string outputUID;
    bool normalStop = true;
    const char *stopReason = "none";
    uint64_t interruptedFrames = 0;
    uint64_t startedAt = 0;

    explicit MMEngine(const char *path) : bundlePath(path ?: "") {}
    ~MMEngine() { stop(); }

    static void mixed(void *context, size_t, audio_data *data) {
        auto &self = *static_cast<MMEngine *>(context);
        if (!data->data[0] || !data->frames) return;
        self.pipe.push(reinterpret_cast<const float *>(data->data[0]), data->frames);
        self.lastMix.store(mixer::nowNS(), std::memory_order_relaxed);
        self.lastMixEnd.store(data->timestamp + uint64_t(data->frames) * 1000000000ULL / mixer::sampleRate);
    }

    bool initialize(std::string &error) {
        // OBS 33 mixes roots through its main canvas. A minimal hidden canvas
        // preserves the unmodified, mature OBS mixer; no display or recording
        // is created. The Metal dependency is deliberately retained.
        if (obs_initialized()) { error = "音频引擎已由其他实例占用"; return false; }
        // OBS initializes macOS keyboard/input-source APIs on this call.
        uiTask([](void *context) {
            auto &engine = *static_cast<MMEngine *>(context);
            base_set_log_handler([](int, const char *, va_list, void *) {}, nullptr);
            engine.initialized = obs_startup("en-US", nullptr, nullptr);
            if (engine.initialized) obs_set_ui_task_handler(uiTask);
        }, this, true);
        if (!initialized) { error = "初始化 OBS 音频引擎失败"; return false; }
        // macOS libobs resolves effects from its framework's Resources folder.
        // Its platform resolver bypasses deprecated obs_add_data_path fallbacks.
        const auto graphics = bundlePath + "/Contents/Frameworks/libobs-metal.dylib";
        obs_video_info video{};
        video.graphics_module = graphics.c_str();
        video.fps_num = 1;
        video.fps_den = 1;
        video.base_width = video.output_width = 16;
        video.base_height = video.output_height = 16;
        video.output_format = VIDEO_FORMAT_BGRA;
        video.colorspace = VIDEO_CS_709;
        video.range = VIDEO_RANGE_FULL;
        video.scale_type = OBS_SCALE_DISABLE;
        if (obs_reset_video(&video) != OBS_VIDEO_SUCCESS) {
            error = "初始化混音处理环境失败，请检查安装包中的 OBS/Metal 依赖"; return false;
        }
        obs_audio_info audio{};
        audio.samples_per_sec = mixer::sampleRate;
        audio.speakers = SPEAKERS_STEREO;
        if (!obs_reset_audio(&audio)) { error = "初始化 48 kHz 音频处理失败"; return false; }
        obs_module_t *module = nullptr;
        const auto binary = bundlePath + "/Contents/Frameworks/MixerMacInput.so";
        const auto locale = bundlePath + "/Contents/Resources/MicrophoneMixer/mac-input";
        if (obs_open_module(&module, binary.c_str(), locale.c_str()) != MODULE_SUCCESS || !obs_init_module(module)) {
            error = "加载麦克风采集模块失败，请重新安装应用"; return false;
        }
        scene = obs_scene_create_private("SayAll Microphone Mixing");
        if (!scene) { error = "创建音频混音场景失败"; return false; }
        obs_set_output_source(0, obs_scene_get_source(scene));
        return true;
    }

    bool start(NSDictionary *config, std::string &error) {
        stop();
        NSArray *inputs = config[@"inputs"];
        if (![inputs isKindOfClass:NSArray.class] || !inputs.count) { error = "请至少选择一个音频输入"; return false; }
        NSString *selectedOutput = config[@"outputUID"];
        if (![selectedOutput isKindOfClass:NSString.class]) { error = "output_unavailable"; return false; }
        outputUID = selectedOutput.UTF8String;
        if (!mixer::deviceAlive(mixer::deviceForUID(outputUID)) ||
            mixer::channelCount(mixer::deviceForUID(outputUID), kAudioDevicePropertyScopeOutput) == 0) {
            error = "虚拟麦克风尚未就绪，请使用完整安装包安装并重启 Mac"; return false;
        }
        std::set<std::string> selected;
        bool anyAvailable = false;
        for (id item in inputs) {
            if (![item isKindOfClass:NSDictionary.class] || ![item[@"deviceUID"] isKindOfClass:NSString.class]) {
                error = "输入设备设置无效"; return false;
            }
            std::string uid = [item[@"deviceUID"] UTF8String];
            if (uid.empty() || uid == outputUID || !selected.insert(uid).second) {
                error = "请为每路选择不同的输入，不能将本软件的输出作为输入"; return false;
            }
            auto id = mixer::deviceForUID(uid);
            bool available = mixer::deviceAlive(id) && mixer::channelCount(id, kAudioDevicePropertyScopeInput) > 0;
            if (available) anyAvailable = true;
        }
        if (!anyAvailable) { error = "所选输入均未连接，请连接设备后重试"; return false; }
        if (!initialize(error)) { stop(); return false; }
        for (NSDictionary *item in inputs) {
            auto channel = std::make_unique<Channel>();
            channel->uid = [item[@"deviceUID"] UTF8String];
            obs_data_t *settings = obs_data_create();
            obs_data_set_string(settings, "device_id", channel->uid.c_str());
            std::string name = "Input " + std::to_string(channels.size() + 1);
            channel->source = obs_source_create_private("coreaudio_input_capture",
                                                         name.c_str(), settings);
            obs_data_release(settings);
            if (!channel->source) { error = "input_creation_failed"; stop(); return false; }
            obs_source_set_flags(channel->source, obs_source_get_flags(channel->source) | OBS_SOURCE_FLAG_FORCE_MONO);
            obs_source_set_audio_mixers(channel->source, 1);
            obs_source_add_audio_capture_callback(channel->source, inputAudio, channel.get());
            if (!obs_scene_add(scene, channel->source)) {
                obs_source_remove_audio_capture_callback(channel->source, inputAudio, channel.get());
                obs_source_release(channel->source);
                error = "无法将输入加入混音"; stop(); return false;
            }
            channels.push_back(std::move(channel));
        }
        controls(config);
        audio_convert_info conversion{};
        conversion.format = AUDIO_FORMAT_FLOAT;
        conversion.speakers = SPEAKERS_STEREO;
        conversion.samples_per_sec = mixer::sampleRate;
        connected = audio_output_connect(obs_get_audio(), 0, &conversion, mixed, this);
        if (!connected) { error = "连接混音输出失败"; stop(); return false; }
        if (!output.start(mixer::deviceForUID(outputUID), pipe, error)) { stop(); return false; }
        startedAt = mixer::nowNS();
        normalStop = true;
        interruptedFrames = 0;
        running = true;
        return true;
    }

    void controls(NSDictionary *config) {
        NSArray *inputs = config[@"inputs"];
        if (![inputs isKindOfClass:NSArray.class]) return;
        // Apply master gain inside OBS, before its final mix clamp. Reducing
        // master volume must prevent clipping rather than attenuate a clipped mix.
        if (scene) obs_source_set_volume(obs_scene_get_source(scene), number(config[@"masterGain"], 0.75f));
        pipe.setGain(1.0f);
        for (auto &channel : channels) {
            for (id item in inputs) {
                if (![item isKindOfClass:NSDictionary.class] || ![item[@"deviceUID"] isKindOfClass:NSString.class]) continue;
                if (channel->uid != [item[@"deviceUID"] UTF8String]) continue;
                float gain = number(item[@"gain"], 0.7f);
                bool mute = [item[@"muted"] isKindOfClass:NSNumber.class] && [item[@"muted"] boolValue];
                channel->gain.store(gain);
                channel->muted.store(mute);
                obs_source_set_volume(channel->source, gain);
                obs_source_set_muted(channel->source, mute);
            }
        }
    }

    void stop() {
        if (running) {
            for (const auto &channel : channels) {
                obs_data_t *settings = obs_data_create();
                obs_data_set_bool(settings, "sayall_stop_capture", true);
                obs_source_update(channel->source, settings);
                obs_data_release(settings);
            }
            uint64_t lastInputEnd = 0;
            for (const auto &channel : channels)
                lastInputEnd = std::max(lastInputEnd, channel->lastCaptureEnd.load());
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (lastMixEnd.load() < lastInputEnd && std::chrono::steady_clock::now() < deadline)
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            if (connected) audio_output_disconnect(obs_get_audio(), 0, mixed, this);
            connected = false;
            while (pipe.pending() && std::chrono::steady_clock::now() < deadline)
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            // One device period acknowledges the final HAL buffer before disposal.
            if (!pipe.pending()) std::this_thread::sleep_for(std::chrono::nanoseconds(output.drainLatencyNS()));
            const auto mixedThrough = std::max(startedAt, lastMixEnd.load());
            const uint64_t unmixed = lastInputEnd > mixedThrough
                ? (lastInputEnd - mixedThrough) * mixer::sampleRate / 1000000000ULL : 0;
            interruptedFrames = pipe.pending() + pipe.dropped() + unmixed;
            if (pipe.dropped()) stopReason = "overflow";
            else if (lastMixEnd.load() < lastInputEnd) stopReason = "mix_timeout";
            else if (pipe.pending()) stopReason = "output_timeout";
            else stopReason = "drained";
            normalStop = std::strcmp(stopReason, "drained") == 0;
        }
        running = false;
        output.stop();
        if (connected && initialized) audio_output_disconnect(obs_get_audio(), 0, mixed, this);
        connected = false;
        if (initialized) {
            obs_set_output_source(0, nullptr);
            for (auto &channel : channels)
                obs_source_remove_audio_capture_callback(channel->source, inputAudio, channel.get());
            if (scene) obs_scene_release(scene);
            scene = nullptr;
            for (auto &channel : channels) obs_source_release(channel->source);
            channels.clear();
            // Let already queued UI work run before destroying the OBS context.
            // Control calls use a background serial queue; the main thread stays
            // available during normal start/stop and asynchronous app termination.
            uiTask([](void *) {}, nullptr, true);
            obs_shutdown();
            initialized = false;
        }
        pipe.reset();
        lastMix.store(0);
        lastMixEnd.store(0);
        startedAt = 0;
    }

    NSDictionary *snapshot() {
        uint64_t now = mixer::nowNS();
        NSMutableArray *inputs = [NSMutableArray array];
        bool allReceiving = !channels.empty(), anyReceiving = false;
        for (const auto &channel : channels) {
            bool receiving = fresh(channel->lastCapture.load(), now);
            bool available = mixer::deviceAlive(mixer::deviceForUID(channel->uid));
            allReceiving = allReceiving && receiving && available;
            anyReceiving = anyReceiving || receiving;
            [inputs addObject:@{@"deviceUID":ns(channel->uid), @"receiving":@(receiving),
                                @"connected":@(available), @"peak":@(receiving ? channel->peak.load() : 0),
                                @"muted":@(channel->muted.load())}];
        }
        bool outputReady = running && fresh(output.lastRender(), now) && fresh(lastMix.load(), now) &&
                           output.callbackError() == noErr && mixer::deviceAlive(mixer::deviceForUID(outputUID));
        bool starting = running && startedAt && now - startedAt < 4000000000ULL;
        return @{@"running":@(running), @"starting":@(starting), @"outputReady":@(outputReady),
                 @"allReceiving":@(allReceiving), @"anyReceiving":@(anyReceiving),
                 @"outputPeak":@(outputReady ? pipe.peak() : 0), @"droppedFrames":@(pipe.dropped()),
                 @"underrunFrames":@(pipe.underrun()), @"clippedFrames":@(pipe.clipped()),
                 @"renderCallbacks":@(output.renderCount()), @"inputs":inputs,
                 @"normalStop":@(normalStop), @"interruptedFrames":@(interruptedFrames),
                 @"stopReason":@(stopReason)};
    }
};

extern "C" {
MMEngine *mm_engine_create(const char *bundle_path) { return new MMEngine(bundle_path); }
void mm_engine_destroy(MMEngine *engine) { @autoreleasepool { delete engine; } }
void mm_free_string(char *string) { free(string); }
char *mm_engine_start(MMEngine *engine, const char *text) {
    @autoreleasepool {
        std::string error;
        bool ok = engine && engine->start(configuration(text), error);
        return json(@{@"ok":@(ok), @"error":ns(error)});
    }
}
void mm_engine_controls(MMEngine *engine, const char *text) {
    @autoreleasepool { if (engine) engine->controls(configuration(text)); }
}
void mm_engine_stop(MMEngine *engine) { @autoreleasepool { if (engine) engine->stop(); } }
char *mm_engine_snapshot(MMEngine *engine) {
    @autoreleasepool { return json(engine ? engine->snapshot() : @{}); }
}
}
