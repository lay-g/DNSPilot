import Combine
import Foundation
import OSLog
import SystemExtensions

@MainActor
protocol SystemExtensionControlling: AnyObject {
    var state: SystemExtensionController.State { get }
    var requestInProgress: Bool { get }
    var installedVersion: SystemExtensionController.BundleVersion? { get }
    var bundledVersion: SystemExtensionController.BundleVersion? { get }
    var statePublisher: AnyPublisher<SystemExtensionController.State, Never> { get }
    func synchronizeState()
    func activate()
    func deactivate()
    func deactivateAndWait() async -> SystemExtensionController.State
}

@MainActor
final class SystemExtensionController: NSObject, ObservableObject {
    private static let deactivationWaitTimeout = Duration.seconds(30)

    struct BundleVersion: Equatable, Sendable {
        let shortVersion: String
        let buildVersion: String

        var description: String {
            "\(shortVersion) (\(buildVersion))"
        }

        func isOlder(than other: Self) -> Bool {
            Self.compare(buildVersion, other.buildVersion) == .orderedAscending
        }

        private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
            lhs.compare(
                rhs,
                options: [.numeric, .caseInsensitive],
                range: nil,
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
    }

    enum State: Equatable {
        case checking
        case notInstalled
        case activating
        case awaitingApproval
        case active
        case deactivating
        case inactive
        case uninstalling
        case restartRequired
        case updateRequired
        case updateFailed(String)
        case downgradeBlocked
        case failed(String)

        var description: String {
            switch self {
            case .checking:
                "Checking installation status..."
            case .notInstalled:
                "Not installed"
            case .activating:
                "Activating..."
            case .awaitingApproval:
                "Approval required in System Settings"
            case .active:
                "Active"
            case .deactivating:
                "Deactivating..."
            case .inactive:
                "Inactive"
            case .uninstalling:
                "Removal pending; restart may be required"
            case .restartRequired:
                "Restart required to complete System Extension change"
            case .updateRequired:
                "A newer bundled System Extension must be installed"
            case let .updateFailed(message):
                "System Extension update failed: \(message)"
            case .downgradeBlocked:
                "The installed System Extension is newer than this application"
            case let .failed(message):
                "Failed: \(message)"
            }
        }

        var allowsDeactivation: Bool {
            switch self {
            case .active, .awaitingApproval, .inactive, .restartRequired:
                true
            case .checking, .notInstalled, .activating, .deactivating, .uninstalling,
                 .updateRequired, .updateFailed, .downgradeBlocked, .failed:
                false
            }
        }

        var allowsActivation: Bool {
            switch self {
            case .checking, .activating, .deactivating:
                false
            case .notInstalled, .awaitingApproval, .active, .inactive, .uninstalling,
                 .restartRequired, .updateRequired, .updateFailed, .failed:
                true
            case .downgradeBlocked:
                false
            }
        }

        var requiresUpdate: Bool {
            switch self {
            case .updateRequired, .updateFailed:
                true
            case .checking, .notInstalled, .activating, .awaitingApproval, .active,
                 .deactivating, .inactive, .uninstalling, .restartRequired, .downgradeBlocked,
                 .failed:
                false
            }
        }

    }

    struct PropertiesSnapshot: Equatable, Sendable {
        let isEnabled: Bool
        let isAwaitingUserApproval: Bool
        let isUninstalling: Bool
        let version: BundleVersion?

        init(
            isEnabled: Bool,
            isAwaitingUserApproval: Bool,
            isUninstalling: Bool,
            version: BundleVersion? = nil
        ) {
            self.isEnabled = isEnabled
            self.isAwaitingUserApproval = isAwaitingUserApproval
            self.isUninstalling = isUninstalling
            self.version = version
        }
    }

    @Published private(set) var state = State.checking {
        didSet { resumeDeactivationWaitersIfFinished() }
    }
    private(set) var installedVersion: BundleVersion?

    static let shared = SystemExtensionController()

    private enum Operation {
        case activation
        case deactivation
        case synchronization
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DNSPilot",
        category: "SystemExtension"
    )
    private var operation: Operation?
    private var pendingRequest: OSSystemExtensionRequest?
    private var pendingDeactivationFailure: String?
    private var deactivationWaiters: [UUID: CheckedContinuation<State, Never>] = [:]
    private var deactivationTimeoutTasks: [UUID: Task<Void, Never>] = [:]

    var requestInProgress: Bool {
        operation != nil
    }

    var bundledVersion: BundleVersion? {
        let directory = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for url in urls where url.pathExtension == "systemextension" {
            guard let bundle = Bundle(url: url), bundle.bundleIdentifier == extensionIdentifier,
                  let shortVersion = bundle.object(
                      forInfoDictionaryKey: "CFBundleShortVersionString"
                  ) as? String,
                  let buildVersion = bundle.object(
                      forInfoDictionaryKey: "CFBundleVersion"
                  ) as? String else { continue }
            return BundleVersion(shortVersion: shortVersion, buildVersion: buildVersion)
        }
        return nil
    }

