import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// History window showing all past transcriptions
struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTranscription: Transcription?
    @State private var showingExportSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var transcriptionToDelete: Transcription?
    
    var body: some View {
        HSplitView {
            // List of transcriptions
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search transcriptions...", text: $appState.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // Transcription list
                if appState.filteredHistory.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(appState.searchText.isEmpty ? "No transcriptions yet" : "No results found")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(appState.filteredHistory, selection: $selectedTranscription) { transcription in
                        TranscriptionRow(transcription: transcription)
                            .tag(transcription)
                            .contextMenu {
                                Button("Copy") {
                                    copyToClipboard(transcription.text)
                                }
                                Button("Delete", role: .destructive) {
                                    transcriptionToDelete = transcription
                                    showingDeleteConfirmation = true
                                }
                            }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 250, idealWidth: 300)
            
            // Detail view
            if let selected = selectedTranscription {
                TranscriptionDetailView(transcription: selected)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a transcription")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .toolbar {
            ToolbarItemGroup {
                Button(action: { showingExportSheet = true }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(appState.transcriptionHistory.isEmpty)
            }
        }
        .fileExporter(
            isPresented: $showingExportSheet,
            document: HistoryExportDocument(transcriptions: appState.transcriptionHistory),
            contentType: .plainText,
            defaultFilename: "VoiceType_History_\(formattedDate())"
        ) { result in
            switch result {
            case .success(let url):
                print("Exported to \(url)")
            case .failure(let error):
                appState.showError("Export failed: \(error.localizedDescription)")
            }
        }
        .alert("Delete Transcription?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let t = transcriptionToDelete {
                    appState.deleteTranscription(t)
                    if selectedTranscription == t {
                        selectedTranscription = nil
                    }
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .onAppear {
            appState.loadHistory()
        }
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// Row view for a transcription in the list
struct TranscriptionRow: View {
    let transcription: Transcription
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transcription.languageEmoji)
                Text(transcription.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(transcription.preview)
                .font(.body)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

/// Detail view for a selected transcription
struct TranscriptionDetailView: View {
    let transcription: Transcription
    @State private var showCopiedFeedback = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        Text(transcription.languageEmoji)
                            .font(.title)
                        Text(transcription.formattedDate)
                            .font(.headline)
                    }
                }
                
                Spacer()
                
                // Copy button
                Button(action: copyText) {
                    Label(showCopiedFeedback ? "Copied!" : "Copy", systemImage: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
            }
            
            Divider()
            
            // Full text
            ScrollView {
                Text(transcription.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcription.text, forType: .string)
        
        showCopiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedFeedback = false
        }
    }
}

/// Document for file export
struct HistoryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.plainText]
    
    var transcriptions: [Transcription]
    
    init(transcriptions: [Transcription]) {
        self.transcriptions = transcriptions
    }
    
    init(configuration: ReadConfiguration) throws {
        transcriptions = []
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var content = "# VoiceType Transcription History\n\n"
        content += "Exported: \(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short))\n\n"
        content += "---\n\n"
        
        for t in transcriptions {
            content += "## \(t.formattedDate) \(t.languageEmoji)\n\n"
            content += t.text + "\n\n"
        }
        
        let data = content.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    HistoryView()
        .environmentObject(AppState())
}
