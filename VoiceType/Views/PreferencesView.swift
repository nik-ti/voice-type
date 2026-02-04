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
            
            HotkeySettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("Hotkey", systemImage: "keyboard")
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
                Picker("Language", selection: $appState.selectedLanguage) {
                    ForEach(TranscriptionLanguage.allCases, id: \.self) { language in
                        Text("\(language.flag) \(language.displayName)")
                            .tag(language)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Transcription")
            }
            
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

/// Hotkey settings tab
struct HotkeySettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var hasAccessibility = false
    
    var body: some View {
        Form {
            Section {
                Picker("Hotkey Mode", selection: $appState.hotkeyMode) {
                    ForEach(HotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.displayName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                
                Text("Current hotkey: \(hotkeyDescription)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Keyboard Shortcut")
            }
            
            Section {
                HStack {
                    Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(hasAccessibility ? .green : .red)
                    
                    VStack(alignment: .leading) {
                        Text(hasAccessibility ? "Accessibility access granted" : "Accessibility access required")
                            .font(.headline)
                        Text("Global hotkeys require accessibility permission")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if !hasAccessibility {
                        Button("Open System Settings") {
                            openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            checkAccessibility()
        }
    }
    
    private var hotkeyDescription: String {
        switch appState.hotkeyMode {
        case .fn:
            return "Hold fn key"
        case .optionSpace:
            return "Hold ⌥ + Space"
        case .toggle:
            return "Press configured key to toggle"
        }
    }
    
    private func checkAccessibility() {
        hasAccessibility = AXIsProcessTrusted()
    }
    
    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// About tab
struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
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
                Text("Powered by Parakeet-TDT 0.6B")
                    .font(.caption)
                Text("FluidAudio by FluidInference")
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
