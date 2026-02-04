import Foundation
import SwiftUI
import Combine
import AppKit
import ServiceManagement

/// Supported languages for transcription
enum TranscriptionLanguage: String, CaseIterable, Codable {
    case english = "en"
    case russian = "ru"
    
    var displayName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        }
    }
    
    var flag: String {
        switch self {
        case .english: return "🇺🇸"
        case .russian: return "🇷🇺"
        }
    }
}

/// Hotkey mode configuration
enum HotkeyMode: String, CaseIterable, Codable {
    case fn = "fn"
    case optionSpace = "optionSpace"
    case toggle = "toggle"
    
    var displayName: String {
        switch self {
        case .fn: return "Hold fn"
        case .optionSpace: return "Hold ⌥ Space"
        case .toggle: return "Toggle (press to start/stop)"
        }
    }
}

/// Shared application state
@MainActor
class AppState: ObservableObject {
    // Singleton for AppDelegate access
    static var shared: AppState?
    
    // MARK: - Published State
    
    @Published var isListening = false
    @Published var isTranscribing = false
    @Published var isModelLoaded = false
    @Published var audioLevel: Float = 0.0
    
    @Published var selectedLanguage: TranscriptionLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: "selectedLanguage")
        }
    }
    
    @Published var hotkeyMode: HotkeyMode {
        didSet {
            UserDefaults.standard.set(hotkeyMode.rawValue, forKey: "hotkeyMode")
        }
    }
    
    @Published var autoPaste: Bool {
        didSet {
            UserDefaults.standard.set(autoPaste, forKey: "autoPaste")
        }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLaunchAtLogin()
        }
    }
    
    @Published var errorMessage: String?
    @Published var showingError = false
    
    @Published var transcriptionHistory: [Transcription] = []
    @Published var searchText = ""
    
    // MARK: - Services
    
    let audioCaptureService = AudioCaptureService()
    let transcriptionService = TranscriptionService()
    let persistenceService = PersistenceService()
    
    // MARK: - Computed Properties
    
    var filteredHistory: [Transcription] {
        if searchText.isEmpty {
            return transcriptionHistory
        }
        return transcriptionHistory.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }
    
    // MARK: - Initialization
    
    init() {
        // Load saved preferences
        if let langString = UserDefaults.standard.string(forKey: "selectedLanguage"),
           let lang = TranscriptionLanguage(rawValue: langString) {
            self.selectedLanguage = lang
        } else {
            self.selectedLanguage = .english
        }
        
        if let modeString = UserDefaults.standard.string(forKey: "hotkeyMode"),
           let mode = HotkeyMode(rawValue: modeString) {
            self.hotkeyMode = mode
        } else {
            self.hotkeyMode = .fn
        }
        
        self.autoPaste = UserDefaults.standard.bool(forKey: "autoPaste")
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        
        // Set singleton reference
        AppState.shared = self
        
        // Load history
        loadHistory()
        
        // Setup audio level monitoring
        setupAudioLevelMonitoring()
    }
    
    // MARK: - Audio Level Monitoring
    
    private func setupAudioLevelMonitoring() {
        audioCaptureService.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)
    }
    
    // MARK: - Listening Control
    
    func startListening() {
        guard !isListening else { return }
        
        Task {
            do {
                let hasPermission = await audioCaptureService.requestMicrophonePermission()
                guard hasPermission else {
                    showError("Microphone permission is required. Please enable it in System Preferences.")
                    return
                }
                
                try audioCaptureService.startRecording()
                isListening = true
            } catch {
                showError("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }
    
    func stopListeningAndTranscribe() async {
        guard isListening else { return }
        
        isListening = false
        isTranscribing = true
        
        defer {
            isTranscribing = false
        }
        
        do {
            // Stop recording and get audio buffer
            guard let audioBuffer = audioCaptureService.stopRecording() else {
                showError("No audio was recorded")
                return
            }
            
            // Transcribe
            let text = try await transcriptionService.transcribe(audioBuffer, language: selectedLanguage)
            
            guard !text.isEmpty else {
                showError("No speech detected")
                return
            }
            
            // Save to history
            let transcription = Transcription(
                id: UUID(),
                timestamp: Date(),
                language: selectedLanguage.rawValue,
                text: text
            )
            try persistenceService.saveTranscription(transcription)
            
            // Update history
            loadHistory()
            
            // Copy to clipboard
            copyToClipboard(text)
            
            // Optionally paste
            if autoPaste {
                pasteFromClipboard()
            }
            
        } catch {
            showError("Transcription failed: \(error.localizedDescription)")
        }
    }
    
    func toggleListening() {
        if isListening {
            Task {
                await stopListeningAndTranscribe()
            }
        } else {
            startListening()
        }
    }
    
    // MARK: - Clipboard Operations
    
    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    private func pasteFromClipboard() {
        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Key down
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // v key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        
        // Key up
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
    
    // MARK: - History Management
    
    func loadHistory() {
        transcriptionHistory = persistenceService.fetchTranscriptions()
    }
    
    func deleteTranscription(_ transcription: Transcription) {
        do {
            try persistenceService.deleteTranscription(id: transcription.id)
            loadHistory()
        } catch {
            showError("Failed to delete: \(error.localizedDescription)")
        }
    }
    
    func clearAllHistory() {
        do {
            try persistenceService.clearAllHistory()
            loadHistory()
        } catch {
            showError("Failed to clear history: \(error.localizedDescription)")
        }
    }
    
    func exportHistory(to url: URL, format: ExportFormat) {
        do {
            try persistenceService.exportHistory(to: url, format: format, transcriptions: transcriptionHistory)
        } catch {
            showError("Failed to export: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Launch at Login
    
    private func updateLaunchAtLogin() {
        // Use SMAppService for macOS 13+
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update launch at login: \(error)")
            }
        }
    }
    
    // MARK: - Error Handling
    
    func showError(_ message: String) {
        errorMessage = message
        showingError = true
        
        // Auto-dismiss after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.showingError = false
        }
    }
}

// Export format enum
enum ExportFormat: String, CaseIterable {
    case text = "txt"
    case markdown = "md"
    
    var displayName: String {
        switch self {
        case .text: return "Plain Text"
        case .markdown: return "Markdown"
        }
    }
}
