import Foundation

/// Where a model sits on the speed↔depth curve. Every connector is described
/// with the same three rungs, so a row means the same thing whichever vendor
/// it belongs to.
enum ModelTier: String, Hashable, CaseIterable, Sendable {
    case fast
    case balanced
    case max

    var label: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .max: "Max"
        }
    }

    /// How many of the three bars in the picker's tier gauge are filled.
    var filledBars: Int {
        switch self {
        case .fast: 1
        case .balanced: 2
        case .max: 3
        }
    }
}

/// One model the app can request by name.
struct AssistantModel: Identifiable, Hashable, Sendable {
    /// Sent verbatim as the CLI's `--model` argument, or used as the API model
    /// name. Prefer a vendor *alias* (`opus`) over a pinned build id
    /// (`claude-opus-5-5`): an alias follows the vendor's newest release, so
    /// this catalog cannot go stale between app builds.
    let id: String
    /// Carries the generation the row currently resolves to, so a reader can
    /// tell Opus 5.5 from Opus 5 without leaving the picker. Where the id is an
    /// alias the number is cosmetic — the alias still follows the vendor — so
    /// it wants a bump when a new generation ships.
    let name: String
    let tier: ModelTier
    /// Never shown as a row subtitle — the picker stays name-only and surfaces
    /// this as the row's tooltip.
    let blurb: String
}

/// What the user must have done for a connector to work.
enum ConnectorAccess: Equatable, Sendable {
    /// Runs on this Mac through the local Ollama server. No key, no cloud.
    case onDevice
    /// A CLI the user signs into once in Terminal, billed to their own plan.
    /// The app spawns the binary and never sees a credential.
    case cliSignIn(binary: String, install: String, signIn: String)
    /// A key the user pastes into Settings, stored in the Keychain and billed
    /// to their own cloud account.
    case apiKey(CloudAPIProvider)
}

/// Which model an ask should use within a connector.
enum ModelChoice: Hashable, Sendable {
    /// The connector has nothing to choose between — agy takes no model flag
    /// at all — or no local model has been discovered yet. Nothing is passed
    /// on the command line.
    case connectorDefault
    case model(String)

    /// Sentinel that cannot collide with a vendor model id.
    static let defaultToken = "@default"

    var storageToken: String {
        switch self {
        case .connectorDefault: Self.defaultToken
        case .model(let id): id
        }
    }
}

enum AssistantConnectorID: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// The local Ollama connector. The raw value stays `onDevice` so a
    /// selection stored before the switch from Apple Intelligence still reads.
    case ollama = "onDevice"
    case claudeCode
    case codex
    case antigravity
    // The BYOK connectors. `gemini` keeps its original raw value so a stored
    // selection or model choice from before the other two existed still reads.
    case gemini
    case anthropicAPI
    case openaiAPI

    var id: String { rawValue }

    var connector: AssistantConnector { AssistantConnector.for(self) }
}

/// Everything the app knows about one place answers can come from: how it is
/// reached, which models it offers, and how capable each of those is. The
/// picker, Settings and the assistant factory all read this and nothing else,
/// so a new connector is added in exactly one file.
struct AssistantConnector: Identifiable, Sendable {
    let id: AssistantConnectorID
    let name: String
    let vendor: String
    /// SF Symbol shown next to the connector name.
    let symbol: String
    let tagline: String
    let access: ConnectorAccess
    /// The connector's fixed catalog. Ollama is the exception: its models are
    /// whatever the local server reports, read live from `OllamaCatalog`.
    private let builtInModels: [AssistantModel]
    /// What the picker's model pane says when there is nothing to choose.
    let noModelsNote: String?
    /// Set apart in the picker: this one needs an API key and a billing account
    /// of its own, unlike the connectors that ride a subscription the user
    /// already pays for.
    let isAdvanced: Bool

    /// Models the app can name explicitly. Empty when this connector has no
    /// model to choose — it is then a leaf in the picker.
    var models: [AssistantModel] {
        id == .ollama ? OllamaCatalog.models : builtInModels
    }

    init(
        id: AssistantConnectorID,
        name: String,
        vendor: String,
        symbol: String,
        tagline: String,
        access: ConnectorAccess,
        models: [AssistantModel],
        noModelsNote: String?,
        isAdvanced: Bool
    ) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.symbol = symbol
        self.tagline = tagline
        self.access = access
        self.builtInModels = models
        self.noModelsNote = noModelsNote
        self.isAdvanced = isAdvanced
    }
}

extension AssistantConnectorID {
    /// The BYOK connectors, in the order Settings lists them.
    static let byok: [AssistantConnectorID] = CloudAPIProvider.allCases.map(\.connectorID)
}

extension AssistantConnector {
    /// True when picking this connector also means picking a model.
    var hasModelChoice: Bool { !models.isEmpty }

