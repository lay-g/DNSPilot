import AppKit
import Combine
import Foundation
import OSLog

enum ProductStartupFailure: Equatable, Sendable {
    case recoveryRequired(String)
    case corruptConfiguration(message: String, recoveryArtifactURL: URL)
    case newerConfigurationSchema(version: Int, message: String)
    case unsupportedConfigurationSchema(version: Int, message: String)
    case unavailable(String)

    var title: String {
        switch self {
        case .newerConfigurationSchema:
            "Configuration Requires a Newer Version of DNSPilot"
        case .recoveryRequired:
            "DNS Proxy Recovery Required"
        case .corruptConfiguration, .unsupportedConfigurationSchema, .unavailable:
            "Configuration Cannot Be Opened"
        }
    }

    var message: String {
        switch self {
        case .recoveryRequired:
            "DNSPilot could not confirm the DNS Proxy state. Reconnect or restore System DNS."
        case .corruptConfiguration:
            "DNSPilot could not read its configuration. Choose a recovery action below."
        case .newerConfigurationSchema:
            "Update DNSPilot to open this configuration."
        case .unsupportedConfigurationSchema:
            "This configuration is not supported by this version of DNSPilot."
        case .unavailable:
            "DNSPilot could not load its configuration."
        }
    }

    var diagnosticDescription: String {
        switch self {
        case let .recoveryRequired(message), let .unavailable(message):
            message
        case let .corruptConfiguration(message, _),
             let .newerConfigurationSchema(_, message),
             let .unsupportedConfigurationSchema(_, message):
            message
        }
    }
}

struct ProductRuntimeSnapshot: Equatable, Sendable {
    let configuration: AppConfiguration?
    let proxy: ProxyControllerSnapshot
    let network: NetworkContext?
    let locationAuthorization: LocationAuthorizationInput
    let startupFailure: ProductStartupFailure?
    let diagnostics: ProductDiagnosticsSnapshot
    let loggingMode: ProxyLoggingMode
    let proxyResumeState: ProductProxyResumeState

    init(
        configuration: AppConfiguration?,
        proxy: ProxyControllerSnapshot,
        network: NetworkContext?,
        locationAuthorization: LocationAuthorizationInput,
        startupFailure: ProductStartupFailure?,
        diagnostics: ProductDiagnosticsSnapshot,
        loggingMode: ProxyLoggingMode,
        proxyResumeState: ProductProxyResumeState = .none
    ) {
        self.configuration = configuration
        self.proxy = proxy
        self.network = network
        self.locationAuthorization = locationAuthorization
        self.startupFailure = startupFailure
        self.diagnostics = diagnostics
        self.loggingMode = loggingMode
        self.proxyResumeState = proxyResumeState
    }
}

enum ProductProxyResumeState: Equatable, Sendable {
    case none
    case waitingForExtension
    case waitingForNetwork
    case restoring
    case failed(ProxyResumeFailureCode)
}

enum ProductDiagnosticsSnapshot: Equatable, Sendable {
    case available(
        runtimeControlProtocolVersion: Int?,
        providerInstanceID: UUID?,
        activeGeneration: UUID?,
        phase: ProxyRuntimePhase,
        errorCode: ProxyRuntimeErrorCode?,
        configurationFingerprint: ProxyConfigurationFingerprint?,
        transitionSequence: UInt64?,
        lastQuiescedGeneration: UUID?
    )
    case unavailable(String)
}

enum ProductIntent: Equatable, Sendable {
    case preflightProfile(DNSProfile)
    case createProfile(DNSProfile)
    case duplicateProfile(sourceProfileID: DNSProfile.ID, duplicate: DNSProfile)
    case editProfile(DNSProfile)
    case deleteProfile(profileID: DNSProfile.ID, plan: ProfileDeletionPlan)
    case saveRule(DNSRule)
    case deleteRule(DNSRule.ID)
    case reorderRules([DNSRule.ID])
    case setDefaultProfile(DNSProfile.ID)
    case setOperatingMode(OperatingMode)
    case turnOnDNSProxy
    case restoreSystemDNS
    case reconnect
    case resetOnboardingConfiguration
    case createNewConfiguration(URL)
    case refreshDiagnostics
    case requestLocationAuthorization
    case setDebugLogging(Bool)
}

enum ProductAction: String, CaseIterable, Equatable, Sendable {
    case profileTest
    case profileSwitch
    case profileCreate
    case profileDuplicate
    case profileEdit
    case profileDelete
    case ruleSave
    case ruleDelete
    case ruleReorder
    case defaultProfileUpdate
    case operatingModeUpdate
    case dnsProxyEnable
    case systemDNSRestore
    case reconnect
    case onboardingReset
    case configurationReplace
    case diagnosticsRefresh
    case diagnosticsExport
    case locationAccessRequest
    case debugLoggingUpdate
    case systemExtensionUpdate
    case systemExtensionDeactivation

    var failureTitle: String {
        switch self {
        case .profileTest: "Profile Test Failed"
        case .profileSwitch: "Profile Could Not Be Switched"
        case .profileCreate: "Profile Could Not Be Created"
        case .profileDuplicate: "Profile Could Not Be Duplicated"
        case .profileEdit: "Profile Could Not Be Saved"
        case .profileDelete: "Profile Could Not Be Deleted"
        case .ruleSave: "Rule Could Not Be Saved"
        case .ruleDelete: "Rule Could Not Be Deleted"
        case .ruleReorder: "Rule Order Could Not Be Saved"
        case .defaultProfileUpdate: "Default Profile Could Not Be Changed"
        case .operatingModeUpdate: "Operating Mode Could Not Be Changed"
        case .dnsProxyEnable: "DNS Proxy Could Not Be Enabled"
        case .systemDNSRestore: "System DNS Restore Could Not Be Confirmed"
        case .reconnect: "Reconnect Did Not Resolve DNS Proxy State"
        case .onboardingReset: "Setup Could Not Be Reset"
        case .configurationReplace: "New Configuration Could Not Be Created"
        case .diagnosticsRefresh: "Runtime Diagnostics Are Unavailable"
        case .diagnosticsExport: "Diagnostics Could Not Be Exported"
        case .locationAccessRequest: "Location Access Could Not Be Requested"
        case .debugLoggingUpdate: "Debug Logging Could Not Be Changed"
        case .systemExtensionUpdate: "System Extension Could Not Be Updated"
        case .systemExtensionDeactivation: "System Extension Could Not Be Deactivated"
        }
    }
}

