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
        
        // Default to true for Whispr-like behavior
        if UserDefaults.standard.object(forKey: "autoPaste") == nil {
            self.autoPaste = true
        } else {
            self.autoPaste = UserDefaults.standard.bool(forKey: "autoPaste")
        }
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
        guard isListening else { 
            print("⚠️ stopListeningAndTranscribe called but not listening")
            return 
        }
        
        print("🎙️ Stopping recording and starting transcription...")
        isListening = false
        isTranscribing = true
        
        defer {
            isTranscribing = false
            print("✅ Transcription process complete")
        }
        
        do {
            // Stop recording and get audio buffer
            guard let audioBuffer = audioCaptureService.stopRecording() else {
                print("❌ No audio buffer returned from stopRecording")
                showError("No audio was recorded")
                return
            }
            
            print("📊 Audio buffer: \(audioBuffer.frameLength) frames at \(audioBuffer.format.sampleRate)Hz")
            
            // Transcribe
            print("🔄 Starting transcription with language: \(selectedLanguage.displayName)")
            let text = try await transcriptionService.transcribe(audioBuffer, language: selectedLanguage)
            
            print("📝 Transcription result: '\(text)'")
            
            guard !text.isEmpty else {
                print("⚠️ Transcription returned empty text")
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
            print("💾 Saved to history")
            
            // Update history
            loadHistory()
            
            // Copy to clipboard
            copyToClipboard(text)
            print("📋 Copied to clipboard: '\(text)'")
            
            // Optionally paste
            if autoPaste {
                print("📤 Auto-pasting...")
                pasteFromClipboard()
            }
            
        } catch {
            print("❌ Transcription error: \(error)")
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
        // Get the text we just copied
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            print("❌ No text on clipboard to paste")
            return
        }
        
        // Small delay to ensure focus is back to the target app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            print("⌨️ Typing text directly: '\(text)'")
            self.typeText(text)
        }
    }
    
    private func typeText(_ text: String) {
        // Use the HID event tap which is the lowest level
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            print("❌ Failed to create HID event source")
            return
        }
        
        // Type each character using Unicode input
        for char in text {
            let utf16 = Array(String(char).utf16)
            
            // Create key events
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            
            // Set the Unicode string on the key down event
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            
            // Post to HID system
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            
            // Small delay between characters
            usleep(2000) // 2ms
        }
        
        print("✅ Typed \(text.count) characters via HID")
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
