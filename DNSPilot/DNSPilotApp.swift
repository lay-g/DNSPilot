//
//  DNSPilotApp.swift
//  DNSPilot
//
//  Copyright 2026 DNSPilot Contributors.
//

import SwiftUI

@main
@MainActor
struct DNSPilotApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var appState = AppState()
    private let isGateAProbeMode: Bool

    init() {
        DNSLogBridge.configure(process: "Host")
        #if DNSPILOT_DEBUG_LOCAL
        isGateAProbeMode = EnabledManagerGateAProbe.isRequested()
        if isGateAProbeMode {
            EnabledManagerGateAProbe.start()
        }
        #else
        isGateAProbeMode = false
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent().environmentObject(appState)
        } label: {
            MenuBarLabel(
                appState: appState,
                applicationDelegate: applicationDelegate,
                suppressAutomaticWindows: isGateAProbeMode
            )
        }
        .menuBarExtraStyle(.menu)

        Window("DNSPilot", id: "main") {
            if isGateAProbeMode {
                EmptyView()
            } else {
                ProductWindowContent()
                    .environmentObject(appState)
                    .background(WindowFrameAutosaveView(name: "DNSPilot.MainWindow"))
                    .task {
                        applicationDelegate.configure(
                            appState: appState,
                            suppressAutomaticWindows: isGateAProbeMode
                        )
                    }
            }
        }
        .defaultSize(width: 960, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            DNSPilotCommands(appState: appState)
        }

        Settings {
            SettingsView().environmentObject(appState)
                .task {
                    applicationDelegate.configure(
                        appState: appState,
                        suppressAutomaticWindows: isGateAProbeMode
                    )
                }
        }
    }
}

@MainActor
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var appState: AppState
    let applicationDelegate: ApplicationDelegate
    let suppressAutomaticWindows: Bool

    var body: some View {
        Image(systemName: appState.menuPresentation?.symbolName ?? "network.slash")
            .accessibilityLabel(appState.menuPresentation?.statusText ?? "DNSPilot")
            .task {
                applicationDelegate.configure(
                    appState: appState,
                    suppressAutomaticWindows: suppressAutomaticWindows
                )
                await appState.start()
                appState.synchronizeSystemExtension()
                route(appState.windowRequest)
            }
            .onChange(of: appState.windowRequest) { _, request in route(request) }
    }

    private func route(_ request: ProductWindowRequest?) {
        guard let request, !suppressAutomaticWindows else { return }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        appState.consumeWindowRequest(request.id)
    }
}

@MainActor
private struct DNSPilotCommands: Commands {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About DNSPilot") {
                appState.selectSettingsSection(.about)
                openSettings()
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Profile") {
                appState.requestEditor(.newProfile)
                appState.requestPrimaryWindow()
            }
            .keyboardShortcut("n")
            .disabled(appState.presentedProductWindow != .main)
            Button("New Rule") {
                appState.requestEditor(.newRule)
                appState.requestPrimaryWindow()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(appState.profiles.isEmpty)
        }
        CommandMenu("View") {
            Button("Overview") {
                appState.navigate(to: .overview)
                appState.requestPrimaryWindow()
            }
            .keyboardShortcut("1")
            Button("Profiles") {
                appState.navigate(to: .profiles)
                appState.requestPrimaryWindow()
            }
            .keyboardShortcut("2")
            Button("Rules") {
                appState.navigate(to: .rules)
                appState.requestPrimaryWindow()
            }
            .keyboardShortcut("3")
        }
        SidebarCommands()
    }
}
