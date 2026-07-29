#if DNSPILOT_DEBUG_LOCAL
import Darwin
import Foundation

enum EnabledManagerGateAProbe {
    static let argumentName = "--dnspilot-gate-a-enabled-update"

    private static let observationCount = 20
    private static let observationInterval = Duration.milliseconds(100)
    private static let runtimeRequestTimeout = Duration.milliseconds(500)

    @MainActor
    static func isRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bundle: Bundle = .main
    ) -> Bool {
        arguments.contains(argumentName)
            && bundle.object(forInfoDictionaryKey: "DNSPilotGateAProbeAllowed") as? String
                == "YES"
    }

    @MainActor
    static func start() {
        Task {
            let report = await run()
            write(report)
            exit(report.result == "pass" ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    private static func run() async -> GateAProbeReport {
        let startedAt = Date()
        let manager = NetworkExtensionDNSProxyManager()
        let runtime = MachXPCStatusProvider()
        var beforeManager: GateAManagerIdentity?
        var targetManager: GateAManagerIdentity?
        var restoredManager: GateAManagerIdentity?
        var beforeRuntime: GateARuntimeSample?
        var targetWindow: [GateARuntimeSample] = []
        var restoreWindow: [GateARuntimeSample] = []
        var oldOwner: DNSProxyManagerGateAOwner?
        var targetOwner: DNSProxyManagerGateAOwner?
        var failure: String?
        var restoreFailure: String?
        var restoreMode = "not-needed"
        var managerWriteStarted = false
        var targetWasConfirmed = false

        do {
            let owner = try await manager.gateALoadOwner()
            let snapshot = owner.snapshot
            let persisted = try requireEnabledConfiguration(snapshot)
            let status = try await runtimeStatus(runtime)
            try requireRuntime(status, matches: persisted)
            let providerInstanceID = try requireValue(
                status.providerInstanceID,
                error: .runtimeDoesNotMatchManager
            )
            let transitionSequence = try requireValue(
                status.transitionSequence,
                error: .runtimeDoesNotMatchManager
            )
            beforeManager = GateAManagerIdentity(owner)
            beforeRuntime = GateARuntimeSample(status: status)
            oldOwner = owner

            let targetValue = try ActiveProxyConfiguration(
                generation: UUID(),
                profileID: persisted.value.profileID,
                upstream: persisted.value.upstream,
                loggingMode: persisted.value.loggingMode,
                schemaVersion: persisted.value.schemaVersion
            )
            let target = try PersistedProxyConfiguration(value: targetValue)
            let expectedTargetOwner = try await manager.gateAPreviewEnabledConfiguration(
                target,
                replacing: owner
            )
            targetOwner = expectedTargetOwner
            managerWriteStarted = true
            let confirmed = try await manager.gateAReplaceEnabledConfiguration(
                target,
                replacing: owner
            )
            guard confirmed == expectedTargetOwner else {
                throw GateAProbeError.managerChangedBeforeRestore
            }
            targetWasConfirmed = true
            targetOwner = confirmed
            targetManager = GateAManagerIdentity(confirmed)
            targetWindow = await observe(runtime: runtime)

            guard targetWindow.count == observationCount else {
                throw GateAProbeError.runtimeObservationFailed
            }
            guard targetWindow.allSatisfy({ $0.matches(
                configuration: persisted,
                providerInstanceID: providerInstanceID,
                transitionSequence: transitionSequence
            ) }) else {
                throw GateAProbeError.providerLifecycleChanged
            }
            let finalTargetOwner = try await manager.gateALoadOwner()
            guard finalTargetOwner == confirmed else {
                throw GateAProbeError.managerChangedBeforeRestore
            }
        } catch {
            failure = error.localizedDescription
        }

        if managerWriteStarted, let oldOwner {
            let oldConfiguration = try? requireEnabledConfiguration(oldOwner.snapshot)
            let managerRestore = await restoreManager(
                manager: manager,
                old: oldOwner,
                target: targetOwner
            )
            restoreMode = managerRestore.mode
            restoredManager = managerRestore.owner.map(GateAManagerIdentity.init)
            restoreFailure = managerRestore.issue

            if managerRestore.issue == nil, let oldConfiguration {
                if targetWasConfirmed, managerRestore.mode == "already-old" {
                    failure = failure
                        ?? GateAProbeError.managerChangedBeforeRestore.localizedDescription
                }

                restoreWindow = await observe(runtime: runtime)
                let finalOwner = try? await manager.gateALoadOwner()
                if let finalOwner {
                    restoredManager = GateAManagerIdentity(finalOwner)
                }

                if
                    let finalOwner,
                    isStableRestore(
                        owner: finalOwner,
                        samples: restoreWindow,
                        expectedOwner: oldOwner,
                        configuration: oldConfiguration
                    )
                {
                    if
                        failure == nil,
                        let beforeRuntime,
                        !restoreWindow.allSatisfy({ $0.matches(
                            configuration: oldConfiguration,
                            providerInstanceID: beforeRuntime.providerInstanceID,
                            transitionSequence: beforeRuntime.transitionSequence
                        ) })
                    {
                        failure = GateAProbeError.providerLifecycleChanged.localizedDescription
                    }
                } else {
                    if let finalOwner, finalOwner == oldOwner {
                        let disableResult = await disableForSafeRecovery(
                            manager: manager,
                            expected: finalOwner
                        )
                        restoreMode = disableResult.mode
                        restoredManager = disableResult.owner.map(GateAManagerIdentity.init)
                        restoreFailure = disableResult.issue
                    } else {
                        restoreFailure = GateAProbeError.managerOwnershipChanged
                            .localizedDescription
                    }
                }
            }

            if managerRestore.issue != nil {
                let currentOwner = try? await manager.gateALoadOwner()
                if
                    let currentOwner,
                    currentOwner == oldOwner
                        || targetOwner.map({ currentOwner == $0 }) == true
                {
                    let disableResult = await disableForSafeRecovery(
                        manager: manager,
                        expected: currentOwner
                    )
                    restoreMode = disableResult.mode
                    restoredManager = disableResult.owner.map(GateAManagerIdentity.init)
                    restoreFailure = disableResult.issue
                }
            }
        } else if managerWriteStarted {
            restoreFailure = "The probe could not recover an exact original manager owner."
        }

        return GateAProbeReport(
            schemaVersion: 1,
            result: failure == nil && restoreFailure == nil ? "pass" : "fail",
            startedAt: startedAt,
            finishedAt: Date(),
            failure: failure,
            restoreFailure: restoreFailure,
            restoreMode: restoreMode,
            beforeManager: beforeManager,
            targetManager: targetManager,
            restoredManager: restoredManager,
            beforeRuntime: beforeRuntime,
            targetWindow: targetWindow,
            restoreWindow: restoreWindow
        )
    }

    private static func restoreManager(
        manager: NetworkExtensionDNSProxyManager,
        old: DNSProxyManagerGateAOwner,
        target: DNSProxyManagerGateAOwner?
    ) async -> GateAManagerRestoreResult {
        var lastIssue: String?
        var didRequestRestore = false
        for _ in 0..<3 {
            do {
                let current = try await manager.gateALoadOwner()
                if current == old {
                    return GateAManagerRestoreResult(
                        owner: current,
                        mode: didRequestRestore ? "enabled-exact-update" : "already-old",
                        issue: nil
                    )
                }
                if let target, current == target {
                    didRequestRestore = true
                    let restored = try await manager.gateAReplaceEnabledConfiguration(
                        try requireEnabledConfiguration(old.snapshot),
                        replacing: target
                    )
                    guard restored == old else {
                        return GateAManagerRestoreResult(
                            owner: restored,
                            mode: "external-owner",
                            issue: GateAProbeError.managerOwnershipChanged.localizedDescription
                        )
                    }
                    continue
                }
                if
                    !current.snapshot.isEnabled,
                    (current.hasSameConfiguration(as: old)
                        || target.map(current.hasSameConfiguration(as:)) == true)
                {
                    return GateAManagerRestoreResult(
                        owner: current,
                        mode: "left-disabled",
                        issue: "The manager is disabled; Provider stop remains unconfirmed."
                    )
                }
                return GateAManagerRestoreResult(
                    owner: current,
                    mode: "external-owner",
                    issue: GateAProbeError.managerOwnershipChanged.localizedDescription
                )
            } catch {
                lastIssue = error.localizedDescription
            }
        }

        let finalOwner = try? await manager.gateALoadOwner()
        if let finalOwner, finalOwner == old {
            return GateAManagerRestoreResult(
                owner: finalOwner,
                mode: "old-confirmed-after-uncertain-save",
                issue: nil
            )
        }
        return GateAManagerRestoreResult(
            owner: finalOwner,
            mode: "restore-uncertain",
            issue: lastIssue ?? GateAProbeError.restoreVerificationFailed.localizedDescription
        )
    }

    private static func disableForSafeRecovery(
        manager: NetworkExtensionDNSProxyManager,
        expected: DNSProxyManagerGateAOwner
    ) async -> GateAManagerRestoreResult {
        var lastIssue: String?
        for _ in 0..<3 {
            do {
                let current = try await manager.gateALoadOwner()
                if
                    !current.snapshot.isEnabled,
                    current.hasSameConfiguration(as: expected)
                {
                    return GateAManagerRestoreResult(
                        owner: current,
                        mode: "left-disabled-runtime-stop-unconfirmed",
                        issue: GateAProbeError.runtimeDidNotRestore.localizedDescription
                    )
                }
                guard current == expected else {
                    return GateAManagerRestoreResult(
                        owner: current,
                        mode: "external-owner",
                        issue: GateAProbeError.managerOwnershipChanged.localizedDescription
                    )
                }
                _ = try await manager.gateADisableForRecovery(
                    ifOwnerMatches: expected
                )
            } catch {
                lastIssue = error.localizedDescription
            }
        }

        let finalOwner = try? await manager.gateALoadOwner()
        if
            let finalOwner,
            !finalOwner.snapshot.isEnabled,
            finalOwner.hasSameConfiguration(as: expected)
        {
            return GateAManagerRestoreResult(
                owner: finalOwner,
                mode: "left-disabled-runtime-stop-unconfirmed",
                issue: GateAProbeError.runtimeDidNotRestore.localizedDescription
            )
        }
        return GateAManagerRestoreResult(
            owner: finalOwner,
            mode: "safe-recovery-uncertain",
            issue: lastIssue ?? GateAProbeError.restoreVerificationFailed.localizedDescription
        )
    }

    private static func observe(runtime: MachXPCStatusProvider) async -> [GateARuntimeSample] {
        var samples: [GateARuntimeSample] = []
        samples.reserveCapacity(observationCount)
        for _ in 0..<observationCount {
            try? await Task.sleep(for: observationInterval)
            do {
                samples.append(GateARuntimeSample(status: try await runtimeStatus(runtime)))
            } catch {
                samples.append(GateARuntimeSample(error: error.localizedDescription))
            }
        }
        return samples
    }

    private static func runtimeStatus(
        _ runtime: MachXPCStatusProvider
    ) async throws -> ProxyRuntimeStatus {
        try await withThrowingTaskGroup(of: ProxyRuntimeStatus.self) { group in
            group.addTask {
                try await runtime.runtimeStatus()
            }
            group.addTask {
                try await Task.sleep(for: runtimeRequestTimeout)
                throw GateAProbeError.runtimeRequestTimedOut
            }
            defer { group.cancelAll() }
            guard let status = try await group.next() else {
                throw GateAProbeError.runtimeRequestTimedOut
            }
            return status
        }
    }

    private static func isStableRestore(
        owner: DNSProxyManagerGateAOwner,
        samples: [GateARuntimeSample],
        expectedOwner: DNSProxyManagerGateAOwner,
        configuration: PersistedProxyConfiguration
    ) -> Bool {
        let stableTail = samples.suffix(5)
        return owner == expectedOwner
            && stableTail.count == 5
            && stableTail.allSatisfy { $0.matches(configuration: configuration) }
    }

    private static func requireEnabledConfiguration(
        _ snapshot: DNSProxyManagerSnapshot
    ) throws -> PersistedProxyConfiguration {
        guard snapshot.isEnabled else { throw GateAProbeError.managerDisabled }
        guard let configuration = snapshot.persistedConfiguration else {
            throw GateAProbeError.missingManagerConfiguration
        }
        return configuration
    }

    private static func requireRuntime(
        _ status: ProxyRuntimeStatus,
        matches configuration: PersistedProxyConfiguration
    ) throws {
        guard
            status.runtimeControlProtocolVersion
                == DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
            status.phase == .ready,
            status.providerInstanceID != nil,
            status.transitionSequence != nil,
            status.generation == configuration.value.generation,
            status.configurationFingerprint == configuration.fingerprint
        else {
            throw GateAProbeError.runtimeDoesNotMatchManager
        }
    }

    private static func requireValue<Value>(
        _ value: Value?,
        error: GateAProbeError
    ) throws -> Value {
        guard let value else { throw error }
        return value
    }

    @MainActor
    private static func write(_ report: GateAProbeReport) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            var data = try encoder.encode(report)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(
                Data("Gate A probe report encoding failed: \(error.localizedDescription)\n".utf8)
            )
        }
    }
}

