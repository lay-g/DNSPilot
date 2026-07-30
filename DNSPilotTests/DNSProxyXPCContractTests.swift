import Foundation
import Testing
@testable import DNSPilot

struct DNSProxyXPCContractTests {
    @Test func cancellingSentMutationReleasesClientWaiter() async {
        let reply = MachXPCClient.Reply<Int>()
        let beganSending = AsyncGate()
        let task = Task<Int, any Error> {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    reply.install(continuation)
                    #expect(reply.beginSending())
                    Task { await beganSending.open() }
                }
            } onCancel: {
                reply.cancel()
            }
        }
        await beganSending.wait()

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to stop waiting for the XPC reply")
        } catch is CancellationError {
            // Cancelling the Host wait does not claim that Provider mutation was cancelled.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func requirementPinsTeamAndBundleIdentifier() throws {
        let requirement = try #require(DNSProxyXPCContract.codeSigningRequirement(
            teamIdentifier: "ABCDE12345",
            bundleIdentifier: "org.example.DNSPilot.DNSProxy"
        ))

        #expect(requirement.contains("identifier \"org.example.DNSPilot.DNSProxy\""))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
    }

    @Test func requirementRejectsInjectedSyntax() {
        #expect(DNSProxyXPCContract.codeSigningRequirement(
            teamIdentifier: "ABCDE12345",
            bundleIdentifier: "com.example.app\" or true"
        ) == nil)
    }

    @Test func serviceConfigurationPrefersDistinctPrimaryAndDeduplicatesLegacy() {
        let versioned = MachXPCServiceConfiguration(
            primaryServiceName: "group.example.status.build19",
            lastSuccessfulServiceName: "group.example.status.build18",
            historicalServiceNames: [
                "group.example.status.build18",
                "group.example.status.build19",
            ],
            legacyServiceName: "group.example.status",
            codeSigningRequirement: "requirement"
        )
        let alreadyMigrated = MachXPCServiceConfiguration(
            primaryServiceName: "group.example.status.build19",
            legacyServiceName: "group.example.status.build19",
            codeSigningRequirement: "requirement"
        )

        #expect(versioned.candidateServiceNames == [
            "group.example.status.build19",
            "group.example.status.build18",
            "group.example.status",
        ])
        #expect(alreadyMigrated.candidateServiceNames == [
            "group.example.status.build19",
        ])
        let firstMigration = MachXPCServiceConfiguration(
            primaryServiceName: "group.example.status.build19",
            historicalServiceNames: ["group.example.status.build18"],
            legacyServiceName: "group.example.status",
            codeSigningRequirement: "requirement"
        )
        #expect(firstMigration.candidateServiceNames == [
            "group.example.status.build19",
            "group.example.status",
            "group.example.status.build18",
        ])
    }

    @Test func serviceConfigurationRecordsBoundedValidatedBuildHistory() throws {
        let suiteName = "DNSProxyXPCContractTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([
            "group.example.status.build17",
            "untrusted.service",
            "group.example.status.build18",
        ], forKey: MachXPCServiceConfiguration.historyDefaultsKey)

        let historicalServiceNames = MachXPCServiceConfiguration.loadAndRecordHistory(
            primaryServiceName: "group.example.status.build19",
            legacyServiceName: "group.example.status",
            userDefaults: defaults
        )

        #expect(historicalServiceNames == [
            "group.example.status.build18",
            "group.example.status.build17",
        ])
        #expect(defaults.stringArray(
            forKey: MachXPCServiceConfiguration.historyDefaultsKey
        ) == [
            "group.example.status.build17",
            "group.example.status.build18",
            "group.example.status.build19",
        ])
    }

    @Test func successfulHistoricalDiscoverySurvivesFailedUpgradeHistory() throws {
        let suiteName = "DNSProxyXPCContractTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyServiceName = "group.example.status"
        let installedServiceName = "group.example.status.build1"
        defaults.set(
            [installedServiceName] + (2 ... 16).map { "\(legacyServiceName).build\($0)" },
            forKey: MachXPCServiceConfiguration.historyDefaultsKey
        )
        MachXPCServiceConfiguration.recordServiceName(
            installedServiceName,
            legacyServiceName: legacyServiceName,
            userDefaults: defaults
        )

        let historicalServiceNames = MachXPCServiceConfiguration.loadAndRecordHistory(
            primaryServiceName: "group.example.status.build17",
            legacyServiceName: legacyServiceName,
            userDefaults: defaults
        )

        #expect(historicalServiceNames.first == installedServiceName)
        #expect(historicalServiceNames.count == 15)
    }

    @Test func authenticatedLegacyDiscoveryBecomesPreferredFallback() throws {
        let suiteName = "DNSProxyXPCContractTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyServiceName = "group.example.status"

        MachXPCServiceConfiguration.recordSuccessfulServiceName(
            legacyServiceName,
            legacyServiceName: legacyServiceName,
            userDefaults: defaults
        )

        #expect(defaults.string(
            forKey: MachXPCServiceConfiguration.successfulServiceDefaultsKey
        ) == legacyServiceName)
    }

    @Test func routerPrefersPrimaryAndBindsMutationToItsProvider() async throws {
        let primaryProvider = UUID()
        let legacyProvider = UUID()
        let primary = RoutingXPCStub(status: routingStatus(providerInstanceID: primaryProvider))
        let legacy = RoutingXPCStub(status: routingStatus(providerInstanceID: legacyProvider))
        let router = makeRouter(primary: primary, legacy: legacy)

        let status = try await router.runtimeStatus()
        let request = try routingReapplyRequest(providerInstanceID: primaryProvider)
        _ = try await router.reapplyConfiguration(request)

        #expect(status.providerInstanceID == primaryProvider)
        #expect(await primary.callCounts() == .init(status: 1, reapply: 1))
        #expect(await legacy.callCounts() == .init(status: 0, reapply: 0))
    }

    @Test func routerUsesLegacyWhenPrimaryIsUnavailable() async throws {
        let providerInstanceID = UUID()
        let primary = RoutingXPCStub(status: nil)
        let legacy = RoutingXPCStub(status: routingStatus(providerInstanceID: providerInstanceID))
        let router = makeRouter(primary: primary, legacy: legacy)

        let status = try await router.runtimeStatus()
        let request = try routingReapplyRequest(providerInstanceID: providerInstanceID)
        _ = try await router.reapplyConfiguration(request)

        #expect(status.providerInstanceID == providerInstanceID)
        #expect(await primary.callCounts() == .init(status: 1, reapply: 0))
        #expect(await legacy.callCounts() == .init(status: 1, reapply: 1))
    }

    @Test func routerPersistsAuthenticatedLegacyAsNextLaunchFallback() async throws {
        let suiteName = "DNSProxyXPCContractTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primary = RoutingXPCStub(status: nil)
        let legacy = RoutingXPCStub(status: routingStatus(providerInstanceID: UUID()))
        let configuration = MachXPCServiceConfiguration(
            primaryServiceName: "group.example.status.build19",
            historicalServiceNames: ["group.example.status.build18"],
            legacyServiceName: "group.example.status",
            codeSigningRequirement: "requirement"
        )
        let clients = [
            "group.example.status.build19": primary,
            "group.example.status": legacy,
        ]
        let router = MachXPCServiceRouter(
            configuration: configuration,
            historyStore: MachXPCServiceHistoryStore(suiteName: suiteName)
        ) { serviceName, _ in
            guard let client = clients[serviceName] else {
                throw RoutingXPCStubError.unavailable
            }
            return client
        }

        _ = try await router.runtimeStatus()

        let preferred = defaults.string(
            forKey: MachXPCServiceConfiguration.successfulServiceDefaultsKey
        )
        let nextLaunch = MachXPCServiceConfiguration(
            primaryServiceName: "group.example.status.build20",
            lastSuccessfulServiceName: preferred,
            historicalServiceNames: [
                "group.example.status.build19",
                "group.example.status.build18",
            ],
            legacyServiceName: "group.example.status",
            codeSigningRequirement: "requirement"
        )
        #expect(nextLaunch.candidateServiceNames.prefix(2) == [
            "group.example.status.build20",
            "group.example.status",
        ])
    }

    @Test func routerUsesPreviousBuildBeforeLegacyDuringLaterUpgrade() async throws {
        let providerInstanceID = UUID()
        let current = RoutingXPCStub(status: nil)
        let previous = RoutingXPCStub(status: routingStatus(providerInstanceID: providerInstanceID))
        let legacy = RoutingXPCStub(status: routingStatus(providerInstanceID: UUID()))
        let router = makeRouter(clients: [
            "group.example.status.build20": current,
            "group.example.status.build19": previous,
            "group.example.status": legacy,
        ], historicalServiceNames: ["group.example.status.build19"])

        let status = try await router.runtimeStatus()
        _ = try await router.reapplyConfiguration(
            routingReapplyRequest(providerInstanceID: providerInstanceID)
        )

        #expect(status.providerInstanceID == providerInstanceID)
        #expect(await current.callCounts() == .init(status: 1, reapply: 0))
        #expect(await previous.callCounts() == .init(status: 1, reapply: 1))
        #expect(await legacy.callCounts() == .init(status: 0, reapply: 0))
    }

    @Test func routerRetainsBindingWhenLaterStatusSelectsAnotherProvider() async throws {
        let oldProvider = UUID()
        let newProvider = UUID()
        let current = RoutingXPCStub(status: nil)
        let previous = RoutingXPCStub(status: routingStatus(providerInstanceID: oldProvider))
        let router = makeRouter(clients: [
            "group.example.status.build20": current,
            "group.example.status.build19": previous,
        ], historicalServiceNames: ["group.example.status.build19"])
        _ = try await router.runtimeStatus()
        await current.setStatus(routingStatus(providerInstanceID: newProvider))
        _ = try await router.runtimeStatus()

        _ = try await router.reapplyConfiguration(
            routingReapplyRequest(providerInstanceID: oldProvider)
        )

        #expect(await current.callCounts() == .init(status: 2, reapply: 0))
        #expect(await previous.callCounts() == .init(status: 1, reapply: 1))
    }

    @Test func routerBoundsEachStatusProbeBeforeFallback() async throws {
        let providerInstanceID = UUID()
        let primary = RoutingXPCStub(
            status: routingStatus(providerInstanceID: UUID()),
            statusDelay: .seconds(1)
        )
        let legacy = RoutingXPCStub(status: routingStatus(providerInstanceID: providerInstanceID))
        let router = makeRouter(
            clients: [
                "group.example.status.build20": primary,
                "group.example.status": legacy,
            ],
            discoveryTimeout: .milliseconds(10)
        )

        let status = try await router.runtimeStatus()

        #expect(status.providerInstanceID == providerInstanceID)
        #expect(await primary.callCounts().status == 1)
        #expect(await legacy.callCounts().status == 1)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await primary.statusCancellationCount() == 1)
    }

    @Test func routerNeverFallsBackMutationAfterSelectedEndpointFailure() async throws {
        let providerInstanceID = UUID()
        let primary = RoutingXPCStub(
            status: routingStatus(providerInstanceID: providerInstanceID),
            failReapply: true
        )
        let legacy = RoutingXPCStub(status: routingStatus(providerInstanceID: providerInstanceID))
        let router = makeRouter(primary: primary, legacy: legacy)
        _ = try await router.runtimeStatus()
        let request = try routingReapplyRequest(providerInstanceID: providerInstanceID)

        await #expect(throws: RoutingXPCStubError.self) {
            try await router.reapplyConfiguration(request)
        }
        #expect(await primary.callCounts() == .init(status: 1, reapply: 1))
        #expect(await legacy.callCounts() == .init(status: 0, reapply: 0))
    }

    @Test func routerRejectsMutationForDifferentProviderIdentity() async throws {
        let primary = RoutingXPCStub(status: routingStatus(providerInstanceID: UUID()))
        let legacy = RoutingXPCStub(status: routingStatus(providerInstanceID: UUID()))
        let router = makeRouter(primary: primary, legacy: legacy)
        let request = try routingReapplyRequest(providerInstanceID: UUID())

        await #expect(throws: MachXPCClientError.self) {
            try await router.reapplyConfiguration(request)
        }
        #expect(await primary.callCounts() == .init(status: 1, reapply: 0))
        #expect(await legacy.callCounts() == .init(status: 1, reapply: 0))
    }

    private func makeRouter(
        primary: RoutingXPCStub,
        legacy: RoutingXPCStub
    ) -> MachXPCServiceRouter {
        let clients = [
            "group.example.status.build19": primary,
            "group.example.status": legacy,
        ]
        return MachXPCServiceRouter(
            configuration: MachXPCServiceConfiguration(
                primaryServiceName: "group.example.status.build19",
                legacyServiceName: "group.example.status",
                codeSigningRequirement: "requirement"
            )
        ) { serviceName, _ in
            guard let client = clients[serviceName] else {
                throw RoutingXPCStubError.unavailable
            }
            return client
        }
    }

    private func makeRouter(
        clients: [String: RoutingXPCStub],
        historicalServiceNames: [String] = [],
        discoveryTimeout: Duration = .milliseconds(125)
    ) -> MachXPCServiceRouter {
        MachXPCServiceRouter(
            configuration: MachXPCServiceConfiguration(
                primaryServiceName: "group.example.status.build20",
                lastSuccessfulServiceName: historicalServiceNames.first,
                historicalServiceNames: historicalServiceNames,
                legacyServiceName: "group.example.status",
                codeSigningRequirement: "requirement"
            ),
            discoveryTimeout: discoveryTimeout
        ) { serviceName, _ in
            guard let client = clients[serviceName] else {
                throw RoutingXPCStubError.unavailable
            }
            return client
        }
    }

    private func routingStatus(providerInstanceID: UUID) -> ProxyRuntimeStatus {
        ProxyRuntimeStatus(
            generation: UUID(),
            phase: .ready,
            errorCode: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            runtimeControlProtocolVersion: DNSProxyXPCContract.currentRuntimeControlProtocolVersion,
            providerInstanceID: providerInstanceID,
            transitionSequence: 1,
            configurationFingerprint: ProxyConfigurationFingerprint(data: Data("active".utf8))
        )
    }

    private func routingReapplyRequest(
        providerInstanceID: UUID
    ) throws -> ProxyReapplyRequest {
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        return ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: UUID(),
            expectedBaseFingerprint: ProxyConfigurationFingerprint(data: Data("base".utf8)),
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )
    }

    @Test func newHostDecodesLegacyRuntimeStatusWithoutSchemaCapability() throws {
        let payload: [String: Any] = [
            "generation": UUID().uuidString,
            "phase": ProxyRuntimePhase.ready.rawValue,
            "updatedAt": Date(timeIntervalSince1970: 0),
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )

        let status = try PropertyListDecoder().decode(ProxyRuntimeStatus.self, from: data)

        #expect(status.maximumConfigurationSchemaVersion == nil)
        #expect(status.runtimeControlProtocolVersion == nil)
        #expect(status.providerInstanceID == nil)
        #expect(status.transitionSequence == nil)
        #expect(status.configurationFingerprint == nil)
        #expect(status.preparedTransactionID == nil)
        #expect(status.preparedGeneration == nil)
        #expect(status.lastQuiescedGeneration == nil)
    }

    @Test func legacyHostDecoderIgnoresRuntimeSchemaCapability() throws {
        struct LegacyRuntimeStatus: Decodable {
            let generation: UUID?
            let phase: ProxyRuntimePhase
            let errorCode: ProxyRuntimeErrorCode?
            let updatedAt: Date
        }
        let current = ProxyRuntimeStatus(
            generation: UUID(),
            phase: .ready,
            errorCode: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            maximumConfigurationSchemaVersion: 2
        )

        let decoded = try PropertyListDecoder().decode(
            LegacyRuntimeStatus.self,
            from: PropertyListEncoder().encode(current)
        )

        #expect(decoded.generation == current.generation)
        #expect(decoded.phase == .ready)
    }

    @Test func legacyHostDecoderIgnoresRuntimeIdentityFields() throws {
        struct LegacyRuntimeStatus: Decodable {
            let generation: UUID?
            let phase: ProxyRuntimePhase
            let errorCode: ProxyRuntimeErrorCode?
            let updatedAt: Date
            let maximumConfigurationSchemaVersion: Int?
        }
        let fingerprint = ProxyConfigurationFingerprint(data: Data("configuration".utf8))
        let current = ProxyRuntimeStatus(
            generation: UUID(),
            phase: .ready,
            errorCode: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            runtimeControlProtocolVersion: 2,
            providerInstanceID: UUID(),
            transitionSequence: 7,
            configurationFingerprint: fingerprint,
            preparedTransactionID: UUID(),
            preparedGeneration: UUID(),
            lastQuiescedGeneration: UUID()
        )

        let decoded = try PropertyListDecoder().decode(
            LegacyRuntimeStatus.self,
            from: PropertyListEncoder().encode(current)
        )

        #expect(decoded.generation == current.generation)
        #expect(decoded.phase == current.phase)
        #expect(
            decoded.maximumConfigurationSchemaVersion
                == ActiveProxyConfiguration.currentSchemaVersion
        )
    }

    @Test func runtimeIdentityRoundTripsAndIgnoresFutureReadFields() throws {
        let fingerprint = ProxyConfigurationFingerprint(data: Data("configuration".utf8))
        let current = ProxyRuntimeStatus(
            generation: UUID(),
            phase: .starting,
            errorCode: nil,
            updatedAt: Date(timeIntervalSince1970: 1),
            runtimeControlProtocolVersion: 2,
            providerInstanceID: UUID(),
            transitionSequence: 4,
            configurationFingerprint: fingerprint,
            preparedTransactionID: UUID(),
            preparedGeneration: UUID(),
            lastQuiescedGeneration: UUID()
        )
        let encoded = try PropertyListEncoder().encode(current)
        var payload = try #require(
            PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
        )
        payload["futureReadCapability"] = true
        let futureData = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )

        #expect(try PropertyListDecoder().decode(
            ProxyRuntimeStatus.self,
            from: futureData
        ) == current)
    }

    @Test func runtimeTransitionPreservesInstanceAndIncrementsSequence() {
        let providerInstanceID = UUID()
        let generation = UUID()
        let fingerprint = ProxyConfigurationFingerprint(data: Data("configuration".utf8))
        let idle = ProxyRuntimeStatus.idle(
            at: Date(timeIntervalSince1970: 0),
            runtimeControlProtocolVersion: 2,
            providerInstanceID: providerInstanceID,
            transitionSequence: 0
        )
        let starting = idle.transitioning(
            generation: generation,
            configurationFingerprint: fingerprint,
            phase: .starting,
            at: Date(timeIntervalSince1970: 1)
        )
        let ready = starting.transitioning(
            generation: generation,
            configurationFingerprint: fingerprint,
            phase: .ready,
            at: Date(timeIntervalSince1970: 2)
        )

        #expect(starting.providerInstanceID == providerInstanceID)
        #expect(ready.providerInstanceID == providerInstanceID)
        #expect(starting.transitionSequence == 1)
        #expect(ready.transitionSequence == 2)
        #expect(ready.configurationFingerprint == fingerprint)
    }

    @Test func malformedRuntimeFingerprintFailsClosed() throws {
        let payload: [String: Any] = [
            "configurationFingerprint": "NOT-A-SHA256-FINGERPRINT",
            "generation": UUID().uuidString,
            "phase": ProxyRuntimePhase.ready.rawValue,
            "updatedAt": Date(timeIntervalSince1970: 0),
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )

        #expect(throws: (any Error).self) {
            try PropertyListDecoder().decode(ProxyRuntimeStatus.self, from: data)
        }
    }

    @Test func reapplyRequestRoundTripsThroughStrictBinaryCodec() throws {
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: UUID(),
            expectedBaseGeneration: UUID(),
            expectedBaseFingerprint: ProxyConfigurationFingerprint(data: Data("base".utf8)),
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )

        let encoded = try ProxyRuntimeControlCodec.encode(request)

        #expect(try ProxyRuntimeControlCodec.decodeReapplyRequest(encoded) == request)
    }

    @Test func reapplyRequestRejectsUnknownFieldsAndNonBinaryPlists() throws {
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: UUID(),
            expectedBaseGeneration: UUID(),
            expectedBaseFingerprint: ProxyConfigurationFingerprint(data: Data("base".utf8)),
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )
        let encoded = try ProxyRuntimeControlCodec.encode(request)
        var payload = try #require(
            PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
        )
        payload["futureWriteField"] = true
        let unknownFieldData = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )
        let xmlData = try PropertyListSerialization.data(
            fromPropertyList: payload.filter { $0.key != "futureWriteField" },
            format: .xml,
            options: 0
        )

        #expect(throws: ProxyRuntimeControlCodecError.malformedRequest) {
            try ProxyRuntimeControlCodec.decodeReapplyRequest(unknownFieldData)
        }
        #expect(throws: ProxyRuntimeControlCodecError.malformedRequest) {
            try ProxyRuntimeControlCodec.decodeReapplyRequest(xmlData)
        }
    }

    @Test func embeddedConfigurationRejectsUnknownTopLevelAndNestedKeys() throws {
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")

        for location in [
            UnknownConfigurationFieldLocation.topLevel,
            .nestedUpstreamConfiguration,
        ] {
            let targetData = try configurationData(
                byAddingUnknownFieldTo: target,
                at: location
            )
            let request = ProxyReapplyRequest(
                operationID: UUID(),
                expectedProviderInstanceID: UUID(),
                expectedBaseGeneration: UUID(),
                expectedBaseFingerprint: ProxyConfigurationFingerprint(data: Data("base".utf8)),
                targetConfigurationData: targetData,
                targetFingerprint: ProxyConfigurationFingerprint(data: targetData)
            )
            let encodedRequest = try ProxyRuntimeControlCodec.encode(request)

            #expect(try ProxyRuntimeControlCodec.decodeReapplyRequest(encodedRequest) == request)
            #expect(throws: ActiveProxyConfigurationError.invalidPropertyListStructure) {
                try PersistedProxyConfiguration(data: targetData)
            }
        }
    }

    @Test func reapplyRequestRejectsOversizedPayloadBeforeDecoding() {
        let oversized = Data(
            repeating: 0,
            count: DNSProxyXPCContract.maximumWriteRequestSize + 1
        )

        #expect(throws: ProxyRuntimeControlCodecError.requestTooLarge) {
            try ProxyRuntimeControlCodec.decodeReapplyRequest(oversized)
        }
    }

    @Test func lifecycleRequestRoundTripsThroughStrictBinaryCodec() throws {
        let request = ProxyLifecycleRequest(
            operationID: UUID(),
            action: .quiesce,
            expectedProviderInstanceID: UUID(),
            expectedGeneration: UUID(),
            expectedFingerprint: ProxyConfigurationFingerprint(data: Data("base".utf8))
        )

        let encoded = try ProxyRuntimeControlCodec.encode(request)

        #expect(try ProxyRuntimeControlCodec.decodeLifecycleRequest(encoded) == request)
    }

    @Test func lifecycleRequestRejectsUnknownFieldsAndWrongSelectorResponse() throws {
        let request = ProxyLifecycleRequest(
            operationID: UUID(),
            action: .quiesce,
            expectedProviderInstanceID: UUID(),
            expectedGeneration: UUID(),
            expectedFingerprint: ProxyConfigurationFingerprint(data: Data("base".utf8))
        )
        let encoded = try ProxyRuntimeControlCodec.encode(request)
        var payload = try #require(
            PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
        )
        payload["futureWriteField"] = true
        let unknownFieldData = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )
        let wrongDisposition = ProxyLifecycleResponse(
            operationID: request.operationID,
            disposition: .resumed,
            providerInstanceID: request.expectedProviderInstanceID,
            generation: request.expectedGeneration,
            fingerprint: request.expectedFingerprint
        )

        #expect(throws: ProxyRuntimeControlCodecError.malformedRequest) {
            try ProxyRuntimeControlCodec.decodeLifecycleRequest(unknownFieldData)
        }
        #expect(throws: MachXPCClientError.self) {
            try MachXPCClient.validateLifecycleResponse(wrongDisposition, for: request)
        }
    }

    @Test func hostValidatesLifecycleTerminalAndRejectionShapes() throws {
        let request = ProxyLifecycleRequest(
            operationID: UUID(),
            action: .resume,
            expectedProviderInstanceID: UUID(),
            expectedGeneration: UUID(),
            expectedFingerprint: ProxyConfigurationFingerprint(data: Data("base".utf8))
        )
        let resumed = ProxyLifecycleResponse(
            operationID: request.operationID,
            disposition: .resumed,
            providerInstanceID: request.expectedProviderInstanceID,
            generation: request.expectedGeneration,
            fingerprint: request.expectedFingerprint
        )
        let failed = ProxyLifecycleResponse(
            operationID: request.operationID,
            disposition: .resumeFailed,
            providerInstanceID: request.expectedProviderInstanceID,
            generation: request.expectedGeneration,
            fingerprint: request.expectedFingerprint
        )
        let rateLimited = ProxyLifecycleResponse(
            operationID: nil,
            disposition: .rejected,
            providerInstanceID: request.expectedProviderInstanceID,
            rejectionCode: .rateLimited
        )

        try MachXPCClient.validateLifecycleResponse(resumed, for: request)
        try MachXPCClient.validateLifecycleResponse(failed, for: request)
        try MachXPCClient.validateLifecycleResponse(rateLimited, for: request)
    }

    @Test func reapplyResponseRoundTripsTerminalIdentity() throws {
        let response = ProxyReapplyResponse(
            operationID: UUID(),
            disposition: .rejectedPreservingBase,
            providerInstanceID: UUID(),
            activeGeneration: UUID(),
            activeFingerprint: ProxyConfigurationFingerprint(data: Data("base".utf8)),
            preservedConfigurationData: Data("configuration".utf8)
        )

        let decoded = try PropertyListDecoder().decode(
            ProxyReapplyResponse.self,
            from: ProxyRuntimeControlCodec.encode(response)
        )

        #expect(decoded == response)
    }

    @Test func hostAcceptsOnlyVerifiedPreservedBaseBytes() throws {
        let providerInstanceID = UUID()
        let base = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: base.value.generation,
            expectedBaseFingerprint: base.fingerprint,
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )
        let valid = ProxyReapplyResponse(
            operationID: request.operationID,
            disposition: .rejectedPreservingBase,
            providerInstanceID: providerInstanceID,
            activeGeneration: base.value.generation,
            activeFingerprint: base.fingerprint,
            preservedConfigurationData: base.data
        )
        let forged = ProxyReapplyResponse(
            operationID: request.operationID,
            disposition: .rejectedPreservingBase,
            providerInstanceID: providerInstanceID,
            activeGeneration: base.value.generation,
            activeFingerprint: base.fingerprint,
            preservedConfigurationData: target.data
        )

        try MachXPCClient.validateReapplyResponse(valid, for: request)
        #expect(throws: MachXPCClientError.self) {
            try MachXPCClient.validateReapplyResponse(forged, for: request)
        }
    }

    @Test func hostRejectsAppliedResponseWithWrongTargetIdentity() throws {
        let providerInstanceID = UUID()
        let base = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: base.value.generation,
            expectedBaseFingerprint: base.fingerprint,
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )
        let response = ProxyReapplyResponse(
            operationID: request.operationID,
            disposition: .applied,
            providerInstanceID: providerInstanceID,
            activeGeneration: UUID(),
            activeFingerprint: target.fingerprint
        )

        #expect(throws: MachXPCClientError.self) {
            try MachXPCClient.validateReapplyResponse(response, for: request)
        }
    }

    @Test func hostAcceptsProviderInstanceMismatchFromActualProvider() throws {
        let expectedProviderInstanceID = UUID()
        let base = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: expectedProviderInstanceID,
            expectedBaseGeneration: base.value.generation,
            expectedBaseFingerprint: base.fingerprint,
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )
        let valid = ProxyReapplyResponse(
            operationID: request.operationID,
            disposition: .rejected,
            providerInstanceID: UUID(),
            rejectionCode: .providerInstanceMismatch
        )
        let forged = ProxyReapplyResponse(
            operationID: request.operationID,
            disposition: .rejected,
            providerInstanceID: expectedProviderInstanceID,
            rejectionCode: .providerInstanceMismatch
        )

        try MachXPCClient.validateReapplyResponse(valid, for: request)
        #expect(throws: MachXPCClientError.self) {
            try MachXPCClient.validateReapplyResponse(forged, for: request)
        }
    }

    @Test func hostAcceptsPredecodeRateLimitWithoutOperationIdentity() throws {
        let providerInstanceID = UUID()
        let base = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: base.value.generation,
            expectedBaseFingerprint: base.fingerprint,
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )
        let response = ProxyReapplyResponse(
            operationID: nil,
            disposition: .rejected,
            providerInstanceID: providerInstanceID,
            rejectionCode: .rateLimited
        )
        let forged = ProxyReapplyResponse(
            operationID: request.operationID,
            disposition: .rejected,
            providerInstanceID: providerInstanceID,
            rejectionCode: .rateLimited
        )

        try MachXPCClient.validateReapplyResponse(response, for: request)
        #expect(throws: MachXPCClientError.self) {
            try MachXPCClient.validateReapplyResponse(forged, for: request)
        }
    }

    @Test func hostAcceptsPredecodeParseRejectionsWithoutOperationIdentity() throws {
        let providerInstanceID = UUID()
        let base = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: base.value.generation,
            expectedBaseFingerprint: base.fingerprint,
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )

        for code in [
            ProxyRuntimeControlRejectionCode.malformedRequest,
            .requestTooLarge,
        ] {
            let valid = ProxyReapplyResponse(
                operationID: nil,
                disposition: .rejected,
                providerInstanceID: providerInstanceID,
                rejectionCode: code
            )
            let forged = ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .rejected,
                providerInstanceID: providerInstanceID,
                rejectionCode: code
            )

            try MachXPCClient.validateReapplyResponse(valid, for: request)
            #expect(throws: MachXPCClientError.self) {
                try MachXPCClient.validateReapplyResponse(forged, for: request)
            }
        }
    }

    @Test func hostAcceptsValidDispositionResponseShapes() throws {
        let providerInstanceID = UUID()
        let base = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: base.value.generation,
            expectedBaseFingerprint: base.fingerprint,
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )
        let responses = [
            ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .applied,
                providerInstanceID: providerInstanceID,
                activeGeneration: target.value.generation,
                activeFingerprint: target.fingerprint
            ),
            ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .rejectedPreservingBase,
                providerInstanceID: providerInstanceID,
                activeGeneration: base.value.generation,
                activeFingerprint: base.fingerprint,
                preservedConfigurationData: base.data
            ),
            ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .unrecoverable,
                providerInstanceID: providerInstanceID
            ),
            ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .rejected,
                providerInstanceID: providerInstanceID,
                rejectionCode: .staleBaseIdentity
            ),
        ]

        for response in responses {
            try MachXPCClient.validateReapplyResponse(response, for: request)
        }
    }

    @Test func hostRejectsDispositionResponsesWithForbiddenFields() throws {
        let providerInstanceID = UUID()
        let base = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let request = ProxyReapplyRequest(
            operationID: UUID(),
            expectedProviderInstanceID: providerInstanceID,
            expectedBaseGeneration: base.value.generation,
            expectedBaseFingerprint: base.fingerprint,
            targetConfigurationData: target.data,
            targetFingerprint: target.fingerprint
        )
        let responses = [
            ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .applied,
                providerInstanceID: providerInstanceID,
                activeGeneration: target.value.generation,
                activeFingerprint: target.fingerprint,
                rejectionCode: .internalFailure
            ),
            ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .rejectedPreservingBase,
                providerInstanceID: providerInstanceID,
                activeGeneration: base.value.generation,
                activeFingerprint: base.fingerprint,
                preservedConfigurationData: base.data,
                rejectionCode: .internalFailure
            ),
            ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .unrecoverable,
                providerInstanceID: providerInstanceID,
                activeGeneration: base.value.generation
            ),
            ProxyReapplyResponse(
                operationID: request.operationID,
                disposition: .rejected,
                providerInstanceID: providerInstanceID,
                activeGeneration: base.value.generation,
                rejectionCode: .staleBaseIdentity
            ),
        ]

        for response in responses {
            #expect(throws: MachXPCClientError.self) {
                try MachXPCClient.validateReapplyResponse(response, for: request)
            }
        }
    }
}