    /// What a fresh install uses: the balanced model, so an answer never
    /// silently depends on a config file the app doesn't own.
    var defaultChoice: ModelChoice {
        if let balanced = models.first(where: { $0.tier == .balanced }) {
            return .model(balanced.id)
        }
        if let first = models.first {
            return .model(first.id)
        }
        return .connectorDefault
    }

    func model(id: String) -> AssistantModel? {
        models.first { $0.id == id }
    }

    /// Reads a persisted token back, falling back to the default when the
    /// stored model has since left the catalog.
    func choice(fromToken token: String?) -> ModelChoice {
        guard let token, token != ModelChoice.defaultToken else { return defaultChoice }
        if model(id: token) != nil { return .model(token) }

        // Keep an explicit tier choice when a pinned API or Codex model is
        // replaced. Older selections are read here without rewriting defaults.
        let replacement: String? = switch (id, token) {
        case (.codex, "gpt-5.6-sol"), (.openaiAPI, "gpt-5.6-sol"): "gpt-6-astra"
        case (.codex, "gpt-5.6-terra"), (.openaiAPI, "gpt-5.6-terra"): "gpt-6-sol"
        case (.codex, "gpt-5.6-luna"), (.openaiAPI, "gpt-5.6-luna"): "gpt-6-luna"
        case (.anthropicAPI, "claude-opus-5"): "claude-opus-5-5"
        case (.gemini, "gemini-3.6-flash"): "gemini-3.7-flash"
        case (.gemini, "gemini-3.7-flash-lite"): "gemini-3.5-flash-lite"
        default: nil
        }
        return replacement.map(ModelChoice.model) ?? defaultChoice
    }

    /// The name for the collapsed picker button.
    func label(for choice: ModelChoice) -> String {
        guard case .model(let id) = choice, let model = model(id: id) else { return name }
        return model.name
    }

    var binaryName: String? {
        if case .cliSignIn(let binary, _, _) = access { return binary }
        return nil
    }

    /// The vendor whose key this connector needs, nil for the rest.
    var apiProvider: CloudAPIProvider? {
        if case .apiKey(let provider) = access { return provider }
        return nil
    }

    /// One line telling the user how to make this connector work.
    var setupHint: String {
        switch access {
        case .onDevice:
            "Start Ollama (`ollama serve`), then install a model."
        case .cliSignIn:
            "Open Settings to install and connect \(name)."
        case .apiKey(let provider):
            "Add your \(provider.vendor) API key in Settings."
        }
    }

    /// What to say when the CLI reports an auth failure mid-answer.
    var signInHint: String {
        if case .cliSignIn = access { return "Reconnect \(name) in Settings, then try again." }
        return setupHint
    }
}

// MARK: - The catalog

extension AssistantConnector {
    static let all: [AssistantConnector] = AssistantConnectorID.allCases.map(AssistantConnector.for)

    /// Connectors offered as first-class choices: they run on hardware or a
    /// subscription the user already has.
    static var primary: [AssistantConnector] { all.filter { !$0.isAdvanced } }
    /// The BYOK connectors, listed in the same order as the Settings key rows.
    static var advanced: [AssistantConnector] { AssistantConnectorID.byok.map(\.connector) }

