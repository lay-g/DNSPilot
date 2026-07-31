import Foundation
import SystemExtensions
import Testing
@testable import DNSPilot

@MainActor
struct SystemExtensionControllerTests {
    @Test func startsByCheckingInsteadOfReportingNotInstalled() {
        let controller = SystemExtensionController()

        #expect(controller.state == .checking)
    }

    @Test func emptyPropertiesMeanNotInstalled() {
        #expect(SystemExtensionController.resolvedState(for: []) == .notInstalled)
    }

    @Test func enabledPropertiesRestoreActiveState() {
        let properties = SystemExtensionController.PropertiesSnapshot(
            isEnabled: true,
            isAwaitingUserApproval: false,
            isUninstalling: false
        )

        #expect(SystemExtensionController.resolvedState(for: [properties]) == .active)
    }

    @Test func disabledPropertiesRemainInstalledButInactive() {
        let properties = SystemExtensionController.PropertiesSnapshot(
            isEnabled: false,
            isAwaitingUserApproval: false,
            isUninstalling: false
        )

        #expect(SystemExtensionController.resolvedState(for: [properties]) == .inactive)
    }

    @Test func awaitingApprovalTakesPriorityOverEnabledState() {
        let properties = SystemExtensionController.PropertiesSnapshot(
            isEnabled: true,
            isAwaitingUserApproval: true,
            isUninstalling: false
        )

        #expect(SystemExtensionController.resolvedState(for: [properties]) == .awaitingApproval)
    }

    @Test func uninstallingPropertiesReportTransitionWithoutAssumingRestart() {
        let properties = SystemExtensionController.PropertiesSnapshot(
            isEnabled: false,
            isAwaitingUserApproval: false,
            isUninstalling: true
        )

        #expect(SystemExtensionController.resolvedState(for: [properties]) == .uninstalling)
    }