    func synchronizeState() {
        submit(
            .propertiesRequest(
                forExtensionWithIdentifier: extensionIdentifier,
                queue: .main
            ),
            operation: .synchronization
        )
    }

    func activate() {
        submit(.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        ), operation: .activation)
    }

    func deactivate() {
        submit(.deactivationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        ), operation: .deactivation)
    }

    func deactivateAndWait() async -> State {
        guard operation == nil, state.allowsDeactivation else { return state }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            deactivationWaiters[waiterID] = continuation
            deactivationTimeoutTasks[waiterID] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.deactivationWaitTimeout)
                guard !Task.isCancelled else { return }
                self?.timeoutDeactivationWaiter(waiterID)
            }
            deactivate()
        }
    }

    private func resumeDeactivationWaitersIfFinished() {
        guard !deactivationWaiters.isEmpty else { return }
        switch state {
        case .checking, .deactivating:
            return
        case .notInstalled, .activating, .awaitingApproval, .active, .inactive, .uninstalling,
             .restartRequired, .updateRequired, .updateFailed, .downgradeBlocked, .failed:
            let waiters = Array(deactivationWaiters.values)
            deactivationWaiters.removeAll()
            let timeoutTasks = Array(deactivationTimeoutTasks.values)
            deactivationTimeoutTasks.removeAll()
            timeoutTasks.forEach { $0.cancel() }
            waiters.forEach { $0.resume(returning: state) }
        }
    }

    private func timeoutDeactivationWaiter(_ waiterID: UUID) {
        guard let waiter = deactivationWaiters.removeValue(forKey: waiterID) else { return }
        deactivationTimeoutTasks.removeValue(forKey: waiterID)
        waiter.resume(returning: .failed("System Extension deactivation timed out."))
    }

    private var extensionIdentifier: String {
        guard let identifier = Bundle.main.object(
            forInfoDictionaryKey: "DNSProxyExtensionIdentifier"
        ) as? String, !identifier.isEmpty else {
            preconditionFailure("DNSProxyExtensionIdentifier is missing from the Host Info.plist")
        }
        return identifier
    }

    private func submit(_ request: OSSystemExtensionRequest, operation: Operation) {
        guard self.operation == nil else { return }

        self.operation = operation
        pendingRequest = request
        switch operation {
        case .activation:
            state = .activating
        case .deactivation:
            state = .deactivating
        case .synchronization:
            state = .checking
        }
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func finishOperation(for request: OSSystemExtensionRequest) -> Operation? {
        guard pendingRequest === request else { return nil }
        pendingRequest = nil
        defer { operation = nil }
        return operation
    }

    static func resolvedState(
        for properties: [PropertiesSnapshot],
        bundledVersion: BundleVersion? = nil
    ) -> State {
        guard !properties.isEmpty else { return .notInstalled }
        if properties.contains(where: \.isAwaitingUserApproval) {
            return .awaitingApproval
        }
        if let enabled = preferredSnapshot(in: properties.filter(\.isEnabled)) {
            return versionAwareState(
                installedVersion: enabled.version,
                bundledVersion: bundledVersion,
                matchingState: .active
            )
        }
        if let installed = preferredSnapshot(in: properties.filter { !$0.isUninstalling }) {
            return versionAwareState(
                installedVersion: installed.version,
                bundledVersion: bundledVersion,
                matchingState: .inactive
            )
        }
        if properties.contains(where: \.isUninstalling) {
            return .uninstalling
        }
        return .inactive
    }

    static func installedVersion(in properties: [PropertiesSnapshot]) -> BundleVersion? {
        let awaitingApproval = properties.filter(\.isAwaitingUserApproval)
        if let snapshot = preferredSnapshot(in: awaitingApproval) { return snapshot.version }
        let enabled = properties.filter(\.isEnabled)
        if let snapshot = preferredSnapshot(in: enabled) { return snapshot.version }
        let installed = properties.filter { !$0.isUninstalling }
        if let snapshot = preferredSnapshot(in: installed) { return snapshot.version }
        return preferredSnapshot(in: properties)?.version
    }

    static func replacementAction(
        existingVersion: BundleVersion,
        bundledVersion: BundleVersion
    ) -> OSSystemExtensionRequest.ReplacementAction {
        existingVersion.isOlder(than: bundledVersion) ? .replace : .cancel
    }

    static func versionMismatchStateAfterRequestFailure(
        installedVersion: BundleVersion?,
        bundledVersion: BundleVersion?,
        message: String
    ) -> State? {
        guard let installedVersion, let bundledVersion else { return nil }
        if installedVersion.isOlder(than: bundledVersion) { return .updateFailed(message) }
        if bundledVersion.isOlder(than: installedVersion) { return .downgradeBlocked }
        return nil
    }

    private static func preferredSnapshot(
        in properties: [PropertiesSnapshot]
    ) -> PropertiesSnapshot? {
        properties.max { lhs, rhs in
            switch (lhs.version, rhs.version) {
            case let (lhs?, rhs?):
                lhs.isOlder(than: rhs)
            case (nil, .some):
                true
            case (.some, nil), (nil, nil):
                false
            }
        }
    }

    private static func versionAwareState(
        installedVersion: BundleVersion?,
        bundledVersion: BundleVersion?,
        matchingState: State
    ) -> State {
        guard let installedVersion, let bundledVersion else { return matchingState }
        if installedVersion.isOlder(than: bundledVersion) { return .updateRequired }
        if bundledVersion.isOlder(than: installedVersion) { return .downgradeBlocked }
        return matchingState
    }

    static func isExtensionNotFoundError(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == OSSystemExtensionErrorDomain
            && error.code == OSSystemExtensionError.Code.extensionNotFound.rawValue
    }

    static func resolvedState(
        for properties: [PropertiesSnapshot],
        bundledVersion: BundleVersion? = nil,
        recoveringFromDeactivationFailure failure: String?
    ) -> State {
        let resolved = resolvedState(for: properties, bundledVersion: bundledVersion)
        guard let failure else { return resolved }
        switch resolved {
        case .notInstalled, .uninstalling, .updateRequired, .updateFailed, .downgradeBlocked:
            return resolved
        case .checking, .activating, .awaitingApproval, .active, .deactivating, .inactive,
             .restartRequired, .failed:
            return .failed(failure)
        }
    }
}

