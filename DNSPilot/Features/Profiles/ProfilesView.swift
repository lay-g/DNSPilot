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
    @State private var profileTestTask: Task<Void, Never>?
    @State private var profileTestStatus: ProfileTestStatus?
    @State private var testedProfile: DNSProfile?

    var body: some View {
        HSplitView {
            List(appState.profiles, selection: $selection) { profile in
                HStack(spacing: 10) {
                    Image(systemName: profile.upstream.transportSymbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayNames[profile.id] ?? profile.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(identity(for: profile).displaySummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        if profile.id == appState.proxy.activeProfileID {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        if profile.id == appState.configuration?.defaultProfileID {
                            Text("Default").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
                .tag(profile.id)
                .contextMenu {
                    Button("Edit") { appState.requestEditor(.editProfile(profile.id)) }
                    Button("Duplicate") { appState.requestEditor(.duplicateProfile(profile.id)) }
                    Button("Test") {
                        selection = profile.id
                        test(profile)
                    }
                    .disabled(appState.configurationWritesLocked)
                    Button("Make Default") {
                        Task { await appState.setDefaultProfile(profile.id) }
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        requestDeletion(of: profile)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                ListActionBar {
                    Button {
                        appState.requestEditor(.newProfile)
                    } label: {
                        Label("New Profile", systemImage: "plus")
                    }
                    .help("New Profile")
                    Button {
                        if let selectedProfile { requestDeletion(of: selectedProfile) }
                    } label: {
                        Label("Delete Profile", systemImage: "minus")
                    }
                    .help("Delete Profile")
                    .disabled(selectedProfile == nil)
                    ListActionDivider()
                    Menu {
                        if let profile = selectedProfile {
                            Button("Edit…") { appState.requestEditor(.editProfile(profile.id)) }
                            Button("Duplicate") { appState.requestEditor(.duplicateProfile(profile.id)) }
                            Button("Test") { test(profile) }
                                .disabled(appState.configurationWritesLocked)
                            Button("Make Default") {
                                Task { await appState.setDefaultProfile(profile.id) }
                            }
                            .disabled(profile.id == appState.configuration?.defaultProfileID)
                        }
                    } label: {
                        Label("More Profile Actions", systemImage: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: ListActionButtonStyle.size.width, height: ListActionButtonStyle.size.height)
                    .help("More Profile Actions")
                    .disabled(selectedProfile == nil)
                }
                .padding(10)
            }
            .frame(minWidth: 240, idealWidth: 270, maxWidth: 320)

            Group {
                if let profile = selectedProfile {
                    ProfileDetailView(
                        profile: profile,
                        isActive: profile.id == appState.proxy.activeProfileID,
                        isDefault: profile.id == appState.configuration?.defaultProfileID,
                        isTestDisabled: appState.configurationWritesLocked,
                        testStatus: testedProfile == profile ? profileTestStatus : nil,
                        rules: appState.rules.filter { $0.profileID == profile.id },
                        openRule: { appState.navigateToRule($0) },
                        edit: { appState.requestEditor(.editProfile(profile.id)) },
                        test: {
                            test(profile)
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
        .onDisappear {
            profileTestTask?.cancel()
            profileTestStatus = nil
            testedProfile = nil
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

    private func test(_ profile: DNSProfile) {
        profileTestTask?.cancel()
        testedProfile = profile
        profileTestStatus = .testing
        profileTestTask = Task {
            let outcome = await appState.preflightProfile(ProfileDraft(profile: profile))
            guard !Task.isCancelled else { return }
            profileTestStatus = ProfileTestStatus(outcome)
        }
    }
}

@MainActor
private struct ProfileDetailView: View {
    let profile: DNSProfile
    let isActive: Bool
    let isDefault: Bool
    let isTestDisabled: Bool
    let testStatus: ProfileTestStatus?
    let rules: [DNSRule]
    let openRule: (DNSRule.ID) -> Void
    let edit: () -> Void
    let test: () -> Void
    let duplicate: () -> Void
    let makeDefault: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("Upstream") {
                    LabeledContent("Protocol", value: profile.upstream.transportTitle)
                    switch profile.upstream {
                    case let .plain(configuration):
                        LabeledContent("Server") { monospaced(configuration.serverAddress.stringValue) }
                        LabeledContent("Port", value: String(configuration.port))
                    case let .tls(configuration):
                        LabeledContent("Server") { monospaced(configuration.serverName) }
                        LabeledContent("Port", value: String(configuration.port))
                        LabeledContent("Bootstrap Servers") {
                            monospaced(configuration.bootstrapServers.map(\.stringValue).joined(separator: "\n"))
                        }
                    case let .https(configuration):
                        LabeledContent("Endpoint") {
                            Text(configuration.endpointURL.absoluteString)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(configuration.endpointURL.absoluteString)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Bootstrap Servers") {
                            monospaced(configuration.bootstrapServers.map(\.stringValue).joined(separator: "\n"))
                        }
                    }
                }
                Section {
                    if profile.hosts.isEmpty {
                        Text("No host overrides")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profile.hosts, id: \.self) { host in
                            LabeledContent {
                                monospaced(host.address.stringValue)
                            } label: {
                                Text(host.domain).font(.callout.monospaced())
                            }
                        }
                    }
                } header: {
                    Text("Hosts")
                } footer: {
                    Text("Overrides A and AAAA answers before the upstream is queried. *.example.com also covers example.com.")
                        .foregroundStyle(.secondary)
                }
                Section("Usage") {
                    LabeledContent("Status") {
                        if isActive {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("Not Active")
                        }
                    }
                    LabeledContent("Default Profile") {
                        if isDefault {
                            Text("Yes")
                        } else {
                            Button("Make Default", action: makeDefault)
                                .buttonStyle(.link)
                        }
                    }
                    LabeledContent("Used by Rules") {
                        if rules.isEmpty {
                            Text("None")
                        } else {
                            HStack(spacing: 6) {
                                ForEach(rules) { rule in
                                    Button(rule.name) { openRule(rule.id) }
                                        .buttonStyle(.link)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                headerTitle
                Spacer(minLength: 12)
                headerActions
            }
            VStack(alignment: .leading, spacing: 10) {
                headerTitle
                headerActions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var headerTitle: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.upstream.transportSymbolName)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(profile.upstream.transportTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if let testStatus {
                ProfileTestStatusView(status: testStatus)
                    .font(.callout)
            }
            Button("Test", action: test)
                .disabled(isTestDisabled)
            Button("Edit…", action: edit)
            Menu {
                Button("Duplicate", action: duplicate)
                Button("Make Default", action: makeDefault).disabled(isDefault)
                Divider()
                Button("Delete…", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(height: 16)
                    .accessibilityLabel("More Profile Actions")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Profile Actions")
        }
    }

    private func monospaced(_ value: String) -> some View {
        Text(value)
            .font(.callout.monospaced())
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
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
        case hosts
        case hostDomain(UUID)
        case hostAddress(UUID)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var appState: AppState
    @State var draft: ProfileDraft
    @State private var validationError: ProfileDraftError?
    @State private var operationFailure: ProductActionFailure?
    @State private var profileTestTask: Task<Void, Never>?
    @State private var profileTestStatus: ProfileTestStatus?
    @FocusState private var focusedField: Field?
    let operation: ProfilesView.EditorOperation

    var body: some View {
        VStack(spacing: 0) {
            Text(editorTitle)
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Home DNS"))
                        .focused($focusedField, equals: .name)
                    fieldError(.name)
                }
                Section("Upstream") {
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
                hostsEditor
            }
            .formStyle(.grouped)
            HStack {
                Button("Test") { startProfileTest() }
                if let profileTestStatus {
                    ProfileTestStatusView(status: profileTestStatus)
                        .font(.caption)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    validateAndSave()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .padding(.top, 4)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 430, idealHeight: 560)
        .disabled(appState.isPerformingAction)
        .onAppear { appState.beginDraft(.profile) }
        .onDisappear {
            profileTestTask?.cancel()
            profileTestStatus = nil
        }
        .onChange(of: draft) { _, _ in
            profileTestTask?.cancel()
            profileTestStatus = nil
        }
        .alert(
            operationFailure?.title ?? "Profile Action Failed",
            isPresented: Binding(
                get: { operationFailure != nil },
                set: { if !$0 { operationFailure = nil } }
            )
        ) {
            if operationFailure?.recoveryActions.contains(.retry) == true {
                Button("Try Again") {
                    operationFailure = nil
                    validateAndSave()
                }
            }
            if operationFailure?.recoveryActions.contains(.reconnect) == true {
                Button("Reconnect") {
                    operationFailure = nil
                    Task { await appState.reconnect() }
                }
            }
            if operationFailure?.recoveryActions.contains(.restoreSystemDNS) == true {
                Button("Restore System DNS") {
                    operationFailure = nil
                    Task { await appState.restoreSystemDNS() }
                }
            }
            if operationFailure?.recoveryActions.contains(.openDiagnostics) == true {
                Button("Open Diagnostics") {
                    operationFailure = nil
                    appState.selectSettingsSection(.diagnostics)
                    openSettings()
                }
            }
            if operationFailure?.reason == .profileNotFound {
                Button("Close Editor") {
                    operationFailure = nil
                    dismiss()
                }
            }
            Button("OK") { operationFailure = nil }
        } message: {
            Text(operationFailure?.message ?? "DNSPilot could not load the Profile failure details. Open Diagnostics for more information.")
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
            handle(
                appState.reportValidationFailure(error, action: operation.productAction),
                dismissOnSuccess: false
            )
            return
        }
        Task {
            let result = await saveDraft()
            handle(result, dismissOnSuccess: true)
        }
    }

    private func startProfileTest() {
        profileTestTask?.cancel()
        profileTestStatus = .testing
        profileTestTask = Task {
            let outcome = await appState.preflightProfile(draft)
            guard !Task.isCancelled else { return }
            profileTestStatus = ProfileTestStatus(outcome)
        }
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
            if failure.reason != .cancelled { operationFailure = failure }
        }
    }

    private func field(for error: ProfileDraftError) -> Field {
        switch error {
        case .emptyName: .name
        case .invalidServerAddress, .invalidServerName: .server
        case .invalidPort: .port
        case .invalidEndpoint: .endpoint
        case .invalidBootstrapServer, .missingBootstrapServers: .bootstrap
        case .invalidHostDomain(let id, _): .hostDomain(id)
        case .invalidHostAddress(let id, _): .hostAddress(id)
        case .tooManyHosts: .hosts
        case .duplicateHost(let id, _): .hostDomain(id)
        case .overlappingWildcardHost(let id, _): .hostDomain(id)
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

    private var editorTitle: String {
        switch operation {
        case .create: "New Profile"
        case .edit: "Edit Profile"
        case .duplicate: "Duplicate Profile"
        }
    }

    @ViewBuilder
    private var hostsEditor: some View {
        Section {
            ForEach($draft.hosts) { $host in
                HStack(spacing: 8) {
                    TextField("Domain", text: $host.domain)
                        .focused($focusedField, equals: .hostDomain(host.id))
                    TextField("Address", text: $host.address)
                        .focused($focusedField, equals: .hostAddress(host.id))
                    Button(role: .destructive) {
                        draft.hosts.removeAll { $0.id == host.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove Host")
                    .accessibilityLabel("Remove Host")
                }
            }
            if draft.hosts.isEmpty {
                Text("No Hosts")
                    .foregroundStyle(.secondary)
            }
            fieldError(.hosts)
            Button {
                draft.hosts.append(ProfileHostDraft())
            } label: {
                Label("Add Host", systemImage: "plus")
            }
            .buttonStyle(.link)
        } header: {
            Text("Hosts")
        } footer: {
            Text("Use an exact domain or a leftmost wildcard. *.example.com also covers example.com.")
                .foregroundStyle(.secondary)
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

private extension ProfilesView.EditorOperation {
    var productAction: ProductAction {
        switch self {
        case .create: .profileCreate
        case .edit: .profileEdit
        case .duplicate: .profileDuplicate
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
