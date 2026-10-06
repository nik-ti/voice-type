// Handles global hotkeys and the recording indicator.
// Recording ownership and safe delivery live in AppState.
import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine
import UserNotifications

/// AppDelegate handles global hotkey registration and floating indicator window
class AppDelegate: NSObject, NSApplicationDelegate {
    var floatingWindow: NSWindow?
    var floatingHostingView: NSHostingView<FloatingIndicatorView>?
    private var indicatorRevision = 0
    
    // Global event monitors
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var flagsChangedMonitor: Any?
    
    // Current hotkey state
    private var isHotkeyPressed = false
    
    // Audio level subscription
    private var audioLevelCancellable: AnyCancellable?
    
    // Store the app that was active before recording
    var previousApp: NSRunningApplication?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        PipelineTiming.event("build=\(Bundle.main.object(forInfoDictionaryKey: "VoiceTypeBuildID") as? String ?? "development")")
        // Don't show app in dock
        NSApp.setActivationPolicy(.accessory)
        
        // Setup floating indicator window
        setupFloatingWindow()
        
        // Request accessibility permission for global hotkeys
        requestAccessibilityPermission()
        
        // Request notification permission for time warnings
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        // Register global hotkey monitor
        registerGlobalHotkeyMonitor()
        
        // Setup recording time limit callbacks
        setupRecordingCallbacks()
        
