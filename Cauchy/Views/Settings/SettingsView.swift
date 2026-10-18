import SwiftUI

struct SettingsView: View {
    var onSettingsChanged: (() -> Void)?

    /// Typed-but-unsaved key text, per provider. Cleared the moment a key is
    /// committed to the Keychain — the app never keeps a secret in view state
    /// longer than the user is typing it.
    @State private var setupConnector: AssistantConnectorID?
    @State private var setup = ConnectorSetupService.shared
    @State private var refreshID = UUID()
    @State private var draftKeys: [CloudAPIProvider: String] = [:]
    @State private var storedKeys: Set<CloudAPIProvider> = Set(
        CloudAPIProvider.allCases.filter(KeychainService.hasKey(for:))
    )
    /// Only one key row is open at a time: the section is a list of vendors,
    /// not a form, and an accordion keeps the window from growing past its frame.
    @State private var expandedProvider: CloudAPIProvider?
    @State private var status: (provider: CloudAPIProvider, message: String, isError: Bool)?
    @AppStorage(AssistantPreferences.selectionKey)
    private var selectionToken = AssistantSelection.automaticToken

    init(onSettingsChanged: (() -> Void)? = nil) {
        self.onSettingsChanged = onSettingsChanged
    }

    /// Reads `selectionToken` so SwiftUI re-renders this view when the picker
    /// writes a new choice.
    private var activeConnector: AssistantConnector {
        switch AssistantSelection(token: selectionToken) {
        case .automatic: AssistantPreferences.automaticTarget.connector
        case .connector(let id): id.connector
        }
    }

    @State private var reopensLastDocument = WorkspaceViewModel.reopensLastDocumentAtLaunch

    var body: some View {
        Form {
            Section {
                Toggle("Reopen the last document at launch", isOn: $reopensLastDocument)
                    .onChange(of: reopensLastDocument) { _, newValue in
                        WorkspaceViewModel.reopensLastDocumentAtLaunch = newValue
                    }
            } header: {
                Text("Reading")
            }

            Section {
                // Deliberately not a LabeledContent: its value slot swallows the
                // menu's clicks and the picker never opens.
                HStack {
                    Text("Ask uses")
                    Spacer()
                    ModelPicker(style: .settings) {
                        onSettingsChanged?()
                    }
                }
                Text(activeConnector.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Assistant")
            }

            Section {
                ForEach(AssistantConnector.primary) { connector in
                    connectorRow(connector)
                }
            } header: {
                Text("Connect your assistant")
            } footer: {
                Text("Ollama runs models on this Mac: start it with `ollama serve` and pull a model with `ollama pull`. The CLI providers below use your existing subscription; Cauchy never sees the credential.")
            }

            Section {
                ForEach(CloudAPIProvider.allCases) { provider in
                    keyRow(provider)
                }
            } header: {
                Text("Your API keys")
            } footer: {
                Text("Bring your own key to reach a vendor's API directly. Keys are stored in your Keychain, sent only to the vendor they belong to, and billed to you per request. A saved key is also the fallback for reference indexing when Ollama is unavailable.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .padding()
        .sheet(item: $setupConnector) { id in
            ConnectorSetupView(connector: id.connector) {
                CLIAgentRunner.invalidateBinaryCache()
                refreshID = UUID()
                onSettingsChanged?()
            }
        }
        .onAppear {
            CLIAgentRunner.invalidateBinaryCache()
            OllamaService.shared.refreshIfNeeded(maxAge: 0)
            refreshID = UUID()
        }
    }

    // MARK: - Connector status

    @ViewBuilder
    private func connectorRow(_ connector: AssistantConnector) -> some View {
        let _ = refreshID
        let status = connector.status
        let connected = setup.authenticated.contains(connector.id) && connector.resolvedBinaryURL != nil
        HStack(spacing: 12) {
            Image(systemName: connector.symbol)
                .font(.title3).frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(connector.name).fontWeight(.medium)
                    if connected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                Text(connector.binaryName == nil ? (status.hint ?? connector.tagline) :
                     connected ? "Ready to answer your questions" :
                     connector.resolvedBinaryURL == nil ? "Install and connect your \(connector.vendor) account" : "Already installed · Connect your account")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if connector.binaryName != nil {
                Button(connected ? "Manage" : connector.resolvedBinaryURL == nil ? "Install & connect" : "Connect") {
                    setupConnector = connector.id
                }
                .controlSize(.small)
                .disabled(setup.busy)
            } else if connector.id == .ollama {
                HStack(spacing: 8) {
                    Text(status.badge).font(.caption).foregroundStyle(.secondary)
                    Button("Refresh") {
                        Task {
                            await OllamaService.shared.refresh()
                            refreshID = UUID()
                            onSettingsChanged?()
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                Text(status.badge).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .font(.callout)
    }

    // MARK: - API keys

    @ViewBuilder
    private func keyRow(_ provider: CloudAPIProvider) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: provider)) {
            VStack(alignment: .leading, spacing: 10) {
                keyControls(provider)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: provider.symbol)
                    .frame(width: 16)
                Text(provider.name)
                Spacer()
                if storedKeys.contains(provider) {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func keyControls(_ provider: CloudAPIProvider) -> some View {
        let draft = draftKeys[provider] ?? ""

        // The hint has to ride `prompt`, not the title: a Form turns a field's
        // title into a left column label, and hiding that label takes the hint
        // with it. As a prompt it sits inside the field, showing the shape of
        // the key the user is about to paste.
        SecureField(text: draftBinding(for: provider), prompt: Text(provider.keyPrefixHint)) {
            Text("\(provider.vendor) API key")
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()

        HStack {
            Button("Save") {
                save(provider)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Clear", role: .destructive) {
                clear(provider)
            }
            .disabled(!storedKeys.contains(provider))

            Spacer()

            Link("Get a key", destination: provider.consoleURL)
                .font(.caption)
        }

        if let status, status.provider == provider {
            Text(status.message)
                .font(.caption)
                .foregroundStyle(status.isError ? .red : .secondary)
        }
    }

    private func expansionBinding(for provider: CloudAPIProvider) -> Binding<Bool> {
        Binding {
            expandedProvider == provider
        } set: { isExpanded in
            expandedProvider = isExpanded ? provider : nil
        }
    }

    private func draftBinding(for provider: CloudAPIProvider) -> Binding<String> {
        Binding {
            draftKeys[provider] ?? ""
        } set: { newValue in
            draftKeys[provider] = newValue
        }
    }

    private func save(_ provider: CloudAPIProvider) {
        do {
            try KeychainService.saveKey(draftKeys[provider] ?? "", for: provider)
            draftKeys[provider] = ""
            storedKeys.insert(provider)
            status = (provider, "\(provider.vendor) API key saved.", false)
            onSettingsChanged?()
        } catch {
            status = (provider, error.localizedDescription, true)
        }
    }

    private func clear(_ provider: CloudAPIProvider) {
        do {
            try KeychainService.deleteKey(for: provider)
            draftKeys[provider] = ""
            storedKeys.remove(provider)
            status = (provider, "\(provider.vendor) API key removed.", false)
            onSettingsChanged?()
        } catch {
            status = (provider, error.localizedDescription, true)
        }
    }
}
