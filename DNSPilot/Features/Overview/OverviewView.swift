import SwiftUI

@MainActor
struct OverviewView: View {
    private enum Mode: Hashable {
        case automatic
        case manual
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var profileTestTask: Task<Void, Never>?
    @State private var profileTestStatus: ProfileTestStatus?
    @State private var testedProfile: DNSProfile?

    var body: some View {
        Form {
            Section { header }
            proxyResumeNotice
            proxyRecoveryActions
            extensionStatus
            networkStatusNotice
            modeSection
            selectionSection
            networkSection
            if let activeProfile {
                Section {
                    HStack(spacing: 10) {
                        Button("Test Active Profile") {
                            test(activeProfile)
                        }
                        .disabled(appState.configurationWritesLocked)
                        if testedProfile == activeProfile, let profileTestStatus {
                            ProfileTestStatusView(status: profileTestStatus)
                                .font(.callout)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Copy Diagnostic Summary") { appState.copyDiagnosticSummary() }
                    Button("Open Diagnostics Settings") { openDiagnostics() }
                    Divider()
                    Button("Restore System DNS") {
                        Task { await appState.restoreSystemDNS() }
                    }
                    .disabled(appState.isPerformingAction || appState.proxy.state == .disabled)
                } label: {
                    Label("More Actions", systemImage: "ellipsis")
                }
                .help("More Actions")
            }
        }
        .onDisappear {
            profileTestTask?.cancel()
            profileTestStatus = nil
            testedProfile = nil
        }
    }

    private var header: some View {
        let appearance = ProxyStatusAppearance(appState: appState)
        return HStack(spacing: 14) {
            ProxyStatusBadge(appearance: appearance)
            VStack(alignment: .leading, spacing: 2) {
                Text(appearance.title)
                    .font(.title2.weight(.bold))
                Text(appearance.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Toggle("DNS Proxy", isOn: Binding(
                get: { if case .active = appState.proxy.state { true } else { false } },
                set: { enabled in
                    Task {
                        if enabled { await appState.turnOnDNSProxy() }
                        else { await appState.restoreSystemDNS() }
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.large)
            .labelsHidden()
            .accessibilityLabel("DNS Proxy")
            .disabled(
                appState.configurationWritesLocked
                    || appState.profiles.isEmpty
                    || appState.proxyResumeState != .none
            )
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var proxyResumeNotice: some View {
        switch appState.proxyResumeState {
        case .none:
            EmptyView()
        case .waitingForExtension:
            Section {
                StatusNotice(
                    "Waiting for System Extension",
                    message: "DNSPilot restores the DNS Proxy when the extension is ready.",
                    symbolName: "puzzlepiece.extension",
                    tint: .secondary
                )
            }
        case .waitingForNetwork:
            Section {
                StatusNotice(
                    "Waiting for Network to Restore DNS Proxy",
                    message: "DNSPilot restores the DNS Proxy when a network becomes available.",
                    symbolName: "network.slash",
                    tint: .secondary
                )
            }
        case .restoring:
            Section {
                StatusNotice(
                    "Restoring DNS Proxy",
                    message: "DNSPilot is restoring the DNS Proxy state from the last session.",
                    symbolName: "arrow.clockwise",
                    tint: .accentColor
                )
            }
        case .failed(.managerChanged):
            Section {
                StatusNotice(
                    "DNS Proxy Configuration Changed",
                    message: "System DNS remains active. Keep System DNS, then turn on DNS Proxy to use the current configuration.",
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .orange
                ) {
                    Button("Keep System DNS") {
                        Task { await appState.keepSystemDNSAfterResumeFailure() }
                    }
                }
                .disabled(appState.isPerformingAction)
            }
        case .failed:
            Section {
                StatusNotice(
                    "DNS Proxy Was Not Restored",
                    message: "System DNS remains active. Retry after resolving the current configuration or Extension issue.",
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .orange
                ) {
                    Button("Retry") { Task { await appState.retryProxyResume() } }
                    Button("Keep System DNS") {
                        Task { await appState.keepSystemDNSAfterResumeFailure() }
                    }
                }
                .disabled(appState.isPerformingAction)
            }
        }
    }

    @ViewBuilder
    private var proxyRecoveryActions: some View {
        if case .recoveryRequired = appState.proxy.state {
            Section {
                StatusNotice(
                    "DNS Proxy State Cannot Be Confirmed",
                    message: "Ownership or manager state changed outside DNSPilot. Reconnect to verify it, or restore System DNS.",
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .orange
                ) {
                    Button("Reconnect") { Task { await appState.reconnect() } }
                    Button("Restore System DNS") { Task { await appState.restoreSystemDNS() } }
                    Button("Open Diagnostics") { openDiagnostics() }
                }
                .disabled(appState.isPerformingAction)
            }
        } else if let switchFailure = appState.proxy.lastSwitchFailure {
            let failure = switchFailure.productActionFailure
            Section {
                StatusNotice(
                    failure.title,
                    message: failure.message,
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .orange
                ) {
                    Button("Retry") {
                        Task { await appState.turnOnDNSProxy() }
                    }
                    if let activeProfileID = appState.proxy.activeProfileID,
                       case let .manual(targetProfileID) = appState.configuration?.operatingMode,
                       targetProfileID != activeProfileID {
                        Button("Use Active Profile (Manual)") {
                            Task {
                                await appState.setOperatingMode(.manual(profileID: activeProfileID))
                            }
                        }
                    }
                    if failure.recoveryActions.contains(.restoreSystemDNS) {
                        Button("Restore System DNS") {
                            Task { await appState.restoreSystemDNS() }
                        }
                    }
                    if failure.recoveryActions.contains(.openDiagnostics) {
                        Button("Open Diagnostics") { openDiagnostics() }
                    }
                }
                .disabled(appState.isPerformingAction)
            }
        } else {
            switch appState.proxy.state {
            case .failed, .degraded:
                Section {
                    StatusNotice(
                        proxyStateFailed ? "DNS Proxy Did Not Start" : "DNS Proxy Is Limited",
                        message: proxyStateFailureMessage,
                        symbolName: "xmark.octagon.fill",
                        tint: proxyStateFailed ? .red : .orange
                    ) {
                        Button("Retry") { Task { await appState.turnOnDNSProxy() } }
                        Button("Open Diagnostics") { openDiagnostics() }
                    }
                    .disabled(appState.isPerformingAction)
                }
            case .disabled, .preparing, .applying, .repairing, .active, .stopping,
                 .recoveryRequired:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var networkStatusNotice: some View {
        if case .automatic = appState.configuration?.operatingMode,
           appState.network?.status != .satisfied {
            Section {
                StatusNotice(
                    "Waiting for Network",
                    message: "Automatic mode chooses a Profile when a network becomes available.",
                    symbolName: "network.slash",
                    tint: .secondary
                )
            }
        }
    }

    private var modeSection: some View {
        Section {
            Picker("Selection", selection: Binding(
                get: {
                    if case .manual = appState.configuration?.operatingMode { Mode.manual }
                    else { Mode.automatic }
                },
                set: { mode in
                    Task {
                        switch mode {
                        case .automatic:
                            await appState.setOperatingMode(.automatic)
                        case .manual:
                            if let profileID = appState.proxy.activeProfileID
                                ?? appState.configuration?.defaultProfileID {
                                await appState.setOperatingMode(.manual(profileID: profileID))
                            }
                        }
                    }
                }
            )) {
                Text("Automatic").tag(Mode.automatic)
                Text("Manual").tag(Mode.manual)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            if case let .manual(profileID) = appState.configuration?.operatingMode {
                Picker("Manual Profile", selection: Binding(
                    get: { profileID },
                    set: { id in Task { await appState.setOperatingMode(.manual(profileID: id)) } }
                )) {
                    ForEach(appState.profiles) { profile in
                        Text(displayNames[profile.id] ?? profile.name).tag(profile.id)
                    }
                }
            }
        } header: {
            Text("Mode")
        } footer: {
            Text(modeFooter)
                .foregroundStyle(.secondary)
        }
        .disabled(appState.configurationWritesLocked)
    }

    private var modeFooter: String {
        if case .manual = appState.configuration?.operatingMode {
            return "Manual selection stays until you return to Automatic."
        }
        return "The first enabled Rule that matches the current network wins. Otherwise the Default Profile is used."
    }

    @ViewBuilder
    private var extensionStatus: some View {
        switch appState.systemExtensionState {
        case .active:
            EmptyView()
        case .awaitingApproval:
            Section {
                StatusNotice(
                    "System Extension Approval Required",
                    message: "Allow the DNSPilot extension in System Settings, then check again.",
                    symbolName: "puzzlepiece.extension.fill",
                    tint: .orange
                ) {
                    Button("Open System Settings") { appState.openSystemExtensionSettings() }
                    Button("Check Again") { appState.synchronizeSystemExtension() }
                }
            }
        case .notInstalled, .inactive:
            Section {
                StatusNotice(
                    "System Extension Required",
                    message: "The DNS Proxy extension is not installed. Resume setup to install it.",
                    symbolName: "puzzlepiece.extension.fill",
                    tint: .orange
                ) {
                    Button("Resume Setup") { appState.requestSetupWindow() }
                }
            }
        case .failed:
            Section {
                StatusNotice(
                    "System Extension Request Failed",
                    message: appState.systemExtensionState.userDescription,
                    symbolName: "xmark.octagon.fill",
                    tint: .red
                ) {
                    Button("Open System Settings") { appState.openSystemExtensionSettings() }
                    Button("Retry") { appState.installSystemExtension() }
                }
            }
        case .updateRequired:
            Section {
                StatusNotice(
                    "System Extension Update Required",
                    message: "DNSPilot restores System DNS, updates the extension, and then resumes the previous state.",
                    symbolName: "arrow.down.circle.fill",
                    tint: .accentColor
                ) {
                    Button("Update Safely") {
                        Task { await appState.updateSystemExtensionSafely() }
                    }
                    .disabled(appState.systemExtensionRequestInProgress)
                }
            }
        case .updateFailed:
            Section {
                StatusNotice(
                    "System Extension Update Failed",
                    message: appState.systemExtensionState.userDescription,
                    symbolName: "xmark.octagon.fill",
                    tint: .red
                ) {
                    Button("Retry Safely") {
                        Task { await appState.updateSystemExtensionSafely() }
                    }
                    .disabled(appState.systemExtensionRequestInProgress)
                }
            }
        case .downgradeBlocked:
            Section {
                StatusNotice(
                    "System Extension",
                    message: "A newer DNSPilot build is required.",
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
        case .checking, .activating, .deactivating, .uninstalling, .restartRequired:
            Section {
                LabeledContent("System Extension", value: appState.systemExtensionState.userDescription)
            }
        }
    }

    private var selectionSection: some View {
        Section("Current Selection") {
            LabeledContent("Active Profile") {
                if let activeProfileID = appState.proxy.activeProfileID {
                    Button(profileName(activeProfileID) ?? "Unknown Profile") {
                        appState.navigateToProfile(activeProfileID)
                    }
                    .buttonStyle(.link)
                } else {
                    Text("System DNS")
                }
            }
            if let target = appState.proxy.targetProfileID, target != appState.proxy.activeProfileID {
                LabeledContent("Target Profile") {
                    Text(profileName(target) ?? "Unknown Profile")
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent("Selected By") {
                switch appState.selectionSource {
                case let .rule(id, name):
                    Button("Rule \u{201C}\(name)\u{201D}") { appState.navigateToRule(id) }
                        .buttonStyle(.link)
                case .defaultProfile:
                    if let profileID = appState.configuration?.defaultProfileID {
                        Button("Default Profile") { appState.navigateToProfile(profileID) }
                            .buttonStyle(.link)
                    }
                case .manual, .unavailable:
                    Text(appState.selectionSource.label)
                }
            }
        }
    }

    private var networkSection: some View {
        Section("Network") {
            LabeledContent {
                Text(wifiSummary)
            } label: {
                Label("Wi-Fi", systemImage: "wifi")
            }
            if appState.network?.ssidAvailability == .permissionDenied {
                Button("Open System Settings") { appState.openLocationSettings() }
            }
            LabeledContent {
                Text(interfaceSummary)
            } label: {
                Label("Interfaces", systemImage: "network")
            }
            LabeledContent {
                Text(addressSummary)
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            } label: {
                Label("Addresses", systemImage: "number")
            }
        }
    }

    private var displayNames: [DNSProfile.ID: String] {
        ProfileDisplayIdentity.displayNames(for: appState.profiles)
    }

    private func profileName(_ id: DNSProfile.ID?) -> String? {
        id.flatMap { displayNames[$0] }
    }

    private var activeProfile: DNSProfile? {
        guard let profileID = appState.proxy.activeProfileID else { return nil }
        return appState.profiles.first { $0.id == profileID }
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

    private var wifiSummary: String {
        if let ssid = appState.network?.ssid { return ssid }
        return switch appState.network?.ssidAvailability {
        case .permissionNotDetermined: "Permission Required"
        case .permissionDenied: "Permission Denied"
        case .notOnWiFi: "Not Connected to Wi-Fi"
        case .temporarilyUnavailable: "Unavailable"
        case .available: "Unavailable"
        case nil: "Checking"
        }
    }

    private var interfaceSummary: String {
        let values = appState.network?.activeInterfaceTypes.map { type -> String in
            return switch type {
            case .wifi: "Wi-Fi"
            case .wiredEthernet: "Ethernet"
            case .other: "Other"
            }
        }.sorted() ?? []
        return values.isEmpty ? "None" : values.joined(separator: ", ")
    }

    private var addressSummary: String {
        let values = appState.network?.addresses.map(\.address.stringValue) ?? []
        return values.isEmpty ? "None" : values.joined(separator: "\n")
    }

    private var proxyStateFailed: Bool {
        if case .failed = appState.proxy.state { return true }
        return false
    }

    private func openDiagnostics() {
        appState.selectSettingsSection(.diagnostics)
        openSettings()
    }

    private var proxyStateFailureMessage: String {
        switch appState.proxy.state {
        case .failed:
            "DNS Proxy did not confirm an active Profile. Retry or review Diagnostics before changing configuration."
        case .degraded:
            "DNS Proxy is running in a limited state. Review Diagnostics, then retry or restore System DNS."
        case .disabled, .preparing, .applying, .repairing, .active, .stopping,
             .recoveryRequired:
            ""
        }
    }
}
