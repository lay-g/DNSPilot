import AppKit
import SwiftUI

@MainActor
struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("onboarding.completed") private var onboardingCompleted = false

    var body: some View {
        let presentation = appState.menuPresentation
        Text(setupRequired ? "Setup Required" : (presentation?.statusText ?? "Checking"))
            .disabled(true)
        ForEach(Array((presentation?.profileLines ?? []).enumerated()), id: \.offset) { _, line in
            Text(line).disabled(true)
        }
        Text(presentation?.networkText ?? "Network: Checking").disabled(true)
        Divider()
        Button {
            perform { await appState.setOperatingMode(.automatic) }
        } label: {
            if case .automatic = appState.configuration?.operatingMode {
                Label("Automatic", systemImage: "checkmark")
            } else {
                Text("Automatic")
            }
        }
        .disabled(setupRequired || appState.configurationWritesLocked)
        Menu("Profiles") {
            ForEach(appState.profiles) { profile in
                Button {
                    perform { await appState.setOperatingMode(.manual(profileID: profile.id)) }
                } label: {
                    if isManualProfile(profile.id) {
                        Label(profileNames[profile.id] ?? profile.name, systemImage: "checkmark")
                    } else {
                        Text(profileNames[profile.id] ?? profile.name)
                    }
                }
            }
            Divider()
            Button("Manage Profiles...") {
                appState.navigate(to: .profiles)
                appState.requestPrimaryWindow()
            }
        }
        .disabled(setupRequired || appState.configurationWritesLocked)
        Divider()
        Button("Open DNSPilot") { appState.requestPrimaryWindow() }
        SettingsLink { Text("Settings...") }
        if presentation?.proxyCommand == .turnOn {
            Button("Turn On DNS Proxy") { perform { await appState.turnOnDNSProxy() } }
                .disabled(setupRequired || appState.systemExtensionState != .active)
        } else if presentation?.proxyCommand == .restoreSystemDNS {
            Button("Restore System DNS") { perform { await appState.restoreSystemDNS() } }
        }
        if case .failed = appState.proxy.state {
            Button("Open DNSPilot to Resolve") {
                appState.navigate(to: .overview)
                appState.requestPrimaryWindow()
            }
        } else if case .degraded = appState.proxy.state {
            Button("Open DNSPilot to Resolve") {
                appState.navigate(to: .overview)
                appState.requestPrimaryWindow()
            }
        } else if case .recoveryRequired = appState.proxy.state {
            Button("Open DNSPilot to Resolve") {
                appState.navigate(to: .overview)
                appState.requestPrimaryWindow()
            }
        }
        Divider()
        Button("Quit DNSPilot") { appState.quit() }
    }

    private var profileNames: [DNSProfile.ID: String] {
        ProfileDisplayIdentity.displayNames(for: appState.profiles)
    }

    private var setupRequired: Bool {
        !onboardingCompleted || appState.profiles.isEmpty
    }

    private func isManualProfile(_ profileID: DNSProfile.ID) -> Bool {
        guard case let .manual(selectedProfileID) = appState.configuration?.operatingMode else {
            return false
        }
        return selectedProfileID == profileID
    }

    private func perform(
        _ action: @escaping @MainActor () async -> ProductActionOutcome
    ) {
        Task {
            guard case .failed = await action() else { return }
            appState.navigate(to: .overview)
            appState.requestPrimaryWindow()
        }
    }
}
