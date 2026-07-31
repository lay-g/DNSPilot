import Foundation
import Testing
@testable import DNSPilot

@MainActor
struct LaunchAtLoginServiceTests {
    @Test func defaultsToSystemStatusAndRefreshesExternalChanges() {
        let registration = FakeLaunchAtLoginRegistration(status: .disabled)
        let service = LaunchAtLoginService(registration: registration)
        #expect(service.status == .disabled)

        registration.status = .requiresApproval
        service.refresh()
        #expect(service.status == .requiresApproval)
        #expect(service.status.isEnabled)
    }

    @Test func enablingAndDisablingMapRegistrationStatus() {
        let registration = FakeLaunchAtLoginRegistration(status: .disabled)
        let service = LaunchAtLoginService(registration: registration)

        service.setEnabled(true)
        #expect(registration.registerCount == 1)
        #expect(service.status == .enabled)

        service.setEnabled(false)
        #expect(registration.unregisterCount == 1)
        #expect(service.status == .disabled)
    }

    @Test func registrationFailureIsStableAndDoesNotClaimEnabled() {
        let registration = FakeLaunchAtLoginRegistration(status: .disabled)
        registration.error = TestError.denied
        let service = LaunchAtLoginService(registration: registration)

        service.setEnabled(true)

        #expect(service.status == .failed("Registration denied"))
        #expect(!service.status.isEnabled)
    }

    @Test func unavailableStatusesDoNotClaimEnabled() {
        #expect(!LaunchAtLoginStatus.notFound.isEnabled)
        #expect(!LaunchAtLoginStatus.unavailable.isEnabled)
    }
}

@MainActor
private final class FakeLaunchAtLoginRegistration: LaunchAtLoginRegistering {
    var status: LaunchAtLoginStatus
    var error: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let error { throw error }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let error { throw error }
        status = .disabled
    }
}

private enum TestError: LocalizedError {
    case denied

    var errorDescription: String? { "Registration denied" }
}
