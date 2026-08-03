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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                proxyResumeNotice
                proxyRecoveryActions
                extensionStatus
                networkStatusNotice
                Divider()
                modeSection
                selectionSection
                networkSection
                Divider()
                HStack {
                    Spacer()
                    if let activeProfile {
                        Button("Test Active Profile") {
                            test(activeProfile)
                        }
                        .disabled(appState.configurationWritesLocked)
                        if testedProfile == activeProfile, let profileTestStatus {
                            ProfileTestStatusView(status: profileTestStatus)
                                .font(.caption)
                        }
                    }
                    Menu {
                        Button("Copy Diagnostic Summary") { appState.copyDiagnosticSummary() }
                        Button("Restore System DNS") {
                            Task { await appState.restoreSystemDNS() }
                        }
                        .disabled(appState.isPerformingAction || appState.proxy.state == .disabled)
                        Button("Open Diagnostics Settings") { openDiagnostics() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("More Actions")
                    .accessibilityLabel("More Actions")
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("Overview")
        .onDisappear {
            profileTestTask?.cancel()
            profileTestStatus = nil
            testedProfile = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(appState.menuPresentation?.statusText ?? "DNS Proxy Off")
                        .font(.title2.weight(.semibold))
                    Text(appState.menuPresentation?.profileLines.first ?? "System DNS is active")
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: appState.menuPresentation?.symbolName ?? "network.slash")
                    .font(.title2)
            }
            Spacer()
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
            .disabled(
                appState.configurationWritesLocked
                    || appState.profiles.isEmpty
                    || appState.proxyResumeState != .none
            )
        }
    }

    @ViewBuilder
    private var proxyResumeNotice: some View {
        switch appState.proxyResumeState {
        case .none:
            EmptyView()
        case .waitingForExtension:
            Label("Waiting for System Extension", systemImage: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
        case .waitingForNetwork:
            Label("Waiting for Network to Restore DNS Proxy", systemImage: "network.slash")
                .foregroundStyle(.secondary)
        case .restoring:
            Label("Restoring DNS Proxy", systemImage: "arrow.clockwise")
                .foregroundStyle(.secondary)
        case .failed(.managerChanged):
            VStack(alignment: .leading, spacing: 8) {
                Text("DNS Proxy Configuration Changed").font(.headline)
                Text("System DNS remains active. Keep System DNS, then turn on DNS Proxy to use the current configuration.")
                    .foregroundStyle(.secondary)
                Button("Keep System DNS") {
                    Task { await appState.keepSystemDNSAfterResumeFailure() }
                }
            }
            .disabled(appState.isPerformingAction)
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text("DNS Proxy Was Not Restored").font(.headline)
                Text("System DNS remains active. Retry after resolving the current configuration or Extension issue.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Retry") { Task { await appState.retryProxyResume() } }
                    Button("Keep System DNS") {
                        Task { await appState.keepSystemDNSAfterResumeFailure() }
                    }
                }
            }
            .disabled(appState.isPerformingAction)
        }
    }

    @ViewBuilder
    private var proxyRecoveryActions: some View {
        if case .recoveryRequired = appState.proxy.state {
            VStack(alignment: .leading, spacing: 8) {
                Text("DNS Proxy state cannot be confirmed because ownership or manager state changed outside DNSPilot.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reconnect") { Task { await appState.reconnect() } }
                    Button("Restore System DNS") { Task { await appState.restoreSystemDNS() } }
                    Button("Open Diagnostics") { openDiagnostics() }
                }
            }
            .disabled(appState.isPerformingAction)
        } else if let switchFailure = appState.proxy.lastSwitchFailure {
            let failure = switchFailure.productActionFailure
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.title).font(.headline)
                Text(failure.message).foregroundStyle(.secondary)
                HStack {
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
            }
            .disabled(appState.isPerformingAction)
        } else {
            switch appState.proxy.state {
            case .failed, .degraded:
                VStack(alignment: .leading, spacing: 8) {
                    Text(proxyStateFailureMessage).foregroundStyle(.secondary)
                    HStack {
                        Button("Retry") { Task { await appState.turnOnDNSProxy() } }
                        Button("Open Diagnostics") { openDiagnostics() }
                    }
                }
                .disabled(appState.isPerformingAction)
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
            Label("Waiting for Network", systemImage: "network.slash")
                .foregroundStyle(.secondary)
        }
    }

    private var modeSection: some View {
        Form {
            Picker("Mode", selection: Binding(
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
        }
        .formStyle(.grouped)
        .disabled(appState.configurationWritesLocked)
    }

    @ViewBuilder
    private var extensionStatus: some View {
        switch appState.systemExtensionState {
        case .active:
            EmptyView()
        case .awaitingApproval:
            LabeledContent("System Extension Approval Required") {
                HStack {
                    Button("Open System Settings") { appState.openSystemExtensionSettings() }
                    Button("Check Again") { appState.synchronizeSystemExtension() }
                }
            }
        case .notInstalled, .inactive:
            LabeledContent("System Extension Required") {
                Button("Resume Setup") { appState.requestSetupWindow() }
            }
        case .failed:
            LabeledContent("System Extension Request Failed") {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(appState.systemExtensionState.userDescription)
                    HStack {
                        Button("Open System Settings") { appState.openSystemExtensionSettings() }
                        Button("Retry") { appState.installSystemExtension() }
                    }
                }
            }
        case .updateRequired:
            LabeledContent("System Extension Update Required") {
                Button("Update Safely") {
                    Task { await appState.updateSystemExtensionSafely() }
                }
                .disabled(appState.systemExtensionRequestInProgress)
            }
        case .updateFailed:
            LabeledContent("System Extension Update Failed") {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(appState.systemExtensionState.userDescription)
                    Button("Retry Safely") {
                        Task { await appState.updateSystemExtensionSafely() }
                    }
                    .disabled(appState.systemExtensionRequestInProgress)
                }
            }
        case .downgradeBlocked:
            LabeledContent(
                "System Extension",
                value: "A newer DNSPilot build is required"
            )
        case .checking, .activating, .deactivating, .uninstalling, .restartRequired:
            LabeledContent("System Extension", value: appState.systemExtensionState.userDescription)
        }
    }

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current Selection").font(.headline)
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
                LabeledContent("Target Profile", value: profileName(target) ?? "Unknown Profile")
            }
            LabeledContent("Selection Source") {
                switch appState.selectionSource {
                case let .rule(id, name):
                    Button(name) { appState.navigateToRule(id) }
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Current Network").font(.headline)
            LabeledContent("Wi-Fi", value: wifiSummary)
            if appState.network?.ssidAvailability == .permissionDenied {
                Button("Open System Settings") { appState.openLocationSettings() }
            }
            LabeledContent("Interfaces", value: interfaceSummary)
            LabeledContent("Addresses") {
                Text(addressSummary).textSelection(.enabled)
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
        return values.isEmpty ? "None" : values.joined(separator: ", ")
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
