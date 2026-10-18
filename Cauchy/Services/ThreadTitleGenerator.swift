import Foundation

/// Names a conversation the way a person would: from what was actually asked
/// and answered, not from the first few characters the user typed. A highlight
/// that was only ever saved — no question, no answer — is named from its
/// passage instead, so a list of saved highlights reads like a list of subjects
/// rather than a list of first sentences.
///
/// This deliberately does not go through the chat connector. Naming a thread is
/// a throwaway one-line job — it must not spawn a CLI child process, must not
/// spend a subscription turn, and must not queue behind the answer the user is
/// waiting for. It prefers the free local Ollama model and only falls back to a
/// BYOK key when Ollama is unavailable, exactly like reference
/// indexing does.
@MainActor
enum ThreadTitleGenerator {
    /// Titles longer than this are the model ignoring the brief; clipped rather
    /// than rejected, so a slightly wordy answer still beats the raw question.
    /// Sized to fit the five- or six-word title the brief asks for: at 42 the
    /// ceiling was doing the editing, clipping exactly the descriptive titles
    /// that were wanted.
    static let maxCharacters = 58

    static var isAvailable: Bool {
        OllamaService.shared.refreshIfNeeded()
        return OllamaService.shared.availability.isAvailable
            || AssistantPreferences.cloudAssistEnabled
    }

    /// The shortest passage worth handing to a model on its own. Below this a
    /// bare selection ("see below", "Region on page 4") names nothing, and a
    /// model asked to name it anyway invents a theorem.
    private static let minimumPassageCharacters = 24

    /// Returns a short name for the thread, or nil when no model is available
    /// or the reply was unusable. Never throws — an unnamed thread just keeps
    /// its fallback name.
    static func generate(
        selectedText: String,
        surroundingText: String,
        messages: [ThreadMessage]
    ) async -> String? {
        guard let model = model() else { return nil }

        let question = messages.first { $0.role == .user }?.content ?? ""
        let answer = messages.first { $0.role == .assistant }?.content ?? ""

        let prompt: String
        let brief: String
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Nothing was asked: the passage is all there is to name it by, so
            // it has to carry a subject on its own.
            let passage = [selectedText, surroundingText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .max(by: { $0.count < $1.count }) ?? ""
            guard passage.count >= minimumPassageCharacters else { return nil }
            prompt = passagePrompt(selectedText: selectedText, surroundingText: surroundingText)
            brief = passageInstructions
        } else {
            prompt = userPrompt(
                selectedText: selectedText,
                surroundingText: surroundingText,
                question: question,
                answer: answer
            )
            brief = instructions
        }

        do {
            let session = ReadingLanguageModelSession(model: model, instructions: brief)
            let response = try await session.respond(to: prompt)
            guard let title = sanitize(response.content) else { return nil }
            // The brief can ask for a grounded title; it cannot guarantee one.
            // A small model handed a passage it can't parse reaches for a
            // subject it knows — often one from the examples — so the text has
            // the last word on whether a title is about it.
            let source = [selectedText, surroundingText, question, answer].joined(separator: " ")
            guard isGrounded(title, in: source) else { return nil }
            return title
        } catch {
            return nil
        }
    }

    /// Whether a title is written in the vocabulary of the text it names.
    ///
    /// Compares stems rather than whole words, so "Uniform Continuity" still
    /// matches a passage that says "uniformly continuous", and asks only that
    /// half the title's content words land — a good title is allowed its own
    /// connective and framing words ("Why", "Definition of"), just not its own
    /// subject.
    static func isGrounded(_ title: String, in source: String) -> Bool {
        let titleWords = contentWords(of: title)
        // Nothing substantive to check — sanitize has already rejected the
        // titles that are too short to be titles.
        guard !titleWords.isEmpty else { return true }

        let sourceWords = Set(words(of: source))
        guard !sourceWords.isEmpty else { return false }
        let sourceStems = Set(sourceWords.map(stem))

        let grounded = titleWords.filter { sourceStems.contains(stem($0)) }.count
        return grounded * 2 >= titleWords.count
    }

