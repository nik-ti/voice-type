import Foundation
import SQLite3

/// Service for persisting transcription history using SQLite
class PersistenceService {
    private var db: OpaquePointer?
    private let dbPath: String
    
    init(databasePath: String? = nil) {
        if let databasePath {
            dbPath = databasePath
            openDatabase()
            createTable()
            return
        }
        // Create application support directory if needed
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("VoiceType", isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        } catch {
            print("Failed to create app directory: \(error)")
        }
        
        dbPath = appDir.appendingPathComponent("history.sqlite").path
        
        openDatabase()
        createTable()
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    // MARK: - Database Setup
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("❌ Failed to open database at \(dbPath)")
        } else {
            print("✅ Database opened at \(dbPath)")
        }
    }
    
    private func createTable() {
        let createTableSQL = """
            CREATE TABLE IF NOT EXISTS transcriptions (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                language TEXT NOT NULL,
                text TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_timestamp ON transcriptions(timestamp DESC);
        """
        
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, createTableSQL, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("❌ Failed to create table: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }
    
    // MARK: - CRUD Operations
    
    func saveTranscription(_ transcription: Transcription) throws {
        let insertSQL = "INSERT OR REPLACE INTO transcriptions (id, timestamp, language, text) VALUES (?, ?, ?, ?);"
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            throw PersistenceError.prepareFailed
        }
        
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, transcription.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(statement, 2, transcription.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, transcription.language, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 4, transcription.text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistenceError.insertFailed
        }
    }
    
    func fetchTranscriptions(searchText: String? = nil) -> [Transcription] {
        var transcriptions: [Transcription] = []
        
        var querySQL = "SELECT id, timestamp, language, text FROM transcriptions"
        if let search = searchText, !search.isEmpty {
            querySQL += " WHERE text LIKE '%\(search.replacingOccurrences(of: "'", with: "''"))%'"
        }
        querySQL += " ORDER BY timestamp DESC;"
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK else {
            return transcriptions
        }
        
        defer { sqlite3_finalize(statement) }
        
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idCStr = sqlite3_column_text(statement, 0),
                  let langCStr = sqlite3_column_text(statement, 2),
                  let textCStr = sqlite3_column_text(statement, 3) else {
                continue
            }
            
            let id = UUID(uuidString: String(cString: idCStr)) ?? UUID()
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let language = String(cString: langCStr)
            let text = String(cString: textCStr)
            
            let transcription = Transcription(
                id: id,
                timestamp: timestamp,
                language: language,
                text: text
            )
            transcriptions.append(transcription)
        }
        
        return transcriptions
    }
    
    func deleteTranscription(id: UUID) throws {
        let deleteSQL = "DELETE FROM transcriptions WHERE id = ?;"
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK else {
            throw PersistenceError.prepareFailed
        }
        
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistenceError.deleteFailed
        }
    }
    
    func clearAllHistory() throws {
        let deleteSQL = "DELETE FROM transcriptions;"
        
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, deleteSQL, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                let error = String(cString: errMsg)
                sqlite3_free(errMsg)
                throw PersistenceError.clearFailed(error)
            }
        }
    }
    
    // MARK: - Export
    
    func exportHistory(to url: URL, format: ExportFormat, transcriptions: [Transcription]) throws {
        var content = ""
        
        switch format {
        case .text:
            for t in transcriptions {
                content += "[\(t.formattedDate)] [\(t.languageEmoji)]\n"
                content += t.text + "\n\n"
                content += "---\n\n"
            }
            
        case .markdown:
            content = "# VoiceType Transcription History\n\n"
            content += "Exported: \(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short))\n\n"
            content += "---\n\n"
            
            for t in transcriptions {
                content += "## \(t.formattedDate) \(t.languageEmoji)\n\n"
                content += t.text + "\n\n"
            }
        }
        
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Database Path
    
    var databasePath: String {
        return dbPath
    }
}

// MARK: - Errors

enum PersistenceError: LocalizedError {
    case prepareFailed
    case insertFailed
    case deleteFailed
    case clearFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .prepareFailed:
            return "Failed to prepare SQL statement"
        case .insertFailed:
            return "Failed to insert transcription"
        case .deleteFailed:
            return "Failed to delete transcription"
        case .clearFailed(let reason):
            return "Failed to clear history: \(reason)"
        }
    }
}
