import SwiftUI

/// Menu bar dropdown view
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
            // Status indicator
            if !appState.isModelLoaded {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading model...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                Divider()
            }
            
            // Language selector
            Menu {
                ForEach(TranscriptionLanguage.allCases, id: \.self) { language in
                    Button(action: {
                        appState.selectedLanguage = language
                    }) {
                        HStack {
                            Text("\(language.flag) \(language.displayName)")
                            if appState.selectedLanguage == language {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("\(appState.selectedLanguage.flag) \(appState.selectedLanguage.displayName)", systemImage: "globe")
            }
            
            Divider()
            
            // Start/Stop listening
            Button(action: {
                appState.toggleListening()
            }) {
                Label(
                    appState.isListening ? "Stop Listening" : "Start Listening",
                    systemImage: appState.isListening ? "stop.fill" : "mic.fill"
                )
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!appState.isModelLoaded)
            
            if appState.isTranscribing {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Transcribing...")
                        .font(.caption)
                }
                .padding(.vertical, 4)
            }
            
            Divider()
            
            // History
            Button(action: {
                openWindow(id: "history")
            }) {
                Label("History...", systemImage: "clock")
            }
            .keyboardShortcut("h", modifiers: .command)
            
            // Preferences
            SettingsLink {
                Label("Preferences...", systemImage: "gear")
            }
            .keyboardShortcut(",", modifiers: .command)
            
            Divider()
            
            // Error display
            if appState.showingError, let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                Divider()
            }
            
            // Quit
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Label("Quit VoiceType", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
