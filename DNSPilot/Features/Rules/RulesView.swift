import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct RulesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: DNSRule.ID?
    @State private var draft: RuleDraft?
    @State private var deletionRequest: DNSRule?
    @FocusState private var focusedRule: DNSRule.ID?
    @State private var draggingRuleID: DNSRule.ID?
    @State private var dropIndicator: RuleDropIndicator?
    @State private var rowHeights: [DNSRule.ID: CGFloat] = [:]

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
        Form {
            Section {
                LabeledContent("Default Profile") {
                    Picker("Default Profile", selection: Binding(
                        get: { appState.configuration?.defaultProfileID ?? appState.profiles[0].id },
                        set: { id in Task { await appState.setDefaultProfile(id) } }
                    )) {
                        ForEach(appState.profiles) { profile in
                            Text(displayNames[profile.id] ?? profile.name).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(appState.isPerformingAction)
                }
            } header: {
                Text("Fallback")
            } footer: {
                Text("Used in Automatic mode when no enabled Rule matches.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if appState.rules.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Rules").font(.headline)
                        Text("Automatic mode uses \(defaultProfileName) on every network.")
                            .foregroundStyle(.secondary)
                        Button("Create Rule") { appState.requestEditor(.newRule) }
                    }
                    .padding(.vertical, 4)
                }
                ForEach(Array(appState.rules.enumerated()), id: \.element.id) { index, rule in
                    ruleRow(rule, index: index)
                }
                .disabled(appState.isPerformingAction)
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Rules")
                    Spacer()
                    Text(isManualMode
                        ? "Paused in Manual mode"
                        : "Checked from top to bottom. The first match wins.")
                        .font(.callout)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Every condition type you set must match. Within a type, any listed value matches. Drag to reorder; double-click to edit.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .contentMargins(.bottom, 56, for: .scrollContent)
        .onChange(of: focusedRule) { _, id in
            if let id { selection = id }
        }
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            ListActionBar {
                Button {
                    appState.requestEditor(.newRule)
                } label: {
                    Label("New Rule", systemImage: "plus")
                }
                .help("New Rule")
                Button {
                    deletionRequest = selectedRule
                } label: {
                    Label("Delete Rule", systemImage: "minus")
                }
                .help("Delete Rule")
                .disabled(selectedRule == nil)
                Divider().frame(height: 14)
                Button {
                    if let selection { move(selection, offset: -1) }
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .help("Move Up")
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(selectedIndex.map { $0 == 0 } ?? true)
                Button {
                    if let selection { move(selection, offset: 1) }
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .help("Move Down")
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(selectedIndex.map { $0 == appState.rules.count - 1 } ?? true)
                Divider().frame(height: 14)
                Button {
                    if let selection { appState.requestEditor(.editRule(selection)) }
                } label: {
                    Label("Edit Rule", systemImage: "pencil")
                }
                .help("Edit Rule")
                .disabled(selectedRule == nil)
            }
            .disabled(appState.isPerformingAction)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private func ruleRow(_ rule: DNSRule, index: Int) -> some View {
        let matches = isMatchingRule(rule.id)
        let isSelected = selection == rule.id
        let profileName = displayNames[rule.profileID] ?? "Unknown Profile"
        return HStack(spacing: 10) {
            Toggle("Enable \(rule.name)", isOn: Binding(
                get: { rule.isEnabled },
                set: { enabled in
                    var updated = RuleDraft(rule: rule)
                    updated.isEnabled = enabled
                    Task { await appState.saveRule(updated) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(
                "Priority \(index + 1), \(rule.name), \(rule.isEnabled ? "enabled" : "disabled"), \(conditionSummary(rule)), Profile \(profileName)\(matches ? ", matches the current network" : "")"
            )
            Text("\(index + 1)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 16, alignment: .trailing)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if matches {
                        Label("Matches Now", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                Text(conditionSummary(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(rule.isEnabled ? 1 : 0.55)
            .accessibilityHidden(true)
            Spacer(minLength: 8)
            Label(profileName, systemImage: "arrow.right")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(rule.isEnabled ? 1 : 0.55)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : .clear,
            in: .rect(cornerRadius: 10)
        )
        .padding(.horizontal, -8)
        .padding(.vertical, -4)
        .overlay(alignment: dropIndicator?.edge == .below ? .bottom : .top) {
            if dropIndicator?.ruleID == rule.id {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .offset(y: dropIndicator?.edge == .below ? 6 : -6)
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            rowHeights[rule.id] = height
        }
        .contentShape(.rect)
        .focusable()
        .focused($focusedRule, equals: rule.id)
        .focusEffectDisabled()
        .onTapGesture(count: 2) { appState.requestEditor(.editRule(rule.id)) }
        .onTapGesture {
            selection = rule.id
            focusedRule = rule.id
        }
        .onKeyPress(.return) {
            appState.requestEditor(.editRule(rule.id))
            return .handled
        }
        .onKeyPress(.delete) {
            deletionRequest = rule
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            // Modified arrows stay with the Move Up/Down shortcuts.
            guard press.modifiers.isEmpty else { return .ignored }
            selectAdjacentRule(to: rule.id, offset: press.key == .upArrow ? -1 : 1)
            return .handled
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Edit") { appState.requestEditor(.editRule(rule.id)) }
        .onDrag {
            draggingRuleID = rule.id
            return NSItemProvider(object: rule.id.uuidString as NSString)
        } preview: {
            Label(rule.name, systemImage: "line.3.horizontal")
                .padding(8)
                .background(.regularMaterial, in: .rect(cornerRadius: 8))
        }
        .onDrop(of: [.utf8PlainText], delegate: RuleDropDelegate(
            targetID: rule.id,
            rowHeight: rowHeights[rule.id] ?? 44,
            draggingRuleID: $draggingRuleID,
            indicator: $dropIndicator,
            perform: moveRule
        ))
        .contextMenu {
            Button("Edit…") { appState.requestEditor(.editRule(rule.id)) }
            Button("Duplicate") { appState.requestEditor(.duplicateRule(rule.id)) }
            Button(rule.isEnabled ? "Disable" : "Enable") {
                var updated = RuleDraft(rule: rule)
                updated.isEnabled.toggle()
                Task { await appState.saveRule(updated) }
            }
            Divider()
            Button("Move Up") { move(rule.id, offset: -1) }.disabled(index == 0)
            Button("Move Down") { move(rule.id, offset: 1) }
                .disabled(index == appState.rules.count - 1)
            Divider()
            Button("Delete…", role: .destructive) {
                deletionRequest = rule
            }
        }
    }

    /// Moves a dragged Rule above or below the drop target; saves and reevaluates once.
    private func moveRule(_ id: DNSRule.ID, to indicator: RuleDropIndicator) -> Bool {
        guard !appState.isPerformingAction,
              let source = appState.rules.firstIndex(where: { $0.id == id }),
              let target = appState.rules.firstIndex(where: { $0.id == indicator.ruleID }) else { return false }
        let insertion = indicator.edge == .below ? target + 1 : target
        // Dropping onto its own slot is a no-op.
        guard insertion != source, insertion != source + 1 else { return false }
        var ids = appState.rules.map(\.id)
        ids.move(fromOffsets: IndexSet(integer: source), toOffset: insertion)
        selection = id
        Task { await appState.reorderRules(ids) }
        return true
    }

    private func selectAdjacentRule(to id: DNSRule.ID, offset: Int) {
        guard let index = appState.rules.firstIndex(where: { $0.id == id }) else { return }
        let next = index + offset
        guard appState.rules.indices.contains(next) else { return }
        let nextID = appState.rules[next].id
        selection = nextID
        focusedRule = nextID
    }

    private var isManualMode: Bool {
        if case .manual = appState.configuration?.operatingMode { return true }
        return false
    }

    private func isMatchingRule(_ id: DNSRule.ID) -> Bool {
        if case let .rule(matchedID, _) = appState.selectionSource { return matchedID == id }
        return false
    }

    private var selectedIndex: Int? {
        appState.rules.firstIndex { $0.id == selection }
    }

    private var selectedRule: DNSRule? { appState.rules.first { $0.id == selection } }
    private var displayNames: [DNSProfile.ID: String] {
        ProfileDisplayIdentity.displayNames(for: appState.profiles)
    }

    private func conditionSummary(_ rule: DNSRule) -> String {
        var parts: [String] = []
        if !rule.conditions.ssids.isEmpty {
            parts.append("Wi-Fi \(rule.conditions.ssids.joined(separator: ", "))")
        }
        if !rule.conditions.interfaceTypes.isEmpty {
            let names = rule.conditions.interfaceTypes.map(\.displayName).sorted()
            parts.append("\(names.joined(separator: " or ")) interface")
        }
        if !rule.conditions.subnets.isEmpty {
            parts.append("Subnet \(rule.conditions.subnets.map(\.stringValue).joined(separator: ", "))")
        }
        return parts.isEmpty ? "Any network" : parts.joined(separator: " · ")
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
            Text(appState.rules.contains { $0.id == draft.id } ? "Edit Rule" : "New Rule")
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Office"))
                        .focused($focusedField, equals: .name)
                    fieldError(.name)
                    Toggle("Enabled", isOn: $draft.isEnabled)
                    Picker("Use Profile", selection: $draft.profileID) {
                        ForEach(appState.profiles) { profile in
                            Text(displayNames[profile.id] ?? profile.name).tag(Optional(profile.id))
                        }
                    }
                    .focused($focusedField, equals: .profile)
                    fieldError(.profile)
                }
                Section {
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
                        normalize: normalizeSubnet,
                        itemPrompt: "192.168.1.0/24"
                    )
                        .focused($focusedField, equals: .conditions)
                    fieldError(.conditions)
                } header: {
                    Text("Conditions")
                } footer: {
                    Text("Every condition type you set must match. Within a type, any listed value matches.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
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
        .frame(width: 540, height: 540)
        .disabled(appState.isPerformingAction)
        .onAppear { appState.beginDraft(.rule) }
        .alert(
            operationFailure?.title ?? "Rule Action Failed",
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
            Button("OK") { operationFailure = nil }
        } message: {
            Text(operationFailure?.message ?? "DNSPilot could not load the Rule failure details. Open Diagnostics for more information.")
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
            let outcome = appState.reportValidationFailure(error, action: .ruleSave)
            if case let .failed(failure) = outcome {
                appState.clearActionFailure()
                operationFailure = failure
            }
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

private struct RuleDropIndicator: Equatable {
    enum Edge: Equatable {
        case above
        case below
    }

    let ruleID: DNSRule.ID
    let edge: Edge
}

/// Tracks an in-window Rule drag over one row and reports whether it lands above or below it.
@MainActor
private struct RuleDropDelegate: DropDelegate {
    let targetID: DNSRule.ID
    let rowHeight: CGFloat
    @Binding var draggingRuleID: DNSRule.ID?
    @Binding var indicator: RuleDropIndicator?
    let perform: (DNSRule.ID, RuleDropIndicator) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        draggingRuleID != nil
    }

    func dropEntered(info: DropInfo) {
        updateIndicator(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if indicator?.ruleID == targetID { indicator = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            indicator = nil
            draggingRuleID = nil
        }
        guard let draggingRuleID else { return false }
        return perform(draggingRuleID, edge(for: info))
    }

    private func updateIndicator(_ info: DropInfo) {
        guard draggingRuleID != nil else { return }
        indicator = edge(for: info)
    }

    private func edge(for info: DropInfo) -> RuleDropIndicator {
        RuleDropIndicator(
            ruleID: targetID,
            edge: info.location.y > rowHeight / 2 ? .below : .above
        )
    }
}
