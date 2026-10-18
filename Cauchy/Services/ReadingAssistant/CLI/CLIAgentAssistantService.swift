import Foundation

/// Reading assistant backed by a locally installed agent CLI (Claude Code,
/// Codex, or Antigravity). The user signs in once in their terminal with their own plan; the
/// app spawns the CLI per question and streams its output. No API key is ever
/// stored or seen by the app.
@MainActor
final class CLIAgentAssistantService: ReadingAssistantProtocol {
    let provider: AssistantConnectorID

    /// The model to request, or nil to let the CLI use whatever it is
    /// configured with. Captured at init so an answer always uses the choice
    /// that was live when the assistant was built.
    private let modelID: String?
    private let connector: AssistantConnector
    private let binary: String

    private var context: ReadingContext?
    private var history: [ThreadMessage] = []
    private(set) var isResponding = false

    init(connector id: AssistantConnectorID, modelID: String?) {
        let connector = id.connector
        guard let binary = connector.binaryName else {
            preconditionFailure("\(connector.name) is not a CLI connector")
        }
        self.provider = id
        self.connector = connector
        self.binary = binary
        self.modelID = modelID
    }

    var availability: ReadingAssistantAvailability {
        connector.availability
    }

    func resetSession(context: ReadingContext) {
        self.context = context
        history = []
    }

    func restoreSession(context: ReadingContext, messages: [ThreadMessage]) {
        self.context = context
        history = messages
    }

    func ask(
        question: String,
        retrieval: AskRetrieval,
        onPartial: ((String) -> Void)? = nil
    ) async throws -> String {
        guard !isResponding else {
            throw ReadingAssistantError.sessionBusy
        }
        guard let binaryURL = CLIAgentRunner.locateBinary(named: binary) else {
            throw ReadingAssistantError.notAvailable(availability)
        }

        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        isResponding = true
        defer { isResponding = false }

        let arguments = makeArguments(question: trimmed, retrieval: retrieval)
        var parser: any CLIAgentStreamParsing = switch provider {
        case .codex: CodexStreamParser()
        case .antigravity: AntigravityStreamParser()
        default: ClaudeCodeStreamParser()
        }

        do {
            let lines = CLIAgentRunner.streamLines(
                binary: binaryURL,
                arguments: arguments,
                workingDirectory: FileManager.default.temporaryDirectory
            )
            for try await line in lines {
                if let partial = parser.consume(line: line) {
                    onPartial?(AssistantResponseNormalizer.normalize(partial))
                }
            }
        } catch let error as CLIAgentError {
            throw ReadingAssistantError.api(friendlyMessage(parser.errorMessage ?? error.localizedDescription))
        }

        if let message = parser.errorMessage {
            throw ReadingAssistantError.api(friendlyMessage(message))
        }
        guard let finalText = parser.finalText,
              !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // agy exits 0 with empty stdout when the backend call fails
            // (e.g. quota exhausted), so give that case a pointer.
            if provider == .antigravity {
                throw ReadingAssistantError.api("Antigravity produced no response. This usually means its quota is exhausted or sign-in expired — run `agy` in Terminal to check.")
            }
            throw ReadingAssistantError.api("\(connector.name) produced no response.")
        }

        let normalized = AssistantResponseNormalizer.normalize(finalText)
        onPartial?(normalized)