private struct GateAManagerRestoreResult: Sendable {
    let owner: DNSProxyManagerGateAOwner?
    let mode: String
    let issue: String?
}

private struct GateAProbeReport: Encodable, Sendable {
    let schemaVersion: Int
    let result: String
    let startedAt: Date
    let finishedAt: Date
    let failure: String?
    let restoreFailure: String?
    let restoreMode: String
    let beforeManager: GateAManagerIdentity?
    let targetManager: GateAManagerIdentity?
    let restoredManager: GateAManagerIdentity?
    let beforeRuntime: GateARuntimeSample?
    let targetWindow: [GateARuntimeSample]
    let restoreWindow: [GateARuntimeSample]
}

private struct GateAManagerIdentity: Encodable, Sendable {
    let isEnabled: Bool
    let generation: UUID?
    let fingerprint: String?
    let providerBundleIdentifier: String?
    let providerConfigurationFingerprint: String
    let localizedDescription: String?

    init(_ owner: DNSProxyManagerGateAOwner) {
        isEnabled = owner.snapshot.isEnabled
        generation = owner.snapshot.persistedConfiguration?.value.generation
        fingerprint = owner.snapshot.persistedConfiguration?.fingerprint.rawValue
        providerBundleIdentifier = owner.providerBundleIdentifier
        providerConfigurationFingerprint = owner.providerConfigurationFingerprint.rawValue
        localizedDescription = owner.localizedDescription
    }
}

