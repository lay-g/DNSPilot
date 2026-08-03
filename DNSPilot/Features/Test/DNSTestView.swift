import SwiftUI

@MainActor
struct DNSTestView: View {
    private enum ServerSource: String, CaseIterable, Identifiable {
        case profile = "Profile"
        case custom = "Custom"

        var id: Self { self }
    }

    private enum Field: Hashable {
        case domain
    }

    @EnvironmentObject private var appState: AppState
    @State private var source = ServerSource.profile
    @State private var profileID: DNSProfile.ID?
    @State private var customDraft = ProfileDraft(name: "Custom DNS")
    @State private var domain = ""
    @State private var queryType = DNSQueryType.a
    @State private var validationMessage: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Form {
                    Section("DNS Server") {
                        Picker("Source", selection: $source) {
                            ForEach(ServerSource.allCases) { value in
                                Text(value.rawValue).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch source {
                        case .profile:
                            Picker("Profile", selection: $profileID) {
                                if appState.profiles.isEmpty {
                                    Text("No Profiles").tag(Optional<DNSProfile.ID>.none)
                                } else {
                                    ForEach(appState.profiles) { profile in
                                        Text(displayNames[profile.id] ?? profile.name)
                                            .tag(Optional(profile.id))
                                    }
                                }
                            }
                        case .custom:
                            customServerFields
                        }

                        if showsPlainDNSProxyWarning {
                            Label {
                                Text(
                                    "DNS Proxy is on. Plain DNS queries on port 53 may be routed through the Active Profile instead of directly to this server."
                                )
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(
                                "Warning: DNS Proxy is on. Plain DNS queries on port 53 may be routed through the Active Profile instead of directly to this server."
                            )
                        }
                    }

                    Section("Request") {
                        TextField("Domain", text: $domain, prompt: Text("example.com"))
                            .focused($focusedField, equals: .domain)
                        Picker("Record Type", selection: $queryType) {
                            ForEach(DNSQueryType.allCases) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        if let validationMessage {
                            Text(validationMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityLabel("Error: \(validationMessage)")
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(isRunning)

                Divider()
                HStack {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                        Text("Querying")
                            .foregroundStyle(.secondary)
                        Button("Cancel") {
                            appState.cancelDNSTest()
                        }
                    }
                    Spacer()
                    Button("Query") {
                        startQuery()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || (source == .profile && selectedProfile == nil))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .frame(minWidth: 0, idealWidth: 360, maxWidth: 520, maxHeight: .infinity)

            ZStack {
                resultContent
            }
            .frame(minWidth: 0, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("DNS Test")
        .onAppear { selectPreferredProfileIfNeeded() }
        .onChange(of: appState.profiles.map(\.id)) { _, _ in
            selectPreferredProfileIfNeeded()
        }
        .onDisappear {
            if isRunning {
                appState.cancelDNSTest()
            }
        }
    }

    @ViewBuilder
    private var customServerFields: some View {
        Picker("Protocol", selection: $customDraft.transport) {
            Text("Plain DNS").tag(ProfileTransport.plain)
            Text("DNS over TLS").tag(ProfileTransport.tls)
            Text("DNS over HTTPS").tag(ProfileTransport.https)
        }
        .pickerStyle(.segmented)

        switch customDraft.transport {
        case .plain:
            TextField(
                "Server Address",
                text: $customDraft.plainServerAddress,
                prompt: Text("1.1.1.1")
            )
            TextField("Port", value: $customDraft.plainPort, format: .number)
        case .tls:
            TextField(
                "Server Name or Address",
                text: $customDraft.dotServerName,
                prompt: Text("dns.example.com")
            )
            TextField("Port", value: $customDraft.dotPort, format: .number)
            bootstrapEditor
        case .https:
            TextField(
                "Endpoint URL",
                text: $customDraft.endpointURL,
                prompt: Text("https://dns.example.com/dns-query")
            )
            bootstrapEditor
        }
    }

    private var bootstrapEditor: some View {
        StringListEditor(
            label: "Bootstrap Servers",
            itemLabel: "Bootstrap Server",
            addLabel: "Add Bootstrap Server",
            values: $customDraft.bootstrapServers,
            normalize: normalizeIPAddress,
            itemPrompt: "1.1.1.1"
        )
    }

    @ViewBuilder
    private var resultContent: some View {
        switch appState.dnsTestState {
        case .idle:
            ContentUnavailableView {
                Label("No Query Result", systemImage: "magnifyingglass")
            }
        case .running:
            ProgressView("Waiting for DNS Response")
        case let .failed(message):
            ContentUnavailableView {
                Label("DNS Query Failed", systemImage: "xmark.circle")
            } description: {
                Text(message)
            }
        case let .response(result):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(
                        result.status,
                        systemImage: result.status == "NOERROR"
                            ? "checkmark.circle"
                            : "exclamationmark.circle"
                    )
                    .font(.headline)
                    .foregroundStyle(result.status == "NOERROR" ? .green : .orange)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        resultRow("Server", result.server)
                        resultRow("Duration", "\(result.elapsedMilliseconds) ms")
                        resultRow("Query", "\(result.domain)  \(result.type.rawValue)")
                        resultRow(
                            "Transfer",
                            "\(result.bytesSent) B sent, \(result.bytesReceived) B received"
                        )
                    }

                    Divider()
                    Text("Answer")
                        .font(.headline)
                    Text(result.answer.isEmpty ? "No records returned." : result.answer)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
        }
    }

    private func resultRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isRunning: Bool {
        appState.dnsTestState == .running
    }

    private var selectedProfile: DNSProfile? {
        guard let profileID else { return nil }
        return appState.profiles.first { $0.id == profileID }
    }

    private var showsPlainDNSProxyWarning: Bool {
        guard case .active = appState.proxy.state else { return false }
        switch source {
        case .profile:
            guard let selectedProfile else { return false }
            if case .plain = selectedProfile.upstream { return true }
            return false
        case .custom:
            return customDraft.transport == .plain
        }
    }

    private var displayNames: [DNSProfile.ID: String] {
        ProfileDisplayIdentity.displayNames(for: appState.profiles)
    }

    private func selectPreferredProfileIfNeeded() {
        if let profileID, appState.profiles.contains(where: { $0.id == profileID }) {
            return
        }
        profileID = [
            appState.proxy.activeProfileID,
            appState.configuration?.defaultProfileID,
            appState.profiles.first?.id,
        ].compactMap { $0 }.first { id in
            appState.profiles.contains { $0.id == id }
        }
        if profileID == nil {
            source = .custom
        }
    }

    private func startQuery() {
        do {
            let upstream: DNSUpstream
            switch source {
            case .profile:
                guard let selectedProfile else {
                    validationMessage = "Choose a Profile."
                    return
                }
                upstream = selectedProfile.upstream
            case .custom:
                upstream = try customDraft.profile().upstream
            }
            let request = try DNSQueryRequest(
                domain: domain,
                type: queryType,
                upstream: upstream
            )
            validationMessage = nil
            appState.startDNSTest(request)
        } catch let error as LocalizedError {
            validationMessage = error.errorDescription ?? "Invalid DNS query."
            if error is DNSQueryRequestError {
                focusedField = .domain
            }
        } catch {
            validationMessage = "Invalid DNS query."
        }
    }

    private func normalizeIPAddress(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? IPAddress(trimmed))?.stringValue
    }
}
