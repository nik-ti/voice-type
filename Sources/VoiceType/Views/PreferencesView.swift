import SwiftUI
import ServiceManagement

/// Preferences/Settings window
struct PreferencesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingClearConfirmation = false
    
    var body: some View {
        TabView {
            GeneralSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 300)
        .padding()
    }
}

/// General settings tab
struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingClearConfirmation = false
    
    var body: some View {
        Form {
            Section {
                Toggle("Paste result automatically after copying", isOn: $appState.autoPaste)
                    .help("Simulates ⌘V after copying the transcription")
                
                Toggle("Launch at login", isOn: $appState.launchAtLogin)
                    .help("Start VoiceType when you log in")
            } header: {
                Text("Behavior")
            }
            
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(appState.transcriptionHistory.count) transcriptions")
                        Text(appState.persistenceService.databasePath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    Spacer()
                    
                    Button("Clear All History", role: .destructive) {
                        showingClearConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text("History")
            }
        }
        .formStyle(.grouped)
        .alert("Clear All History?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                appState.clearAllHistory()
            }
        } message: {
            Text("This will permanently delete all transcriptions. This action cannot be undone.")
        }
    }
}

/// About tab
struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image("logo")
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
            
            Text("VoiceType")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Version 1.0")
                .foregroundColor(.secondary)
            
            Text("Fast, local speech-to-text for macOS")
                .font(.body)
            
            Divider()
                .padding(.horizontal, 40)
            
            VStack(spacing: 8) {
                Text("Speech: Parakeet-TDT 0.6B via FluidAudio")
                    .font(.caption)
                Text("Polished Mode: Llama 3.2 3B Instruct")
                    .font(.caption)
            }
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    PreferencesView()
        .environmentObject(AppState())
}
