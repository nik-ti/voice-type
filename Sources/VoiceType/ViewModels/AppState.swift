// Coordinates one dictation from microphone startup through delivery and history.
// Session ownership protects against early release and delayed callbacks.
import Foundation
import SwiftUI
import Combine
import AppKit
import ServiceManagement
import UserNotifications
import VoiceTypeCore

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
    
    @Published var isStarting = false
    @Published var isListening = false
    @Published var isTranscribing = false
    @Published var isModelLoaded = false
    @Published var audioLevel: Float = 0.0
    
    /// `"auto"` follows the current macOS input device.
    @Published var selectedInputDeviceUID: String {
        didSet {
            preferences.set(selectedInputDeviceUID, forKey: "selectedInputDeviceUID")
            applySelectedInputDevice()
        }
    }

    @Published var availableInputDevices: [AudioInputDevice] = []
    
    @Published var isPolishedMode: Bool {
        didSet {
            preferences.set(isPolishedMode, forKey: "isPolishedMode")
            LLMService.shared.setEnabled(isPolishedMode)
        }
    }
    
    @Published var isPolishing = false
    
    @Published var hotkeyMode: HotkeyMode {
        didSet {
            preferences.set(hotkeyMode.rawValue, forKey: "hotkeyMode")
        }
    }
    
    @Published var autoPaste: Bool {
        didSet {
            preferences.set(autoPaste, forKey: "autoPaste")
        }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            preferences.set(launchAtLogin, forKey: "launchAtLogin")
            updateLaunchAtLogin()
        }
    }
    
    @Published var errorMessage: String?
    @Published var showingError = false
    
    @Published var transcriptionHistory: [Transcription] = []
    @Published var searchText = ""
    
    // Paste safety: prevent double-paste
    private var isPasting = false
    private var session = DictationSession()
    private var startTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var pasteTargetApp: NSRunningApplication?
    
    // MARK: - Services
    
    let audioCaptureService: AudioCaptureService
    let transcriptionService: TranscriptionService
    let persistenceService: PersistenceService
    private let preferences: UserDefaults
    private let clipboardWriter: (String) -> Int
    private let startCue: () -> Void
    private let stopCue: () -> Void
    
    // MARK: - Computed Properties
    
    var filteredHistory: [Transcription] {
        if searchText.isEmpty {
            return transcriptionHistory
        }
        return transcriptionHistory.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }
    
    // MARK: - Initialization
    
    init(audioCaptureService: AudioCaptureService = AudioCaptureService(),
         transcriptionService: TranscriptionService = TranscriptionService(),
         persistenceService: PersistenceService = PersistenceService(),
         preferences: UserDefaults = .standard,
         clipboardWriter: ((String) -> Int)? = nil,
         startCue: @escaping () -> Void = { _ = NSSound(named: "Tink")?.play() },
         stopCue: @escaping () -> Void = { _ = NSSound(named: "Pop")?.play() }) {
        self.audioCaptureService = audioCaptureService
        self.transcriptionService = transcriptionService
        self.persistenceService = persistenceService
        self.preferences = preferences
        self.clipboardWriter = clipboardWriter ?? Self.writeClipboard
        self.startCue = startCue
        self.stopCue = stopCue
        // Load saved preferences
        self.isPolishedMode = preferences.bool(forKey: "isPolishedMode")
        
        if let modeString = preferences.string(forKey: "hotkeyMode"),
           let mode = HotkeyMode(rawValue: modeString) {
            self.hotkeyMode = mode
        } else {
            self.hotkeyMode = .fn
        }
        
        // Default to true for Whispr-like behavior
        if preferences.object(forKey: "autoPaste") == nil {
            self.autoPaste = true
        } else {
            self.autoPaste = preferences.bool(forKey: "autoPaste")
        }
        self.launchAtLogin = preferences.bool(forKey: "launchAtLogin")

        if let savedUID = preferences.string(forKey: "selectedInputDeviceUID") {
            self.selectedInputDeviceUID = savedUID
        } else {
            self.selectedInputDeviceUID = AudioInputDevice.autoUID
        }

        // Set singleton reference
        AppState.shared = self

        applySelectedInputDevice()
        refreshInputDevices()
        
        // Load history
        loadHistory()
        
        // Setup audio level monitoring
        setupAudioLevelMonitoring()
        
        // Preload LLM if polished mode enabled
        if isPolishedMode {
            LLMService.shared.setEnabled(true)
        }
    }

    func refreshInputDevices() {
        availableInputDevices = AudioDeviceManager.listInputDevices()
    }
    
    // MARK: - Audio Level Monitoring
    
    private func setupAudioLevelMonitoring() {
        audioCaptureService.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)
    }
    
    // MARK: - Listening Control
    
    @discardableResult
    func startListening() -> Bool {
        guard isModelLoaded else {
            showError("Speech model is still loading. Please wait a moment.")
            return false
        }
        guard let id = session.begin() else { return false }
        isStarting = true
        pasteTargetApp = NSWorkspace.shared.frontmostApplication
        if pasteTargetApp == NSRunningApplication.current {
            pasteTargetApp = (NSApplication.shared.delegate as? AppDelegate)?.previousApp
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Voice dictation")
        if isPolishedMode { LLMService.shared.warmIfNeeded() }
        startTask = Task {
            defer { startTask = nil }
            do {
                let permitted = await audioCaptureService.requestMicrophonePermission()
                try Task.checkCancellation()
                guard permitted else { throw AudioCaptureError.noPermission }
                try await audioCaptureService.startRecording()
                try Task.checkCancellation()
                guard session.didStart(id) else { throw CancellationError() }
                // Cue only once the mic is live, so the user never talks into a dead mic.
                playStartSound()
                isStarting = false
                isListening = true
            } catch {
                _ = audioCaptureService.stopRecording()
                finishSession(id)
                if !(error is CancellationError) {
                    showError("Failed to start recording: \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    func shutdown() {
        startTask?.cancel()
        _ = audioCaptureService.stopRecording()
        if let id = session.id { finishSession(id) }
        LLMService.shared.setEnabled(false)
    }

    private func finishSession(_ id: UUID) {
        guard session.id == id else { return }
        session.finish(id)
        isStarting = false
        isListening = false
        isTranscribing = false
        isPolishing = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        (NSApplication.shared.delegate as? AppDelegate)?.recordingDidEnd()
    }

    func stopListeningAndTranscribe() async {
        switch session.requestStop() {
        case .cancelStartup:
            startTask?.cancel()
            return
        case .ignore:
            return
        case .transcribe:
            break
        }
        guard let id = session.id else { return }
        let polish = isPolishedMode
        isListening = false
        isTranscribing = true
        var timing = PipelineTiming()
        defer { finishSession(id) }

        guard let buffer = audioCaptureService.stopRecording() else {
            showError("No audio was recorded")
            return
        }
        playStopSound()
        timing.mark("recording_stopped")

        do {
            let text = try await transcriptionService.transcribe(buffer)
            timing.mark("transcription")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showError("No speech detected. Please try again.")
                return
            }
            let detected = TextCleanupService.detectLanguage(from: text)
            var finalText = LLMService.shared.basicFormat(text, language: detected.cleanupLanguage)
            timing.mark("basic_cleanup")
            if polish {
                isPolishing = true
                finalText = try await LLMService.shared.processPolished(finalText, language: detected.cleanupLanguage)
                isPolishing = false
            }
            timing.mark("polishing")
            guard session.id == id, !Task.isCancelled else { return }
            guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showError("No speech remained after cleanup")
                return
            }

            let transcription = Transcription(id: UUID(), timestamp: Date(), language: detected.code, text: finalText)
            // Delivery must not depend on SQLite being writable.
            let clipboardVersion = clipboardWriter(finalText)
            if autoPaste { await pasteFromClipboard(expectedChangeCount: clipboardVersion) }
            timing.mark("delivery")
            do {
                try persistenceService.saveTranscription(transcription)
                transcriptionHistory.insert(transcription, at: 0)
            } catch {
                showError("Text is ready, but history could not be saved: \(error.localizedDescription)")
            }
            timing.mark("history")
        } catch {
            showError("Transcription failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Sound Feedback
    
    private func playStartSound() {
        startCue()
    }
    
    private func playStopSound() {
        stopCue()
    }

    private func applySelectedInputDevice() {
        guard selectedInputDeviceUID != AudioInputDevice.autoUID,
              let device = AudioDeviceManager.device(uid: selectedInputDeviceUID),
              AudioDeviceManager.defaultInputDeviceID() != device.id else { return }
        _ = AudioDeviceManager.setDefaultInputDevice(device.id)
    }
    
    func toggleListening() {
        if isListening || isStarting {
            Task {
                await stopListeningAndTranscribe()
            }
        } else {
            startListening()
        }
    }
    
    // MARK: - Clipboard Operations
    
    private static func writeClipboard(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }
    
    private func pasteFromClipboard(expectedChangeCount: Int) async {
        guard !isPasting else { return }
        isPasting = true
        defer { isPasting = false }

        // Preserve the accepted recording's destination; never paste into an unrelated app.
        guard let target = pasteTargetApp, !target.isTerminated,
              target != NSRunningApplication.current else {
            showCopiedNotification()
            return
        }
        if NSWorkspace.shared.frontmostApplication == NSRunningApplication.current {
            target.activate()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
            while !Task.isCancelled, NSWorkspace.shared.frontmostApplication != target, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard !Task.isCancelled else { return }
        guard PastePolicy.canPost(
            hasPermission: CGPreflightPostEventAccess(),
            targetIsFrontmost: NSWorkspace.shared.frontmostApplication == target,
            clipboardUnchanged: NSPasteboard.general.changeCount == expectedChangeCount
        ) else {
            if NSPasteboard.general.changeCount == expectedChangeCount {
                showCopiedNotification()
            } else {
                showError("Clipboard changed while preparing paste. Your dictation is in History.")
            }
            PipelineTiming.event("paste_skipped")
            return
        }
        guard postCommandV() else { showCopiedNotification(); return }
        PipelineTiming.event("paste_event_posted")
    }

    private func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        // CGEvent has no cross-application acknowledgement. Never retry blindly.
        return true
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
