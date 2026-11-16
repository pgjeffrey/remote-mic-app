#include "../../Sources/MicrophoneMixerNative/core/AudioPipe.hpp"
#include <cassert>
#include <vector>

int main() {
    mixer::AudioPipe pipe;
    pipe.setGain(1.0f);
    // More than the original recovery threshold must remain ordered until drain.
    std::vector<float> input(6000 * 2, 0.25f);
    assert(pipe.push(input.data(), 6000) == 6000);
    assert(pipe.pending() == 6000);
    std::vector<float> output(6000 * 2);
    assert(pipe.render(output.data(), 6000) == 6000);
    assert(pipe.pending() == 0);
    assert(pipe.dropped() == 0);
    for (float sample : output) assert(sample == 0.25f);
    pipe.reset();
    assert(pipe.pending() == 0);
    assert(pipe.render(output.data(), 128) == 0);
    assert(pipe.underrun() == 128);
    return 0;
}
