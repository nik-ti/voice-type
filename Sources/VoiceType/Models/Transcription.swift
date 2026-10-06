import Foundation

/// Represents a single transcription record
struct Transcription: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let language: String
    let text: String
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    var languageEmoji: String {
        switch language {
        case "en": return "🇺🇸"
        case "ru": return "🇷🇺"
        case "uk": return "🇺🇦"
        case "es": return "🇪🇸"
        case "fr": return "🇫🇷"
        case "de": return "🇩🇪"
        case "it": return "🇮🇹"
        case "pt": return "🇵🇹"
        case "pl": return "🇵🇱"
        case "nl": return "🇳🇱"
        default: return "🌐"
        }
    }
    
    var preview: String {
        if text.count > 100 {
            return String(text.prefix(100)) + "..."
        }
        return text
    }
}
