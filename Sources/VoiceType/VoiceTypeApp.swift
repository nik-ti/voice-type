import SwiftUI
import AppKit

/// Main entry point for VoiceType menu bar transcription app
@main
struct VoiceTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        // Menu bar extra - the main interface
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            // Revert to system icon - custom assets missing
            Image(systemName: appState.isStarting ? "hourglass" : (appState.isTranscribing ? "ellipsis.circle" : (appState.isListening ? "mic.fill" : "mic")))
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)
        
        // Settings window
        Settings {
            PreferencesView()
                .environmentObject(appState)
        }
        
        // History window
        Window("Transcription History", id: "history") {
            HistoryView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 500)
    }
}
