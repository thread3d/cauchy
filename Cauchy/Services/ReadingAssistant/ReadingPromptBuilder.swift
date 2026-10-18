import Foundation

enum ReadingPromptBuilder {
    static func evidenceBudgets(for provider: AssistantConnectorID) -> (statements: Int, passages: Int) {
        // Local Ollama models commonly run with a ~4k-token window, so they get
        // the same conservative retrieval budget the old on-device model used.
        provider == .ollama ? (1_200, 800) : (2_500, 4_000)
    }

    static func instructions(for context: ReadingContext, provider: AssistantConnectorID = .ollama) -> String {
        var prompt = """
        You are helping someone read "\(context.documentTitle)".

        SELECTED TEXT (their exact focus — answer about this first):
        ---
        \(context.selectedText)
        ---

        SURROUNDING CONTEXT (nearby paragraphs for reference):
        ---
        \(context.surroundingText)
        ---
        """

        if !context.retrievedPassages.isEmpty {
            prompt += """

            RELEVANT PASSAGES (from elsewhere in the document):
            ---
            \(context.retrievedPassages.joined(separator: "\n\n"))
            ---
            """
        }

        // Every provider now streams from a general model; all of them need
        // the reminder that replies render inside the app's LaTeX engine.
        prompt += """

        IMPORTANT: Your reply is rendered by a LaTeX math engine in the app. Any LaTeX command written outside $...$ or $$...$$ will appear as broken raw text.
        """

        prompt += """

        Content rules:
        - Ground your answer in the text above (and retrieved passages if present).
        - Use supplied PDF text rather than a model's restatement. Excerpts can be clipped or have lossy math extraction; do not silently complete missing notation. Say when a precise formula needs checking on the original page.
        - A CITABLE PDF LOCATIONS block accompanies each question when Cauchy has resolved exact original-page regions. S1 identifies the selected text, R1/R2/... identify PDF source excerpts in order, and P1/P2/... identify relevant passages in order. A source without an ID is context only, not a verified location.
        - Put a source ID such as [S1] or [R1] immediately after each material claim drawn directly from a cited PDF excerpt. Keep separate claims in separate sentences or paragraphs, and cite each substantive paragraph or list item. Keep IDs outside math delimiters. Use only listed IDs; do not invent one or substitute a page number. An ID identifies an inspectable input, not automatic proof of your reasoning.
        - You may use established knowledge of the field to actually answer the question; note briefly when something comes from outside the passage.
        - If the passage defers something (to an appendix, a problem sheet, another paper), still state the standard account of it rather than only saying it is deferred.
        - Do not summarize the whole document.
        - Be precise and concise.
        - Use plain-text section headings (for example, "1. Proof for addition"). Do not use markdown # headings or code fences.

        Evidence boundary (mandatory):
        - End every reply with exactly one machine-readable marker on its own line. The app hides it from the reader.
        - Use [[CAUCHY_BASIS: PDF]] only when every material mathematical or factual claim follows directly from a source with a listed, resolvable ID and each such claim carries its source ID. If no ID is available, do not declare PDF-only.
        - Use [[CAUCHY_BASIS: MIXED]] when any material claim uses established knowledge, an inference not stated in the supplied PDF text, or a completion of clipped/lossy notation. Clearly separate that outside material in the prose.
        - Use [[CAUCHY_BASIS: INSUFFICIENT]] when the supplied evidence is too incomplete or ambiguous to answer reliably. State what the PDF does and does not establish; do not guess.
        - Never cite or imply access to a page that was not supplied in the prompt.

        \(latexOutputContract)
        """

        return prompt
    }

    /// Formats PDF source excerpts for the prompt, clipped to a character
    /// budget. They sit above the passages block, but may be incomplete.
    static func referencedStatementsBlock(_ statements: [String], characterBudget: Int) -> String? {
        guard let clipped = clip(statements, to: characterBudget) else { return nil }
        return """
        PDF SOURCE EXCERPTS (verbatim text layer; may be clipped or lose math layout — do not assume a complete statement):

        \(clipped.joined(separator: "\n\n"))
        """
    }

    /// Formats ask-time retrieved passages for inclusion in the model prompt,
    /// clipped to a per-provider character budget (the on-device context
    /// window is small). Returns nil when nothing fits.
    static func retrievedPassagesBlock(_ passages: [String], characterBudget: Int) -> String? {
        guard let clipped = clip(passages, to: characterBudget) else { return nil }
        return """
        RELEVANT PASSAGES (from elsewhere in the document — mention the page number when you rely on one):

        \(clipped.joined(separator: "\n\n"))
        """
    }