    private static func words(of text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func contentWords(of text: String) -> [String] {
        words(of: text).filter { $0.count >= 4 && !ignoredTitleWords.contains($0) }
    }

    /// Five characters is enough to survive the endings that differ between a
    /// title and its source ("continuity"/"continuous", "divides"/"dividing")
    /// without collapsing words that are genuinely different.
    private static func stem(_ word: String) -> String {
        String(word.prefix(5))
    }

    /// Words a title can carry without the text having to supply them: the
    /// connectives long enough to pass the length filter, and the framing nouns
    /// the brief itself asks for.
    private static let ignoredTitleWords: Set<String> = [
        "that", "this", "with", "from", "into", "over", "under", "between",
        "when", "where", "which", "while", "whether", "what", "does", "their",
        "than", "then", "these", "those", "here", "such", "each", "both",
        "definition", "meaning", "overview", "summary", "explanation",
        "introduction", "reason", "purpose", "role", "idea", "notion",
    ]

    private static func model() -> (any LanguageModel)? {
        OllamaService.shared.refreshIfNeeded()
        if let local = AssistantPreferences.localModel() {
            return local
        }
        // The cheapest model the active provider offers: a four-word title does
        // not need reasoning, and this runs once per thread.
        return AssistantPreferences.activeEconomyCloudModel()
    }

    private static let instructions = """
        You name conversations about passages from technical papers — pure
        mathematics, machine learning, and research writing generally. Given a
        passage a reader selected and the question they asked about it, reply
        with a title for that conversation and nothing else.

        Rules:
        - Four to six words. Never fewer than four, and never a whole sentence.
        - Build the title out of the words in front of you. Every noun in it
        must appear in the passage, the question, or the answer.
        - Never name a theorem, model, method or concept that is absent from
        that text — not one you recognise, not one from the examples below. If
        the passage names no subject, say what it claims in its own words.
        - Name the subject, not the act of asking: "Why the Bound Is Tight",
        not "User Asks About a Bound".
        - A bare noun phrase is too thin. Say what about the subject: which
        result, which direction, which case, which step.
        - Title Case, no trailing period, no quotation marks, no LaTeX, no emoji.
        - Output only the title. No preamble, no explanation, no alternatives.
        - Never decline. Every passage can be named: when one is thin or
        unfamiliar, name it with its own words. "Not Applicable", "N/A",
        "Unknown" and "Insufficient Context" are never titles.

        The examples below show the shape of a good title. Their subjects belong
        to them, not to your answer — take the form, never the topic.

        Examples:
        Passage on scaled dot-product attention, asked "why divide by sqrt d"
        -> Why Attention Divides by Root D
        Passage on the triangle inequality, asked "why is this true"
        -> Why the Triangle Inequality Holds
        Passage on learning-rate warmup, asked "is this needed"
        -> Whether Warmup Is Needed for Stability
        Passage defining a quotient group, asked "what does this mean"
        -> Meaning of the Quotient Group Construction
        """

    /// The brief for a highlight nobody asked anything about. Same voice as the
    /// conversation brief, minus every mention of a question — a model told to
    /// name "the conversation" when there isn't one writes "Reader's Highlight".
    private static let passageInstructions = """
        You name passages a reader highlighted in a technical paper — pure
        mathematics, machine learning, and research writing generally. Given the
        passage and the paragraph it sits in, reply with a title for that
        highlight and nothing else.

        Rules:
        - Four to six words. Never fewer than four, and never a whole sentence.
        - Build the title out of the words in front of you. Every noun in it
        must appear in the passage you were given.
        - Never name a theorem, model, method or concept that is absent from
        that passage — not one you recognise, not one from the examples below.
        If the passage names no subject, say what it claims in its own words.
        - Name the subject, not the act of highlighting: "Cost of the Backward
        Pass", not "A Saved Passage".
        - A bare noun phrase is too thin. Say what about the subject: which
        result, which hypothesis, which case, what it claims.
        - Title Case, no trailing period, no quotation marks, no LaTeX, no emoji.
        - Output only the title. No preamble, no explanation, no alternatives.
        - Never decline. Every passage can be named: when one is thin or
        unfamiliar, name it with its own words. "Not Applicable", "N/A",
        "Unknown" and "Insufficient Context" are never titles.

        The examples below show the shape of a good title. Their subjects belong
        to them, not to your answer — take the form, never the topic.

        Examples:
        A passage on the memory cost of attention
        -> Memory Cost of Attention Layers
        A passage stating the triangle inequality
        -> Triangle Inequality for Real Numbers
        A passage on how a sampler picks the next token
        -> How the Sampler Picks Each Token
        A passage defining uniform continuity
        -> Definition of Uniform Continuity on Intervals
        """

    private static func passagePrompt(selectedText: String, surroundingText: String) -> String {
        var prompt = """
            PASSAGE THE READER HIGHLIGHTED:
            \(selectedText.prefix(600))
            """

        let surroundings = surroundingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedText.count < 200, !surroundings.isEmpty, surroundings != selectedText {
            prompt += """


                THE PARAGRAPH IT SITS IN (context — the subject is named here):
                \(surroundings.prefix(700))
                """
        }

        prompt += "\n\nTitle:"
        return prompt
    }

    private static func userPrompt(
        selectedText: String,
        surroundingText: String,
        question: String,
        answer: String
    ) -> String {
        // Small budgets on purpose: the on-device context window is tight, and
        // the opening of each field already carries what the title needs.
        var prompt = """
            PASSAGE THE READER SELECTED:
            \(selectedText.prefix(600))
            """

        // A one-line selection ("If such a p exists, it is necessarily prime.")
        // names nothing on its own, and a model asked to name it anyway invents
        // a theorem. The paragraph it sits in is what identifies the subject.
        let surroundings = surroundingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedText.count < 200, !surroundings.isEmpty, surroundings != selectedText {
            prompt += """


                THE PARAGRAPH IT SITS IN (context — the subject is named here):
                \(surroundings.prefix(700))
                """
        }

        prompt += """


            THEIR QUESTION:
            \(question.prefix(300))
            """

        if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += """


                HOW IT WAS ANSWERED (for subject matter only):
                \(answer.prefix(500))
                """
        }

        prompt += "\n\nTitle:"
        return prompt
    }