private struct GateARuntimeSample: Encodable, Sendable {
    let recordedAt: Date
    let runtimeControlProtocolVersion: Int?
    let providerInstanceID: UUID?
    let transitionSequence: UInt64?
    let generation: UUID?
    let fingerprint: String?
    let phase: String?
    let error: String?

    init(status: ProxyRuntimeStatus) {
        recordedAt = Date()
        runtimeControlProtocolVersion = status.runtimeControlProtocolVersion
        providerInstanceID = status.providerInstanceID
        transitionSequence = status.transitionSequence
        generation = status.generation
        fingerprint = status.configurationFingerprint?.rawValue
        phase = status.phase.rawValue
        error = nil
    }

    init(error: String) {
        recordedAt = Date()
        runtimeControlProtocolVersion = nil
        providerInstanceID = nil
        transitionSequence = nil
        generation = nil
        fingerprint = nil
        phase = nil
        self.error = error
    }

    func matches(
        configuration: PersistedProxyConfiguration,
        providerInstanceID expectedProviderInstanceID: UUID? = nil,
        transitionSequence expectedTransitionSequence: UInt64? = nil
    ) -> Bool {
        error == nil
            && runtimeControlProtocolVersion
                == DNSProxyXPCContract.currentRuntimeControlProtocolVersion
            && phase == ProxyRuntimePhase.ready.rawValue
            && generation == configuration.value.generation
            && fingerprint == configuration.fingerprint.rawValue
            && (expectedProviderInstanceID == nil
                || providerInstanceID == expectedProviderInstanceID)
            && (expectedTransitionSequence == nil
                || transitionSequence == expectedTransitionSequence)
    }
}

