import Foundation
import os.log

// Optional LLM pass over batch dictations, applied AFTER the deterministic
// PostProcessor (fillers, voice commands, dictionary) and BEFORE insertion -
// the same order Voice Edit uses. Off by default; every failure path falls
// back to the deterministic text so a dictation is never lost or stalled.

enum LLMPostProcessLevel: String, Codable, CaseIterable, Identifiable {
    case off, cleanup, rewrite
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .cleanup: return "Clean up"
        case .rewrite: return "Rewrite"
        }
    }
    var summary: String {
        switch self {
        case .off: return "Standard cleanup only - fillers, voice commands and dictionary."
        case .cleanup:
            return "Fixes punctuation and false starts and formats spoken lists. Never changes your words."
        case .rewrite: return "Rewrites for clarity, keeping your meaning and language."
        }
    }
}

enum LLMPostProcessor {
    private static let log = Logger(subsystem: "com.arunbrahma.purr", category: "llm-postprocess")

    // 15 s watchdog: LlamaRuntime serializes generations, so a meeting
    // summary in flight can queue this call - past the deadline the dictation
    // ships deterministic rather than waiting.
    private static let timeout: Duration = .seconds(15)

    static func polish(_ text: String) async -> String {
        await polish(
            text,
            level: SettingsStore.shared.llmPostProcessLevel,
            customInstructions: SettingsStore.shared.llmCustomInstructions)
    }

    static func polish(
        _ text: String, level: LLMPostProcessLevel, customInstructions: String
    ) async -> String {
        guard level != .off,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return text }
        guard LLMModelManager.isInstalled() else {
            log.info("LLM level active but Gemma not installed - shipping deterministic text")
            return text
        }
        let parameters = LlamaSession.Parameters(
            maxTokens: maxTokens(forInputLength: text.count), temperature: 0.2)
        let work = Task {
            try await LlamaRuntime.shared.generate(
                prompt: prompt(for: text, level: level, customInstructions: customInstructions),
                parameters: parameters)
        }
        let watchdog = Task<Void, Error> {
            try await Task.sleep(for: timeout)
            work.cancel()
        }
        do {
            let raw = try await work.value
            watchdog.cancel()
            let cleaned = sanitize(raw)
            guard !cleaned.isEmpty else {
                log.warning("LLM returned empty output - shipping deterministic text")
                return text
            }
            return cleaned
        } catch {
            watchdog.cancel()
            log.warning(
                "LLM post-processing failed or timed out (\(error.localizedDescription, privacy: .public)) - shipping deterministic text"
            )
            return text
        }
    }

    // MARK: - Prompt

    static func prompt(
        for text: String, level: LLMPostProcessLevel, customInstructions: String
    ) -> String {
        let task: String
        switch level {
        case .off:
            task = ""  // never reached by polish(); kept total for the type
        case .cleanup:
            task = """
                Clean up this dictated text. Fix punctuation and capitalization, remove \
                false starts, hesitations and immediate repetitions, and format spoken \
                enumerations (like "first... second..." or "one... two...") as a list with \
                line breaks. Never change the user's words beyond those repairs, never add \
                content, and never translate - keep the original language exactly.
                """
        case .rewrite:
            task = """
                Rewrite this dictated text so it reads clearly and naturally. Keep the \
                meaning, tone and language of the original - never translate. Fix grammar, \
                punctuation and structure, and format spoken enumerations as a list with \
                line breaks.
                """
        }
        let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let customBlock =
            custom.isEmpty
            ? ""
            : """


                Additional instructions from the user:
                \(custom)
                """
        let body = """
            \(task)\(customBlock)

            Reply with ONLY the resulting text - no preamble, no quotes, no code fences.

            Text:
            \(text)
            """
        // Gemma chat template, same shape EditInterpreter uses.
        return """
            <start_of_turn>user
            \(body)<end_of_turn>
            <start_of_turn>model

            """
    }

    // MARK: - Output hygiene

    // Models occasionally wrap output in code fences or stray whitespace
    // despite instructions; strip the wrappers, never the content.
    static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if !lines.isEmpty { lines.removeFirst() }  // ``` or ```lang
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // ~2x the input tokens at the ~4 chars/token rule of thumb, clamped so a
    // one-liner still has room and a monologue can't run the context out.
    static func maxTokens(forInputLength count: Int) -> Int {
        max(256, min(2000, count / 2))
    }
}