    /// Source IDs are generated only after the current PDF revalidates the
    /// corresponding page region. Keep this compact so local models receive it.
    static func citableSourcesBlock(_ sources: [AnswerSourceAnchor]) -> String? {
        let lines = sources.compactMap { source -> String? in
            guard let id = source.sourceID else { return nil }
            return "[\(id)] \(source.label), PDF p. \(source.pageIndex + 1)"
        }
        guard !lines.isEmpty else { return nil }
        return "CITABLE PDF LOCATIONS (IDs map to the selected text, numbered source excerpts, and passages above):\n"
            + lines.joined(separator: "\n")
    }

    /// Greedily fits items into a character budget, clipping the last one;
    /// fragments under 40 characters are dropped. Returns nil if nothing fits.
    static func clip(_ items: [String], to characterBudget: Int) -> [String]? {
        guard !items.isEmpty, characterBudget > 0 else { return nil }
        var clipped: [String] = []
        var used = 0
        for item in items {
            let piece = String(item.prefix(characterBudget - used))
            guard piece.count >= 40 else { break }
            clipped.append(piece)
            used += piece.count
            if used >= characterBudget { break }
        }
        return clipped.isEmpty ? nil : clipped
    }

    static func latexRepairInstructions() -> String {
        """
        You fix LaTeX delimiter placement in assistant replies for a math rendering engine.
        Output ONLY the corrected reply. No commentary, no markdown, no code fences.

        \(latexOutputContract)

        Fix rules:
        - Preserve all technical meaning and prose wording.
        - Preserve a final [[CAUCHY_BASIS: PDF]], [[CAUCHY_BASIS: MIXED]], or [[CAUCHY_BASIS: INSUFFICIENT]] marker exactly.
        - Only change delimiter placement and LaTeX syntax needed for valid rendering.
        - Convert \\(...\\) to $...$ and \\[...\\] to $$...$$.
        - Move any bare LaTeX commands (\\frac, \\leq, \\epsilon, \\lambda, etc.) inside delimiters.
        """
    }

    static func latexRepairPrompt(previousOutput: String) -> String {
        """
        Fix the LaTeX delimiters in this reply so every LaTeX command is inside $...$ or $$...$$.
        Output ONLY the corrected reply.

        ---
        \(previousOutput)
        ---
        """
    }

    static let latexOutputContract = """
        MATHEMATICS OUTPUT CONTRACT (mandatory):
        - Use ONLY $...$ for inline math and $$...$$ for display math.
        - Do NOT use \\(...\\), \\[...\\], \\begin{equation}, or markdown math fences.
        - NEVER write LaTeX commands outside delimiters. This includes \\frac, \\leq, \\geq, \\epsilon, \\lambda, \\delta, \\in, \\left, \\right, and \\|.
        - Inline math: short symbols or brief phrases inside prose, e.g. $f$, $g$, $C(X)$, $\\epsilon > 0$, $\\delta_1$.
        - Display math: fractions, norms, inequalities, and multi-step equations on their own line in $$...$$.
        - Use \\frac{a}{b} only inside math delimiters. Prefer display math for fractions.
        - Use \\left| ... \\right| for absolute values and norms inside math delimiters.
        - Do not write raw subscripts like f_y outside math; use $f_y$ or $f_{y}$.

        SUPPORTED COMMANDS (the renderer implements a subset of LaTeX — an
        unsupported command makes the whole formula fall back to raw source):
        - Available: \\frac, \\sqrt, \\sum, \\int, \\lim, \\underline, \\overline, \\vec, \\hat,
          \\text, \\mathrm, \\mathbb, \\mathcal, \\mathfrak, \\binom, \\left/\\right, \\langle,
          \\quad, \\cdots, and the usual Greek letters, relations, and arrows.
        - Environments: only cases, matrix, pmatrix, bmatrix, Bmatrix, vmatrix, gather.
        - NEVER use: \\underbrace, \\overbrace, \\overset, \\underset, \\stackrel, \\substack,
          \\xrightarrow, \\boxed, \\tag, \\phantom, \\operatorname, \\pmod, \\dfrac, \\tfrac,
          \\bigl/\\bigr/\\Big, \\begin{align}, \\begin{array}, \\begin{equation}.
        - For an annotated repeated sum, do not reach for \\underbrace — put the
          count in prose: "the sum of $p$ copies of $1$", or write $1+1+\\cdots+1$ ($p$ terms).
        - For multi-line derivations use consecutive $$...$$ blocks, not an align environment.

        Good:
        Since $f$ and $g$ are continuous, for any $\\epsilon > 0$ there exists $\\delta > 0$ such that
        $$|f(x) - f(a)| \\leq \\frac{\\epsilon}{2}$$

        Bad (never do this):
        Since f and g are continuous, |f(x) - f(a)| \\leq \\frac{\\epsilon}{2}
        \\left| (f+g)(x) - (f+g)(a) \\right| = \\left| (f(x) - f(a)) + (g(x) - g(a)) \\right|\\leq \\left| f(x) - f(a) \\right| + \\left| g(x) - g(a) \\right|< \\frac{\\epsilon}{2} + \\frac{\\epsilon}{2} = \\epsilon
        """
}