enum ProductFailureReason: String, CaseIterable, Equatable, Sendable {
    case cancelled
    case notReady
    case networkUnavailable
    case invalidConfiguration
    case conflict
    case recoveryRequired
    case operationInProgress
    case upstreamTestUnclassified
    case profileNotFound
    case profileAlreadyExists
    case invalidDeletionPlan
    case persistenceFailed
    case runtimePreparationFailed
    case desiredConfigurationPersistenceFailed
    case recoveryJournalWriteFailed
    case runtimeRejected
    case systemExtensionNotActive
    case systemDNSRestoreUnconfirmed
    case reconnectUnresolved
    case systemExtensionOperationUnavailable
    case restartRequired
    case compatibilityUnavailable
    case targetChanged
    case managerStateUnavailable
    case targetWriteFailed
    case readinessTimedOut
    case providerFailed
    case unknown
}

enum ProductRecoveryAction: Equatable, Sendable {
    case retry
    case reconnect
    case restoreSystemDNS
    case openDiagnostics
    case openSystemSettings
    case chooseAnotherLocation
}

struct ProductActionFailure: Equatable, Sendable {
    let action: ProductAction
    let reason: ProductFailureReason
    let diagnosticDescription: String

    init(
        action: ProductAction,
        reason: ProductFailureReason,
        diagnosticDescription: String? = nil
    ) {
        self.action = action
        self.reason = reason
        self.diagnosticDescription = diagnosticDescription ?? "\(action.rawValue):\(reason.rawValue)"
    }

    var title: String { action.failureTitle }

    var message: String {
        switch reason {
        case .cancelled:
            "The action was cancelled before it completed."
        case .notReady:
            "DNSPilot has not finished loading. Wait for startup to complete, then try again."
        case .networkUnavailable:
            "Automatic mode has no usable network connection. Connect to a network, then enable DNS Proxy again."
        case .invalidConfiguration:
            "The requested settings are invalid or incomplete. Review the current values before trying again."
        case .conflict:
            "The configuration changed while this action was running. Review the latest values before trying again."
        case .recoveryRequired:
            "DNSPilot cannot safely change configuration until DNS Proxy state is reconciled. Reconnect or restore System DNS."
        case .operationInProgress:
            "Another DNSPilot action is still running. Wait for it to finish before trying again."
        case .upstreamTestUnclassified:
            "DnsLibs could not complete its upstream DNS test and does not provide a safe structured cause. Check the Profile address, protocol, port, bootstrap servers, and network connection, then test again."
        case .profileNotFound:
            "This Profile no longer exists. Close the editor and review the latest Profile list."
        case .profileAlreadyExists:
            "A Profile with this identity already exists. Reopen the latest Profile list before trying again."
        case .invalidDeletionPlan:
            "This Profile is still in use. Choose valid replacements for its Rules, Default selection, Manual target, and Active runtime before deleting it."
        case .persistenceFailed:
            if action == .diagnosticsExport {
                "DNSPilot could not write the diagnostics file to the selected location. Choose another location and try again."
            } else if [.profileCreate, .profileDuplicate, .profileEdit, .ruleSave].contains(action) {
                "DNSPilot could not save the configuration. Your draft remains available; check available disk space and try again."
            } else if action == .configurationReplace {
                "DNSPilot could not create the replacement configuration. The existing recovery artifact was preserved; check available disk space and try again."
            } else {
                "DNSPilot could not save this configuration change. The previously stored configuration remains in use; check available disk space and try again."
            }
        case .runtimePreparationFailed:
            "DNSPilot could not confirm the conditions required to prepare this Active Profile update. No new configuration was published; reconnect or restore System DNS if the current runtime state is uncertain."
        case .desiredConfigurationPersistenceFailed:
            "DNSPilot could not record the requested Active Profile configuration, so it was not applied."
        case .recoveryJournalWriteFailed:
            "DNSPilot could not record the recovery data required for this Active Profile change, so it was not applied."
        case .runtimeRejected:
            if action == .debugLoggingUpdate {
                "The DNS runtime did not accept the Debug Logging change. Review the current runtime state in Diagnostics, then try again."
            } else {
                "The DNS runtime rejected the Active Profile change. DNSPilot rolled back to the previous configuration or restored System DNS."
            }
        case .systemExtensionNotActive:
            "The DNSPilot System Extension is not active. Finish installation or approval in System Settings before enabling DNS Proxy."
        case .systemDNSRestoreUnconfirmed:
            "DNSPilot could not confirm that macOS returned to System DNS. Retry the restore or open Diagnostics before continuing."
        case .reconnectUnresolved:
            "DNSPilot still cannot confirm a stable DNS Proxy state. Restore System DNS before making more configuration changes."
        case .systemExtensionOperationUnavailable:
            "The System Extension is busy or is not in a state that allows this action. Check its current status before trying again."
        case .restartRequired:
            "System DNS was restored, but macOS requires a restart to finish deactivating the System Extension. Restart before attempting another extension change."
        case .compatibilityUnavailable:
            "The installed System Extension cannot apply this configuration. Update DNSPilot and the System Extension before trying again."
        case .targetChanged:
            "The DNS runtime identity changed before this request completed. Review the current Active and Target Profiles, then reconnect."
        case .managerStateUnavailable:
            "DNSPilot could not confirm the DNS Proxy manager state. Reconnect or restore System DNS before continuing."
        case .targetWriteFailed:
            "DNSPilot could not confirm that the target Profile was saved to DNS Proxy. Review the current Active and Target state before continuing."
        case .readinessTimedOut:
            "DNS Proxy did not report the target Profile ready within five seconds. Retry or open Diagnostics."
        case .providerFailed:
            "The System Extension could not start the target Profile. Review Diagnostics, then retry or restore System DNS."
        case .unknown:
            "DNSPilot could not complete this action because an unclassified internal failure occurred. Open Diagnostics for the recorded details."
        }
    }

