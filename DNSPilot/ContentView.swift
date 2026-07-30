import SwiftUI

@MainActor
struct ProductWindowContent: View {
    @AppStorage(ProductWindowPolicy.onboardingCompletedKey)
    private var onboardingCompleted = false

    var body: some View {
        if onboardingCompleted {
            ContentView()
        } else {
            SetupWindowContent()
        }
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("window.sidebarVisible") private var sidebarVisible = true

    var body: some View {
        Group {
            if appState.startupFailure != nil {
                ProductStartupFailureView()
            } else if appState.configuration == nil {
                ProgressView("Starting DNSPilot")
                    .controlSize(.large)
            } else {
                managementView
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            await appState.start()
            if appState.configuration != nil, appState.profiles.isEmpty {
                appState.requestSetupWindow()
            }
        }
        .onChange(of: appState.profiles.isEmpty) { _, isEmpty in
            if appState.configuration != nil, isEmpty { appState.requestSetupWindow() }
        }
        .onAppear { appState.synchronizeSystemExtension() }
        .onAppear {
            appState.productWindowPresented(.main)
            appState.redirectMainWindowToSetupIfNeeded()
        }
        .onDisappear { appState.productWindowClosed(.main) }
        .alert(
            "Operation Failed",
            isPresented: Binding(
                get: { appState.actionFailure != nil },
                set: { if !$0 { appState.clearActionFailure() } }
            )
        ) {
            Button("OK") { appState.clearActionFailure() }
        } message: {
            Text(appState.actionFailure?.message ?? "Unknown error")
        }
    }

    private var managementView: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = $0 != .detailOnly }
        )) {
            List(AppNavigationSection.allCases, selection: $appState.navigation) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationTitle("DNSPilot")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 240)
        } detail: {
            switch appState.navigation {
            case .overview:
                OverviewView()
            case .profiles:
                ProfilesView()
            case .rules:
                RulesView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.navigate(to: .overview)
                } label: {
                    Image(systemName: appState.menuPresentation?.symbolName ?? "network.slash")
                }
                .help(appState.menuPresentation?.statusText ?? "DNS Proxy status")
                .accessibilityLabel(appState.menuPresentation?.statusText ?? "DNS Proxy status")
            }
        }
    }
}

@MainActor
struct SetupWindowContent: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.startupFailure != nil {
                ProductStartupFailureView()
            } else if appState.configuration == nil {
                ProgressView("Starting DNSPilot")
                    .controlSize(.large)
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .task { await appState.start() }
        .onAppear { appState.synchronizeSystemExtension() }
        .onAppear { appState.productWindowPresented(.setup) }
        .onDisappear { appState.productWindowClosed(.setup) }
    }
}

@MainActor
private struct ProductStartupFailureView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let failure = appState.startupFailure {
            ContentUnavailableView {
                Label(failure.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.message)
            } actions: {
                StartupRecoveryActions(failure: failure)
            }
        }
    }
}

@MainActor
private struct StartupRecoveryActions: View {
    @EnvironmentObject private var appState: AppState
    let failure: ProductStartupFailure
    @State private var confirmsNewConfiguration = false

    var body: some View {
        HStack {
            switch failure {
            case .recoveryRequired:
                Button("Reconnect") { Task { await appState.reconnect() } }
                Button("Restore System DNS") { Task { await appState.restoreSystemDNS() } }
            case .corruptConfiguration:
                Button("Reveal Backup") { appState.revealStartupRecoveryArtifact() }
                Button("Copy Error Details") { appState.copyStartupFailureDetails() }
                Button("Restore System DNS") { Task { await appState.restoreSystemDNS() } }
                Button("Create New Configuration...", role: .destructive) {
                    confirmsNewConfiguration = true
                }
            case .newerConfigurationSchema:
                Button("Reveal Configuration") { appState.revealConfiguration() }
                Button("Open App Store") { appState.openAppStore() }
                Button("Restore System DNS") { Task { await appState.restoreSystemDNS() } }
                Button("Quit DNSPilot") { appState.quit() }
            case .unsupportedConfigurationSchema, .unavailable:
                Button("Copy Error Details") { appState.copyStartupFailureDetails() }
                Button("Restore System DNS") { Task { await appState.restoreSystemDNS() } }
                Button("Quit DNSPilot") { appState.quit() }
            }
        }
        .disabled(appState.isPerformingAction)
        .confirmationDialog(
            "Create a New Configuration?",
            isPresented: $confirmsNewConfiguration
        ) {
            Button("Create New Configuration", role: .destructive) {
                Task { await appState.createNewConfiguration() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("DNSPilot will restore System DNS, preserve the corrupt backup, and replace only the matching corrupt configuration.")
        }
    }
}

private extension AppNavigationSection {
    var title: String {
        switch self {
        case .overview: "Overview"
        case .profiles: "Profiles"
        case .rules: "Rules"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "network"
        case .profiles: "list.bullet.rectangle"
        case .rules: "arrow.triangle.branch"
        }
    }
}
