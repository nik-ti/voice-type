import Foundation
import SwiftUI
import Combine
import AppKit
import ServiceManagement
import UserNotifications

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
    
    @Published var isPolishedMode: Bool {
        didSet {
            UserDefaults.standard.set(isPolishedMode, forKey: "isPolishedMode")
            if isPolishedMode {
                Task { await LLMService.shared.loadModel() }
            } else {
                LLMService.shared.unloadModel()
            }
        }
    }
    
    @Published var isPolishing = false
    
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
    
    // Paste safety: prevent double-paste
    private var isPasting = false
    
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
        
        self.isPolishedMode = UserDefaults.standard.bool(forKey: "isPolishedMode")
        
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
        
        // Preload LLM if polished mode enabled
        if isPolishedMode {
            Task { await LLMService.shared.loadModel() }
        }
    }
    
    // MARK: - Audio Level Monitoring
    
    private func setupAudioLevelMonitoring() {
        audioCaptureService.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)
    }
    
    // MARK: - Listening Control
    
    func startListening() {
        guard !isListening else {
            print("⚠️ startListening ignored: already listening")
            return
        }
        
        // If transcription is stuck, reset it
        if isTranscribing {
            print("⚠️ isTranscribing was stuck true, resetting...")
            isTranscribing = false
            isPolishing = false
        }
        
        Task {
            do {
                let hasPermission = await audioCaptureService.requestMicrophonePermission()
                guard hasPermission else {
                    showError("Microphone permission is required. Please enable it in System Preferences.")
                    return
                }
                
                print("🎤️ Starting audio recording...")
                try audioCaptureService.startRecording()
                isListening = true
                playStartSound()
                print("✅ Now listening")
            } catch {
                print("❌ Failed to start recording: \(error)")
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
        playStopSound()
        
        defer {
            isTranscribing = false
            isPolishing = false
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
            
            // Silence detection: skip if no actual speech was detected
            if !audioCaptureService.hadSpeech {
                print("🤫 Silence detected (peak=\(String(format: "%.3f", audioCaptureService.peakAudioLevel))), skipping transcription")
                return
            }
            
            // Transcribe with comprehensive error handling
            print("🔄 Starting transcription with language: \(selectedLanguage.displayName)")
            let text: String
            do {
                text = try await transcriptionService.transcribe(audioBuffer, language: selectedLanguage)
            } catch let error as TranscriptionError {
                // Handle specific transcription errors with user-friendly messages
                switch error {
                case .modelNotLoaded:
                    print("❌ Transcription model not loaded")
                    showError("Speech model not ready. Please wait a moment and try again.")
                case .emptyAudio:
                    print("❌ Empty audio buffer")
                    showError("No audio detected. Please speak louder or check your microphone.")
                case .invalidFormat:
                    print("❌ Invalid audio format")
                    showError("Microphone format issue. Try unplugging and reconnecting your mic.")
                case .conversionFailed(let reason):
                    print("❌ Audio conversion failed: \(reason)")
                    showError("Audio processing failed: \(reason)")
                case .transcriptionFailed(let reason):
                    print("❌ Transcription failed: \(reason)")
                    showError("Transcription failed: \(reason)")
                }
                return
            } catch {
                // Catch-all for unexpected errors
                print("❌ Unexpected transcription error: \(error.localizedDescription)")
                showError("Transcription failed: \(error.localizedDescription)")
                return
            }
            
            print("✅ Transcription result: '\(text)'")
            
            if text.isEmpty {
                print("⚠️ Transcription returned empty text")
                showError("No speech detected. Please try again.")
                return
            }
            
            var finalText = text
            
            // Always apply basic formatting (instant, rule-based)
            finalText = LLMService.shared.basicFormat(text)
            print("📝 Basic format: '\(finalText)'")
            
            // Polished Mode (GRMR with filler removal)
            if isPolishedMode {
                await MainActor.run { self.isPolishing = true }
                print("✨ Polishing text...")
                do {
                    finalText = try await LLMService.shared.processPolished(text)
                    print("✨ Polished result: '\(finalText)'")
                } catch {
                    print("⚠️ Polish failed: \(error), using basic format")
                    // Fallback already applied above
                }
                await MainActor.run { self.isPolishing = false }
            }
            
            // (isTranscribing and isPolishing reset by defer)
            
            // Save to history
            let transcription = Transcription(
                id: UUID(),
                timestamp: Date(),
                language: selectedLanguage.rawValue,
                text: finalText
            )
            try persistenceService.saveTranscription(transcription)
            print("💾 Saved to history")
            
            // Update history
            loadHistory()
            
            // Copy to clipboard
            copyToClipboard(finalText)
            print("📋 Copied to clipboard: '\(finalText)'")
            
            // Optionally paste
            // Check if we need to restore focus first (handled in AppDelegate for stop button, but what about auto?)
            // If the user clicked "Stop" in MenuBar, focus might be lost.
            // But usually this flow is triggered by Hotkey/Button which handles focus.
            
            if autoPaste {
                print("📤 Auto-pasting...")
                pasteFromClipboard()
            }
            
        } catch {
            print("❌ Transcription error: \(error)")
            showError("Transcription failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Sound Feedback
    
    private func playStartSound() {
        NSSound(named: "Tink")?.play()
    }
    
    private func playStopSound() {
        NSSound(named: "Pop")?.play()
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
        // Prevent double-paste
        guard !isPasting else {
            print("⚠️ Paste already in progress, skipping")
            return
        }
        isPasting = true
        
        // Get the text we just copied (sanity check)
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            print("❌ No text on clipboard to paste")
            isPasting = false
            return
        }
        
        // Re-activate the target app — during LLM processing it may have lost focus
        var activated = false
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let targetApp = appDelegate.previousApp {
            // Check if the target app is still running
            if targetApp.isTerminated {
                print("⚠️ Target app has been terminated, falling back to notification")
                isPasting = false
                showCopiedNotification()
                return
            }
            print("📱 Re-activating target app: \(targetApp.localizedName ?? "unknown")")
            activated = targetApp.activate()
            
            // Retry activation once if it fails
            if !activated {
                print("⚠️ First activation attempt failed, retrying...")
                Thread.sleep(forTimeInterval: 0.2)
                activated = targetApp.activate()
            }
        }
        
        if !activated {
            print("⚠️ Could not activate target app, trying frontmost app instead")
            // The user may have switched apps — paste into whatever's in front
        }
        
        // Delay: focus restoration needs time to complete
        // Use longer delay (0.7s) to handle slow focus switches after inactivity
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            print("📤 Simulating Command+V...")
            self.simulatePasteCommand()
            
            // Reset paste flag after a short delay to prevent re-entry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isPasting = false
            }
        }
    }
    
    private func simulatePasteCommand() {
        // Use AppleScript to reliably send Command+V
        // This is more robust than CGEvent for global shortcuts
        let scriptSource = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        
        var error: NSDictionary?
        if let script = NSAppleScript(source: scriptSource) {
            script.executeAndReturnError(&error)
            if let error = error {
                print("❌ AppleScript Paste Error: \(error)")
                // Fallback to CGEvent if AppleScript fails
                fallbackPaste()
            } else {
                print("✅ Pasted via AppleScript")
            }
        }
    }
    
    private func fallbackPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9 // 'v' key
        let cmdFlag = CGEventFlags.maskCommand
        
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            showCopiedNotification()
            return
        }
        
        keyDown.flags = cmdFlag
        keyUp.flags = cmdFlag
        
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        print("⚠️ Used Fallback CGEvent Paste")
    }
    
    private func showCopiedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "VoiceType"
        content.body = "Text copied to clipboard — paste with ⌘V"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "paste-fallback-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
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