    var recoveryActions: [ProductRecoveryAction] {
        switch reason {
        case .cancelled:
            []
        case .operationInProgress:
            []
        case .notReady, .desiredConfigurationPersistenceFailed, .recoveryJournalWriteFailed:
            [.retry]
        case .runtimePreparationFailed:
            [.reconnect, .restoreSystemDNS, .openDiagnostics]
        case .targetWriteFailed:
            [.retry, .openDiagnostics]
        case .persistenceFailed:
            action == .diagnosticsExport ? [.chooseAnotherLocation] : [.retry]
        case .networkUnavailable:
            [.retry]
        case .invalidConfiguration:
            []
        case .conflict, .profileNotFound, .profileAlreadyExists, .invalidDeletionPlan:
            []
        case .targetChanged:
            [.reconnect, .openDiagnostics]
        case .recoveryRequired, .managerStateUnavailable:
            [.reconnect, .restoreSystemDNS]
        case .upstreamTestUnclassified:
            [.retry, .openDiagnostics]
        case .runtimeRejected:
            action == .debugLoggingUpdate
                ? [.retry, .openDiagnostics]
                : [.retry, .restoreSystemDNS, .openDiagnostics]
        case .systemExtensionNotActive, .systemExtensionOperationUnavailable,
             .restartRequired, .compatibilityUnavailable:
            [.openSystemSettings]
        case .systemDNSRestoreUnconfirmed:
            [.retry, .openDiagnostics]
        case .reconnectUnresolved:
            [.restoreSystemDNS, .openDiagnostics]
        case .readinessTimedOut, .providerFailed, .unknown:
            [.retry, .openDiagnostics]
        }
    }
}

enum ProductActionOutcome: Equatable, Sendable {
    case completed
    case failed(ProductActionFailure)
}

@MainActor
protocol ProductRuntimeBacking: AnyObject {
    func start() async -> Bool
    func productSnapshot() async -> ProductRuntimeSnapshot
    func performProductIntent(_ intent: ProductIntent) async -> ProductActionOutcome
    func setProductChangeHandler(_ handler: (@MainActor () -> Void)?)
    func restoreSystemDNSForTermination() async -> DNSProxyControllerState
    func restoreSystemDNSForTerminationResult(
        rememberActiveState: Bool
    ) async -> DNSProxyTerminationRestoreResult
    func cancelTerminationRequest() async
    func setProxyResumeAllowed(_ allowed: Bool) async
    func retryProxyResume() async
    func keepSystemDNSAfterResumeFailure() async
}

extension ProductRuntimeBacking {
    func setProxyResumeAllowed(_ allowed: Bool) async {}
    func retryProxyResume() async {}
    func keepSystemDNSAfterResumeFailure() async {}
    func restoreSystemDNSForTerminationResult(
        rememberActiveState: Bool
    ) async -> DNSProxyTerminationRestoreResult {
        let state = await restoreSystemDNSForTermination()
        return state == .disabled ? .disabled : .restoreFailed(state)
    }
}

enum ProductSelectionSource: Equatable, Sendable {
    case manual
    case rule(id: DNSRule.ID, name: String)
    case defaultProfile
    case unavailable

    var label: String {
        switch self {
        case .manual:
            "Manual Selection"
        case let .rule(_, name):
            name
        case .defaultProfile:
            "Default Profile"
        case .unavailable:
            "Unavailable"
        }
    }
}

enum ProductDraftKind: Equatable, Sendable {
    case profile
    case rule
}

enum ProductSettingsSection: String, CaseIterable, Sendable {
    case general
    case privacy
    case diagnostics
    case about
}

struct ProductEditorRequest: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case newProfile
        case editProfile(DNSProfile.ID)
        case duplicateProfile(DNSProfile.ID)
        case newRule
        case editRule(DNSRule.ID)
        case duplicateRule(DNSRule.ID)
    }

    let id = UUID()
    let kind: Kind
}

struct ProductProfileTestResult: Equatable, Sendable {
    let profileID: DNSProfile.ID
    let upstream: DNSUpstream
    let message: String

    func matches(_ profile: DNSProfile) -> Bool {
        profileID == profile.id && upstream == profile.upstream
    }
}

private enum SettingsRetryOperation {
    case systemExtensionUpdate
    case systemExtensionDeactivation
    case diagnosticsExport
    case debugLogging(Bool)
    case systemDNSRestore
}