        // Load models in background
        Task { @MainActor in
            await loadTranscriptionModels()
        }
    }
    
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared?.shutdown()
        // Remove event monitors
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = keyUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
        }
        audioLevelCancellable?.cancel()
    }
    
    // MARK: - Floating Window Setup
    
    private func setupFloatingWindow() {
        let contentView = FloatingIndicatorView(audioLevel: 0, isVisible: false, isLocked: false)
        let hostingView = NSHostingView(rootView: contentView)

        let window = Self.makeFloatingIndicatorPanel()
        window.contentView = hostingView

        self.floatingWindow = window
        self.floatingHostingView = hostingView
    }

    /// A non-activating panel stays above the app receiving dictation without
    /// stealing keyboard focus from it.
    static func makeFloatingIndicatorPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func positionIndicatorOnActiveScreen() {
        guard let window = floatingWindow else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let x = screen.visibleFrame.midX - window.frame.width / 2
        let y = screen.visibleFrame.minY + 80
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    @MainActor
    func showFloatingIndicator() {
        indicatorRevision += 1
        print("🔵 Showing floating indicator, locked=\(isLockedMode)")
        updateIndicatorView(audioLevel: 0)
        positionIndicatorOnActiveScreen()
        floatingWindow?.alphaValue = 1
        floatingWindow?.contentView?.layoutSubtreeIfNeeded()
        floatingWindow?.orderFrontRegardless()
        PipelineTiming.event("indicator_show visible=\(floatingWindow?.isVisible == true)")
        
        // Subscribe to audio level updates
        if let appState = AppState.shared {
            audioLevelCancellable = appState.audioCaptureService.$audioLevel
                .receive(on: DispatchQueue.main)
                .sink { [weak self] level in
                    self?.updateIndicatorView(audioLevel: level)
                }
        }
    }
    
    @MainActor
    private func updateIndicatorView(audioLevel: Float) {
        floatingHostingView?.rootView = FloatingIndicatorView(
            audioLevel: audioLevel,
            isVisible: true,
            isLocked: isLockedMode,
            onStop: { [weak self] in
                self?.handleStopButtonPressed()
            }
        )
    }
    
    @MainActor
    private func handleStopButtonPressed() {
        print("🛑 Stop button pressed")
        isLockedMode = false
        isHotkeyPressed = false
        
        triggerStopListening()
    }
    
    @MainActor
    func hideFloatingIndicator() {
        print("🔵 Hiding floating indicator")
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        floatingHostingView?.rootView = FloatingIndicatorView(audioLevel: 0, isVisible: false, isLocked: false)
        
        indicatorRevision += 1
        let revision = indicatorRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.indicatorRevision == revision else { return }
            self.floatingWindow?.orderOut(nil)
        }
    }
    
    // MARK: - Accessibility Permission
    
    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if !trusted {
            print("⚠️ Accessibility permission required for global hotkeys and auto-paste")
        } else {
            print("✅ Accessibility permission granted")
        }
    }
    
    func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    
    // MARK: - Global Hotkey Monitoring
    
    private var isLockedMode = false  // fn+space locks recording on
    
    private func registerGlobalHotkeyMonitor() {
        // Monitor for fn key (flags changed)
        flagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }
        
        // Also monitor for custom key combinations
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
        }
        
        // keyUp is empty but let's be consistent
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
             Task { @MainActor in
                self?.handleKeyUp(event)
            }
        }
        
        print("✅ Global hotkey monitors registered")
    }
    
    @MainActor
    private func handleFlagsChanged(_ event: NSEvent) {
        // Get current mode
        guard let appState = AppState.shared else { return }
        let mode = appState.hotkeyMode
        
        let fnKeyPressed = event.modifierFlags.contains(.function)
        let optionKeyPressed = event.modifierFlags.contains(.option)
        
        // Mode 1: Function Key (Fn)
        if mode == .fn {
            // fn + Option: Toggle lock mode (Special case always allowed)
            if fnKeyPressed && optionKeyPressed && !isLockedMode {
                print("🔒 Locked mode activated (fn+Option)")
                isLockedMode = true
                if !isHotkeyPressed {
                    isHotkeyPressed = true
                    triggerStartListening()
                }
                return
            }
            
            // Option alone (no fn): Exit locked mode
            if optionKeyPressed && !fnKeyPressed && isLockedMode && [58, 61].contains(event.keyCode) {
                print("🔓 Locked mode deactivated (Option)")
                isLockedMode = false
                isHotkeyPressed = false
                triggerStopListening()
                return
            }
            
            // Skip routine handling if locked
            if isLockedMode { return }
            
            // Standard Fn Hold-to-speak
            if fnKeyPressed && !optionKeyPressed && !isHotkeyPressed {
                isHotkeyPressed = true
                triggerStartListening()
            } else if !fnKeyPressed && isHotkeyPressed {
                isHotkeyPressed = false
                triggerStopListening()
            }
        }
        
        // Mode 2: Option + Space (Flags part - check Option key release)
        if mode == .optionSpace {
            // If Option is released while recording, stop
            if !optionKeyPressed && isHotkeyPressed {
                print("⌨️ Option released, stopping")
                isHotkeyPressed = false
                triggerStopListening()
            }
        }
    }
    
    @MainActor
    private func handleKeyDown(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        guard let appState = AppState.shared else { return }
        let mode = appState.hotkeyMode
        
        // Special: fn+space toggle lock (Always available as backup)
        if event.modifierFlags.contains(.function) && event.keyCode == 49 { // 49 = space
            if !isLockedMode {
                isLockedMode = true
                if !isHotkeyPressed {
                    isHotkeyPressed = true
                    triggerStartListening()
                }
            } else {
                isLockedMode = false
                isHotkeyPressed = false
                triggerStopListening()
            }
            return
        }
        
        // Mode 2: Option + Space (Hold)
        if mode == .optionSpace {
            if event.modifierFlags.contains(.option) && event.keyCode == 49 { // Option + Space
                if !isHotkeyPressed {
                    print("⌨️ Option+Space pressed, starting")
                    isHotkeyPressed = true
                    triggerStartListening()
                }
            }
        }
        
        // Mode 3: Toggle Key (Using F5 as toggle for now, can be configured)
        if mode == .toggle {
            if event.keyCode == 96 { // F5 key usually (check keycode map)
                // Actually let's use Control+Space for toggle since F keys are tricky
            }
            
            // Let's use Right Command for toggle for now as a simple placeholder
            // Or better, stick to Option+Space but as a toggle
             if event.modifierFlags.contains(.option) && event.keyCode == 49 {
                if !isHotkeyPressed {
                    isHotkeyPressed = true
                    triggerStartListening()
                } else {
                    isHotkeyPressed = false
                    triggerStopListening()
                }
            }
        }
        
        // Escape: Stop anything
        if event.keyCode == 53 && (isLockedMode || isHotkeyPressed) { // 53 = Escape
            print("🛑 Escape pressed, stopping all")
            isLockedMode = false
            isHotkeyPressed = false
            triggerStopListening()
            return
        }
    }
    
    @MainActor
    private func handleKeyUp(_ event: NSEvent) {
        if AppState.shared?.hotkeyMode == .optionSpace, event.keyCode == 49, isHotkeyPressed {
            isHotkeyPressed = false
            triggerStopListening()
        }
    }
    
    // MARK: - Listening Control
    
    @MainActor
    private func triggerStartListening() {
        guard let appState = AppState.shared else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if appState.startListening() {
            if front != NSRunningApplication.current { previousApp = front }
            showFloatingIndicator()
        } else {
            isHotkeyPressed = false
            isLockedMode = false
        }
    }

    private func triggerStopListening() {
        Task { @MainActor in
            guard let appState = AppState.shared else { return }
            hideFloatingIndicator()
            await appState.stopListeningAndTranscribe()
        }
    }

    @MainActor
    func recordingDidEnd() {
        isHotkeyPressed = false
        isLockedMode = false
        hideFloatingIndicator()
    }

    // MARK: - Model Loading
    
    @MainActor
    private func loadTranscriptionModels() async {
        guard let appState = AppState.shared else { return }
        
        do {
            try await appState.transcriptionService.loadModels()
            appState.isModelLoaded = true
        } catch {
            print("❌ Failed to load transcription models: \(error)")
            appState.showError("Failed to load transcription model: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Recording Time Limit
    
    @MainActor
    func setupRecordingCallbacks() {
        guard let appState = AppState.shared else { return }
        
        // Warning at 15 seconds before limit
        appState.audioCaptureService.onTimeWarning = {
            let content = UNMutableNotificationContent()
            content.title = "Recording Limit"
            content.body = "15 seconds remaining. Finish your thought — you can start a new recording after."
            content.sound = .default
            
            let request = UNNotificationRequest(
                identifier: "recording-warning",
                content: content,
                trigger: nil  // Deliver immediately
            )
            UNUserNotificationCenter.current().add(request) { _ in }
        }
        
        // Auto-stop at limit
        appState.audioCaptureService.onTimeLimit = { [weak self, weak appState] in
            Task { @MainActor in
                guard let self = self else { return }
                print("⏱️ Auto-stopping: recording limit reached")
                self.isLockedMode = false
                self.isHotkeyPressed = false
                self.hideFloatingIndicator()
                await appState?.stopListeningAndTranscribe()
            }
        }
        
        // Mic disconnect recovery
        appState.audioCaptureService.onAudioInterruption = { [weak self, weak appState] in
            Task { @MainActor in
                guard let self = self else { return }
                print("⚠️ Mic disconnected, stopping recording")
                self.isLockedMode = false
                self.isHotkeyPressed = false
                self.hideFloatingIndicator()
                appState?.showError("Microphone changed — finishing the audio already recorded")
                await appState?.stopListeningAndTranscribe()
            }
        }
    }
}
