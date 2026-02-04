import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine

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
    private var previousApp: NSRunningApplication?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Don't show app in dock
        NSApp.setActivationPolicy(.accessory)
        
        // Setup floating indicator window
        setupFloatingWindow()
        
        // Request accessibility permission for global hotkeys
        requestAccessibilityPermission()
        
        // Register global hotkey monitor
        registerGlobalHotkeyMonitor()
        
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
            self?.handleFlagsChanged(event)
        }
        
        // Also monitor for custom key combinations
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
        }
        
        print("✅ Global hotkey monitors registered")
    }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        let fnKeyPressed = event.modifierFlags.contains(.function)
        let optionKeyPressed = event.modifierFlags.contains(.option)
        
        // fn + Option: Toggle lock mode
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
        
        // Skip normal fn handling if in locked mode
        if isLockedMode {
            return
        }
        
        // Hold-to-speak: fn key only (no Option)
        if fnKeyPressed && !optionKeyPressed && !isHotkeyPressed {
            isHotkeyPressed = true
            triggerStartListening()
        } else if !fnKeyPressed && isHotkeyPressed {
            isHotkeyPressed = false
            triggerStopListening()
        }
    }
    
    private func handleKeyDown(_ event: NSEvent) {
        print("⌨️ KeyDown: keyCode=\(event.keyCode), fn=\(event.modifierFlags.contains(.function)), locked=\(isLockedMode)")
        
        // fn+space: Toggle lock mode
        if event.modifierFlags.contains(.function) && event.keyCode == 49 { // 49 = space
            if !isLockedMode {
                // Enter locked mode - keep recording even after fn is released
                print("🔒 Locked mode activated (fn+space)")
                isLockedMode = true
                // If not already recording, start now
                if !isHotkeyPressed {
                    isHotkeyPressed = true
                    triggerStartListening()
                }
            } else {
                // Already locked - toggle off
                print("🔓 Locked mode deactivated (fn+space toggle)")
                isLockedMode = false
                isHotkeyPressed = false
                triggerStopListening()
            }
            return
        }
        
        // Escape: Stop if in locked mode
        if event.keyCode == 53 && isLockedMode { // 53 = Escape
            print("🔓 Locked mode deactivated (Escape)")
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
}
