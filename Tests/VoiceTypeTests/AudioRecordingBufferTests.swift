// Exercises actual PCM accumulation without opening a microphone.
// A route change must never reinterpret old samples or duplicate the captured prefix.
import AVFoundation
import XCTest
@testable import VoiceTypeCore

final class AudioRecordingBufferTests: XCTestCase {
    private func buffer(rate: Double, samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
        return buffer
    }

    func testFirstSamplesAreKeptAndDrainIsExactlyOnce() {
        let recording = AudioRecordingBuffer()
        let id = recording.begin(sampleRate: 16000)
        _ = recording.append(buffer(rate: 16000, samples: [0.1, 0.2]), sessionID: id)
        _ = recording.append(buffer(rate: 16000, samples: [0.3]), sessionID: id)
        let output = recording.take()!
        XCTAssertEqual(output.frameLength, 3)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: 3)), [0.1, 0.2, 0.3])
        XCTAssertNil(recording.take())
    }

    func testRouteRateChangeKeepsOriginalAudioWithoutMixingClocks() {
        let recording = AudioRecordingBuffer()
        let id = recording.begin(sampleRate: 48000)
        _ = recording.append(buffer(rate: 48000, samples: [0.1, 0.2]), sessionID: id)
        XCTAssertNil(recording.append(buffer(rate: 16000, samples: [0.9]), sessionID: id))
        let output = recording.take()!
        XCTAssertEqual(output.frameLength, 2)
        XCTAssertEqual(output.format.sampleRate, 48000)
        let next = recording.begin(sampleRate: 16000)
        XCTAssertNil(recording.append(buffer(rate: 16000, samples: [0.9]), sessionID: id))
        _ = recording.append(buffer(rate: 16000, samples: [0.5]), sessionID: next)
        XCTAssertEqual(recording.take()?.frameLength, 1)
    }
}
