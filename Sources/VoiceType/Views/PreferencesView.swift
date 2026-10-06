import SwiftUI
import ServiceManagement

/// Preferences/Settings window
struct PreferencesView: View {
    @EnvironmentObject var appState: AppState

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
        .frame(width: 480, height: 500)
        .padding()
    }
}

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
                Text("Language is detected automatically from what you say. English, Russian, and most other European languages work. Chinese, Japanese, Arabic, and similar languages are not supported by the local model.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Language")
            }

            Section {
                Picker("Microphone", selection: $appState.selectedInputDeviceUID) {
                    Text("Auto (follow System Settings)")
                        .tag(AudioInputDevice.autoUID)
                    ForEach(appState.availableInputDevices) { device in
                        Text(device.displayName).tag(device.uid)
                    }
                }
                .onAppear { appState.refreshInputDevices() }

                Text("Auto follows the input selected in macOS System Settings. Choosing a microphone here changes the Mac's default input once, so VoiceType does not switch audio devices during every recording.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Microphone")
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

            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
                .foregroundColor(.secondary)

            Text("Fast, local speech-to-text for macOS")
                .font(.body)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 8) {
                Text("Speech: Parakeet TDT v3 (25 European languages)")
                    .font(.caption)
                Text("Polished Mode: Qwen3 0.6B on-device")
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
