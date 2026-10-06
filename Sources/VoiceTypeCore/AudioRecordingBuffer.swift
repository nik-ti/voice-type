// Accumulates PCM samples at one hardware rate and drains each take exactly once.
// A lock and session token protect against late audio callbacks after stop or device changes.
import AVFoundation
import Foundation

public final class AudioRecordingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 16000
    private var sessionID: UUID?
    private var peak: Float = 0

    public init() {}
    public var peakLevel: Float { lock.withLock { peak } }

    @discardableResult
    public func begin(sampleRate: Double) -> UUID {
        lock.withLock {
            let id = UUID()
            self.sampleRate = sampleRate
            samples.removeAll(keepingCapacity: true)
            peak = 0
            sessionID = id
            return id
        }
    }

    public func append(_ buffer: AVAudioPCMBuffer, sessionID: UUID) -> Float? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0,
              !buffer.format.isInterleaved else { return nil }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return nil }
        var mono = [Float](repeating: 0, count: count)
        var energy: Float = 0
        for i in 0..<count {
            for channel in 0..<channelCount { mono[i] += channels[channel][i] }
            mono[i] /= Float(channelCount)
            energy += mono[i] * mono[i]
        }
        let level = sqrt(energy / Float(count))
        return lock.withLock {
            guard self.sessionID == sessionID, buffer.format.sampleRate == sampleRate else { return nil }
            samples.append(contentsOf: mono)
            peak = max(peak, level)
            return level
        }
    }

    public func take() -> AVAudioPCMBuffer? {
        let (recorded, rate) = lock.withLock {
            let result = (samples, sampleRate)
            samples = []
            sessionID = nil
            return result
        }
        guard !recorded.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(recorded.count)) else {
            return nil
        }
        buffer.frameLength = buffer.frameCapacity
        recorded.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: recorded.count)
        }
        return buffer
    }
}