        history.append(ThreadMessage(role: .user, content: trimmed))
        history.append(ThreadMessage(role: .assistant, content: normalized))
        return normalized
    }

    // MARK: - Prompt & argument construction

    private func makeArguments(question: String, retrieval: AskRetrieval) -> [String] {
        // Retrieval rides the one-shot prompt only — it is never appended to
        // the stored history, so re-asks don't compound it. Exact statements
        // come before passages: they are source text, though extraction can be lossy.
        var instructions = instructionsText()
        let budgets = ReadingPromptBuilder.evidenceBudgets(for: provider)
        if let block = ReadingPromptBuilder.referencedStatementsBlock(retrieval.statements, characterBudget: budgets.statements) {
            instructions += "\n\n" + block
        }
        if let block = ReadingPromptBuilder.retrievedPassagesBlock(retrieval.passages, characterBudget: budgets.passages) {
            instructions += "\n\n" + block
        }
        if let block = ReadingPromptBuilder.citableSourcesBlock(retrieval.citableSources) {
            instructions += "\n\n" + block
        }
        let transcript = Self.transcriptPrompt(history: history, question: question)

        switch provider {
        case .codex:
            // Codex has no separate system-prompt flag; prepend instructions.
            // The sandbox flag keeps the agent read-only on the user's machine.
            // A chosen model is passed explicitly because ~/.codex/config.toml
            // is shared with the ChatGPT desktop app, which rewrites it — the
            // user's in-app choice must win. Omitting the flag is itself a
            // choice ("Match my CLI") and then that config wins instead.
            return [
                "exec", instructions + "\n\n" + transcript,
                "--json",
                "--skip-git-repo-check",
                "--sandbox", "read-only",
                "-c", "model_reasoning_effort=\"medium\"",
            ] + modelArguments(flag: "--model")
        case .antigravity:
            // agy has neither a system-prompt nor a model flag (the model is
            // whatever the user set with /model in the agy TUI), so
            // instructions ride the prompt. --sandbox keeps the run inside the
            // OS sandbox; headless mode also soft-denies any tool that would
            // need approval, and the working directory is the temp dir.
            return [
                "-p", instructions + "\n\n" + transcript,
                "--sandbox",
            ]
        default:
            // Tools are disabled: this is a chat provider, so the agent must
            // never run commands or edit files on the user's machine. The model
            // is passed explicitly so answers don't silently depend on the
            // user's CLI-side default.
            return [
                "-p", transcript,
                "--output-format", "stream-json",
                "--include-partial-messages",
                "--verbose",
                "--tools", "",
                "--no-session-persistence",
                "--append-system-prompt", instructions,
            ] + modelArguments(flag: "--model")
        }
    }

    /// `--model <id>`, or nothing when the user asked to follow the CLI's own
    /// configuration.
    private func modelArguments(flag: String) -> [String] {
        guard let modelID else { return [] }
        return [flag, modelID]
    }

    private func instructionsText() -> String {
        if let context {
            return ReadingPromptBuilder.instructions(for: context, provider: provider)
        }
        return "You are a precise math reading assistant. Answer concisely. Write all mathematics as LaTeX inside $...$ or $$...$$ delimiters; never emit LaTeX commands outside math delimiters."
    }

    /// The CLI runs one-shot per question, so earlier turns are replayed as a
    /// transcript inside the prompt (simple and version-independent, at the
    /// cost of resending history — which the user's plan quota absorbs).
    static func transcriptPrompt(history: [ThreadMessage], question: String) -> String {
        guard !history.isEmpty else { return question }
        var lines = ["Earlier conversation about this passage:", ""]
        for message in history {
            lines.append("\(message.role == .user ? "User" : "Assistant"): \(message.content)")
        }
        lines.append("")
        lines.append("New question from the user — answer this:")
        lines.append(question)
        return lines.joined(separator: "\n")
    }

    private func friendlyMessage(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("login") || lowered.contains("authentication") || lowered.contains("unauthorized") || lowered.contains("401") {
            return "\(connector.name) is not signed in. \(connector.signInHint)"
        }
        return raw
    }
}

/// Adapts the signed-in CLI connectors to the same text-generation interface
/// used by reference indexing. Each request is isolated, read-only, and has no
/// tools; the indexer still checks every result against the PDF text.
struct CLIIndexLanguageModel: LanguageModel {
    let connectorID: AssistantConnectorID
    let modelID: String?

    func streamResponse(
        to prompt: CloudPrompt,
        onDelta: @Sendable (String) async -> Void
    ) async throws {
        let connector = connectorID.connector
        guard let binary = connector.binaryName,
              let binaryURL = await CLIAgentRunner.locateBinary(named: binary) else {
            throw ReadingAssistantError.notAvailable(.cliNotInstalled(connectorID))
        }
        let question = prompt.sendableTurns.last?.text ?? ""
        let instructions = prompt.instructions ?? ""
        let fullPrompt = instructions + "\n\n" + question
        let modelArguments = modelID.map { ["--model", $0] } ?? []
        let arguments: [String]
        var parser: any CLIAgentStreamParsing
        switch connectorID {
        case .codex:
            arguments = ["exec", fullPrompt, "--json", "--skip-git-repo-check",
                         "--sandbox", "read-only", "-c", "model_reasoning_effort=\"medium\""]
                + modelArguments
            parser = CodexStreamParser()
        case .antigravity:
            arguments = ["-p", fullPrompt, "--sandbox"]
            parser = AntigravityStreamParser()
        default:
            arguments = ["-p", question, "--output-format", "stream-json",
                         "--verbose", "--tools", "", "--no-session-persistence",
                         "--append-system-prompt", instructions] + modelArguments
            parser = ClaudeCodeStreamParser()
        }

        let lines = CLIAgentRunner.streamLines(
            binary: binaryURL,
            arguments: arguments,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        for try await line in lines {
            _ = parser.consume(line: line)
        }
        if let error = parser.errorMessage {
            throw ReadingAssistantError.api(error)
        }
        guard let answer = parser.finalText, !answer.isEmpty else {
            throw ReadingAssistantError.api("\(connector.name) produced no index response.")
        }
        await onDelta(answer)
    }
}
