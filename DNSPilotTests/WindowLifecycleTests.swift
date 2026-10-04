import AppKit
import Foundation
import Testing
@testable import DNSPilot

struct WindowLifecycleTests {
    @Test func primaryDestinationSeparatesSetupFromCompletedProduct() {
        #expect(ProductWindowPolicy.primaryDestination(onboardingCompleted: false) == .setup)
        #expect(ProductWindowPolicy.primaryDestination(onboardingCompleted: true) == .main)
    }

    @Test func dockIconFollowsTheLastOpenWindow() {
        let mainWindow = NSObject()
        let settingsWindow = NSObject()
        var policy = DockWindowPolicy()
        #expect(policy.activationPolicy == .accessory)

        policy.windowOpened(ObjectIdentifier(mainWindow))
        #expect(policy.activationPolicy == .regular)
        policy.windowOpened(ObjectIdentifier(settingsWindow))
        policy.windowClosed(ObjectIdentifier(mainWindow))
        #expect(policy.activationPolicy == .regular)
        policy.windowClosed(ObjectIdentifier(settingsWindow))
        #expect(policy.activationPolicy == .accessory)
    }

    @Test func retainedWindowCanReopenWithoutDoubleCounting() {
        let window = NSObject()
        var policy = DockWindowPolicy()
        policy.windowOpened(ObjectIdentifier(window))
        policy.windowOpened(ObjectIdentifier(window))
        policy.windowClosed(ObjectIdentifier(window))
        #expect(policy.activationPolicy == .accessory)

        policy.windowOpened(ObjectIdentifier(window))
        #expect(policy.activationPolicy == .regular)
        policy.windowClosed(ObjectIdentifier(window))
        #expect(policy.activationPolicy == .accessory)
    }

    @Test func closingUntrackedWindowsDoesNotHideAnOpenWindow() {
        let mainWindow = NSObject()
        let auxiliaryWindow = NSObject()
        var policy = DockWindowPolicy()
        policy.windowOpened(ObjectIdentifier(mainWindow))
        policy.windowClosed(ObjectIdentifier(auxiliaryWindow))
        #expect(policy.activationPolicy == .regular)
    }

    @Test func loginItemDetectionRequiresOpenApplicationAndLoginReason() {
        #expect(LoginItemLaunchDetector.isLoginItem(
            isOpenApplicationEvent: true,
            launchReason: keyAELaunchedAsLogInItem
        ))
        #expect(!LoginItemLaunchDetector.isLoginItem(
            isOpenApplicationEvent: false,
            launchReason: keyAELaunchedAsLogInItem
        ))
        #expect(!LoginItemLaunchDetector.isLoginItem(
            isOpenApplicationEvent: true,
            launchReason: nil
        ))
    }

    @MainActor
    @Test func appStateRoutesPrimaryWindowAndCompletesOnboarding() throws {
        let suiteName = "WindowLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            backend: WindowLifecycleBackend(),
            userDefaults: defaults
        )

        state.requestPrimaryWindow()
        #expect(state.windowRequest?.destination == .setup)
        if let request = state.windowRequest { state.consumeWindowRequest(request.id) }

        state.redirectMainWindowToSetupIfNeeded()
        #expect(state.windowRequest?.destination == .setup)
        if let request = state.windowRequest { state.consumeWindowRequest(request.id) }

        state.completeOnboarding()
        #expect(defaults.bool(forKey: ProductWindowPolicy.onboardingCompletedKey))
        #expect(state.windowRequest?.destination == .main)
        if let request = state.windowRequest { state.consumeWindowRequest(request.id) }

        state.requestSetupWindow()
        #expect(state.windowRequest?.destination == .main)
        if let request = state.windowRequest { state.consumeWindowRequest(request.id) }

        state.redirectMainWindowToSetupIfNeeded()
        #expect(state.windowRequest == nil)

        state.navigate(to: .rules)
        let restoredState = AppState(
            backend: WindowLifecycleBackend(),
            userDefaults: defaults
        )
        #expect(restoredState.navigation == .rules)
    }
}

@MainActor
private final class WindowLifecycleBackend: ProductRuntimeBacking {
    func start() async -> Bool { true }

    func productSnapshot() async -> ProductRuntimeSnapshot {
        ProductRuntimeSnapshot(
            configuration: nil,
            proxy: ProxyControllerSnapshot(
                state: .disabled,
                targetProfileID: nil,
                activeProfileID: nil,
                activeGeneration: nil,
                lastSwitchFailure: nil
            ),
            network: nil,
            locationAuthorization: .notDetermined,
            startupFailure: nil,
            diagnostics: .unavailable("Not refreshed"),
            loggingMode: .default
        )
    }

    func performProductIntent(_ intent: ProductIntent) async -> ProductActionOutcome {
        .completed
    }

    func setProductChangeHandler(_ handler: (@MainActor () -> Void)?) { }

    func restoreSystemDNSForTermination() async -> DNSProxyControllerState { .disabled }

    func cancelTerminationRequest() async { }
}
