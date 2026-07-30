import SwiftUI

@MainActor
struct OverviewView: View {
    private enum Mode: Hashable {
        case automatic
        case manual
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
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
                            Task { await appState.preflightProfile(ProfileDraft(profile: activeProfile)) }
                        }
                        .disabled(appState.configurationWritesLocked)
                        if let result = appState.profileTestResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            .disabled(appState.configurationWritesLocked || appState.profiles.isEmpty)
        }
    }

    @ViewBuilder
    private var proxyRecoveryActions: some View {
        if appState.proxy.lastSwitchFailure != nil {
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
            }
            .disabled(appState.isPerformingAction)
        } else {
            switch appState.proxy.state {
            case .recoveryRequired:
                VStack(alignment: .leading, spacing: 8) {
                    Text("DNS Proxy ownership or manager state changed outside DNSPilot.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Reconnect") { Task { await appState.reconnect() } }
                        Button("Keep Off") { Task { await appState.restoreSystemDNS() } }
                    }
                }
                .disabled(appState.isPerformingAction)
            case .failed, .degraded:
                HStack {
                    Button("Retry") { Task { await appState.turnOnDNSProxy() } }
                    Button("Open Diagnostics") { openDiagnostics() }
                }
                .disabled(appState.isPerformingAction)
            case .disabled, .preparing, .applying, .repairing, .active, .stopping:
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
            LabeledContent("System Extension Error") {
                Button("Retry") { appState.installSystemExtension() }
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
                Button("Retry Safely") {
                    Task { await appState.updateSystemExtensionSafely() }
                }
                .disabled(appState.systemExtensionRequestInProgress)
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
}
