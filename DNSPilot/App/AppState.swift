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

enum ProductActionFailure: Equatable, Sendable {
    case startupUnavailable
    case networkUnavailable
    case invalidConfiguration
    case conflict
    case recoveryRequired
    case rejected(String)

    var message: String {
        switch self {
        case .startupUnavailable:
            "DNSPilot is not ready."
        case .networkUnavailable:
            "Connect to a network before turning on DNS Proxy in Automatic mode."
        case .invalidConfiguration:
            "The requested configuration is invalid."
        case .conflict:
            "The configuration changed. Review the latest values and try again."
        case .recoveryRequired:
            "Configuration recovery is required before making changes."
        case .rejected:
            "The operation could not be completed. Try again."
        }
    }

    var diagnosticDescription: String {
        switch self {
        case .startupUnavailable:
            "startupUnavailable"
        case .networkUnavailable:
            "networkUnavailable"
        case .invalidConfiguration:
            "invalidConfiguration"
        case .conflict:
            "conflict"
        case .recoveryRequired:
            "recoveryRequired"
        case let .rejected(reason):
            reason
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
    func cancelTerminationRequest() async
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
    @Published private(set) var actionFailure: ProductActionFailure?
    @Published private(set) var profileTestResult: String?
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
                }
            }
            .store(in: &cancellables)
    }

    var profiles: [DNSProfile] { configuration?.profiles ?? [] }
    var rules: [DNSRule] { configuration?.rules ?? [] }
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
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let snapshot = await backend.productSnapshot()
        guard generation == refreshGeneration else { return }
        configuration = snapshot.configuration
        reconcileOnboardingMigration(with: snapshot.configuration)
        reconcileRequiredSetup(with: snapshot.configuration)
        proxy = snapshot.proxy
        network = snapshot.network
        locationAuthorization = snapshot.locationAuthorization
        startupFailure = snapshot.startupFailure
        diagnostics = snapshot.diagnostics
        loggingMode = snapshot.loggingMode
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
        requestWindow(.setup)
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

    @discardableResult
    func updateSystemExtensionSafely() async -> ProductActionOutcome {
        guard startupCompleted,
              startupFailure == nil,
              !systemExtensionRequestInProgress,
              systemExtensionState.requiresUpdate else {
            return failSettingsAction(.rejected("systemExtensionUpdateUnavailable"))
        }
        guard !isPerformingAction else {
            return failSettingsAction(.rejected("operationInProgress"))
        }
        if proxy.state != .disabled {
            let outcome = await restoreSystemDNS()
            guard outcome == .completed else { return outcome }
            guard proxy.state == .disabled else {
                return failSettingsAction(.rejected("systemDNSRestoreUnconfirmed"))
            }
        }
        guard !isPerformingAction,
              !systemExtension.requestInProgress,
              systemExtensionState.requiresUpdate else {
            return failSettingsAction(.rejected("systemExtensionUpdateUnavailable"))
        }
        systemExtension.activate()
        return .completed
    }

    func deactivateSystemExtension() {
        systemExtension.deactivate()
    }

    @discardableResult
    func deactivateSystemExtensionSafely() async -> ProductActionOutcome {
        guard !systemExtensionRequestInProgress, systemExtensionState.allowsDeactivation else {
            return failSettingsAction(.rejected("systemExtensionOperationUnavailable"))
        }
        let outcome = await restoreSystemDNS()
        guard outcome == .completed else { return outcome }
        let state = await systemExtension.deactivateAndWait()
        switch state {
        case .notInstalled, .inactive, .uninstalling:
            userDefaults.set(true, forKey: ProductWindowPolicy.migrationEvaluatedKey)
            userDefaults.set(false, forKey: ProductWindowPolicy.onboardingCompletedKey)
            userDefaults.removeObject(forKey: ProductWindowPolicy.introductionCompletedKey)
            userDefaults.removeObject(forKey: ProductWindowPolicy.locationStepCompletedKey)
            userDefaults.removeObject(forKey: ProductWindowPolicy.setupProfileIDKey)
            return .completed
        case .restartRequired:
            return failSettingsAction(.rejected(state.description))
        case let .failed(message):
            return failSettingsAction(.rejected(message))
        case .checking, .activating, .awaitingApproval, .active, .deactivating,
             .updateRequired, .updateFailed, .downgradeBlocked:
            return failSettingsAction(.rejected("systemExtensionDeactivationFailed"))
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
            return .completed
        } catch {
            return failSettingsAction(.rejected(error.localizedDescription))
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
        await validatedProfileIntent(draft, clearsDraftOnSuccess: true) { .createProfile($0) }
    }

    @discardableResult
    func preflightProfile(_ draft: ProfileDraft) async -> ProductActionOutcome {
        profileTestResult = nil
        let outcome = await validatedProfileIntent(draft) { .preflightProfile($0) }
        if outcome == .completed { profileTestResult = "Profile test passed." }
        return outcome
    }

    @discardableResult
    func duplicateProfile(
        sourceProfileID: DNSProfile.ID,
        draft: ProfileDraft
    ) async -> ProductActionOutcome {
        await validatedProfileIntent(draft, clearsDraftOnSuccess: true) {
            .duplicateProfile(sourceProfileID: sourceProfileID, duplicate: $0)
        }
    }

    @discardableResult
    func editProfile(_ draft: ProfileDraft) async -> ProductActionOutcome {
        await validatedProfileIntent(draft, clearsDraftOnSuccess: true) { .editProfile($0) }
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
            return failValidation(error)
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
            return failAction(.rejected("systemExtensionNotActive"))
        }
        return await submit(.turnOnDNSProxy)
    }

    @discardableResult
    func restoreSystemDNS() async -> ProductActionOutcome {
        await submit(.restoreSystemDNS)
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
        await submit(.setDebugLogging(enabled))
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
            return .failed(.startupUnavailable)
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

    private func validatedProfileIntent(
        _ draft: ProfileDraft,
        clearsDraftOnSuccess: Bool = false,
        intent: (DNSProfile) -> ProductIntent
    ) async -> ProductActionOutcome {
        do {
            return await submit(
                intent(try draft.profile()),
                clearsDraftOnSuccess: clearsDraftOnSuccess
            )
        } catch {
            return failValidation(error)
        }
    }

    private func submit(
        _ intent: ProductIntent,
        clearsDraftOnSuccess: Bool = false
    ) async -> ProductActionOutcome {
        if case .recoveryRequired = proxy.state, !intent.isRecoveryAction {
            actionFailure = .recoveryRequired
            return .failed(.recoveryRequired)
        }
        guard !isPerformingAction else {
            return failAction(.rejected("operationInProgress"))
        }
        isPerformingAction = true
        actionFailure = nil
        let outcome = await backend.performProductIntent(intent)
        await refresh()
        isPerformingAction = false
        switch outcome {
        case .completed:
            if clearsDraftOnSuccess { activeDraft = nil }
        case let .failed(failure):
            Self.logger.error(
                "Product action failed: \(failure.diagnosticDescription, privacy: .private)"
            )
            actionFailure = failure
        }
        return outcome
    }

    private func failValidation(_ error: any Error) -> ProductActionOutcome {
        Self.logger.error(
            "Product validation failed: \(error.localizedDescription, privacy: .private)"
        )
        let failure = ProductActionFailure.rejected(
            (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        )
        actionFailure = failure
        return .failed(failure)
    }

    private func failAction(_ failure: ProductActionFailure) -> ProductActionOutcome {
        Self.logger.error(
            "Product action rejected: \(failure.diagnosticDescription, privacy: .private)"
        )
        actionFailure = failure
        return .failed(failure)
    }

    private func failSettingsAction(_ failure: ProductActionFailure) -> ProductActionOutcome {
        Self.logger.error(
            "Settings action failed: \(failure.diagnosticDescription, privacy: .private)"
        )
        settingsActionFailure = failure
        return .failed(failure)
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

private extension ProductIntent {
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
