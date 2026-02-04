import AppKit
import SwiftUI
import Carbon.HIToolbox

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
    }
    
    // MARK: - Floating Window Setup
    
    private func setupFloatingWindow() {
        let contentView = FloatingIndicatorView(audioLevel: 0, isVisible: false)
        let hostingView = NSHostingView(rootView: contentView)
        
        // Create borderless, floating window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
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
        window.ignoresMouseEvents = true
        
        // Position at bottom center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = window.frame
            let x = screenFrame.midX - windowFrame.width / 2
            let y = screenFrame.minY + 100
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        self.floatingWindow = window
        self.floatingHostingView = hostingView
    }
    
    @MainActor
    func showFloatingIndicator() {
        floatingWindow?.orderFront(nil)
    }
    
    @MainActor
    func hideFloatingIndicator() {
        floatingWindow?.orderOut(nil)
    }
    
    @MainActor
    func updateFloatingIndicator(audioLevel: Float, isVisible: Bool) {
        let contentView = FloatingIndicatorView(audioLevel: audioLevel, isVisible: isVisible)
        floatingHostingView?.rootView = contentView
    }
    
    // MARK: - Accessibility Permission
    
    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if !trusted {
            print("⚠️ Accessibility permission required for global hotkeys")
        }
    }
    
    func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    
    // MARK: - Global Hotkey Monitoring
    
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
    }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        // Check for fn key press (secondary function key)
        // fn key modifier flag is .function (bit 23)
        let fnKeyPressed = event.modifierFlags.contains(.function)
        
        // Get configured hotkey from UserDefaults
        let hotkeyMode = UserDefaults.standard.string(forKey: "hotkeyMode") ?? "fn"
        
        if hotkeyMode == "fn" {
            if fnKeyPressed && !isHotkeyPressed {
                // Fn key pressed - start listening
                isHotkeyPressed = true
                triggerStartListening()
            } else if !fnKeyPressed && isHotkeyPressed {
                // Fn key released - stop listening
                isHotkeyPressed = false
                triggerStopListening()
            }
        }
    }
    
    private func handleKeyDown(_ event: NSEvent) {
        // Check for custom hotkey (e.g., Option+Space)
        let hotkeyMode = UserDefaults.standard.string(forKey: "hotkeyMode") ?? "fn"
        
        if hotkeyMode == "optionSpace" {
            if event.modifierFlags.contains(.option) && event.keyCode == 49 { // 49 = space
                if !isHotkeyPressed {
                    isHotkeyPressed = true
                    triggerStartListening()
                }
            }
        } else if hotkeyMode == "toggle" {
            // Toggle mode with specific key
            if event.keyCode == UserDefaults.standard.integer(forKey: "toggleKeyCode") {
                if isHotkeyPressed {
                    isHotkeyPressed = false
                    triggerStopListening()
                } else {
                    isHotkeyPressed = true
                    triggerStartListening()
                }
            }
        }
    }
    
    private func handleKeyUp(_ event: NSEvent) {
        let hotkeyMode = UserDefaults.standard.string(forKey: "hotkeyMode") ?? "fn"
        
        if hotkeyMode == "optionSpace" {
            if event.keyCode == 49 { // space released
                if isHotkeyPressed {
                    isHotkeyPressed = false
                    triggerStopListening()
                }
            }
        }
    }
    
    // MARK: - Listening Control
    
    private func triggerStartListening() {
        Task { @MainActor in
            guard let appState = AppState.shared else { return }
            appState.startListening()
            showFloatingIndicator()
        }
    }
    
    private func triggerStopListening() {
        Task { @MainActor in
            guard let appState = AppState.shared else { return }
            await appState.stopListeningAndTranscribe()
            hideFloatingIndicator()
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