    @Test func enabledRecordTakesPriorityOverOldUninstallingRecord() {
        let enabled = SystemExtensionController.PropertiesSnapshot(
            isEnabled: true,
            isAwaitingUserApproval: false,
            isUninstalling: false
        )
        let uninstalling = SystemExtensionController.PropertiesSnapshot(
            isEnabled: false,
            isAwaitingUserApproval: false,
            isUninstalling: true
        )

        #expect(
            SystemExtensionController.resolvedState(for: [enabled, uninstalling]) == .active
        )
    }

    @Test func pendingRemovalCannotBeDeactivatedAgain() {
        #expect(SystemExtensionController.State.uninstalling.allowsActivation)
        #expect(!SystemExtensionController.State.uninstalling.allowsDeactivation)
        #expect(SystemExtensionController.State.active.allowsDeactivation)
        #expect(SystemExtensionController.State.restartRequired.allowsActivation)
        #expect(SystemExtensionController.State.restartRequired.allowsDeactivation)
        #expect(!SystemExtensionController.State.updateRequired.allowsDeactivation)
        #expect(!SystemExtensionController.State.updateFailed("failed").allowsDeactivation)
        #expect(!SystemExtensionController.State.downgradeBlocked.allowsDeactivation)
        #expect(!SystemExtensionController.State.failed("unknown state").allowsDeactivation)
        #expect(SystemExtensionController.State.updateFailed("failed").allowsActivation)
    }

    @Test func userDescriptionDoesNotExposeSystemErrorDetails() {
        let detail = "OSSystemExtensionErrorDomain error 9"

        #expect(
            SystemExtensionController.State.failed(detail).userDescription
                == "macOS did not complete the System Extension request. Retry or open System Settings."
        )
        #expect(
            SystemExtensionController.State.updateFailed(detail).userDescription
                == "The System Extension update did not complete. Retry safely or review Diagnostics."
        )
    }

    @Test func bundleVersionsUseNumericBuildOrdering() {
        let build9 = version("1.0", "9")
        let build10 = version("1.0", "10")
        let nextRelease = version("1.1", "1")

        #expect(build9.isOlder(than: build10))
        #expect(nextRelease.isOlder(than: build10))
        #expect(!build10.isOlder(than: build10))
        #expect(version("2.0", "19").isOlder(than: version("1.9", "20")))
    }

    @Test func installedVersionIsComparedWithBundledCandidate() {
        let installed = properties(enabled: true, version: version("1.0", "13"))

        #expect(SystemExtensionController.resolvedState(
            for: [installed],
            bundledVersion: version("1.0", "13")
        ) == .active)
        #expect(SystemExtensionController.resolvedState(
            for: [installed],
            bundledVersion: version("1.0", "17")
        ) == .updateRequired)
        #expect(SystemExtensionController.resolvedState(
            for: [installed],
            bundledVersion: version("1.0", "12")
        ) == .downgradeBlocked)
    }

    @Test func enabledVersionWinsOverNewerStaleUninstallingRecord() {
        let active = properties(enabled: true, version: version("1.0", "13"))
        let stale = properties(uninstalling: true, version: version("1.0", "17"))

        #expect(SystemExtensionController.installedVersion(in: [stale, active]) == version("1.0", "13"))
        #expect(SystemExtensionController.resolvedState(
            for: [stale, active],
            bundledVersion: version("1.0", "17")
        ) == .updateRequired)
    }

    @Test func pendingRemovalDoesNotRequestAutomaticReplacement() {
        let uninstalling = properties(uninstalling: true, version: version("1.0", "13"))
        let state = SystemExtensionController.resolvedState(
            for: [uninstalling],
            bundledVersion: version("1.0", "17")
        )

        #expect(state == .uninstalling)
        #expect(!state.requiresUpdate)
    }

    @Test func replacementDelegateAllowsUpgradeButBlocksSameVersionAndDowngrade() {
        #expect(SystemExtensionController.replacementAction(
            existingVersion: version("1.0", "13"),
            bundledVersion: version("1.0", "17")
        ) == .replace)
        #expect(SystemExtensionController.replacementAction(
            existingVersion: version("1.0", "17"),
            bundledVersion: version("1.0", "17")
        ) == .cancel)
        #expect(SystemExtensionController.replacementAction(
            existingVersion: version("1.0", "17"),
            bundledVersion: version("1.0", "13")
        ) == .cancel)
    }

    @Test func requestFailureRetainsVersionMismatchProtection() {
        #expect(SystemExtensionController.versionMismatchStateAfterRequestFailure(
            installedVersion: version("1.0", "13"),
            bundledVersion: version("1.0", "17"),
            message: "failed"
        ) == .updateFailed("failed"))
        #expect(SystemExtensionController.versionMismatchStateAfterRequestFailure(
            installedVersion: version("1.0", "18"),
            bundledVersion: version("1.0", "17"),
            message: "failed"
        ) == .downgradeBlocked)
        #expect(SystemExtensionController.versionMismatchStateAfterRequestFailure(
            installedVersion: version("1.0", "17"),
            bundledVersion: version("2.0", "17"),
            message: "failed"
        ) == nil)
    }

    @Test func extensionNotFoundErrorCanRecoverBySynchronizing() {
        let extensionNotFound = NSError(
            domain: OSSystemExtensionErrorDomain,
            code: OSSystemExtensionError.Code.extensionNotFound.rawValue
        )
        let unrelated = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)

        #expect(SystemExtensionController.isExtensionNotFoundError(extensionNotFound))
        #expect(!SystemExtensionController.isExtensionNotFoundError(unrelated))
    }

    @Test func deactivationNotFoundIsRecoveredOnlyAfterRemovalIsConfirmed() {
        let uninstalling = SystemExtensionController.PropertiesSnapshot(
            isEnabled: false,
            isAwaitingUserApproval: false,
            isUninstalling: true
        )
        let active = SystemExtensionController.PropertiesSnapshot(
            isEnabled: true,
            isAwaitingUserApproval: false,
            isUninstalling: false
        )

        #expect(
            SystemExtensionController.resolvedState(
                for: [uninstalling],
                recoveringFromDeactivationFailure: "extension not found"
            ) == .uninstalling
        )
        #expect(
            SystemExtensionController.resolvedState(
                for: [],
                recoveringFromDeactivationFailure: "extension not found"
            ) == .notInstalled
        )
        #expect(
            SystemExtensionController.resolvedState(
                for: [active],
                recoveringFromDeactivationFailure: "extension not found"
            ) == .failed("extension not found")
        )
    }

    private func version(
        _ shortVersion: String,
        _ buildVersion: String
    ) -> SystemExtensionController.BundleVersion {
        SystemExtensionController.BundleVersion(
            shortVersion: shortVersion,
            buildVersion: buildVersion
        )
    }

    private func properties(
        enabled: Bool = false,
        awaitingApproval: Bool = false,
        uninstalling: Bool = false,
        version: SystemExtensionController.BundleVersion
    ) -> SystemExtensionController.PropertiesSnapshot {
        SystemExtensionController.PropertiesSnapshot(
            isEnabled: enabled,
            isAwaitingUserApproval: awaitingApproval,
            isUninstalling: uninstalling,
            version: version
        )
    }
}
