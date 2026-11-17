import Foundation
import Testing
@testable import RemoteMic

@Suite struct MicrophoneMixerTests {
    @Test func captureFollowsActualReadersAndGracePeriod() {
        var demand = MicrophoneMixerCaptureDemand()
        #expect(!({ demand.wantsCapture(armed: false, clientInUse: true, capturing: false, now: 0) })())
        #expect(!({ demand.wantsCapture(armed: true, clientInUse: false, capturing: false, now: 1) })())
        #expect(({ demand.wantsCapture(armed: true, clientInUse: true, capturing: false, now: 2) })())
        #expect(({ demand.wantsCapture(armed: true, clientInUse: false, capturing: true, now: 3) })())
        #expect(({ demand.wantsCapture(armed: true, clientInUse: false, capturing: true, now: 3.9) })())
        #expect(!({ demand.wantsCapture(armed: true, clientInUse: false, capturing: true, now: 4) })())
    }

    @Test func newReaderCancelsReleaseAndUnknownDemandReleases() {
        var demand = MicrophoneMixerCaptureDemand()
        #expect(({ demand.wantsCapture(armed: true, clientInUse: false, capturing: true, now: 0) })())
        #expect(({ demand.wantsCapture(armed: true, clientInUse: true, capturing: true, now: 0.9) })())
        #expect(({ demand.wantsCapture(armed: true, clientInUse: false, capturing: true, now: 2) })())
        #expect(!({ demand.wantsCapture(armed: true, clientInUse: nil, capturing: true, now: 2.5) })())
        #expect(!({ demand.wantsCapture(armed: false, clientInUse: true, capturing: true, now: 3) })())
    }

    @Test func configurationPreservesSelectionsAndSanitizesInvalidGain() throws {
        var configuration = MicrophoneMixerConfiguration(inputs: [
            MicrophoneMixerInput(deviceUID: "input_a", name: "Input A", gain: 1.2, muted: true),
            MicrophoneMixerInput(deviceUID: "input_b", name: "Input B", gain: -.infinity),
            MicrophoneMixerInput(deviceUID: "input_a", name: "Duplicate")
        ], masterGain: .nan)
        configuration.validate()
        #expect(configuration.inputs.count == 2)
        #expect(configuration.inputs[0].gain == 1.2)
        #expect(configuration.inputs[0].muted)
        #expect(configuration.inputs[1].gain == 0.7)
        #expect(configuration.masterGain == 0.75)
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(MicrophoneMixerConfiguration.self, from: data) == configuration)
    }

    @Test func nativeStopAcknowledgementIsDecoded() throws {
        let json = """
        {"running":false,"starting":false,"outputReady":false,"allReceiving":false,
         "anyReceiving":false,"outputPeak":0,"droppedFrames":0,"underrunFrames":0,
         "clippedFrames":0,"renderCallbacks":20,"inputs":[],"normalStop":false,
         "interruptedFrames":128,"stopReason":"output_timeout"}
        """
        let status = try JSONDecoder().decode(MicrophoneMixerStatus.self, from: Data(json.utf8))
        #expect(!status.normalStop)
        #expect(status.interruptedFrames == 128)
        #expect(status.stopReason == "output_timeout")
    }
    @Test @MainActor func cleanupCompletesInsideNestedMainRunLoop() async {
        let engine = MicrophoneMixerEngine()
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                var completed = false
                engine.shutdown { completed = true }
                let deadline = Date().addingTimeInterval(0.25)
                while !completed, Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                continuation.resume(returning: completed)
            }
        }
        #expect(result)
    }

}
