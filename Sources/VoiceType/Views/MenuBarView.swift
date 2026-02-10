import SwiftUI
import AppKit

/// Menu bar dropdown view
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var llmService = LLMService.shared
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
            
            
            // Polished Mode (removes fillers, fixes grammar)
            Button(action: {
                appState.isPolishedMode.toggle()
            }) {
                HStack {
                    Text("✨ Polished Mode")
                    if appState.isPolishedMode {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            // LLM download progress (#3)
            if llmService.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    if llmService.loadingProgress > 0 {
                        Text("Downloading grammar model... \(Int(llmService.loadingProgress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Downloading grammar model...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
            }
            
            Divider()
            
            
            if appState.isTranscribing {
                HStack {
                    if appState.isPolishing {
                        Text("✨")
                    } else {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Text(appState.isPolishing ? "Polishing..." : "Transcribing...")
                        .font(.caption)
                }
                .padding(.vertical, 4)
                
                // Live preview during polishing (#5 Streaming)
                if appState.isPolishing && !llmService.polishingPreview.isEmpty {
                    Text(llmService.polishingPreview)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .italic()
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                }
            }
            
            // Recent transcriptions (#9)
            if !appState.transcriptionHistory.isEmpty {
                let recent = Array(appState.transcriptionHistory.prefix(3))
                ForEach(recent) { item in
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                    }) {
                        HStack {
                            Text(item.text.prefix(40) + (item.text.count > 40 ? "..." : ""))
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("📋")
                                .font(.caption2)
                        }
                    }
                    .help(item.text) // Full text on hover
                }
                Divider()
            }
            
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
