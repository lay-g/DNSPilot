import Combine
import OSLog
import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case notFound
    case unavailable
    case failed(String)

    var isEnabled: Bool {
        switch self {
        case .enabled, .requiresApproval:
            true
        case .disabled, .notFound, .unavailable, .failed:
            false
        }
    }
}

@MainActor
protocol LaunchAtLoginRegistering: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class LaunchAtLoginService: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus

    private let registration: any LaunchAtLoginRegistering
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DNSPilot",
        category: "LaunchAtLogin"
    )

    init(registration: (any LaunchAtLoginRegistering)? = nil) {
        let resolvedRegistration = registration ?? {
            if AppRuntimeEnvironment.isUnitTestProcess {
                return IsolatedLaunchAtLoginRegistration() as any LaunchAtLoginRegistering
            }
            return SystemLaunchAtLoginRegistration() as any LaunchAtLoginRegistering
        }()
        self.registration = resolvedRegistration
        status = resolvedRegistration.status
    }

    func refresh() {
        status = registration.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try registration.register()
            } else {
                try registration.unregister()
            }
            status = registration.status
        } catch {
            logger.error(
                "Launch at Login update failed: \(error.localizedDescription, privacy: .private)"
            )
            status = .failed(error.localizedDescription)
        }
    }
}

@MainActor
private final class IsolatedLaunchAtLoginRegistration: LaunchAtLoginRegistering {
    let status = LaunchAtLoginStatus.unavailable

    func register() throws {
        throw LaunchAtLoginIsolationError.unitTestProcess
    }

    func unregister() throws {
        throw LaunchAtLoginIsolationError.unitTestProcess
    }
}

private enum LaunchAtLoginIsolationError: LocalizedError {
    case unitTestProcess

    var errorDescription: String? {
        "Unit tests cannot change Launch at Login."
    }
}

@MainActor
private final class SystemLaunchAtLoginRegistration: LaunchAtLoginRegistering {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}
