import Foundation

/// What the user picked in the model selector.
enum AssistantSelection: Equatable {
    /// Resolve at ask-time to the best connector that is actually ready on this
    /// Mac, so the app works out of the box and keeps working when a CLI is
    /// installed or removed later.
    case automatic
    case connector(AssistantConnectorID)

    static let automaticToken = "automatic"

    var storageToken: String {
        switch self {
        case .automatic: Self.automaticToken
        case .connector(let id): id.rawValue
        }
    }

    init(token: String?) {
        guard let token else { self = .automatic; return }
        if let id = AssistantConnectorID(rawValue: token) {
            self = .connector(id)
        } else {
            self = .automatic
        }
    }
}

/// The connector and model an ask will actually use, once `automatic` has been
/// resolved away.
struct ResolvedAssistant {
    let connector: AssistantConnector
    let choice: ModelChoice
    /// True when the user chose Automatic and this is what it landed on.
    let viaAutomatic: Bool

    /// nil when the connector picks its own model — the app then passes no
    /// `--model` at all.
    var modelID: String? {
        if case .model(let id) = choice { return id }
        return nil
    }

    var model: AssistantModel? { modelID.flatMap(connector.model(id:)) }

    /// Short name for the collapsed picker button.
    var label: String {
        let name = model?.name ?? connector.name
        return viaAutomatic ? "Auto · \(name)" : name
    }
}

enum AssistantPreferences {
    /// Legacy key name, kept so existing installs keep their choice — the
    /// stored values ("automatic" plus the connector raw values) are unchanged.
    static let selectionKey = "assistantProviderChoice"
    private static let legacyForceOnDeviceKey = "forceOnDeviceModel"

    static func modelKey(for id: AssistantConnectorID) -> String {
        "assistantModel.\(id.rawValue)"
    }

    /// The order Automatic walks: a signed-in CLI beats the local Ollama
    /// server, which beats an API key the user has to pay for separately.
    static let automaticOrder: [AssistantConnectorID] = [
        .claudeCode, .codex, .antigravity, .ollama,
    ] + AssistantConnectorID.byok

    // MARK: - Selection

    static var selection: AssistantSelection {
        get {
            if let raw = UserDefaults.standard.string(forKey: selectionKey) {
                return AssistantSelection(token: raw)
            }
            // Migrate the pre-picker "always use on-device model" toggle.
            if UserDefaults.standard.bool(forKey: legacyForceOnDeviceKey) {
                return .connector(.ollama)
            }
            return .automatic
        }
        set {
            UserDefaults.standard.set(newValue.storageToken, forKey: selectionKey)
        }
    }

    static func modelChoice(for id: AssistantConnectorID) -> ModelChoice {
        id.connector.choice(fromToken: UserDefaults.standard.string(forKey: modelKey(for: id)))
    }

    static func setModelChoice(_ choice: ModelChoice, for id: AssistantConnectorID) {
        UserDefaults.standard.set(choice.storageToken, forKey: modelKey(for: id))
    }

    // MARK: - Resolution

    /// What Automatic lands on right now, whether or not it is the current
    /// choice — the picker shows this so Automatic is never a mystery.
    @MainActor
    static var automaticTarget: ResolvedAssistant {
        let id = automaticOrder.first { $0.connector.isReady } ?? .ollama
        return ResolvedAssistant(
            connector: id.connector,
            choice: modelChoice(for: id),
            viaAutomatic: true
        )
    }

    @MainActor
    static var resolved: ResolvedAssistant {
        switch selection {
        case .connector(let id):
            ResolvedAssistant(
                connector: id.connector,
                choice: modelChoice(for: id),
                viaAutomatic: false
            )
        case .automatic:
            automaticTarget
        }
    }

    // MARK: - BYOK keys

    /// Which vendor the background jobs — reference indexing, vision re-index,
    /// thread titles — should call when they need a cloud model. The connector
    /// the user picked for chat wins if it is a BYOK one and has a key;
    /// otherwise the first provider that has a key at all.
    ///
    /// nil when the user explicitly pinned the assistant to the local Ollama
    /// model: that one choice is what keeps everything local. Choosing a CLI
    /// connector for chat does NOT disable cloud assist here — indexing still
    /// falls back to a saved key when Ollama is unavailable.
    static var activeCloudProvider: CloudAPIProvider? {
        guard selection != .connector(.ollama) else { return nil }
        if case .connector(let id) = selection,
           let provider = id.connector.apiProvider,
           KeychainService.hasKey(for: provider) {
            return provider
        }
        return CloudAPIProvider.fallbackOrder.first { KeychainService.hasKey(for: $0) }
    }

    /// Same rule as `activeCloudProvider`, but only checks that a key exists
    /// rather than reading one — safe to call from a view body, which
    /// `activeCloudModel(named:)` is not.
    static var cloudAssistEnabled: Bool {
        activeCloudProvider != nil
    }

    /// A ready-to-use model for the active provider, or nil when there is none.
    /// Every cloud call site must obtain its model here rather than from
    /// KeychainService, so the on-device pin keeps everything local.
    static func activeCloudModel(named modelID: String? = nil) -> CloudLanguageModel? {
        guard let provider = activeCloudProvider,
              let apiKey = KeychainService.loadKey(for: provider)
        else { return nil }
        return CloudLanguageModel(provider: provider, apiKey: apiKey, modelName: modelID)
    }

    /// The cheapest model of the active provider — for the throwaway one-line
    /// jobs that must not spend a frontier call.
    static func activeEconomyCloudModel() -> CloudLanguageModel? {
        guard let provider = activeCloudProvider else { return nil }
        return activeCloudModel(named: provider.economyModelID)
    }

    // MARK: - Local Ollama model

    /// A ready-to-use local model. The explicit `modelID` wins, then the
    /// stored choice, then whatever Ollama lists first.
    @MainActor
    static func localModel(named modelID: String? = nil) -> OllamaLanguageModel? {
        guard OllamaService.shared.availability.isAvailable else { return nil }
        let selected: String? = switch modelChoice(for: .ollama) {
        case .model(let id): id
        case .connectorDefault: nil
        }
        guard let resolved = modelID ?? selected ?? OllamaCatalog.defaultModelID,
              !resolved.isEmpty
        else { return nil }
        return OllamaLanguageModel(modelName: resolved)
    }
}