    /// Models like to wrap a title in quotes, prefix it with "Title:", or add a
    /// second line of commentary. Take the first real line and strip the
    /// decoration; reject anything that still doesn't look like a title.
    static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // A stray leading label, then the first non-empty line.
        if let colon = text.range(of: "Title:"), colon.lowerBound == text.startIndex {
            text = String(text[colon.upperBound...])
        }
        text = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""

        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*#`.,;: -"))
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        guard text.count >= 3 else { return nil }
        // A markdown list, a refusal, or a full sentence of commentary — all
        // longer than any title worth keeping, and all better replaced by the
        // question itself. Kept near its old absolute value as the title budget
        // grew: what counts as prose didn't change.
        guard text.count <= maxCharacters * 2 else { return nil }
        // A short refusal is the same failure wearing a title's clothes:
        // "Not Applicable" is the right length and the right shape, and only
        // its wording gives it away.
        guard !isNonAnswer(text) else { return nil }
        // One word is never the four-to-six the brief asks for; it is the model
        // labelling the task ("Highlight", "Attention") rather than naming it.
        guard text.split(whereSeparator: \.isWhitespace).count >= 2 else { return nil }

        guard text.count > maxCharacters else { return text }
        let clipped = text.prefix(maxCharacters)
        guard let lastSpace = clipped.lastIndex(of: " ") else { return String(clipped) + "…" }
        return clipped[..<lastSpace] + "…"
    }

    /// Whether a reply is the model declining rather than naming — "Not
    /// Applicable", "N/A", "Unknown", "Unable to determine".
    ///
    /// These arrive title-shaped: short, capitalised, no punctuation to give
    /// them away, and the grounding check can wave one through when the source
    /// happens to share a word with it. Wording is the only tell, so this
    /// matches against a list of them.
    static func isNonAnswer(_ title: String) -> Bool {
        let normalized = title
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")

        guard !normalized.isEmpty else { return true }
        if nonAnswerTitles.contains(normalized) { return true }
        return nonAnswerOpenings.contains { normalized.hasPrefix($0) }
    }

    /// Whole replies that are refusals, not names. Matched exactly, so a title
    /// that merely contains one of these words survives.
    private static let nonAnswerTitles: Set<String> = [
        "n a", "na", "not applicable", "none", "none applicable",
        "no title", "untitled", "title", "no name", "unnamed",
        "unknown", "unclear", "unspecified", "not specified", "not available",
        "not provided", "no subject", "no topic", "no answer", "no content",
        "no text", "no passage", "no question", "no conversation",
        "empty", "blank", "null", "nil", "undefined", "error",
        "insufficient context", "insufficient information",
        "not enough information", "not enough context",
        "cannot determine", "unable to determine",
        "highlight", "passage", "conversation", "thread",
    ]

    /// Openings that only ever begin a refusal. Deliberately specific: "there
    /// is no" alone would throw away "There Is No Largest Prime", which is a
    /// perfectly good title.
    private static let nonAnswerOpenings: [String] = [
        "i cannot", "i can t", "i am unable", "i m unable", "i m sorry",
        "sorry", "as an ai", "unfortunately", "unable to",
        "cannot provide", "can t provide", "cannot generate", "cannot name",
        "there is no title", "there is no passage", "there is no text",
        "there is no subject", "there is no question", "there is no content",
        "the passage does not", "the text does not", "this passage does not",
        "no title", "not enough",
    ]
}
