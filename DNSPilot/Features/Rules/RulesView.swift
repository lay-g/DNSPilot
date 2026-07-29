import SwiftUI

@MainActor
struct RulesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: DNSRule.ID?
    @State private var draft: RuleDraft?
    @State private var deletionRequest: DNSRule?

    var body: some View {
        Group {
            if appState.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No DNS Profiles", systemImage: "list.bullet.rectangle")
                } actions: {
                    Button("Create Profile") { appState.requestEditor(.newProfile) }
                }
            } else {
                rulesContent
            }
        }
        .navigationTitle("Rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.requestEditor(.newRule)
                } label: { Image(systemName: "plus") }
                .help("New Rule")
                .accessibilityLabel("New Rule")
                .disabled(appState.profiles.isEmpty)
            }
        }
        .sheet(item: $draft, onDismiss: appState.endDraft) { draft in
            RuleEditorView(draft: draft)
        }
        .confirmationDialog(
            "Delete \(deletionRequest?.name ?? "Rule")?",
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            presenting: deletionRequest
        ) { rule in
            Button("Delete", role: .destructive) {
                Task { await appState.deleteRule(rule.id) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { rule in
            Text("This permanently deletes the Rule \"\(rule.name)\".")
        }
        .onAppear { selection = selection ?? appState.rules.first?.id }
        .onAppear { handleEditorRequest(appState.editorRequest) }
        .onChange(of: appState.editorRequest) { _, request in handleEditorRequest(request) }
        .onChange(of: appState.draftDiscardGeneration) { _, _ in draft = nil }
        .onChange(of: appState.requestedRuleSelection) { _, ruleID in
            if let ruleID, appState.rules.contains(where: { $0.id == ruleID }) {
                selection = ruleID
            }
        }
        .onChange(of: appState.rules.map(\.id)) { _, ids in
            if selection == nil || !ids.contains(selection!) {
                selection = ids.first
            }
        }
    }

    private var rulesContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Default Profile")
                Spacer()
                Picker("Default Profile", selection: Binding(
                    get: { appState.configuration?.defaultProfileID ?? appState.profiles[0].id },
                    set: { id in Task { await appState.setDefaultProfile(id) } }
                )) {
                    ForEach(appState.profiles) { profile in
                        Text(displayNames[profile.id] ?? profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)
                .disabled(appState.isPerformingAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            HSplitView {
                List(selection: $selection) {
                    ForEach(Array(appState.rules.enumerated()), id: \.element.id) { index, rule in
                        HStack(alignment: .top) {
                            Toggle("Enable \(rule.name)", isOn: Binding(
                                get: { rule.isEnabled },
                                set: { enabled in
                                    var updated = RuleDraft(rule: rule)
                                    updated.isEnabled = enabled
                                    Task { await appState.saveRule(updated) }
                                }
                            ))
                            .labelsHidden()
                            .accessibilityLabel(
                                "Priority \(index + 1), \(rule.name), \(rule.isEnabled ? "enabled" : "disabled"), \(conditionSummary(rule)), Profile \(displayNames[rule.profileID] ?? "Unknown")"
                            )
                            Text("\(index + 1)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name)
                                Text(conditionSummary(rule))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(displayNames[rule.profileID] ?? "Unknown Profile")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .accessibilityHidden(true)
                        }
                        .tag(rule.id)
                        .contextMenu {
                            Button("Edit") { appState.requestEditor(.editRule(rule.id)) }
                            Button("Duplicate") { appState.requestEditor(.duplicateRule(rule.id)) }
                            Button(rule.isEnabled ? "Disable" : "Enable") {
                                var updated = RuleDraft(rule: rule)
                                updated.isEnabled.toggle()
                                Task { await appState.saveRule(updated) }
                            }
                            Button("Move Up") { move(rule.id, offset: -1) }.disabled(index == 0)
                            Button("Move Down") { move(rule.id, offset: 1) }
                                .disabled(index == appState.rules.count - 1)
                            Divider()
                            Button("Delete", role: .destructive) {
                                deletionRequest = rule
                            }
                        }
                    }
                    .onMove(perform: reorder)
                }
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                .disabled(appState.isPerformingAction)

                Group {
                    if let rule = selectedRule {
                        Form {
                            detailRow("Name", value: rule.name)
                            detailRow("Enabled", value: rule.isEnabled ? "Yes" : "No")
                            detailRow("Conditions", value: conditionSummary(rule))
                            detailRow("Profile", value: displayNames[rule.profileID] ?? "Unknown")
                            HStack {
                                Spacer()
                                Button("Edit") { appState.requestEditor(.editRule(rule.id)) }
                            }
                        }
                        .formStyle(.grouped)
                        .padding()
                    } else {
                        ContentUnavailableView {
                            Label(
                                appState.rules.isEmpty ? "No Rules" : "Select a Rule",
                                systemImage: "arrow.triangle.branch"
                            )
                        } description: {
                            if appState.rules.isEmpty {
                                Text("Automatic mode uses \(defaultProfileName) when no Rule matches.")
                            }
                        } actions: {
                            if appState.rules.isEmpty {
                                Button("Create Rule") { appState.requestEditor(.newRule) }
                            }
                        }
                    }
                }
                .frame(minWidth: 260, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var selectedRule: DNSRule? { appState.rules.first { $0.id == selection } }
    private var displayNames: [DNSProfile.ID: String] {
        ProfileDisplayIdentity.displayNames(for: appState.profiles)
    }

    private func conditionSummary(_ rule: DNSRule) -> String {
        var values = rule.conditions.ssids
        values += rule.conditions.interfaceTypes.map(\.rawValue).sorted()
        values += rule.conditions.subnets.map(\.stringValue)
        return values.joined(separator: ", ")
    }

    private func detailRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(value)
        }
    }

    private func move(_ id: DNSRule.ID, offset: Int) {
        guard !appState.isPerformingAction else { return }
        guard let index = appState.rules.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard appState.rules.indices.contains(destination) else { return }
        var ids = appState.rules.map(\.id)
        ids.swapAt(index, destination)
        Task { await appState.reorderRules(ids) }
    }

    private func reorder(from offsets: IndexSet, to destination: Int) {
        guard !appState.isPerformingAction else { return }
        var ids = appState.rules.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        Task { await appState.reorderRules(ids) }
    }

    private var defaultProfileName: String {
        guard let profileID = appState.configuration?.defaultProfileID else { return "the Default Profile" }
        return displayNames[profileID] ?? "the Default Profile"
    }

    private func handleEditorRequest(_ request: ProductEditorRequest?) {
        guard let request else { return }
        switch request.kind {
        case .newRule:
            draft = RuleDraft(profileID: appState.configuration?.defaultProfileID)
        case let .editRule(ruleID):
            guard let rule = appState.rules.first(where: { $0.id == ruleID }) else {
                appState.consumeEditorRequest(request.id)
                return
            }
            draft = RuleDraft(rule: rule)
        case let .duplicateRule(ruleID):
            guard let rule = appState.rules.first(where: { $0.id == ruleID }) else {
                appState.consumeEditorRequest(request.id)
                return
            }
            var duplicate = RuleDraft(rule: rule)
            duplicate.id = UUID()
            duplicate.name = "\(rule.name) Copy"
            draft = duplicate
        case .newProfile, .editProfile, .duplicateProfile:
            return
        }
        appState.beginDraft(.rule)
        appState.consumeEditorRequest(request.id)
    }
}

@MainActor
private struct RuleEditorView: View {
    private enum Field: Hashable {
        case name
        case conditions
        case profile
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State var draft: RuleDraft
    @State private var validationError: RuleDraftError?
    @State private var operationFailure: ProductActionFailure?
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $draft.name)
                    .focused($focusedField, equals: .name)
                fieldError(.name)
                Toggle("Enabled", isOn: $draft.isEnabled)
                StringListEditor(
                    label: "Wi-Fi Networks",
                    itemLabel: "Wi-Fi Network",
                    addLabel: "Add Network",
                    values: $draft.ssids
                )
                Toggle("Wi-Fi", isOn: interfaceBinding(.wifi))
                Toggle("Ethernet", isOn: interfaceBinding(.wiredEthernet))
                Toggle("Other Interfaces", isOn: interfaceBinding(.other))
                StringListEditor(
                    label: "IP Subnets",
                    itemLabel: "IP Subnet",
                    addLabel: "Add Subnet",
                    values: $draft.subnets,
                    normalize: normalizeSubnet
                )
                    .focused($focusedField, equals: .conditions)
                fieldError(.conditions)
                Picker("Use Profile", selection: $draft.profileID) {
                    ForEach(appState.profiles) { profile in
                        Text(displayNames[profile.id] ?? profile.name).tag(Optional(profile.id))
                    }
                }
                .focused($focusedField, equals: .profile)
                fieldError(.profile)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    validateAndSave()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 460)
        .disabled(appState.isPerformingAction)
        .onAppear { appState.beginDraft(.rule) }
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

    private func interfaceBinding(_ type: NetworkInterfaceType) -> Binding<Bool> {
        Binding(
            get: { draft.interfaceTypes.contains(type) },
            set: { enabled in
                if enabled { draft.interfaceTypes.insert(type) }
                else { draft.interfaceTypes.remove(type) }
            }
        )
    }

    private var displayNames: [DNSProfile.ID: String] {
        ProfileDisplayIdentity.displayNames(for: appState.profiles)
    }

    private func normalizeSubnet(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? IPNetwork(trimmed))?.stringValue
    }

    private func validateAndSave() {
        do {
            _ = try draft.rule()
            validationError = nil
        } catch let error as RuleDraftError {
            validationError = error
            focusedField = field(for: error)
            return
        } catch {
            return
        }
        Task {
            switch await appState.saveRule(draft) {
            case .completed:
                dismiss()
            case let .failed(failure):
                appState.clearActionFailure()
                operationFailure = failure
            }
        }
    }

    private func field(for error: RuleDraftError) -> Field {
        switch error {
        case .emptyName: .name
        case .missingConditions, .invalidSubnet: .conditions
        case .missingProfile: .profile
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
