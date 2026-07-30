import SwiftUI

@MainActor
struct ProfilesView: View {
    fileprivate enum EditorOperation {
        case create
        case edit
        case duplicate(sourceProfileID: DNSProfile.ID)
    }

    @EnvironmentObject private var appState: AppState
    @State private var selection: DNSProfile.ID?
    @State private var draft: ProfileDraft?
    @State private var editorOperation = EditorOperation.create
    @State private var deletionRequest: ProfileDeletionRequest?

    var body: some View {
        HSplitView {
            List(appState.profiles, selection: $selection) { profile in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(displayNames[profile.id] ?? profile.name)
                        Spacer()
                        if profile.id == appState.proxy.activeProfileID {
                            Image(systemName: "checkmark").accessibilityLabel("Active")
                        }
                    }
                    Text(identity(for: profile).displaySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if profile.id == appState.configuration?.defaultProfileID {
                        Text("Default").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(profile.id)
                .contextMenu {
                    Button("Edit") { appState.requestEditor(.editProfile(profile.id)) }
                    Button("Duplicate") { appState.requestEditor(.duplicateProfile(profile.id)) }
                    Button("Test") {
                        Task { await appState.preflightProfile(ProfileDraft(profile: profile)) }
                    }
                    Button("Make Default") {
                        Task { await appState.setDefaultProfile(profile.id) }
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        requestDeletion(of: profile)
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 270, maxWidth: 320)

            Group {
                if let profile = selectedProfile {
                    ProfileDetailView(
                        profile: profile,
                        isActive: profile.id == appState.proxy.activeProfileID,
                        isDefault: profile.id == appState.configuration?.defaultProfileID,
                        edit: { appState.requestEditor(.editProfile(profile.id)) },
                        test: {
                            Task { await appState.preflightProfile(ProfileDraft(profile: profile)) }
                        },
                        duplicate: { appState.requestEditor(.duplicateProfile(profile.id)) },
                        makeDefault: { Task { await appState.setDefaultProfile(profile.id) } },
                        delete: { requestDeletion(of: profile) }
                    )
                } else {
                    ContentUnavailableView {
                        Label(
                            appState.profiles.isEmpty ? "No DNS Profiles" : "Select a Profile",
                            systemImage: "list.bullet.rectangle"
                        )
                    } actions: {
                        if appState.profiles.isEmpty {
                            Button("Create Profile") { appState.requestEditor(.newProfile) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.requestEditor(.newProfile)
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Profile")
                .accessibilityLabel("New Profile")
            }
        }
        .sheet(item: $draft, onDismiss: appState.endDraft) { draft in
            ProfileEditorView(draft: draft, operation: editorOperation)
        }
        .sheet(item: $deletionRequest) { request in
            ProfileDeletionView(request: request)
        }
        .onChange(of: appState.profiles.map(\.id)) { _, ids in
            if selection == nil || !ids.contains(selection!) { selection = ids.first }
        }
        .onAppear { selection = selection ?? appState.profiles.first?.id }
        .onChange(of: appState.requestedProfileSelection) { _, profileID in
            if let profileID, appState.profiles.contains(where: { $0.id == profileID }) {
                selection = profileID
            }
        }
        .onAppear { handleEditorRequest(appState.editorRequest) }
        .onChange(of: appState.editorRequest) { _, request in handleEditorRequest(request) }
        .onChange(of: appState.draftDiscardGeneration) { _, _ in draft = nil }
        .safeAreaInset(edge: .bottom) {
            if let result = appState.profileTestResult {
                Label(result, systemImage: "checkmark.circle")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
    }

    private var selectedProfile: DNSProfile? {
        appState.profiles.first { $0.id == selection }
    }

    private var displayNames: [DNSProfile.ID: String] {
        ProfileDisplayIdentity.displayNames(for: appState.profiles)
    }

    private func identity(for profile: DNSProfile) -> ProfileDisplayIdentity {
        ProfileDisplayIdentity.identities(for: appState.profiles)[profile.id]!
    }

    private func handleEditorRequest(_ request: ProductEditorRequest?) {
        guard let request else { return }
        switch request.kind {
        case .newProfile:
            editorOperation = .create
            draft = ProfileDraft()
        case let .editProfile(profileID):
            guard let profile = appState.profiles.first(where: { $0.id == profileID }) else {
                appState.consumeEditorRequest(request.id)
                return
            }
            editorOperation = .edit
            draft = ProfileDraft(profile: profile)
        case let .duplicateProfile(profileID):
            guard let profile = appState.profiles.first(where: { $0.id == profileID }) else {
                appState.consumeEditorRequest(request.id)
                return
            }
            var duplicate = ProfileDraft(profile: profile)
            duplicate.id = UUID()
            duplicate.name = "\(profile.name) Copy"
            editorOperation = .duplicate(sourceProfileID: profileID)
            draft = duplicate
        case .newRule, .editRule, .duplicateRule:
            return
        }
        appState.beginDraft(.profile)
        appState.consumeEditorRequest(request.id)
    }

    private func requestDeletion(of profile: DNSProfile) {
        deletionRequest = ProfileDeletionRequest(
            profile: profile,
            configuration: appState.configuration,
            activeProfileID: appState.proxy.activeProfileID,
            targetProfileID: appState.proxy.targetProfileID
        )
    }
}

@MainActor
private struct ProfileDetailView: View {
    let profile: DNSProfile
    let isActive: Bool
    let isDefault: Bool
    let edit: () -> Void
    let test: () -> Void
    let duplicate: () -> Void
    let makeDefault: () -> Void
    let delete: () -> Void

    var body: some View {
        Form {
            LabeledContent("Name", value: profile.name)
            switch profile.upstream {
            case let .plain(configuration):
                LabeledContent("Protocol", value: "Plain DNS")
                LabeledContent("Server", value: configuration.serverAddress.stringValue)
                LabeledContent("Port", value: String(configuration.port))
            case let .tls(configuration):
                LabeledContent("Protocol", value: "DNS over TLS")
                LabeledContent("Server", value: configuration.serverName)
                LabeledContent("Port", value: String(configuration.port))
                LabeledContent("Bootstrap Servers") {
                    Text(configuration.bootstrapServers.map(\.stringValue).joined(separator: ", "))
                        .textSelection(.enabled)
                }
            case let .https(configuration):
                LabeledContent("Protocol", value: "DNS over HTTPS")
                LabeledContent("Endpoint") {
                    Text(configuration.endpointURL.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(configuration.endpointURL.absoluteString)
                        .textSelection(.enabled)
                }
                LabeledContent("Bootstrap Servers") {
                    Text(configuration.bootstrapServers.map(\.stringValue).joined(separator: ", "))
                        .textSelection(.enabled)
                }
            }
            if isDefault { LabeledContent("Default Profile", value: "Yes") }
            if isActive { LabeledContent("Active", value: "Yes") }
            HStack {
                Spacer()
                Button("Test", action: test)
                Button("Edit", action: edit)
                Menu {
                    Button("Duplicate", action: duplicate)
                    Button("Make Default", action: makeDefault).disabled(isDefault)
                    Divider()
                    Button("Delete", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("More Profile Actions")
                .accessibilityLabel("More Profile Actions")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

@MainActor
private struct ProfileEditorView: View {
    private enum Field: Hashable {
        case name
        case server
        case port
        case endpoint
        case bootstrap
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State var draft: ProfileDraft
    @State private var validationError: ProfileDraftError?
    @State private var operationFailure: ProductActionFailure?
    @FocusState private var focusedField: Field?
    let operation: ProfilesView.EditorOperation

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $draft.name, prompt: Text("Home DNS"))
                    .focused($focusedField, equals: .name)
                fieldError(.name)
                Picker("Protocol", selection: $draft.transport) {
                    Text("Plain DNS").tag(ProfileTransport.plain)
                    Text("DNS over TLS").tag(ProfileTransport.tls)
                    Text("DNS over HTTPS").tag(ProfileTransport.https)
                }
                .pickerStyle(.segmented)

                switch draft.transport {
                case .plain:
                    TextField(
                        "Server Address",
                        text: $draft.plainServerAddress,
                        prompt: Text("1.1.1.1")
                    )
                        .focused($focusedField, equals: .server)
                    fieldError(.server)
                    TextField(
                        "Port",
                        value: $draft.plainPort,
                        format: .number,
                        prompt: Text("53")
                    )
                        .focused($focusedField, equals: .port)
                    fieldError(.port)
                case .tls:
                    TextField(
                        "Server Name or Address",
                        text: $draft.dotServerName,
                        prompt: Text("dns.example.com")
                    )
                        .focused($focusedField, equals: .server)
                    fieldError(.server)
                    TextField(
                        "Port",
                        value: $draft.dotPort,
                        format: .number,
                        prompt: Text("853")
                    )
                        .focused($focusedField, equals: .port)
                    fieldError(.port)
                    bootstrapEditor
                case .https:
                    TextField(
                        "Endpoint URL",
                        text: $draft.endpointURL,
                        prompt: Text("https://dns.example.com/dns-query")
                    )
                        .focused($focusedField, equals: .endpoint)
                    fieldError(.endpoint)
                    bootstrapEditor
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Test") { Task { await testDraft() } }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    validateAndSave()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 390)
        .disabled(appState.isPerformingAction)
        .onAppear { appState.beginDraft(.profile) }
        .alert(
            "Operation Failed",
            isPresented: Binding(
                get: { operationFailure != nil },
                set: { if !$0 { operationFailure = nil } }
            )
        ) {
            Button("OK") { operationFailure = nil }
        } message: {
            Text(operationFailure?.message ?? "Unknown error")
        }
    }

    private func saveDraft() async -> ProductActionOutcome {
        switch operation {
        case .create:
            await appState.createProfile(draft)
        case .edit:
            await appState.editProfile(draft)
        case let .duplicate(sourceProfileID):
            await appState.duplicateProfile(sourceProfileID: sourceProfileID, draft: draft)
        }
    }

    private func validateAndSave() {
        do {
            _ = try draft.profile()
            validationError = nil
        } catch let error as ProfileDraftError {
            validationError = error
            focusedField = field(for: error)
            return
        } catch {
            return
        }
        Task {
            let result = await saveDraft()
            handle(result, dismissOnSuccess: true)
        }
    }

    private func testDraft() async {
        handle(await appState.preflightProfile(draft), dismissOnSuccess: false)
    }

    private func handle(
        _ outcome: ProductActionOutcome,
        dismissOnSuccess: Bool
    ) {
        switch outcome {
        case .completed:
            if dismissOnSuccess { dismiss() }
        case let .failed(failure):
            appState.clearActionFailure()
            operationFailure = failure
        }
    }

    private func field(for error: ProfileDraftError) -> Field {
        switch error {
        case .emptyName: .name
        case .invalidServerAddress, .invalidServerName: .server
        case .invalidPort: .port
        case .invalidEndpoint: .endpoint
        case .invalidBootstrapServer, .missingBootstrapServers: .bootstrap
        }
    }

    private func normalizeIPAddress(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? IPAddress(trimmed))?.stringValue
    }

    private var bootstrapEditor: some View {
        Group {
            StringListEditor(
                label: "Bootstrap Servers",
                itemLabel: "Bootstrap Server",
                addLabel: "Add Bootstrap Server",
                values: $draft.bootstrapServers,
                normalize: normalizeIPAddress,
                itemPrompt: "1.1.1.1"
            )
            .focused($focusedField, equals: .bootstrap)
            fieldError(.bootstrap)
        }
    }

    @ViewBuilder
    private func fieldError(_ field: Field) -> some View {
        if let validationError, self.field(for: validationError) == field {
            Text(validationError.errorDescription ?? "Invalid value")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Error: \(validationError.errorDescription ?? "Invalid value")")
        }
    }
}

private struct ProfileDeletionRequest: Identifiable {
    let profile: DNSProfile
    let affectedRuleIDs: [DNSRule.ID]
    let isDefault: Bool
    let isManualTarget: Bool
    let isActive: Bool
    let isUnresolvedTarget: Bool
    let replacements: [DNSProfile]

    var id: DNSProfile.ID { profile.id }

    init(
        profile: DNSProfile,
        configuration: AppConfiguration?,
        activeProfileID: DNSProfile.ID?,
        targetProfileID: DNSProfile.ID?
    ) {
        self.profile = profile
        affectedRuleIDs = configuration?.rules.filter { $0.profileID == profile.id }.map(\.id) ?? []
        isDefault = configuration?.defaultProfileID == profile.id
        if case let .manual(profileID) = configuration?.operatingMode {
            isManualTarget = profileID == profile.id
        } else {
            isManualTarget = false
        }
        isActive = activeProfileID == profile.id
        isUnresolvedTarget = ProfileDeletionPolicy.isPendingTarget(
            profileID: profile.id,
            targetProfileID: targetProfileID,
            activeProfileID: activeProfileID
        )
        replacements = configuration?.profiles.filter { $0.id != profile.id } ?? []
    }

    var needsReplacement: Bool {
        !affectedRuleIDs.isEmpty || isDefault || isManualTarget || isActive
    }
}

@MainActor
private struct ProfileDeletionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let request: ProfileDeletionRequest
    @State private var replacementProfileID: DNSProfile.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete \"\(request.profile.name)\"?").font(.headline)
            if request.isUnresolvedTarget {
                Text("This Profile is the pending switch target. Retry, use the Active Profile, or restore System DNS before deleting it.")
                    .foregroundStyle(.secondary)
            } else if request.needsReplacement {
                Text(referenceSummary).foregroundStyle(.secondary)
                Picker("Replace With", selection: $replacementProfileID) {
                    Text("Choose a Profile").tag(Optional<DNSProfile.ID>.none)
                    ForEach(request.replacements) { profile in
                        Text(displayNames[profile.id] ?? profile.name).tag(Optional(profile.id))
                    }
                }
            } else {
                Text("This action cannot be undone.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Delete", role: .destructive) {
                    Task {
                        let plan = deletionPlan
                        if await appState.deleteProfile(request.profile.id, plan: plan) == .completed {
                            dismiss()
                        }
                    }
                }
                .disabled(
                    appState.isPerformingAction
                        || request.isUnresolvedTarget
                        || (request.needsReplacement && replacementProfileID == nil)
                )
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var deletionPlan: ProfileDeletionPlan {
        guard let replacementProfileID else { return ProfileDeletionPlan() }
        return ProfileDeletionPlan(
            ruleReplacements: Dictionary(
                uniqueKeysWithValues: request.affectedRuleIDs.map { ($0, replacementProfileID) }
            ),
            defaultReplacementProfileID: request.isDefault ? replacementProfileID : nil,
            manualReplacementProfileID: request.isManualTarget ? replacementProfileID : nil,
            activeReplacementProfileID: request.isActive ? replacementProfileID : nil
        )
    }

    private var referenceSummary: String {
        var references: [String] = []
        if !request.affectedRuleIDs.isEmpty { references.append("\(request.affectedRuleIDs.count) Rule(s)") }
        if request.isDefault { references.append("Default Profile") }
        if request.isManualTarget { references.append("Manual target") }
        if request.isActive { references.append("Active DNS Proxy") }
        return "Choose a replacement for: \(references.joined(separator: ", "))."
    }

    private var displayNames: [DNSProfile.ID: String] {
        ProfileDisplayIdentity.displayNames(for: request.replacements)
    }
}
