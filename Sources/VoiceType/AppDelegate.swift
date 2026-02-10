import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine
import UserNotifications

/// AppDelegate handles global hotkey registration and floating indicator window
class AppDelegate: NSObject, NSApplicationDelegate {
    var floatingWindow: NSWindow?
    var floatingHostingView: NSHostingView<FloatingIndicatorView>?
    
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
    
    func applicationWillTerminate(_ notification: Notification) {
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
        
        // Create borderless, floating window - compact pill size
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.contentView = hostingView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = true
        window.ignoresMouseEvents = false // Allow button clicks
        
        // Position at bottom center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = window.frame
            let x = screenFrame.midX - windowFrame.width / 2
            let y = screenFrame.minY + 80
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        self.floatingWindow = window
        self.floatingHostingView = hostingView
    }
    
    @MainActor
    func showFloatingIndicator() {
        print("🔵 Showing floating indicator, locked=\(isLockedMode)")
        updateIndicatorView(audioLevel: 0)
        floatingWindow?.orderFront(nil)
        
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
        
        // Restore focus to the previous app before stopping (so paste goes there)
        if let app = previousApp {
            print("📱 Restoring focus to: \(app.localizedName ?? "unknown")")
            app.activate()
        }
        
        triggerStopListening()
    }
    
    @MainActor
    func hideFloatingIndicator() {
        print("🔵 Hiding floating indicator")
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        floatingHostingView?.rootView = FloatingIndicatorView(audioLevel: 0, isVisible: false, isLocked: false)
        
        // Give animation time before hiding window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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
            if optionKeyPressed && !fnKeyPressed && isLockedMode {
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
        // Get current mode
        guard let appState = AppState.shared else { return }
        let mode = appState.hotkeyMode
        
        print("⌨️ KeyDown: keyCode=\(event.keyCode), mode=\(mode)")
        
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
    
    private func handleKeyUp(_ event: NSEvent) {
        // Nothing needed for key up in current mode
    }
    
    // MARK: - Listening Control
    
    private func triggerStartListening() {
        // Capture the currently active app before we start
        previousApp = NSWorkspace.shared.frontmostApplication
        print("📱 Captured previous app: \(previousApp?.localizedName ?? "none")")
        
        Task { @MainActor in
            guard let appState = AppState.shared else { 
                print("❌ AppState.shared is nil")
                return 
            }
            print("🎤 Starting listening via hotkey")
            appState.startListening()
            showFloatingIndicator()
        }
    }
    
    private func triggerStopListening() {
        // Restore focus to the previous app FIRST (before hiding indicator)
        // This covers ALL stop paths: Fn release, Option release, Escape, locked mode
        if let app = previousApp {
            print("📱 Restoring focus to: \(app.localizedName ?? "unknown")")
            app.activate()
        }
        
        Task { @MainActor in
            guard let appState = AppState.shared else { 
                print("❌ AppState.shared is nil")
                return 
            }
            print("🎤 Stopping listening via hotkey")
            hideFloatingIndicator()
            await appState.stopListeningAndTranscribe()
        }
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
    private func setupRecordingCallbacks() {
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
                appState?.showError("Microphone disconnected — recording stopped")
                // Don't transcribe partial audio from a disconnect
            }
        }
    }
}
