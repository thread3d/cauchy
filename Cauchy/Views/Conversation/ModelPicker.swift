import SwiftUI

/// The single place the user chooses where answers come from. A native menu of
/// connectors; the ones with models open a submenu of those models. Every name
/// and availability check comes from `AssistantConnector`.
struct ModelPicker: View {
    enum Style {
        /// Bare text and chevron, sitting inside the composer bar — the bar
        /// already carries the glass, so the chip adds no chrome of its own.
        case inline
        /// Plain bordered button inside a Settings form row.
        case settings
    }

    var style: Style = .inline
    /// Called after the choice is persisted, so the workspace can swap the live
    /// assistant without losing the current thread.
    var onChange: () -> Void

    @AppStorage(AssistantPreferences.selectionKey)
    private var selectionToken = AssistantSelection.automaticToken
    @AppStorage(AssistantPreferences.modelKey(for: .claudeCode))
    private var claudeToken = AssistantConnectorID.claudeCode.connector.defaultChoice.storageToken
    @AppStorage(AssistantPreferences.modelKey(for: .codex))
    private var codexToken = AssistantConnectorID.codex.connector.defaultChoice.storageToken
    @AppStorage(AssistantPreferences.modelKey(for: .gemini))
    private var geminiToken = AssistantConnectorID.gemini.connector.defaultChoice.storageToken
    @AppStorage(AssistantPreferences.modelKey(for: .anthropicAPI))
    private var anthropicToken = AssistantConnectorID.anthropicAPI.connector.defaultChoice.storageToken
    @AppStorage(AssistantPreferences.modelKey(for: .openaiAPI))
    private var openaiToken = AssistantConnectorID.openaiAPI.connector.defaultChoice.storageToken
    /// Empty means "use whatever Ollama lists first"; the catalog is dynamic.
    @AppStorage(AssistantPreferences.modelKey(for: .ollama))
    private var ollamaToken = ""

    var body: some View {
        // Reading the revision makes the menu rebuild when Ollama's model list
        // arrives or changes.
        let _ = OllamaService.shared.revision
        Menu {
            Toggle("Automatic", isOn: binding(for: .automatic))

            Divider()

            ForEach(AssistantConnector.primary) { connector in
                connectorItem(connector)
            }

            Divider()

            ForEach(AssistantConnector.advanced) { connector in
                connectorItem(connector)
            }
        } label: {
            // The chrome has to be part of the label: applied to the Menu it
            // would sit outside the button's hit area, and clicking the padding
            // would do nothing.
            label.modifier(PickerChrome(style: style))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Model: \(resolved.label)")
        .help("Choose where answers come from")
        .task { OllamaService.shared.refreshIfNeeded() }
    }

    // MARK: - Menu items

    @ViewBuilder
    private func connectorItem(_ connector: AssistantConnector) -> some View {
        let status = connector.status

        if connector.hasModelChoice {
            Menu(menuTitle(connector, status)) {
                ForEach(connector.models) { model in
                    Toggle(
                        model.name,
                        isOn: binding(for: .connector(connector.id), choice: .model(model.id))
                    )
                }
            }
            .disabled(!status.isReady)
        } else {
            // Nothing to choose inside, so the connector itself is the item.
            Toggle(menuTitle(connector, status), isOn: binding(for: .connector(connector.id)))
                .disabled(!status.isReady)
        }
    }

    /// A disabled row has to say why it is disabled — Settings carries the full
    /// instructions, so this is only the reason in three words.
    private func menuTitle(_ connector: AssistantConnector, _ status: ConnectorStatus) -> String {
        guard let note = status.shortNote else { return connector.name }
        return "\(connector.name) — \(note)"
    }

    // MARK: - Collapsed label

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: resolved.connector.symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(resolved.label)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    // MARK: - Selection

    private var selection: AssistantSelection {
        AssistantSelection(token: selectionToken)
    }

    /// Built from the `@AppStorage` values rather than
    /// `AssistantPreferences.resolved`, so SwiftUI records the dependency and
    /// the button relabels the instant an item is picked.
    private var resolved: ResolvedAssistant {
        switch selection {
        case .automatic:
            return AssistantPreferences.automaticTarget
        case .connector(let id):
            let connector = id.connector
            return ResolvedAssistant(
                connector: connector,
                choice: storedChoice(for: connector),
                viaAutomatic: false
            )
        }
    }

    /// Read through the `@AppStorage` values rather than UserDefaults so the
    /// checkmarks move the moment a choice is made.
    private func storedChoice(for connector: AssistantConnector) -> ModelChoice {
        switch connector.id {
        case .claudeCode: connector.choice(fromToken: claudeToken)
        case .codex: connector.choice(fromToken: codexToken)
        case .gemini: connector.choice(fromToken: geminiToken)
        case .anthropicAPI: connector.choice(fromToken: anthropicToken)
        case .openaiAPI: connector.choice(fromToken: openaiToken)
        case .ollama: connector.choice(fromToken: ollamaToken)
        case .antigravity: .connectorDefault
        }
    }

    /// A menu item is "on" when it is the live choice; switching it on commits.
    /// Switching one off is meaningless here, so it is ignored.
    private func binding(for target: AssistantSelection, choice: ModelChoice? = nil) -> Binding<Bool> {
        Binding {
            guard selection == target else { return false }
            guard case .connector(let id) = target, let choice else { return true }
            return storedChoice(for: id.connector) == choice
        } set: { isOn in
            guard isOn else { return }
            commit(target, choice: choice)
        }
    }

    private func commit(_ target: AssistantSelection, choice: ModelChoice?) {
        if case .connector(let id) = target, let choice {
            switch id {
            case .claudeCode: claudeToken = choice.storageToken
            case .codex: codexToken = choice.storageToken
            case .gemini: geminiToken = choice.storageToken
            case .anthropicAPI: anthropicToken = choice.storageToken
            case .openaiAPI: openaiToken = choice.storageToken
            case .ollama: ollamaToken = choice.storageToken
            case .antigravity: break
            }
        }
        selectionToken = target.storageToken
        onChange()
    }
}

// MARK: - Chrome

private struct PickerChrome: ViewModifier {
    let style: ModelPicker.Style

    func body(content: Content) -> some View {
        switch style {
        case .inline:
            content
                .padding(.vertical, 2)
                .contentShape(.rect)
        case .settings:
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(.rect(cornerRadius: 6))
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        }
    }
}
