import Foundation

// Chat provider backed by the local `claude` CLI (Claude Code).
//
// Uses the login the user already has in Claude Code — no API key. Each turn runs
// `claude -p` headless; the conversation is continued with `--resume <session_id>`.
// GitHub build only: the sandboxed App Store build cannot spawn the CLI.

@MainActor
final class ClaudeCodeChat {
    static let shared = ClaudeCodeChat()

    /// Aliases understood by `claude --model`.
    nonisolated static let models: [(id: String, label: String)] = [
        ("sonnet", "Sonnet"),
        ("opus",   "Opus"),
        ("haiku",  "Haiku"),
    ]

    private nonisolated static let timeoutSeconds: TimeInterval = 180
    private var sessionID: String?

    var hasSession: Bool { sessionID != nil }
    func resetSession() { sessionID = nil }

    // MARK: - Locating the CLI

    nonisolated static var binaryURL: URL? {
        #if APPSTORE
        return nil
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        #endif
    }

    nonisolated static var isAvailable: Bool { binaryURL != nil }

    // MARK: - One turn

    enum ChatError: LocalizedError {
        case notInstalled
        case timedOut
        case cli(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Claude Code CLI not found. Install it, then run `claude` once to log in."
            case .timedOut:     "Claude Code took too long to answer."
            case .cli(let m):   m
            }
        }
    }

    /// Sends `prompt` and returns the reply text. Updates the session id for the next turn.
    func send(prompt: String, model: String, systemPrompt: String) async throws -> String {
        guard let binary = Self.binaryURL else { throw ChatError.notInstalled }
        let resume = sessionID

        let output = try await Task.detached(priority: .userInitiated) {
            try Self.run(binary: binary, prompt: prompt, model: model,
                         systemPrompt: systemPrompt, resume: resume)
        }.value

        guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw ChatError.cli("Unexpected response from Claude Code.")
        }
        let result = (json["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if json["is_error"] as? Bool == true {
            throw ChatError.cli(result.isEmpty ? "Claude Code returned an error." : result)
        }
        guard !result.isEmpty else { throw ChatError.cli("No response text.") }
        if let id = json["session_id"] as? String { sessionID = id }
        return result
    }

    // MARK: - Process

    private nonisolated static func run(binary: URL, prompt: String, model: String,
                                        systemPrompt: String, resume: String?) throws -> Data {
        // Run in an empty scratch directory so no project CLAUDE.md / settings are picked up.
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-claude-code")
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        var args = [
            "-p",
            "--output-format", "json",
            "--model", model,
            "--append-system-prompt", systemPrompt,
            // Chat only: read-only web tools, nothing that touches files or runs commands.
            "--tools", "WebSearch,WebFetch",
            "--allowedTools", "WebSearch", "WebFetch",
            // Skip user/project hooks, MCP servers and skills: the chat must not show up
            // as a session in the island nor run the user's own automations.
            "--setting-sources", "local",
            "--strict-mcp-config",
            "--disable-slash-commands",
        ]
        if let resume { args += ["--resume", resume] }

        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.currentDirectoryURL = cwd

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                       env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // The prompt goes through stdin: no argv length limit, and a leading "-" is harmless.
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        // Watchdog — terminate a hung CLI.
        let timedOut = ManagedFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            if process.isRunning { timedOut.set(); process.terminate() }
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if timedOut.isSet { throw ChatError.timedOut }
        if process.terminationStatus != 0 && outData.isEmpty {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ChatError.cli(msg.isEmpty ? "Claude Code exited with status \(process.terminationStatus)." : msg)
        }
        return outData
    }
}

private final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

// MARK: - ClaudeService entry point

extension ClaudeService {
    func chatClaudeCode(query: String, context: PromptContext?, state: AppState) async {
        let chat = ClaudeCodeChat.shared
        var prompt = query
        // File / window context goes on the first turn only (the CLI session keeps it afterwards).
        if !chat.hasSession, let ctx = context {
            switch ctx {
            case .window(let app, let title, let url):
                var prefix = "Context — App: \(app), Window: \(title)"
                if let url { prefix += ", URL: \(url)" }
                prompt = prefix + "\n\n" + query
            case .file(let name, let fileURL):
                let binaryExts = ["pdf", "jpg", "jpeg", "png", "gif", "webp"]
                if let fileURL, !binaryExts.contains(fileURL.pathExtension.lowercased()),
                   let text = try? String(contentsOf: fileURL, encoding: .utf8), !text.isEmpty {
                    let body = text.count > 24_000 ? String(text.prefix(24_000)) + "\n[truncated]" : text
                    prompt = "File: \(name)\n\n\(body)\n\n" + query
                } else {
                    prompt = "File: \(name)\n\n" + query
                }
            }
        }

        do {
            let reply = try await chat.send(prompt: prompt, model: state.activeChatModel,
                                            systemPrompt: systemPrompt)
            state.chatHistory.append(ChatMessage(role: .assistant, content: reply))
            state.stateOverride = nil
            state.view = .prompt
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        } catch {
            await showError(error.localizedDescription, state: state)
        }
    }
}