extension SystemExtensionController: SystemExtensionControlling {
    var statePublisher: AnyPublisher<State, Never> {
        $state.eraseToAnyPublisher()
    }
}

extension SystemExtensionController: @MainActor OSSystemExtensionRequestDelegate {
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard pendingRequest === request, operation == .activation else { return }
        state = .awaitingApproval
        logger.notice("System Extension activation requires user approval")
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension newExtension: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        Self.replacementAction(
            existingVersion: BundleVersion(
                shortVersion: existing.bundleShortVersion,
                buildVersion: existing.bundleVersion
            ),
            bundledVersion: BundleVersion(
                shortVersion: newExtension.bundleShortVersion,
                buildVersion: newExtension.bundleVersion
            )
        )
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        if pendingRequest === request, operation == .synchronization {
            logger.notice("System Extension properties request emitted a generic completion callback")
            return
        }
        guard finishOperation(for: request) != nil else { return }
        logger.notice("System Extension request completed with result \(result.rawValue, privacy: .public)")

        switch result {
        case .completed:
            synchronizeState()
        case .willCompleteAfterReboot:
            state = .restartRequired
        @unknown default:
            state = .failed("Unknown System Extension request result: \(result.rawValue)")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        guard let operation = finishOperation(for: request) else { return }
        logger.error("System Extension request failed: \(error.localizedDescription, privacy: .public)")
        if operation == .deactivation, Self.isExtensionNotFoundError(error) {
            logger.notice("System Extension is no longer deactivatable; synchronizing current state")
            pendingDeactivationFailure = error.localizedDescription
            synchronizeState()
            return
        }
        if operation == .synchronization {
            pendingDeactivationFailure = nil
            if let mismatchState = Self.versionMismatchStateAfterRequestFailure(
                installedVersion: installedVersion,
                bundledVersion: bundledVersion,
                message: error.localizedDescription
            ) {
                state = mismatchState
                return
            }
        }
        if operation == .activation,
           case let .updateFailed(message)? = Self.versionMismatchStateAfterRequestFailure(
               installedVersion: installedVersion,
               bundledVersion: bundledVersion,
               message: error.localizedDescription
           ) {
            state = .updateFailed(message)
        } else {
            state = .failed(error.localizedDescription)
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        guard finishOperation(for: request) == .synchronization else { return }
        let snapshots = properties.map {
            PropertiesSnapshot(
                isEnabled: $0.isEnabled,
                isAwaitingUserApproval: $0.isAwaitingUserApproval,
                isUninstalling: $0.isUninstalling,
                version: BundleVersion(
                    shortVersion: $0.bundleShortVersion,
                    buildVersion: $0.bundleVersion
                )
            )
        }
        let bundledVersion = bundledVersion
        installedVersion = Self.installedVersion(in: snapshots)
        let resolved = Self.resolvedState(
            for: snapshots,
            bundledVersion: bundledVersion,
            recoveringFromDeactivationFailure: pendingDeactivationFailure
        )
        pendingDeactivationFailure = nil
        state = resolved
        logger.notice("System Extension state synchronized as \(self.state.description, privacy: .public)")
    }
}