private enum RoutingXPCStubError: Error {
    case unavailable
}

private actor RoutingXPCStub: MachXPCRequesting {
    struct CallCounts: Equatable, Sendable {
        let status: Int
        let reapply: Int
    }

    private var status: ProxyRuntimeStatus?
    private let statusDelay: Duration?
    private let failReapply: Bool
    private var statusCalls = 0
    private var statusCancellations = 0
    private var reapplyCalls = 0

    init(
        status: ProxyRuntimeStatus?,
        statusDelay: Duration? = nil,
        failReapply: Bool = false
    ) {
        self.status = status
        self.statusDelay = statusDelay
        self.failReapply = failReapply
    }

    func runtimeStatus() async throws -> ProxyRuntimeStatus {
        statusCalls += 1
        if let statusDelay {
            do {
                try await Task.sleep(for: statusDelay)
            } catch is CancellationError {
                statusCancellations += 1
                throw CancellationError()
            }
        }
        guard let status else { throw RoutingXPCStubError.unavailable }
        return status
    }

    func setStatus(_ status: ProxyRuntimeStatus?) {
        self.status = status
    }

    func runtimeEvidence() throws -> ProxyRuntimeEvidence {
        throw RoutingXPCStubError.unavailable
    }

    func reapplyConfiguration(
        _ request: ProxyReapplyRequest
    ) throws -> ProxyReapplyResponse {
        reapplyCalls += 1
        if failReapply { throw RoutingXPCStubError.unavailable }
        let target = try PersistedProxyConfiguration(data: request.targetConfigurationData)
        return ProxyReapplyResponse(
            operationID: request.operationID,
            disposition: .applied,
            providerInstanceID: request.expectedProviderInstanceID,
            activeGeneration: target.value.generation,
            activeFingerprint: target.fingerprint
        )
    }

    func quiesceRuntime(
        _ request: ProxyLifecycleRequest
    ) throws -> ProxyLifecycleResponse {
        throw RoutingXPCStubError.unavailable
    }

    func resumeRuntime(
        _ request: ProxyLifecycleRequest
    ) throws -> ProxyLifecycleResponse {
        throw RoutingXPCStubError.unavailable
    }

    func callCounts() -> CallCounts {
        CallCounts(status: statusCalls, reapply: reapplyCalls)
    }

    func statusCancellationCount() -> Int {
        statusCancellations
    }
}