private enum GateAProbeError: LocalizedError, Sendable {
    case managerDisabled
    case missingManagerConfiguration
    case runtimeDoesNotMatchManager
    case runtimeObservationFailed
    case runtimeRequestTimedOut
    case providerLifecycleChanged
    case managerChangedBeforeRestore
    case managerOwnershipChanged
    case runtimeDidNotRestore
    case restoreVerificationFailed

    var errorDescription: String? {
        switch self {
        case .managerDisabled:
            "Gate A requires an enabled DNS Proxy manager."
        case .missingManagerConfiguration:
            "Gate A could not read the exact manager configuration."
        case .runtimeDoesNotMatchManager:
            "Gate A requires an exact ready runtime matching the manager."
        case .runtimeObservationFailed:
            "Gate A did not collect the complete runtime observation window."
        case .runtimeRequestTimedOut:
            "A Gate A runtime status request timed out."
        case .providerLifecycleChanged:
            "The enabled manager update changed Provider lifecycle or runtime identity."
        case .managerChangedBeforeRestore:
            "The target manager configuration changed before probe restoration."
        case .managerOwnershipChanged:
            "The manager configuration changed outside the Gate A transaction."
        case .runtimeDidNotRestore:
            "The exact old runtime did not stabilize; the manager is disabled but Provider stop remains unconfirmed."
        case .restoreVerificationFailed:
            "Gate A could not verify restoration of the exact original manager state."
        }
    }
}
#endif
