// Exercises local Polished editing with fixed, public dictation fixtures.
// Opt in to load model weights and GPU shaders; this never records or pastes text.
import XCTest
import VoiceTypeCore
import MLXLLM
import MLXLMCommon
import MLX
@testable import VoiceType

@MainActor
final class PolishedQualityTests: XCTestCase {
    func testGrammarCorrectionsAndFacts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOICETYPE_POLISH_QUALITY"] == "1",
              let shader = environment["VOICETYPE_METALLIB"] else {
            throw XCTSkip("Opt-in: requires local models and VOICETYPE_METALLIB")
        }
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.createSymbolicLink(atPath: directory.appendingPathComponent("default.metallib").path,
                                    withDestinationPath: shader)
        let previousDirectory = files.currentDirectoryPath
        XCTAssertTrue(files.changeCurrentDirectoryPath(directory.path))
        defer {
            _ = files.changeCurrentDirectoryPath(previousDirectory)
            try? files.removeItem(at: directory)
        }

        let configuration: ModelConfiguration
        switch environment["VOICETYPE_POLISH_MODEL"] {
        case "4b": configuration = LLMService.defaultModelConfiguration
        case "1.7b": configuration = LLMRegistry.qwen3_1_7b_4bit
        case "0.6b": configuration = LLMRegistry.qwen3_0_6b_4bit
        default: configuration = LLMService.defaultModelConfiguration
        }
        let model = LLMService(modelConfiguration: configuration)
        model.setEnabled(true)
        defer { model.setEnabled(false) }
        let loadDeadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !model.isModelLoaded, model.error == nil, ContinuousClock.now < loadDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(model.isModelLoaded, model.error ?? "Model loading timed out")
        guard model.isModelLoaded else { return }

        let cases: [(String, String, TextCleanupService.Language, [String], [String])] = [
            ("long-proposal",
             "Before we send the proposal to Microsoft, let's check three things: the budget, the deadline, and the client's feedback. Sarah said, \"It looks great, but can we make the introduction shorter?\" I agree with her—mostly. The current version is clear; it just takes too long to get to the point. Also, did Adobe approve the revised design, or are we still waiting? If we haven't heard back by Thursday, please follow up. Oh, and one last thing: the total should be $1,450.75, not $1,540. Don't mix those up!",
             .english,
             ["before we send", "microsoft", "three things:", "client's feedback", "sarah", "adobe", "if we haven't", "$1,450.75", "$1,540", "one last thing"], []),
            ("corrected-instructions",
             "Um, send the the proposal to Microsoft on Tuesday—sorry, Thursday. The budget is fifteen hundred, no, fourteen hundred dollars. Me and Sarah was reviewing it, and, uh, we thinks it's ready. Did Adobe approved the design yet?",
             .english,
             ["send the proposal", "microsoft", "thursday", "1,400", "sarah and i were", "we think", "adobe", "?"],
             ["tuesday", "1,500", "me and sarah", "we thinks", "did adobe approved"]),
            ("short-grammar", "Me and Sarah was reviewing it.", .english,
             ["sarah and i were reviewing it"], ["me and sarah", "was reviewing"]),
            ("intentional-contrast",
             "If Adobe hasn't approved the design by Thursday, do not send it. The total should be $1,450.75, not $1,540. Don't mix those up!",
             .english,
             ["if", "adobe", "thursday", "not", "$1,450.75", "$1,540"], []),
            ("russian-correction",
             "Отправь предложение в Microsoft во вторник, нет, в четверг. Бюджет 1500, нет, 1400 долларов.",
             .russian, ["отправь", "microsoft", "четверг", "1400"], ["вторник", "1500"]),
            ("russian-grammar",
             "Завтра нужно отправить в Яндекс договор, смету, презентацию и список участников. Мы с Анной уже проверил документы, но забыли добавить адрес, телефон и электронную почту. Пожалуйста, убедись, что все файлы на месте и ничего не потерялись.",
             .russian,
             ["яндекс", "анной", "проверили", "убедись", "не потерялось", "адрес", "телефон", "электронную почту"],
             ["уже проверил документы", "не потерялись", "убедитесь"]),
            ("filenames", "Please open Cloud. Md. and edit the introduction.", .english,
             ["open claude.md", "introduction"], ["cloud. md"]),
            ("direct-speech", "Sarah said quote it looks great, but can we make the introduction shorter? end quote", .english,
             ["sarah said", "introduction shorter?"], []),
            ("literal-filename", "Cloud. Md.", .english, ["claude.md"], ["cloud"]),
            ("duration", "Make a 10-second video.", .english, ["10-second video"], ["12th"]),
            ("unseen-grammar", "Him and Olivia was reviewing the estimate, and they thinks the documents is ready.", .english,
             ["olivia", "were reviewing", "documents", "ready"], ["him and", "they thinks", "documents is"]),
            ("unseen-russian", "Эти документы уже готова, но мы ещё не проверила адреса. Не отправляй письмо, если клиент не подтвердил дату.", .russian,
             ["документы уже готовы", "не проверили", "не отправляй", "если", "не подтвердил"], ["уже готова", "мы ещё не проверила"]),
        ]
        for (name, input, language, required, forbidden) in cases {
            let drainDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            while model.isInferenceBusy, ContinuousClock.now < drainDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertFalse(model.isInferenceBusy, "Previous inference did not finish")
            let started = ContinuousClock.now
            let prepared = model.basicFormat(input, language: language)
            let output = try await model.processPolished(prepared, language: language)
            let normalized = output.lowercased().replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
                .replacingOccurrences(of: ",", with: "")
            print("POLISH_QUALITY fixture=\(name) elapsed=\(started.duration(to: .now)) output=\(output)")
            print("POLISH_CANDIDATE fixture=\(name) output=\(model.lastCandidate ?? "<none>")")
            XCTAssertNil(model.lastFallbackReason, "\(name): \(model.lastFallbackReason ?? "")")
            if name == "direct-speech" {
                XCTAssertGreaterThanOrEqual(output.filter { "\"“”'«»".contains($0) }.count, 2, "Direct speech needs quotation marks: \(output)")
                XCTAssertFalse(output.hasSuffix("?'."), "Do not append a period after a quoted question")
            }
            if name == "long-proposal" {
                XCTAssertTrue(output.contains("\n\n"), "Separate the proposal, approval follow-up and total into paragraphs")
            }
            for fragment in required {
                XCTAssertTrue(normalized.contains(fragment.replacingOccurrences(of: ",", with: "")), "\(name): missing \(fragment): \(output)")
            }
            for fragment in forbidden {
                XCTAssertFalse(normalized.contains(fragment.replacingOccurrences(of: ",", with: "")), "\(name): retained \(fragment): \(output)")
            }
        }
        print("POLISH_MEMORY model=\(configuration.name) peak_mlx_bytes=\(Memory.peakMemory)")
    }
}
