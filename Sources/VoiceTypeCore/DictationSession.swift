// Orders recording startup, capture, and processing for one dictation at a time.
// Session IDs prevent delayed callbacks from changing a newer recording.
import Foundation

public struct DictationSession {
    public enum Phase { case idle, starting, cancellingStartup, recording, processing }
    public enum StopAction { case cancelStartup, transcribe, ignore }
    public private(set) var phase: Phase = .idle
    public private(set) var id: UUID?

    public init() {}

    public mutating func begin() -> UUID? {
        guard phase == .idle else { return nil }
        let next = UUID()
        id = next
        phase = .starting
        return next
    }

    public mutating func didStart(_ candidate: UUID) -> Bool {
        guard id == candidate, phase == .starting else { return false }
        phase = .recording
        return true
    }

    public mutating func requestStop() -> StopAction {
        switch phase {
        case .starting:
            phase = .cancellingStartup
            return .cancelStartup
        case .recording:
            phase = .processing
            return .transcribe
        default:
            return .ignore
        }
    }

    public mutating func finish(_ candidate: UUID) {
        guard id == candidate else { return }
        id = nil
        phase = .idle
    }
}
