// Records elapsed times for dictation stages in macOS unified logging.
// Logs identify builds and stages, never transcript contents or microphone samples.
import Foundation
import OSLog

struct PipelineTiming {
    private static let logger = Logger(subsystem: "com.nikti.VoiceType", category: "latency")
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var previous: ContinuousClock.Instant
    private let id = UUID().uuidString.prefix(8)

    init() {
        let now = ContinuousClock.now
        started = now
        previous = now
    }

    mutating func mark(_ stage: String) {
        let now = clock.now
        let interval = previous.duration(to: now)
        let total = started.duration(to: now)
        let sessionID = id
        Self.logger.notice("session=\(sessionID, privacy: .public) stage=\(stage, privacy: .public) seconds=\(Self.seconds(interval)) total=\(Self.seconds(total))")
        previous = now
    }

    static func event(_ name: String) {
        logger.notice("\(name, privacy: .public)")
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
