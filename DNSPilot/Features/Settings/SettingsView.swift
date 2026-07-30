import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsExtensionDeactivation = false
    @State private var pendingDebugLoggingValue: Bool?
    @State private var confirmsDiagnosticsExport = false
    @State private var showsThirdPartyNotices = false

    var body: some View {
        TabView(selection: $appState.settingsSection) {
            Form {
                Toggle("Launch at Login", isOn: Binding(
                    get: { appState.launchAtLoginStatus.isEnabled },
                    set: { enabled in appState.setLaunchAtLoginEnabled(enabled) }
                ))
                if appState.launchAtLoginStatus == .requiresApproval {
                    Text("Approval is required in System Settings.")
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings") { appState.openLoginItemsSettings() }
                }
                if case .failed = appState.launchAtLoginStatus {
                    Text("Launch at Login could not be changed.").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }
            .tag(ProductSettingsSection.general)

            Form {
                LabeledContent("Wi-Fi Name Access", value: locationSummary)
                Text("Location is used only to read the current Wi-Fi name for SSID Rules.")
                    .foregroundStyle(.secondary)
                LabeledContent("Debug Logging", value: debugLoggingEnabled ? "On" : "Off")
                switch appState.locationAuthorization {
                case .denied:
                    Button("Open System Settings") { appState.openLocationSettings() }
                case .notDetermined:
                    Button("Request Access") {
                        Task { await appState.requestLocationAuthorization() }
                    }
                case .authorized:
                    EmptyView()
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
            .tag(ProductSettingsSection.privacy)

            Form {
                if debugLoggingEnabled {
                    Label(
                        "Debug Logging may record full domain names, endpoint tokens, Wi-Fi names, IP addresses, and DNS answers.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                LabeledContent("DNS Proxy", value: appState.menuPresentation?.statusText ?? "Checking")
                LabeledContent("Active Profile", value: activeProfileName)
                LabeledContent("System Extension", value: appState.systemExtensionState.userDescription)
                LabeledContent(
                    "Installed System Extension",
                    value: appState.installedSystemExtensionVersion
                )
                LabeledContent(
                    "Bundled System Extension",
                    value: appState.bundledSystemExtensionVersion
                )
                LabeledContent("DnsLibs", value: DNSLogBridge.libraryVersion)
                diagnosticsDetails
                Toggle("Debug Logging", isOn: Binding(
                    get: { debugLoggingEnabled },
                    set: { pendingDebugLoggingValue = $0 }
                ))
                .disabled(appState.configurationWritesLocked)
                Button("Copy Diagnostic Summary") { appState.copyDiagnosticSummary() }
                Button("Export Diagnostics...") { confirmsDiagnosticsExport = true }
                Menu("More") {
                    Button("Deactivate System Extension...", role: .destructive) {
                        confirmsExtensionDeactivation = true
                    }
                    .disabled(
                        appState.systemExtensionRequestInProgress
                            || !appState.systemExtensionState.allowsDeactivation
                    )
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            .tag(ProductSettingsSection.diagnostics)

            Form {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DNSPilot")
                            .font(.title2)
                        Text("Version \(appVersion)")
                            .foregroundStyle(.secondary)
                        Text("DNSPilot forwards system DNS through the selected Profile.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Open Source Software") {
                    Button {
                        showsThirdPartyNotices = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AdGuard DnsLibs")
                                Text("2.8.45 - Apache License 2.0")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows copyright and license details")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }
            .tag(ProductSettingsSection.about)
        }
        .frame(width: 620, height: 460)
        .onAppear {
            appState.refreshLaunchAtLogin()
            appState.synchronizeSystemExtension()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            appState.refreshLaunchAtLogin()
            appState.synchronizeSystemExtension()
        }
        .task {
            await appState.start()
            await appState.refreshDiagnostics()
        }
        .confirmationDialog(
            pendingDebugLoggingValue == true ? "Enable Debug Logging?" : "Disable Debug Logging?",
            isPresented: Binding(
                get: { pendingDebugLoggingValue != nil },
                set: { if !$0 { pendingDebugLoggingValue = nil } }
            )
        ) {
            Button(pendingDebugLoggingValue == true ? "Enable" : "Disable") {
                guard let enabled = pendingDebugLoggingValue else { return }
                pendingDebugLoggingValue = nil
                Task { await appState.setDebugLoggingEnabled(enabled) }
            }
            Button("Cancel", role: .cancel) { pendingDebugLoggingValue = nil }
        } message: {
            Text("Debug logs may contain full domain names, endpoint tokens, Wi-Fi names, IP addresses, and DNS answers.")
        }
        .confirmationDialog(
            "Export Sensitive Diagnostics?",
            isPresented: $confirmsDiagnosticsExport
        ) {
            Button("Export") { Task { await appState.exportDiagnostics() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The exported file is not redacted and may contain DNS endpoints, Wi-Fi names, IP addresses, Profile details, and error messages.")
        }
        .confirmationDialog(
            "Deactivate System Extension?",
            isPresented: $confirmsExtensionDeactivation
        ) {
            Button("Deactivate", role: .destructive) {
                Task { await appState.deactivateSystemExtensionSafely() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("DNS Proxy will be restored to System DNS first. The extension must be installed again before DNSPilot can be turned on.")
        }
        .alert(
            "Operation Failed",
            isPresented: Binding(
                get: { appState.settingsActionFailure != nil },
                set: { if !$0 { appState.clearSettingsActionFailure() } }
            )
        ) {
            Button("OK") { appState.clearSettingsActionFailure() }
        } message: {
            Text(appState.settingsActionFailure?.message ?? "Unknown error")
        }
        .sheet(isPresented: $showsThirdPartyNotices) {
            ThirdPartyNoticesView()
        }
    }

    private var locationSummary: String {
        switch appState.locationAuthorization {
        case .authorized: "Allowed"
        case .notDetermined: "Not Requested"
        case .denied: "Denied"
        }
    }

    private var activeProfileName: String {
        guard let id = appState.proxy.activeProfileID else { return "System DNS" }
        return ProfileDisplayIdentity.displayNames(for: appState.profiles)[id] ?? "Unknown"
    }

    private var debugLoggingEnabled: Bool {
        appState.loggingMode == .debug
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    @ViewBuilder
    private var diagnosticsDetails: some View {
        switch appState.diagnostics {
        case let .available(protocolVersion, _, _, phase, errorCode, _, sequence, _):
            LabeledContent("Runtime Protocol", value: protocolVersion.map(String.init) ?? "Unavailable")
            LabeledContent("Runtime Phase", value: phase.rawValue)
            LabeledContent("Last Stable Error", value: stableErrorDescription(errorCode))
            LabeledContent("Transition Sequence", value: sequence.map(String.init) ?? "Unavailable")
        case .unavailable:
            LabeledContent("Runtime Details", value: "Unavailable")
        }
    }

    private func stableErrorDescription(_ runtimeError: ProxyRuntimeErrorCode?) -> String {
        if let failure = appState.proxy.lastSwitchFailure { return failure.code.rawValue }
        return runtimeError?.rawValue ?? "None"
    }
}

@MainActor
private struct ThirdPartyNoticesView: View {
    @Environment(\.dismiss) private var dismiss
    private let notices = Self.loadNotices()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AdGuard DnsLibs")
                            .font(.title2)
                        Text("Version 2.8.45 - Apache License 2.0")
                            .foregroundStyle(.secondary)
                        Link(
                            "Open Project Website",
                            destination: URL(string: "https://github.com/AdguardTeam/DnsLibs")!
                        )
                    }

                    Divider()

                    Text(notices.rendered)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .navigationTitle("Third-Party Notices")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Copy License") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notices.source, forType: .string)
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    private static func loadNotices() -> (source: String, rendered: AttributedString) {
        guard
            let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            let message = "Third-party notices could not be loaded."
            return (message, AttributedString(message))
        }

        let rendered = (try? AttributedString(markdown: source)) ?? AttributedString(source)
        return (source, rendered)
    }
}