@MainActor
final class AppState: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DNSPilot",
        category: "ProductActions"
    )

    @Published var navigation: AppNavigationSection {
        didSet { userDefaults.set(navigation.rawValue, forKey: ProductWindowPolicy.navigationSectionKey) }
    }
    @Published private(set) var configuration: AppConfiguration?
    @Published private(set) var proxy = ProxyControllerSnapshot(
        state: .disabled,
        targetProfileID: nil,
        activeProfileID: nil,
        activeGeneration: nil,
        lastSwitchFailure: nil
    )
    @Published private(set) var network: NetworkContext?
    @Published private(set) var locationAuthorization = LocationAuthorizationInput.notDetermined
    @Published private(set) var startupFailure: ProductStartupFailure?
    @Published private(set) var proxyResumeState = ProductProxyResumeState.none
    @Published private(set) var actionFailure: ProductActionFailure?
    @Published private(set) var profileTestResult: ProductProfileTestResult?
    @Published private(set) var isPerformingAction = false
    @Published private(set) var activeDraft: ProductDraftKind?
    @Published private(set) var draftDiscardGeneration: UInt64 = 0
    @Published private(set) var editorRequest: ProductEditorRequest?
    @Published private(set) var windowRequest: ProductWindowRequest?
    @Published private(set) var presentedProductWindow: ProductWindowDestination?
    @Published private(set) var requestedProfileSelection: DNSProfile.ID?
    @Published private(set) var requestedRuleSelection: DNSRule.ID?
    @Published private(set) var systemExtensionState = SystemExtensionController.State.checking
    @Published private(set) var systemExtensionRequestInProgress = false
    @Published private(set) var installedSystemExtensionVersion = "Unavailable"
    @Published private(set) var bundledSystemExtensionVersion = "Unavailable"
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published private(set) var diagnostics = ProductDiagnosticsSnapshot.unavailable("Not refreshed")
    @Published private(set) var loggingMode = ProxyLoggingMode.default
    @Published private(set) var settingsActionFailure: ProductActionFailure?
    private var retryIntent: ProductIntent?
    private var profileTestGeneration: UInt64 = 0
    private var settingsRetryOperation: SettingsRetryOperation?
    @Published var settingsSection: ProductSettingsSection {
        didSet { userDefaults.set(settingsSection.rawValue, forKey: ProductWindowPolicy.settingsSectionKey) }
    }

    private let backend: any ProductRuntimeBacking
    private let systemExtension: any SystemExtensionControlling
    private let launchAtLogin: LaunchAtLoginService
    private let diagnosticExporter: any DiagnosticExporting
    private let userDefaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private var didStart = false
    private var startupCompleted = false
    private var refreshGeneration: UInt64 = 0
    private var quitHandler: (@MainActor () -> Void)?

    init(
        backend: any ProductRuntimeBacking = DNSPilotAppModel.shared,
        systemExtension: any SystemExtensionControlling = SystemExtensionController.shared,
        launchAtLogin: LaunchAtLoginService = LaunchAtLoginService(),
        diagnosticExporter: any DiagnosticExporting = DiagnosticExporter(),
        userDefaults: UserDefaults = .standard
    ) {
        self.backend = backend
        self.systemExtension = systemExtension
        self.launchAtLogin = launchAtLogin
        self.diagnosticExporter = diagnosticExporter
        self.userDefaults = userDefaults
        navigation = userDefaults.string(forKey: ProductWindowPolicy.navigationSectionKey)
            .flatMap(AppNavigationSection.init(rawValue:)) ?? .overview
        settingsSection = userDefaults.string(forKey: ProductWindowPolicy.settingsSectionKey)
            .flatMap(ProductSettingsSection.init(rawValue:)) ?? .general
        systemExtensionState = systemExtension.state
        systemExtensionRequestInProgress = systemExtension.requestInProgress
        installedSystemExtensionVersion = systemExtension.installedVersion?.description ?? "Unavailable"
        bundledSystemExtensionVersion = systemExtension.bundledVersion?.description ?? "Unavailable"
        launchAtLoginStatus = launchAtLogin.status
        backend.setProductChangeHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        systemExtension.statePublisher
            .sink { [weak self, weak systemExtension] state in
                guard let self, let systemExtension else { return }
                self.systemExtensionState = state
                self.systemExtensionRequestInProgress = systemExtension.requestInProgress
                self.installedSystemExtensionVersion = systemExtension.installedVersion?.description
                    ?? "Unavailable"
                self.bundledSystemExtensionVersion = systemExtension.bundledVersion?.description
                    ?? "Unavailable"
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.replaceBundledSystemExtensionIfSafe()
                    await self?.coordinateProxyResume()
                }
            }
            .store(in: &cancellables)
    }

    var profiles: [DNSProfile] { configuration?.profiles ?? [] }
    var rules: [DNSRule] { configuration?.rules ?? [] }
    var onboardingCompleted: Bool {
        userDefaults.bool(forKey: ProductWindowPolicy.onboardingCompletedKey)
    }
    var hasUnsavedDrafts: Bool { activeDraft != nil }
    var configurationWritesLocked: Bool {
        if isPerformingAction { return true }
        return switch proxy.state {
        case .preparing, .applying, .repairing, .stopping, .recoveryRequired:
            true
        case .disabled, .active, .failed, .degraded:
            false
        }
    }

    var selectionSource: ProductSelectionSource {
        guard let configuration else { return .unavailable }
        switch configuration.operatingMode {
        case .manual:
            return .manual
        case .automatic:
            guard let network,
                  network.status == .satisfied,
                  let defaultProfileID = configuration.defaultProfileID else {
                return .unavailable
            }
            let result = RuleEngine.resolveProfile(
                context: network,
                rules: configuration.rules,
                defaultProfileID: defaultProfileID
            )
            switch result.source {
            case let .rule(id):
                guard let rule = configuration.rules.first(where: { $0.id == id }) else {
                    return .unavailable
                }
                return .rule(id: id, name: rule.name)
            case .default:
                return .defaultProfile
            }
        }
    }

    var menuPresentation: MenuBarPresentation? {
        guard let configuration else { return nil }
        return .make(configuration: configuration, proxy: proxy, network: network)
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        let backendStarted = await backend.start()
        await refresh()
        startupCompleted = backendStarted
        if !backendStarted { didStart = false }
        replaceBundledSystemExtensionIfSafe()
        await coordinateProxyResume()
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let snapshot = await backend.productSnapshot()
        guard generation == refreshGeneration else { return }
        configuration = snapshot.configuration
        if let result = profileTestResult,
           snapshot.configuration?.profiles.contains(where: result.matches) != true {
            profileTestGeneration &+= 1
            profileTestResult = nil
        }
        reconcileOnboardingMigration(with: snapshot.configuration)
        reconcileRequiredSetup(with: snapshot.configuration)
        proxy = snapshot.proxy
        network = snapshot.network
        locationAuthorization = snapshot.locationAuthorization
        startupFailure = snapshot.startupFailure
        diagnostics = snapshot.diagnostics
        loggingMode = snapshot.loggingMode
        proxyResumeState = snapshot.proxyResumeState
    }

    func retryProxyResume() async {
        await backend.retryProxyResume()
        await refresh()
        await coordinateProxyResume()
    }

    func keepSystemDNSAfterResumeFailure() async {
        await backend.keepSystemDNSAfterResumeFailure()
        await refresh()
    }

    func navigate(to section: AppNavigationSection) {
        navigation = section
    }

    func navigateToProfile(_ profileID: DNSProfile.ID) {
        requestedProfileSelection = profileID
        navigation = .profiles
        requestPrimaryWindow()
    }

    func navigateToRule(_ ruleID: DNSRule.ID) {
        requestedRuleSelection = ruleID
        navigation = .rules
        requestPrimaryWindow()
    }

    func selectSettingsSection(_ section: ProductSettingsSection) {
        settingsSection = section
        userDefaults.set(section.rawValue, forKey: ProductWindowPolicy.settingsSectionKey)
    }

    func requestEditor(_ kind: ProductEditorRequest.Kind) {
        switch kind {
        case .newProfile, .editProfile, .duplicateProfile:
            navigation = .profiles
        case .newRule, .editRule, .duplicateRule:
            navigation = .rules
        }
        editorRequest = ProductEditorRequest(kind: kind)
    }

    func consumeEditorRequest(_ id: ProductEditorRequest.ID) {
        guard editorRequest?.id == id else { return }
        editorRequest = nil
    }

    func requestPrimaryWindow() {
        let completed = userDefaults.bool(
            forKey: ProductWindowPolicy.onboardingCompletedKey
        )
        requestWindow(ProductWindowPolicy.primaryDestination(onboardingCompleted: completed))
    }

    func requestSetupWindow() {
        requestWindow(onboardingCompleted ? .main : .setup)
    }

    @discardableResult
    func resetOnboardingConfiguration() async -> ProductActionOutcome {
        guard !profiles.isEmpty else { return .completed }
        return await submit(.resetOnboardingConfiguration)
    }

    func redirectMainWindowToSetupIfNeeded() {
        guard !userDefaults.bool(forKey: ProductWindowPolicy.onboardingCompletedKey) else {
            return
        }
        requestWindow(.setup)
    }

    func completeOnboarding() {
        userDefaults.set(true, forKey: ProductWindowPolicy.onboardingCompletedKey)
        requestWindow(.main)
    }

    func consumeWindowRequest(_ id: ProductWindowRequest.ID) {
        guard windowRequest?.id == id else { return }
        windowRequest = nil
    }

    func productWindowPresented(_ destination: ProductWindowDestination) {
        presentedProductWindow = destination
    }

    func productWindowClosed(_ destination: ProductWindowDestination) {
        if presentedProductWindow == destination { presentedProductWindow = nil }
    }

    func beginDraft(_ kind: ProductDraftKind) {
        activeDraft = kind
    }

    func discardDraft() {
        activeDraft = nil
        draftDiscardGeneration &+= 1
    }

    func endDraft() {
        activeDraft = nil
    }

    func synchronizeSystemExtension() {
        systemExtension.synchronizeState()
    }

    func installSystemExtension() {
        systemExtension.activate()
    }

    private func replaceBundledSystemExtensionIfSafe() {
        guard startupCompleted,
              startupFailure == nil,
              proxy.state == .disabled,
              !isPerformingAction,
              systemExtensionState == .updateRequired,
              !systemExtension.requestInProgress else { return }
        systemExtension.activate()
    }

    private func coordinateProxyResume() async {
        guard startupCompleted, startupFailure == nil else {
            await backend.setProxyResumeAllowed(false)
            return
        }
        await backend.setProxyResumeAllowed(
            systemExtensionState == .active && !systemExtension.requestInProgress
        )
        await refresh()
    }

    @discardableResult
    func updateSystemExtensionSafely() async -> ProductActionOutcome {
        guard startupCompleted,
              startupFailure == nil,
              !systemExtensionRequestInProgress,
              systemExtensionState.requiresUpdate else {
            return failSettingsAction(ProductActionFailure(
                action: .systemExtensionUpdate,
                reason: .systemExtensionOperationUnavailable
            ), retryOperation: .systemExtensionUpdate)
        }
        guard !isPerformingAction else {
            return failSettingsAction(ProductActionFailure(
                action: .systemExtensionUpdate,
                reason: .operationInProgress
            ), retryOperation: .systemExtensionUpdate)
        }
        if proxy.state != .disabled {
            let outcome = await restoreSystemDNS()
            guard outcome == .completed else {
                return routeFailureToSettings(
                    outcome,
                    action: .systemExtensionUpdate,
                    retryOperation: .systemExtensionUpdate
                )
            }
            guard proxy.state == .disabled else {
                return failSettingsAction(ProductActionFailure(
                    action: .systemExtensionUpdate,
                    reason: .systemDNSRestoreUnconfirmed
                ), retryOperation: .systemExtensionUpdate)
            }
        }
        guard !isPerformingAction,
              !systemExtension.requestInProgress,
              systemExtensionState.requiresUpdate else {
            return failSettingsAction(ProductActionFailure(
                action: .systemExtensionUpdate,
                reason: .systemExtensionOperationUnavailable
            ), retryOperation: .systemExtensionUpdate)
        }
        systemExtension.activate()
        settingsRetryOperation = nil
        return .completed
    }

    func deactivateSystemExtension() {
        systemExtension.deactivate()
    }

    @discardableResult
    func deactivateSystemExtensionSafely() async -> ProductActionOutcome {
        guard !systemExtensionRequestInProgress, systemExtensionState.allowsDeactivation else {
            return failSettingsAction(ProductActionFailure(
                action: .systemExtensionDeactivation,
                reason: .systemExtensionOperationUnavailable
            ), retryOperation: .systemExtensionDeactivation)
        }
        let outcome = await restoreSystemDNS()
        guard outcome == .completed else {
            return routeFailureToSettings(
                outcome,
                action: .systemExtensionDeactivation,
                retryOperation: .systemExtensionDeactivation
            )
        }
        let state = await systemExtension.deactivateAndWait()
        switch state {
        case .notInstalled, .inactive, .uninstalling:
            settingsRetryOperation = nil
            userDefaults.set(true, forKey: ProductWindowPolicy.migrationEvaluatedKey)
            userDefaults.set(false, forKey: ProductWindowPolicy.onboardingCompletedKey)
            userDefaults.removeObject(forKey: ProductWindowPolicy.introductionCompletedKey)
            userDefaults.removeObject(forKey: ProductWindowPolicy.locationStepCompletedKey)
            userDefaults.removeObject(forKey: ProductWindowPolicy.setupProfileIDKey)
            return .completed
        case .restartRequired:
            return failSettingsAction(ProductActionFailure(
                action: .systemExtensionDeactivation,
                reason: .restartRequired,
                diagnosticDescription: state.description
            ), retryOperation: .systemExtensionDeactivation)
        case let .failed(message):
            return failSettingsAction(ProductActionFailure(
                action: .systemExtensionDeactivation,
                reason: .unknown,
                diagnosticDescription: message
            ), retryOperation: .systemExtensionDeactivation)
        case .checking, .activating, .awaitingApproval, .active, .deactivating,
             .updateRequired, .updateFailed, .downgradeBlocked:
            return failSettingsAction(ProductActionFailure(
                action: .systemExtensionDeactivation,
                reason: .systemExtensionOperationUnavailable,
                diagnosticDescription: state.description
            ), retryOperation: .systemExtensionDeactivation)
        }
    }

    func refreshLaunchAtLogin() {
        launchAtLogin.refresh()
        launchAtLoginStatus = launchAtLogin.status
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLogin.setEnabled(enabled)
        launchAtLoginStatus = launchAtLogin.status
    }

    func openLoginItemsSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    func openLocationSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
    }

    func openSystemExtensionSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.ExtensionsPreferences")
    }

    func quit() {
        quitHandler?()
    }

    func setQuitHandler(_ handler: (@MainActor () -> Void)?) {
        quitHandler = handler
    }

    func restoreSystemDNSForTermination() async -> DNSProxyControllerState {
        await backend.restoreSystemDNSForTermination()
    }

    func restoreSystemDNSForTerminationResult(
        rememberActiveState: Bool
    ) async -> DNSProxyTerminationRestoreResult {
        await backend.restoreSystemDNSForTerminationResult(
            rememberActiveState: rememberActiveState
        )
    }

    func cancelTerminationRequest() async {
        await backend.cancelTerminationRequest()
    }

    func copyDiagnosticSummary() {
        let summary = diagnosticReport().summary
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    @discardableResult
    func exportDiagnostics() async -> ProductActionOutcome {
        do {
            _ = try await diagnosticExporter.export(diagnosticReport().export)
            settingsRetryOperation = nil
            return .completed
        } catch {
            return failSettingsAction(ProductActionFailure(
                action: .diagnosticsExport,
                reason: .persistenceFailed,
                diagnosticDescription: error.localizedDescription
            ), retryOperation: .diagnosticsExport)
        }
    }

    func diagnosticReport(generatedAt: Date = Date()) -> ProductDiagnosticReport {
        ProductDiagnosticReport.make(
            configuration: configuration,
            proxy: proxy,
            network: network,
            systemExtensionDescription: systemExtensionState.userDescription,
            systemExtensionVersion: systemExtensionVersion,
            diagnostics: diagnostics,
            loggingMode: loggingMode,
            generatedAt: generatedAt
        )
    }

    func copyStartupFailureDetails() {
        guard let startupFailure else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(startupFailure.diagnosticDescription, forType: .string)
    }

    func revealStartupRecoveryArtifact() {
        guard case let .corruptConfiguration(_, url) = startupFailure else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealConfiguration() {
        guard let store = try? ConfigurationStore.live() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.configurationURL])
    }

    func openAppStore() {
        guard let url = URL(string: "macappstore://showUpdatesPage") else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func createProfile(_ draft: ProfileDraft) async -> ProductActionOutcome {
        await validatedProfileIntent(
            draft,
            action: .profileCreate,
            clearsDraftOnSuccess: true
        ) { .createProfile($0) }
    }

    @discardableResult
    func preflightProfile(_ draft: ProfileDraft) async -> ProductActionOutcome {
        profileTestGeneration &+= 1
        let generation = profileTestGeneration
        profileTestResult = nil
        let profile: DNSProfile
        do {
            profile = try draft.profile()
        } catch {
            return failValidation(error, action: .profileTest)
        }
        let outcome = await submit(.preflightProfile(profile))
        if outcome == .completed,
           generation == profileTestGeneration,
           !Task.isCancelled {
            profileTestResult = ProductProfileTestResult(
                profileID: profile.id,
                upstream: profile.upstream,
                message: "\"\(profile.name)\" passed the DNS test."
            )
        }
        return outcome
    }

    @discardableResult
    func duplicateProfile(
        sourceProfileID: DNSProfile.ID,
        draft: ProfileDraft
    ) async -> ProductActionOutcome {
        await validatedProfileIntent(
            draft,
            action: .profileDuplicate,
            clearsDraftOnSuccess: true
        ) {
            .duplicateProfile(sourceProfileID: sourceProfileID, duplicate: $0)
        }
    }

    @discardableResult
    func editProfile(_ draft: ProfileDraft) async -> ProductActionOutcome {
        await validatedProfileIntent(
            draft,
            action: .profileEdit,
            clearsDraftOnSuccess: true
        ) { .editProfile($0) }
    }

    @discardableResult
    func deleteProfile(
        _ profileID: DNSProfile.ID,
        plan: ProfileDeletionPlan = ProfileDeletionPlan()
    ) async -> ProductActionOutcome {
        await submit(.deleteProfile(profileID: profileID, plan: plan))
    }

    @discardableResult
    func saveRule(_ draft: RuleDraft) async -> ProductActionOutcome {
        do {
            return await submit(.saveRule(try draft.rule()), clearsDraftOnSuccess: true)
        } catch {
            return failValidation(error, action: .ruleSave)
        }
    }

    @discardableResult
    func deleteRule(_ ruleID: DNSRule.ID) async -> ProductActionOutcome {
        await submit(.deleteRule(ruleID))
    }

    @discardableResult
    func reorderRules(_ ruleIDs: [DNSRule.ID]) async -> ProductActionOutcome {
        await submit(.reorderRules(ruleIDs))
    }

    @discardableResult
    func setDefaultProfile(_ profileID: DNSProfile.ID) async -> ProductActionOutcome {
        await submit(.setDefaultProfile(profileID))
    }

    @discardableResult
    func setOperatingMode(_ mode: OperatingMode) async -> ProductActionOutcome {
        await submit(.setOperatingMode(mode))
    }

    @discardableResult
    func turnOnDNSProxy() async -> ProductActionOutcome {
        guard systemExtensionState == .active else {
            return failAction(ProductActionFailure(
                action: .dnsProxyEnable,
                reason: .systemExtensionNotActive
            ))
        }
        return await submit(.turnOnDNSProxy)
    }

    @discardableResult
    func restoreSystemDNS() async -> ProductActionOutcome {
        await submit(.restoreSystemDNS)
    }

    @discardableResult
    func restoreSystemDNSFromSettings() async -> ProductActionOutcome {
        routeFailureToSettings(
            await restoreSystemDNS(),
            retryOperation: .systemDNSRestore
        )
    }

    @discardableResult
    func reconnect() async -> ProductActionOutcome {
        await submit(.reconnect)
    }

    func refreshDiagnostics() async {
        _ = await submit(.refreshDiagnostics)
    }

    @discardableResult
    func setDebugLoggingEnabled(_ enabled: Bool) async -> ProductActionOutcome {
        routeFailureToSettings(
            await submit(.setDebugLogging(enabled)),
            retryOperation: .debugLogging(enabled)
        )
    }

    var systemExtensionVersion: String {
        guard installedSystemExtensionVersion != "Unavailable" else {
            return bundledSystemExtensionVersion
        }
        guard installedSystemExtensionVersion != bundledSystemExtensionVersion else {
            return installedSystemExtensionVersion
        }
        return "Installed \(installedSystemExtensionVersion); bundled \(bundledSystemExtensionVersion)"
    }

    @discardableResult
    func createNewConfiguration() async -> ProductActionOutcome {
        guard case let .corruptConfiguration(_, recoveryArtifactURL) = startupFailure else {
            return .failed(ProductActionFailure(
                action: .configurationReplace,
                reason: .notReady
            ))
        }
        return await submit(.createNewConfiguration(recoveryArtifactURL))
    }

    func requestLocationAuthorization() async {
        _ = await submit(.requestLocationAuthorization)
    }

    func clearActionFailure() {
        actionFailure = nil
    }

    func clearSettingsActionFailure() {
        settingsActionFailure = nil
    }

    func cancelProfileTest() {
        profileTestGeneration &+= 1
        profileTestResult = nil
    }

    @discardableResult
    func retryLastAction() async -> ProductActionOutcome {
        guard let retryIntent else {
            return .failed(ProductActionFailure(
                action: .diagnosticsRefresh,
                reason: .unknown,
                diagnosticDescription: "retryIntentUnavailable"
            ))
        }
        if case let .preflightProfile(profile) = retryIntent {
            return await preflightProfile(ProfileDraft(profile: profile))
        }
        return await submit(retryIntent)
    }

    @discardableResult
    func retrySettingsAction() async -> ProductActionOutcome {
        guard let settingsRetryOperation else {
            return failSettingsAction(ProductActionFailure(
                action: .diagnosticsRefresh,
                reason: .unknown,
                diagnosticDescription: "settingsRetryOperationUnavailable"
            ))
        }
        switch settingsRetryOperation {
        case .systemExtensionUpdate:
            return await updateSystemExtensionSafely()
        case .systemExtensionDeactivation:
            return await deactivateSystemExtensionSafely()
        case .diagnosticsExport:
            return await exportDiagnostics()
        case let .debugLogging(enabled):
            return await setDebugLoggingEnabled(enabled)
        case .systemDNSRestore:
            return await restoreSystemDNSFromSettings()
        }
    }

    @discardableResult
    func reportValidationFailure(
        _ error: any Error,
        action: ProductAction
    ) -> ProductActionOutcome {
        failValidation(error, action: action)
    }

    private func validatedProfileIntent(
        _ draft: ProfileDraft,
        action: ProductAction,
        clearsDraftOnSuccess: Bool = false,
        intent: (DNSProfile) -> ProductIntent
    ) async -> ProductActionOutcome {
        do {
            return await submit(
                intent(try draft.profile()),
                clearsDraftOnSuccess: clearsDraftOnSuccess
            )
        } catch {
            return failValidation(error, action: action)
        }
    }

    private func submit(
        _ intent: ProductIntent,
        clearsDraftOnSuccess: Bool = false
    ) async -> ProductActionOutcome {
        if case .recoveryRequired = proxy.state, !intent.isRecoveryAction {
            retryIntent = nil
            let failure = ProductActionFailure(
                action: intent.action,
                reason: .recoveryRequired
            )
            actionFailure = failure
            return .failed(failure)
        }
        guard !isPerformingAction else {
            return failAction(ProductActionFailure(
                action: intent.action,
                reason: .operationInProgress
            ))
        }
        isPerformingAction = true
        actionFailure = nil
        let outcome = await backend.performProductIntent(intent)
        await refresh()
        isPerformingAction = false
        let presentedOutcome: ProductActionOutcome
        if case let .failed(failure) = outcome,
           case .recoveryRequired = proxy.state,
           !intent.isRecoveryAction {
            presentedOutcome = .failed(ProductActionFailure(
                action: intent.action,
                reason: .recoveryRequired,
                diagnosticDescription: failure.diagnosticDescription
            ))
        } else {
            presentedOutcome = outcome
        }
        switch presentedOutcome {
        case .completed:
            retryIntent = nil
            if intent.action.invalidatesProfileTestResult {
                profileTestGeneration &+= 1
                profileTestResult = nil
            }
            if clearsDraftOnSuccess { activeDraft = nil }
        case let .failed(failure):
            Self.logger.error(
                "Product action failed: \(failure.diagnosticDescription, privacy: .private)"
            )
            if failure.reason != .cancelled {
                retryIntent = intent
                actionFailure = failure
            }
        }
        return presentedOutcome
    }

    private func failValidation(
        _ error: any Error,
        action: ProductAction
    ) -> ProductActionOutcome {
        Self.logger.error(
            "Product validation failed: \(error.localizedDescription, privacy: .private)"
        )
        let failure = ProductActionFailure(
            action: action,
            reason: .invalidConfiguration,
            diagnosticDescription: (error as? any LocalizedError)?.errorDescription
                ?? error.localizedDescription
        )
        retryIntent = nil
        actionFailure = failure
        return .failed(failure)
    }

    private func failAction(_ failure: ProductActionFailure) -> ProductActionOutcome {
        Self.logger.error(
            "Product action rejected: \(failure.diagnosticDescription, privacy: .private)"
        )
        retryIntent = nil
        actionFailure = failure
        return .failed(failure)
    }

    private func failSettingsAction(
        _ failure: ProductActionFailure,
        retryOperation: SettingsRetryOperation? = nil
    ) -> ProductActionOutcome {
        Self.logger.error(
            "Settings action failed: \(failure.diagnosticDescription, privacy: .private)"
        )
        settingsRetryOperation = retryOperation
        settingsActionFailure = failure
        return .failed(failure)
    }

    private func routeFailureToSettings(
        _ outcome: ProductActionOutcome,
        action: ProductAction? = nil,
        retryOperation: SettingsRetryOperation
    ) -> ProductActionOutcome {
        guard case let .failed(failure) = outcome else {
            settingsRetryOperation = nil
            return outcome
        }
        let routedFailure = ProductActionFailure(
            action: action ?? failure.action,
            reason: failure.reason,
            diagnosticDescription: failure.diagnosticDescription
        )
        actionFailure = nil
        retryIntent = nil
        return failSettingsAction(routedFailure, retryOperation: retryOperation)
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestWindow(_ destination: ProductWindowDestination) {
        windowRequest = ProductWindowRequest(destination: destination)
    }

    private func reconcileOnboardingMigration(with configuration: AppConfiguration?) {
        guard let configuration,
              !userDefaults.bool(forKey: ProductWindowPolicy.migrationEvaluatedKey) else {
            return
        }
        userDefaults.set(true, forKey: ProductWindowPolicy.migrationEvaluatedKey)
        guard !configuration.profiles.isEmpty, configuration.defaultProfileID != nil else { return }
        let setupProfileID = userDefaults.string(forKey: ProductWindowPolicy.setupProfileIDKey)
            .flatMap(UUID.init(uuidString:))
        let isPartialSetup = setupProfileID.map { id in
            configuration.profiles.contains { $0.id == id }
        } ?? false
        guard !isPartialSetup,
              !userDefaults.bool(forKey: ProductWindowPolicy.onboardingCompletedKey) else {
            return
        }
        userDefaults.set(true, forKey: ProductWindowPolicy.onboardingCompletedKey)
        if presentedProductWindow == .setup || windowRequest?.destination == .setup {
            requestWindow(.main)
        }
    }

    private func reconcileRequiredSetup(with configuration: AppConfiguration?) {
        guard let configuration, configuration.profiles.isEmpty else { return }
        userDefaults.set(false, forKey: ProductWindowPolicy.onboardingCompletedKey)
        if presentedProductWindow == .main || windowRequest?.destination == .main {
            requestWindow(.setup)
        }
    }
}

extension ProductIntent {
    var action: ProductAction {
        switch self {
        case .preflightProfile: .profileTest
        case .createProfile: .profileCreate
        case .duplicateProfile: .profileDuplicate
        case .editProfile: .profileEdit
        case .deleteProfile: .profileDelete
        case .saveRule: .ruleSave
        case .deleteRule: .ruleDelete
        case .reorderRules: .ruleReorder
        case .setDefaultProfile: .defaultProfileUpdate
        case .setOperatingMode: .operatingModeUpdate
        case .turnOnDNSProxy: .dnsProxyEnable
        case .restoreSystemDNS: .systemDNSRestore
        case .reconnect: .reconnect
        case .resetOnboardingConfiguration: .onboardingReset
        case .createNewConfiguration: .configurationReplace
        case .refreshDiagnostics: .diagnosticsRefresh
        case .requestLocationAuthorization: .locationAccessRequest
        case .setDebugLogging: .debugLoggingUpdate
        }
    }

    var isRecoveryAction: Bool {
        switch self {
        case .restoreSystemDNS, .reconnect, .createNewConfiguration, .refreshDiagnostics:
            true
        case .preflightProfile, .createProfile, .duplicateProfile, .editProfile,
              .deleteProfile, .saveRule, .deleteRule, .reorderRules, .setDefaultProfile,
              .setOperatingMode, .turnOnDNSProxy, .requestLocationAuthorization,
              .setDebugLogging, .resetOnboardingConfiguration:
            false
        }
    }
}

private extension ProductAction {
    var invalidatesProfileTestResult: Bool {
        switch self {
        case .profileCreate, .profileDuplicate, .profileEdit, .profileDelete:
            true
        case .profileTest, .profileSwitch, .ruleSave, .ruleDelete, .ruleReorder,
             .defaultProfileUpdate, .operatingModeUpdate, .dnsProxyEnable,
             .systemDNSRestore, .reconnect, .onboardingReset, .configurationReplace,
             .diagnosticsRefresh, .diagnosticsExport, .locationAccessRequest,
             .debugLoggingUpdate, .systemExtensionUpdate, .systemExtensionDeactivation:
            false
        }
    }
}

extension ProxySwitchFailureCode {
    var productFailureReason: ProductFailureReason {
        switch self {
        case .targetPreflightFailed: .upstreamTestUnclassified
        case .providerCompatibilityUnavailable: .compatibilityUnavailable
        case .oldGenerationChanged: .targetChanged
        case .managerStateUnavailable: .managerStateUnavailable
        case .targetWriteFailed: .targetWriteFailed
        case .targetReadinessTimedOut: .readinessTimedOut
        case .targetProviderFailed: .providerFailed
        }
    }
}

extension ProfileMutationFailure {
    var productFailureReason: ProductFailureReason {
        switch self {
        case .operationInProgress: .operationInProgress
        case .operationConflict, .expectedConfigurationMismatch, .configurationConflict: .conflict
        case .profileNotFound: .profileNotFound
        case .profileAlreadyExists: .profileAlreadyExists
        case .invalidDeletionPlan: .invalidDeletionPlan
        case .invalidDuplicateIdentity, .invalidDuplicatePayload, .invalidConfiguration:
            .invalidConfiguration
        case .configurationCommitFailed: .persistenceFailed
        case .controllerPreparationFailed: .runtimePreparationFailed
        case .desiredPersistenceFailed: .desiredConfigurationPersistenceFailed
        case .journalWriteFailed: .recoveryJournalWriteFailed
        case .runtimeRejected: .runtimeRejected
        }
    }
}

extension ProxySwitchFailure {
    var productActionFailure: ProductActionFailure {
        ProductActionFailure(
            action: .profileSwitch,
            reason: code.productFailureReason,
            diagnosticDescription: diagnosticSummary
        )
    }
}
