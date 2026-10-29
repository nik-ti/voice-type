// Defines the optional recognition language preference independently of cleanup language detection.
// Explicit choices request script filtering from FluidAudio; Auto leaves multilingual recognition unchanged.
import enum FluidAudio.Language

enum DictationLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .english: return "English"
        case .russian: return "Russian"
        }
    }

    var recognitionHint: Language? {
        switch self {
        case .automatic: return nil
        case .english: return .english
        case .russian: return .russian
        }
    }
}