    static func `for`(_ id: AssistantConnectorID) -> AssistantConnector {
        switch id {
        case .ollama:
            AssistantConnector(
                id: .ollama,
                name: "Ollama",
                vendor: "Ollama",
                symbol: "server.rack",
                tagline: "Runs local models through Ollama. No key, no cloud.",
                access: .onDevice,
                models: [],
                noModelsNote: "Start Ollama to list local models",
                isAdvanced: false
            )

        case .claudeCode:
            AssistantConnector(
                id: .claudeCode,
                name: "Claude Code",
                vendor: "Anthropic",
                symbol: "asterisk",
                tagline: "Connect your Claude account and use your existing subscription.",
                access: .cliSignIn(
                    binary: "claude",
                    install: "Install Claude Code",
                    signIn: "Run `claude` in Terminal and log in"
                ),
                // Aliases, not build ids: `opus` always resolves to the newest
                // Opus the installed CLI knows about. Only the displayed
                // numbers date, and only cosmetically.
                models: [
                    AssistantModel(id: "fable", name: "Fable 5.1", tier: .max, blurb: "Most capable, for the hardest proofs"),
                    AssistantModel(id: "opus", name: "Opus 5.5", tier: .max, blurb: "Deep reasoning on hard proofs"),
                    AssistantModel(id: "sonnet", name: "Sonnet 5", tier: .balanced, blurb: "Strong at everyday mathematics"),
                    AssistantModel(id: "haiku", name: "Haiku 4.5", tier: .fast, blurb: "Quickest replies"),
                ],
                noModelsNote: nil,
                isAdvanced: false
            )

        case .codex:
            AssistantConnector(
                id: .codex,
                name: "Codex",
                vendor: "OpenAI",
                symbol: "chevron.left.forwardslash.chevron.right",
                tagline: "Connect your ChatGPT account and use your existing plan.",
                access: .cliSignIn(
                    binary: "codex",
                    install: "Install Codex (`brew install codex`)",
                    signIn: "Run `codex login` in Terminal"
                ),
                // Codex takes no aliases, so these are pinned ids and do need
                // a catalog bump when OpenAI ships a new family.
                models: [
                    AssistantModel(id: "gpt-6-astra", name: "GPT-6 Astra", tier: .max, blurb: "Most capable"),
                    AssistantModel(id: "gpt-6-sol", name: "GPT-6 Sol", tier: .balanced, blurb: "Balanced speed and depth"),
                    AssistantModel(id: "gpt-6-luna", name: "GPT-6 Luna", tier: .fast, blurb: "Quickest replies"),
                ],
                noModelsNote: nil,
                isAdvanced: false
            )

        case .antigravity:
            AssistantConnector(
                id: .antigravity,
                name: "Antigravity",
                vendor: "Google",
                symbol: "arrow.up.circle",
                tagline: "Connect your Google account to use Antigravity.",
                access: .cliSignIn(
                    binary: "agy",
                    install: "Install it (`curl -fsSL https://antigravity.google/cli/install.sh | bash`)",
                    signIn: "Run `agy` in Terminal and sign in with Google"
                ),
                // agy has no --model flag at all; the model lives in the TUI.
                models: [],
                noModelsNote: "Set with /model in agy",
                isAdvanced: false
            )

        case .anthropicAPI:
            AssistantConnector(
                id: .anthropicAPI,
                name: "Anthropic API",
                vendor: "Anthropic",
                symbol: "asterisk",
                tagline: "Direct API access. Needs your own key and billing.",
                access: .apiKey(.anthropic),
                // API aliases checked against platform.claude.com/docs/en/models/overview
                // (September 2026). Recheck the names when the line-up moves.
                models: [
                    AssistantModel(id: "claude-fable-5-1", name: "Fable 5.1", tier: .max, blurb: "Most capable, for the hardest proofs"),
                    AssistantModel(id: "claude-opus-5-5", name: "Opus 5.5", tier: .max, blurb: "Deep reasoning on hard proofs"),
                    AssistantModel(id: "claude-sonnet-5", name: "Sonnet 5", tier: .balanced, blurb: "Strong at everyday mathematics"),
                    AssistantModel(id: "claude-haiku-4-5", name: "Haiku 4.5", tier: .fast, blurb: "Quickest replies"),
                ],
                noModelsNote: nil,
                isAdvanced: true
            )

        case .openaiAPI:
            AssistantConnector(
                id: .openaiAPI,
                name: "OpenAI API",
                vendor: "OpenAI",
                symbol: "circle.hexagongrid",
                tagline: "Direct API access. Needs your own key and billing.",
                access: .apiKey(.openai),
                // Pinned ids, like the Codex catalog above: OpenAI publishes no
                // alias that follows the newest release.
                models: [
                    AssistantModel(id: "gpt-6-astra", name: "GPT-6 Astra", tier: .max, blurb: "Most capable"),
                    AssistantModel(id: "gpt-6-sol", name: "GPT-6 Sol", tier: .balanced, blurb: "Balanced speed and depth"),
                    AssistantModel(id: "gpt-6-luna", name: "GPT-6 Luna", tier: .fast, blurb: "Quickest replies"),
                ],
                noModelsNote: nil,
                isAdvanced: true
            )

        case .gemini:
            AssistantConnector(
                id: .gemini,
                name: "Gemini API",
                vendor: "Google",
                symbol: "sparkle",
                tagline: "Direct API access. Needs your own key and billing.",
                access: .apiKey(.gemini),
                // The API rejects an unknown model name outright, and Google
                // publishes no documented versioned alias per variant, so these
                // are pinned ids checked against ai.google.dev/gemini-api/docs/models
                // (September 2026) and need a manual bump when the line-up moves.
                models: [
                    AssistantModel(id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro", tier: .max, blurb: "Most capable (preview)"),
                    AssistantModel(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", tier: .balanced, blurb: "Newest stable Flash"),
                    AssistantModel(id: "gemini-3.7-flash", name: "Gemini 3.7 Flash", tier: .balanced, blurb: "The Flash before it"),
                    AssistantModel(id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash-Lite", tier: .fast, blurb: "Quickest replies"),
                ],
                noModelsNote: nil,
                isAdvanced: true
            )
        }
    }
}
