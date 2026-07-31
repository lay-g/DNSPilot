import Combine
import Foundation
import Testing
@testable import DNSPilot

@MainActor
struct AppStateTests {
    @Test func startProjectsConfigurationNetworkProxyAndRuleSelection() async throws {
        let fixture = try Fixture()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot)
        let state = AppState(
            backend: backend,
            systemExtension: FakeSystemExtensionController(state: .active)
        )

        await state.start()

        #expect(backend.startCount == 1)
        #expect(state.profiles == [fixture.profile])
        #expect(state.rules == [fixture.rule])
        #expect(state.proxy.activeProfileID == fixture.profile.id)
        #expect(state.selectionSource == .rule(id: fixture.rule.id, name: "Studio Rule"))
        #expect(state.menuPresentation?.statusText == "DNS Proxy On")
        await state.start()
        #expect(backend.startCount == 1)
    }

    @Test(arguments: [NetworkStatus.requiresConnection, .unsatisfied])
    func unavailableNetworkDoesNotProjectDefaultSelection(status: NetworkStatus) async throws {
        let fixture = try Fixture()
        let current = fixture.snapshot
        let snapshot = ProductRuntimeSnapshot(
            configuration: current.configuration,
            proxy: current.proxy,
            network: NetworkContext(
                status: status,
                ssid: nil,
                ssidAvailability: .notOnWiFi,
                activeInterfaceTypes: [],
                addresses: []
            ),
            locationAuthorization: current.locationAuthorization,
            startupFailure: current.startupFailure,
            diagnostics: current.diagnostics,
            loggingMode: current.loggingMode
        )
        let state = AppState(backend: FakeProductRuntimeBackend(snapshot: snapshot))

        await state.start()

        #expect(state.selectionSource == .unavailable)
    }

    @Test func invalidDraftNeverCrossesIntentBoundaryAndRemainsOpen() async {
        let backend = FakeProductRuntimeBackend(snapshot: .empty)
        let state = AppState(backend: backend)
        state.beginDraft(.profile)

        let outcome = await state.createProfile(ProfileDraft(name: " "))

        guard case .failed = outcome else {
            Issue.record("Expected validation failure")
            return
        }
        #expect(backend.intents.isEmpty)
        #expect(state.activeDraft == .profile)
        #expect(state.actionFailure != nil)
    }

    @Test func successfulProfileAndRuleActionsUseOneIntentBoundaryAndCloseDraft() async throws {
        let fixture = try Fixture()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot)
        let state = AppState(backend: backend)
        let profileDraft = ProfileDraft(
            name: "Backup",
            transport: .plain,
            plainServerAddress: "198.51.100.53"
        )
        state.beginDraft(.profile)

        #expect(await state.createProfile(profileDraft) == .completed)
        #expect(state.activeDraft == nil)

        let ruleDraft = RuleDraft(
            name: "Ethernet",
            interfaceTypes: [.wiredEthernet],
            profileID: fixture.profile.id
        )
        state.beginDraft(.rule)
        #expect(await state.saveRule(ruleDraft) == .completed)
        #expect(state.activeDraft == nil)
        #expect(backend.intents.count == 2)
        guard case .createProfile = backend.intents[0], case .saveRule = backend.intents[1] else {
            Issue.record("Unexpected intents: \(backend.intents)")
            return
        }
    }

    @Test func failedBackendIntentKeepsDraftAndPublishesStableFailure() async throws {
        let fixture = try Fixture()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot)
        let failure = ProductActionFailure(action: .profileEdit, reason: .conflict)
        backend.outcome = .failed(failure)
        let state = AppState(backend: backend)
        state.beginDraft(.profile)

        let outcome = await state.editProfile(ProfileDraft(profile: fixture.profile))

        #expect(outcome == .failed(failure))
        #expect(state.activeDraft == .profile)
        #expect(state.actionFailure == failure)
    }

    @Test func persistenceFailureRemainsVisibleAndCanBeRetried() async throws {
        let fixture = try Fixture()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot)
        let failure = ProductActionFailure(
            action: .profileEdit,
            reason: .persistenceFailed,
            diagnosticDescription: "Could not save configuration"
        )
        backend.outcome = .failed(failure)
        let state = AppState(backend: backend)
        state.beginDraft(.profile)
        let draft = ProfileDraft(profile: fixture.profile)

        #expect(
            await state.editProfile(draft)
                == .failed(failure)
        )
        #expect(state.activeDraft == .profile)
        #expect(state.actionFailure == failure)

        backend.outcome = .completed
        #expect(await state.editProfile(draft) == .completed)
        #expect(state.activeDraft == nil)
        #expect(backend.intents == [.editProfile(fixture.profile), .editProfile(fixture.profile)])
    }

    @Test func operationalFailurePresentationIsSpecificAndDoesNotExposeDiagnosticDetails() {
        let detail = "Upstream exchange failed at internal/file.cc:51"
        let failure = ProductActionFailure(
            action: .profileTest,
            reason: .upstreamTestUnclassified,
            diagnosticDescription: detail
        )

        #expect(failure.title == "Profile Test Failed")
        #expect(failure.message.contains("DnsLibs"))
        #expect(failure.message.contains("does not provide a safe structured cause"))
        #expect(failure.recoveryActions == [.retry, .openDiagnostics])
        #expect(!failure.message.contains(detail))
        #expect(failure.diagnosticDescription == detail)
    }

    @Test func everyOperationalFailureUsesAnActionSpecificTitleAndSafeMessage() {
        let detail = "https://dns.example/dns-query?token=secret internal/file.swift:51"

        for action in ProductAction.allCases {
            #expect(!action.failureTitle.contains("Operation Failed"))
            #expect(!action.failureTitle.isEmpty)
        }
        for reason in ProductFailureReason.allCases {
            let failure = ProductActionFailure(
                action: .profileEdit,
                reason: reason,
                diagnosticDescription: detail
            )
            #expect(!failure.message.isEmpty)
            #expect(!failure.message.contains("token=secret"))
            #expect(!failure.message.contains("internal/file.swift"))
            #expect(failure.diagnosticDescription == detail)
        }
    }

    @Test func dnsLibsErrorClassificationUsesStableBoundaryWithoutParsingDescription() {
        let error = NSError(
            domain: "com.adguard.dnsproxy",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "private upstream explanation"]
        )

        let failure = ProfileTestFailure.dnsLibs(error)

        #expect(failure == .upstreamRejected(
            "com.adguard.dnsproxy(13): private upstream explanation"
        ))
    }

    @Test func startupFailureSeparatesUserTextFromDiagnosticDetails() {
        let detail = "Configuration decoder failed at byte 51"
        let failure = ProductStartupFailure.unavailable(detail)

        #expect(failure.message == "DNSPilot could not load its configuration.")
        #expect(failure.diagnosticDescription == detail)
    }

    @Test func realBackendProjectsDnsLibsPreflightFailureWithoutLeakingDetails() async throws {
        let detail = "https://dns.example/dns-query?token=secret at internal/file.cc:51"
        let backend = DNSPilotAppModel(
            upstreamValidator: FakeUpstreamValidator {
                throw ProfileTestFailure.upstreamRejected(detail)
            }
        )
        let profile = try DNSProfile(
            name: "Test",
            upstream: .plain(PlainDNSConfiguration(
                serverAddress: try IPAddress("192.0.2.53")
            ))
        )

        let outcome = await backend.performProductIntent(.preflightProfile(profile))

        guard case let .failed(failure) = outcome else {
            Issue.record("Expected Profile Test failure")
            return
        }
        #expect(failure.action == .profileTest)
        #expect(failure.reason == .upstreamTestUnclassified)
        #expect(failure.title == "Profile Test Failed")
        #expect(!failure.message.contains("token=secret"))
        #expect(!failure.message.contains("192.0.2.53"))
        #expect(!failure.message.contains("internal/file.cc"))
        #expect(failure.diagnosticDescription == detail)
    }

    @Test func proxySwitchCodesProjectStableReasons() {
        #expect(ProxySwitchFailureCode.targetPreflightFailed.productFailureReason == .upstreamTestUnclassified)
        #expect(ProxySwitchFailureCode.providerCompatibilityUnavailable.productFailureReason == .compatibilityUnavailable)
        #expect(ProxySwitchFailureCode.oldGenerationChanged.productFailureReason == .targetChanged)
        #expect(ProxySwitchFailureCode.managerStateUnavailable.productFailureReason == .managerStateUnavailable)
        #expect(ProxySwitchFailureCode.targetWriteFailed.productFailureReason == .targetWriteFailed)
        #expect(ProxySwitchFailureCode.targetReadinessTimedOut.productFailureReason == .readinessTimedOut)
        #expect(ProxySwitchFailureCode.targetProviderFailed.productFailureReason == .providerFailed)
    }

    @Test func profileMutationFailuresProjectStableReasons() {
        let id = UUID()
        #expect(ProfileMutationFailure.operationInProgress.productFailureReason == .operationInProgress)
        #expect(ProfileMutationFailure.operationConflict.productFailureReason == .conflict)
        #expect(ProfileMutationFailure.expectedConfigurationMismatch.productFailureReason == .conflict)
        #expect(ProfileMutationFailure.profileNotFound(id).productFailureReason == .profileNotFound)
        #expect(ProfileMutationFailure.profileAlreadyExists(id).productFailureReason == .profileAlreadyExists)
        #expect(ProfileMutationFailure.invalidDeletionPlan(.missingDefaultReplacement).productFailureReason == .invalidDeletionPlan)
        #expect(ProfileMutationFailure.invalidConfiguration.productFailureReason == .invalidConfiguration)
        #expect(ProfileMutationFailure.configurationCommitFailed.productFailureReason == .persistenceFailed)
        #expect(ProfileMutationFailure.controllerPreparationFailed.productFailureReason == .runtimePreparationFailed)
        #expect(ProfileMutationFailure.desiredPersistenceFailed.productFailureReason == .desiredConfigurationPersistenceFailed)
        #expect(ProfileMutationFailure.journalWriteFailed.productFailureReason == .recoveryJournalWriteFailed)
        #expect(ProfileMutationFailure.runtimeRejected.productFailureReason == .runtimeRejected)
    }

    @Test func successfulPreflightDoesNotClearUnsavedProfileDraft() async throws {
        let fixture = try Fixture()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot)
        let state = AppState(backend: backend)
        state.beginDraft(.profile)

        #expect(await state.preflightProfile(ProfileDraft(profile: fixture.profile)) == .completed)

        #expect(state.activeDraft == .profile)
        #expect(state.profileTestResult?.matches(fixture.profile) == true)
        #expect(state.profileTestResult?.message == "\"Office DNS\" passed the DNS test.")
        #expect(backend.intents.count == 1)
        guard case .preflightProfile = backend.intents[0] else {
            Issue.record("Expected preflight intent")
            return
        }
    }

    @Test func cancelledProfileTestDoesNotPublishAnAlertOrSuccess() async throws {
        let fixture = try Fixture()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot)
        backend.outcome = .failed(ProductActionFailure(
            action: .profileTest,
            reason: .cancelled
        ))
        let state = AppState(backend: backend)

        let outcome = await state.preflightProfile(ProfileDraft(profile: fixture.profile))

        #expect(outcome == backend.outcome)
        #expect(state.actionFailure == nil)
        #expect(state.profileTestResult == nil)
    }

    @Test func invalidatedInFlightProfileTestCannotPublishLateSuccess() async throws {
        let fixture = try Fixture()
        let gate = AsyncGate()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot)
        backend.intentGate = gate
        let state = AppState(backend: backend)

        let task = Task {
            await state.preflightProfile(ProfileDraft(profile: fixture.profile))
        }
        while backend.intents.isEmpty { await Task.yield() }

        state.cancelProfileTest()
        task.cancel()
        await gate.open()
        _ = await task.value

        #expect(state.profileTestResult == nil)
    }

    @Test func finalRecoveryStateOverridesOrdinarySwitchFailurePresentation() async throws {
        let fixture = try Fixture()
        let diagnostic = "manager write outcome uncertain"
        let backend = FakeProductRuntimeBackend(snapshot: ProductRuntimeSnapshot(
            configuration: fixture.snapshot.configuration,
            proxy: ProxyControllerSnapshot(
                state: .recoveryRequired(diagnostic),
                targetProfileID: fixture.profile.id,
                activeProfileID: fixture.profile.id,
                activeGeneration: fixture.snapshot.proxy.activeGeneration,
                lastSwitchFailure: nil
            ),
            network: fixture.snapshot.network,
            locationAuthorization: .authorized,
            startupFailure: nil,
            diagnostics: .unavailable("Not refreshed"),
            loggingMode: .default
        ))
        backend.outcome = .failed(ProductActionFailure(
            action: .dnsProxyEnable,
            reason: .targetWriteFailed,
            diagnosticDescription: diagnostic
        ))
        let state = AppState(
            backend: backend,
            systemExtension: FakeSystemExtensionController(state: .active)
        )

        let outcome = await state.turnOnDNSProxy()

        let expected = ProductActionFailure(
            action: .dnsProxyEnable,
            reason: .recoveryRequired,
            diagnosticDescription: diagnostic
        )
        #expect(outcome == .failed(expected))
        #expect(state.actionFailure == expected)
        #expect(expected.recoveryActions == [.reconnect, .restoreSystemDNS])
    }

    @Test func successfulProfileEditInvalidatesPreviousTestResult() async throws {
        let fixture = try Fixture()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot)
        let state = AppState(backend: backend)

        #expect(await state.preflightProfile(ProfileDraft(profile: fixture.profile)) == .completed)
        #expect(state.profileTestResult != nil)

        #expect(await state.editProfile(ProfileDraft(profile: fixture.profile)) == .completed)
        #expect(state.profileTestResult == nil)
    }

    @Test func globalDraftDiscardPublishesDismissalGeneration() {
        let state = AppState(backend: FakeProductRuntimeBackend(snapshot: .empty))
        state.beginDraft(.rule)

        state.discardDraft()

        #expect(state.activeDraft == nil)
        #expect(state.draftDiscardGeneration == 1)
    }

    @Test func editorCommandsNavigateAndPublishOneConsumableRequest() {
        let state = AppState(backend: FakeProductRuntimeBackend(snapshot: .empty))

        state.requestEditor(.newProfile)

        #expect(state.navigation == .profiles)
        let request = state.editorRequest
        #expect(request?.kind == .newProfile)
        if let request { state.consumeEditorRequest(request.id) }
        #expect(state.editorRequest == nil)
    }

    @Test func commandsRouteThroughTheSameIntentBoundary() async throws {
        let fixture = try Fixture()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot)
        let state = AppState(
            backend: backend,
            systemExtension: FakeSystemExtensionController(state: .active)
        )
        let backup = try DNSProfile(
            name: "Backup",
            upstream: .plain(try PlainDNSConfiguration(serverAddress: IPAddress("198.51.100.53")))
        )
        let deletionPlan = ProfileDeletionPlan(
            ruleReplacements: [fixture.rule.id: backup.id],
            defaultReplacementProfileID: backup.id,
            manualReplacementProfileID: backup.id,
            activeReplacementProfileID: backup.id
        )

        _ = await state.preflightProfile(ProfileDraft(profile: fixture.profile))
        _ = await state.createProfile(ProfileDraft(profile: backup))
        _ = await state.duplicateProfile(
            sourceProfileID: fixture.profile.id,
            draft: ProfileDraft(profile: backup)
        )
        _ = await state.editProfile(ProfileDraft(profile: fixture.profile))
        _ = await state.deleteProfile(fixture.profile.id, plan: deletionPlan)
        _ = await state.saveRule(RuleDraft(rule: fixture.rule))
        _ = await state.setDefaultProfile(fixture.profile.id)
        _ = await state.setOperatingMode(.manual(profileID: fixture.profile.id))
        _ = await state.reorderRules([fixture.rule.id])
        _ = await state.deleteRule(fixture.rule.id)
        _ = await state.turnOnDNSProxy()
        _ = await state.restoreSystemDNS()
        _ = await state.reconnect()
        _ = await state.resetOnboardingConfiguration()
        await state.refreshDiagnostics()
        await state.requestLocationAuthorization()
        _ = await state.setDebugLoggingEnabled(true)

        #expect(backend.intents == [
            .preflightProfile(fixture.profile),
            .createProfile(backup),
            .duplicateProfile(sourceProfileID: fixture.profile.id, duplicate: backup),
            .editProfile(fixture.profile),
            .deleteProfile(profileID: fixture.profile.id, plan: deletionPlan),
            .saveRule(fixture.rule),
            .setDefaultProfile(fixture.profile.id),
            .setOperatingMode(.manual(profileID: fixture.profile.id)),
            .reorderRules([fixture.rule.id]),
            .deleteRule(fixture.rule.id),
            .turnOnDNSProxy,
            .restoreSystemDNS,
            .reconnect,
            .resetOnboardingConfiguration,
            .refreshDiagnostics,
            .requestLocationAuthorization,
            .setDebugLogging(true),
        ])
    }

    @Test func corruptRecoveryRoutesExactArtifactIntent() async throws {
        let artifact = URL(
            fileURLWithPath: "/tmp/DNSPilot-corrupt-\(UUID().uuidString).json"
        )
        let backend = FakeProductRuntimeBackend(snapshot: ProductRuntimeSnapshot(
            configuration: nil,
            proxy: .init(
                state: .disabled,
                targetProfileID: nil,
                activeProfileID: nil,
                activeGeneration: nil,
                lastSwitchFailure: nil
            ),
            network: nil,
            locationAuthorization: .notDetermined,
            startupFailure: .corruptConfiguration(
                message: "Corrupt configuration",
                recoveryArtifactURL: artifact
            ),
            diagnostics: .unavailable("Not refreshed"),
            loggingMode: .default
        ))
        let state = AppState(backend: backend)
        await state.start()

        #expect(await state.createNewConfiguration() == .completed)
        #expect(backend.intents == [.createNewConfiguration(artifact)])
    }

    @Test func turnOnRequiresAnActiveSystemExtension() async {
        let backend = FakeProductRuntimeBackend(snapshot: .empty)
        let state = AppState(
            backend: backend,
            systemExtension: FakeSystemExtensionController(state: .awaitingApproval)
        )

        let outcome = await state.turnOnDNSProxy()

        #expect(outcome == .failed(ProductActionFailure(
            action: .dnsProxyEnable,
            reason: .systemExtensionNotActive
        )))
        #expect(backend.intents.isEmpty)
    }

    @Test func backendChangeNotificationRefreshesProjection() async throws {
        let fixture = try Fixture()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot)
        let state = AppState(backend: backend)
        await state.start()
        backend.snapshot = .empty

        backend.notifyChange()
        await Task.yield()

        #expect(state.configuration == nil)
        #expect(state.proxy.state == .disabled)
    }

    @Test func recoveryRequiredRejectsOrdinaryWritesBeforeBackendBoundary() async throws {
        let fixture = try Fixture()
        let snapshot = ProductRuntimeSnapshot(
            configuration: fixture.snapshot.configuration,
            proxy: ProxyControllerSnapshot(
                state: .recoveryRequired("Reconcile manager state"),
                targetProfileID: fixture.profile.id,
                activeProfileID: nil,
                activeGeneration: nil,
                lastSwitchFailure: nil
            ),
            network: fixture.snapshot.network,
            locationAuthorization: .authorized,
            startupFailure: nil,
            diagnostics: .unavailable("Not refreshed"),
            loggingMode: .default
        )
        let backend = FakeProductRuntimeBackend(snapshot: snapshot)
        let state = AppState(backend: backend)
        await state.start()

        #expect(await state.setDefaultProfile(fixture.profile.id) == .failed(ProductActionFailure(
            action: .defaultProfileUpdate,
            reason: .recoveryRequired
        )))
        #expect(backend.intents.isEmpty)
    }

    @Test func existingConfigurationWithoutSetupIdentityMigratesPastOnboarding() async throws {
        let fixture = try Fixture()
        let suiteName = "AppStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            backend: FakeProductRuntimeBackend(snapshot: fixture.snapshot),
            userDefaults: defaults
        )
        state.requestSetupWindow()

        await state.start()

        #expect(defaults.bool(forKey: ProductWindowPolicy.onboardingCompletedKey))
        #expect(state.windowRequest?.destination == .main)
    }

    @Test func partialOnboardingIdentityIsNotMistakenForAnUpgrade() async throws {
        let fixture = try Fixture()
        let suiteName = "AppStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(fixture.profile.id.uuidString, forKey: ProductWindowPolicy.setupProfileIDKey)
        let state = AppState(
            backend: FakeProductRuntimeBackend(snapshot: fixture.snapshot),
            userDefaults: defaults
        )

        await state.start()

        #expect(!defaults.bool(forKey: ProductWindowPolicy.onboardingCompletedKey))
    }

    @Test func staleSetupIdentityDoesNotBlockExistingConfigurationMigration() async throws {
        let fixture = try Fixture()
        let suiteName = "AppStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(UUID().uuidString, forKey: ProductWindowPolicy.setupProfileIDKey)
        let state = AppState(
            backend: FakeProductRuntimeBackend(snapshot: fixture.snapshot),
            userDefaults: defaults
        )

        await state.start()

        #expect(defaults.bool(forKey: ProductWindowPolicy.onboardingCompletedKey))
    }

    @Test func configurationWithoutDefaultStillRequiresSetup() async throws {
        let fixture = try Fixture()
        let configuration = try AppConfiguration(profiles: [fixture.profile])
        let snapshot = ProductRuntimeSnapshot(
            configuration: configuration,
            proxy: fixture.snapshot.proxy,
            network: fixture.snapshot.network,
            locationAuthorization: .authorized,
            startupFailure: nil,
            diagnostics: .unavailable("Not refreshed"),
            loggingMode: .default
        )
        let suiteName = "AppStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            backend: FakeProductRuntimeBackend(snapshot: snapshot),
            userDefaults: defaults
        )

        await state.start()

        #expect(!defaults.bool(forKey: ProductWindowPolicy.onboardingCompletedKey))
    }

    @Test func successfulExtensionDeactivationResetsOnboardingForNextOpen() async throws {
        let suiteName = "AppStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: ProductWindowPolicy.onboardingCompletedKey)
        defaults.set(true, forKey: ProductWindowPolicy.introductionCompletedKey)
        defaults.set(true, forKey: ProductWindowPolicy.locationStepCompletedKey)
        defaults.set(UUID().uuidString, forKey: ProductWindowPolicy.setupProfileIDKey)
        let extensionController = FakeSystemExtensionController(state: .active)
        extensionController.deactivationResult = .inactive
        let state = AppState(
            backend: FakeProductRuntimeBackend(snapshot: .empty),
            systemExtension: extensionController,
            userDefaults: defaults
        )
        state.productWindowPresented(.main)

        #expect(await state.deactivateSystemExtensionSafely() == .completed)
        #expect(!defaults.bool(forKey: ProductWindowPolicy.onboardingCompletedKey))
        #expect(defaults.object(forKey: ProductWindowPolicy.introductionCompletedKey) == nil)
        #expect(defaults.object(forKey: ProductWindowPolicy.locationStepCompletedKey) == nil)
        #expect(defaults.string(forKey: ProductWindowPolicy.setupProfileIDKey) == nil)
        #expect(state.windowRequest == nil)
        #expect(state.presentedProductWindow == .main)

        state.productWindowClosed(.main)
        state.requestPrimaryWindow()
        #expect(state.windowRequest?.destination == .setup)
    }

    @Test func failedExtensionDeactivationPublishesActionFailure() async {
        let extensionController = FakeSystemExtensionController(state: .active)
        extensionController.deactivationResult = .failed("Extension remained active")
        let state = AppState(
            backend: FakeProductRuntimeBackend(snapshot: .empty),
            systemExtension: extensionController
        )

        let outcome = await state.deactivateSystemExtensionSafely()

        let failure = ProductActionFailure(
            action: .systemExtensionDeactivation,
            reason: .unknown,
            diagnosticDescription: "Extension remained active"
        )
        #expect(outcome == .failed(failure))
        #expect(state.settingsActionFailure == failure)
    }

    @Test func restartPendingExtensionDeactivationPreservesCompletedOnboarding() async throws {
        let suiteName = "AppStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: ProductWindowPolicy.onboardingCompletedKey)
        defaults.set(true, forKey: ProductWindowPolicy.introductionCompletedKey)
        defaults.set(true, forKey: ProductWindowPolicy.locationStepCompletedKey)
        let setupProfileID = UUID().uuidString
        defaults.set(setupProfileID, forKey: ProductWindowPolicy.setupProfileIDKey)
        let extensionController = FakeSystemExtensionController(state: .active)
        extensionController.deactivationResult = .restartRequired
        let state = AppState(
            backend: FakeProductRuntimeBackend(snapshot: .empty),
            systemExtension: extensionController,
            userDefaults: defaults
        )

        #expect(
            await state.deactivateSystemExtensionSafely()
                == .failed(ProductActionFailure(
                    action: .systemExtensionDeactivation,
                    reason: .restartRequired,
                    diagnosticDescription: "Restart required to complete System Extension change"
                ))
        )
        #expect(defaults.bool(forKey: ProductWindowPolicy.onboardingCompletedKey))
        #expect(defaults.bool(forKey: ProductWindowPolicy.introductionCompletedKey))
        #expect(defaults.bool(forKey: ProductWindowPolicy.locationStepCompletedKey))
        #expect(defaults.string(forKey: ProductWindowPolicy.setupProfileIDKey) == setupProfileID)
        #expect(state.windowRequest == nil)
    }

    @Test func failedDNSRestoreNeverRequestsExtensionDeactivation() async {
        let backend = FakeProductRuntimeBackend(snapshot: .empty)
        let failure = ProductActionFailure(
            action: .systemDNSRestore,
            reason: .systemDNSRestoreUnconfirmed,
            diagnosticDescription: "restore failed"
        )
        backend.outcome = .failed(failure)
        let extensionController = FakeSystemExtensionController(state: .active)
        let state = AppState(backend: backend, systemExtension: extensionController)

        #expect(
            await state.deactivateSystemExtensionSafely()
                == .failed(ProductActionFailure(
                    action: .systemExtensionDeactivation,
                    reason: .systemDNSRestoreUnconfirmed,
                    diagnosticDescription: failure.diagnosticDescription
                ))
        )
        #expect(extensionController.deactivationCount == 0)
    }

    @Test func extensionDeactivationRetryRepeatsTheWholeSafeOperation() async {
        let restoreFailure = ProductActionFailure(
            action: .systemDNSRestore,
            reason: .systemDNSRestoreUnconfirmed,
            diagnosticDescription: "restore failed"
        )
        let backend = FakeProductRuntimeBackend(snapshot: .empty)
        backend.outcome = .failed(restoreFailure)
        let extensionController = FakeSystemExtensionController(state: .active)
        extensionController.deactivationResult = .inactive
        let state = AppState(backend: backend, systemExtension: extensionController)

        #expect(await state.deactivateSystemExtensionSafely() == .failed(ProductActionFailure(
            action: .systemExtensionDeactivation,
            reason: .systemDNSRestoreUnconfirmed,
            diagnosticDescription: "restore failed"
        )))
        #expect(extensionController.deactivationCount == 0)

        backend.outcome = .completed
        #expect(await state.retrySettingsAction() == .completed)
        #expect(extensionController.deactivationCount == 1)
        #expect(backend.intents == [.restoreSystemDNS, .restoreSystemDNS])
    }

    @Test func debugLoggingRetryPreservesTheRequestedValue() async {
        let failure = ProductActionFailure(
            action: .debugLoggingUpdate,
            reason: .runtimeRejected
        )
        let backend = FakeProductRuntimeBackend(snapshot: .empty)
        backend.outcome = .failed(failure)
        let state = AppState(backend: backend)

        #expect(await state.setDebugLoggingEnabled(true) == .failed(failure))

        backend.outcome = .completed
        #expect(await state.retrySettingsAction() == .completed)
        #expect(backend.intents == [.setDebugLogging(true), .setDebugLogging(true)])
    }

    @Test func extensionDeactivationRunsAfterSuccessfulDNSRestore() async {
        let events = EventRecorder()
        let backend = FakeProductRuntimeBackend(snapshot: .empty, events: events)
        let extensionController = FakeSystemExtensionController(state: .active, events: events)
        extensionController.deactivationResult = .inactive
        let state = AppState(backend: backend, systemExtension: extensionController)

        #expect(await state.deactivateSystemExtensionSafely() == .completed)
        #expect(events.values == ["restoreSystemDNS", "deactivateSystemExtension"])
    }

    @Test func completedStartupAllowsAutomaticExtensionUpdateOnlyWhenDNSIsDisabled() async throws {
        let disabledController = FakeSystemExtensionController(state: .updateRequired)
        let disabledState = AppState(
            backend: FakeProductRuntimeBackend(snapshot: .empty),
            systemExtension: disabledController
        )
        #expect(disabledController.activationCount == 0)

        await disabledState.start()
        #expect(disabledController.activationCount == 1)

        let fixture = try Fixture()
        let activeController = FakeSystemExtensionController(state: .updateRequired)
        let activeState = AppState(
            backend: FakeProductRuntimeBackend(snapshot: fixture.snapshot),
            systemExtension: activeController
        )
        await activeState.start()
        #expect(activeController.activationCount == 0)
    }

    @Test func startupFailureNeverAllowsAutomaticExtensionUpdate() async {
        let failedSnapshot = ProductRuntimeSnapshot(
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
            startupFailure: .unavailable("startup failed"),
            diagnostics: .unavailable("Not refreshed"),
            loggingMode: .default
        )
        let extensionController = FakeSystemExtensionController(state: .updateRequired)
        let state = AppState(
            backend: FakeProductRuntimeBackend(snapshot: failedSnapshot),
            systemExtension: extensionController
        )

        await state.start()

        #expect(extensionController.activationCount == 0)
    }

    @Test func interruptedStartupDoesNotUpdateExtensionAndCanRetry() async {
        let backend = FakeProductRuntimeBackend(snapshot: .empty)
        backend.startSucceeded = false
        let extensionController = FakeSystemExtensionController(state: .updateRequired)
        let state = AppState(backend: backend, systemExtension: extensionController)

        await state.start()
        #expect(extensionController.activationCount == 0)

        backend.startSucceeded = true
        await state.start()
        #expect(backend.startCount == 2)
        #expect(extensionController.activationCount == 1)
    }

    @Test func cancelledRealBackendStartupReturnsIncompleteAndCanRetry() async {
        var attempts = 0
        let backend = DNSPilotAppModel(configurationStoreFactory: {
            attempts += 1
            throw CancellationError()
        })

        #expect(await backend.start() == false)
        #expect(await backend.start() == false)
        #expect(attempts == 2)
    }

    @Test func inFlightProductActionBlocksAutomaticExtensionUpdate() async {
        let gate = AsyncGate()
        let backend = FakeProductRuntimeBackend(snapshot: .empty)
        backend.intentGate = gate
        let extensionController = FakeSystemExtensionController(state: .active)
        let state = AppState(backend: backend, systemExtension: extensionController)
        await state.start()

        let turnOnTask = Task { await state.turnOnDNSProxy() }
        while backend.intents.isEmpty { await Task.yield() }
        extensionController.send(.updateRequired)
        await Task.yield()
        await Task.yield()

        #expect(extensionController.activationCount == 0)
        await gate.open()
        _ = await turnOnTask.value
    }

    @Test func explicitExtensionUpdateRestoresDNSBeforeActivation() async throws {
        let fixture = try Fixture()
        let events = EventRecorder()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot, events: events)
        let extensionController = FakeSystemExtensionController(
            state: .updateRequired,
            events: events
        )
        let state = AppState(backend: backend, systemExtension: extensionController)
        await state.start()

        #expect(await state.updateSystemExtensionSafely() == .completed)
        #expect(events.values == ["restoreSystemDNS", "activateSystemExtension"])
        #expect(extensionController.activationCount == 1)
    }

    @Test func explicitExtensionUpdateSkipsRestoreWhenDNSIsAlreadyDisabled() async {
        let events = EventRecorder()
        let backend = FakeProductRuntimeBackend(snapshot: .empty, events: events)
        let extensionController = FakeSystemExtensionController(
            state: .updateFailed("retry"),
            events: events
        )
        let state = AppState(backend: backend, systemExtension: extensionController)
        await state.start()

        #expect(await state.updateSystemExtensionSafely() == .completed)
        #expect(events.values == ["activateSystemExtension"])
    }

    @Test func explicitExtensionUpdateRequiresCompletedStartup() async {
        let extensionController = FakeSystemExtensionController(state: .updateRequired)
        let state = AppState(
            backend: FakeProductRuntimeBackend(snapshot: .empty),
            systemExtension: extensionController
        )

        #expect(
            await state.updateSystemExtensionSafely()
                == .failed(ProductActionFailure(
                    action: .systemExtensionUpdate,
                    reason: .systemExtensionOperationUnavailable
                ))
        )
        #expect(extensionController.activationCount == 0)
    }

    @Test func explicitExtensionUpdateRequiresConfirmedDisabledSnapshot() async throws {
        let fixture = try Fixture()
        let backend = FakeProductRuntimeBackend(snapshot: fixture.snapshot)
        backend.restoreUpdatesSnapshot = false
        let extensionController = FakeSystemExtensionController(state: .updateRequired)
        let state = AppState(backend: backend, systemExtension: extensionController)
        await state.start()

        #expect(
            await state.updateSystemExtensionSafely()
                == .failed(ProductActionFailure(
                    action: .systemExtensionUpdate,
                    reason: .systemDNSRestoreUnconfirmed
                ))
        )
        #expect(extensionController.activationCount == 0)
    }

    @Test func menuQuitUsesConfiguredCoordinatorBoundary() {
        let state = AppState(backend: FakeProductRuntimeBackend(snapshot: .empty))
        var quitCount = 0
        state.setQuitHandler { quitCount += 1 }

        state.quit()

        #expect(quitCount == 1)
    }

    @Test func terminationActionsUseTheInjectedRuntimeBoundary() async {
        let backend = FakeProductRuntimeBackend(snapshot: .empty)
        backend.terminationRestoreState = .disabled
        let state = AppState(backend: backend)

        #expect(await state.restoreSystemDNSForTermination() == .disabled)
        await state.cancelTerminationRequest()

        #expect(backend.terminationRestoreCount == 1)
        #expect(backend.terminationCancelCount == 1)
    }

    @Test func emptyConfigurationReopensSetupAndClearsCompletion() async throws {
        let suiteName = "AppStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: ProductWindowPolicy.onboardingCompletedKey)
        let emptyConfiguration = ProductRuntimeSnapshot(
            configuration: try AppConfiguration(),
            proxy: .init(
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
        let state = AppState(
            backend: FakeProductRuntimeBackend(snapshot: emptyConfiguration),
            userDefaults: defaults
        )
        state.requestPrimaryWindow()
        #expect(state.windowRequest?.destination == .main)

        await state.start()

        #expect(!defaults.bool(forKey: ProductWindowPolicy.onboardingCompletedKey))
        #expect(state.windowRequest?.destination == .setup)
    }

    @Test func navigationRequestsSelectExactProfileAndRule() async throws {
        let fixture = try Fixture()
        let state = AppState(backend: FakeProductRuntimeBackend(snapshot: fixture.snapshot))

        state.navigateToProfile(fixture.profile.id)
        #expect(state.navigation == .profiles)
        #expect(state.requestedProfileSelection == fixture.profile.id)

        state.navigateToRule(fixture.rule.id)
        #expect(state.navigation == .rules)
        #expect(state.requestedRuleSelection == fixture.rule.id)
    }

    @Test func diagnosticsExportUsesExplicitUnredactedReport() async throws {
        let fixture = try Fixture()
        let exporter = FakeDiagnosticExporter()
        let state = AppState(
            backend: FakeProductRuntimeBackend(snapshot: fixture.snapshot),
            diagnosticExporter: exporter
        )
        await state.start()

        #expect(await state.exportDiagnostics() == .completed)
        #expect(exporter.contents?.contains("Profile: Office DNS") == true)
    }

}

@MainActor
private final class FakeProductRuntimeBackend: ProductRuntimeBacking {
    var snapshot: ProductRuntimeSnapshot
    var outcome: ProductActionOutcome = .completed
    var restoreUpdatesSnapshot = true
    var startSucceeded = true
    var intentGate: AsyncGate?
    private(set) var startCount = 0
    private(set) var intents: [ProductIntent] = []
    var terminationRestoreState = DNSProxyControllerState.disabled
    private(set) var terminationRestoreCount = 0
    private(set) var terminationCancelCount = 0
    private var changeHandler: (@MainActor () -> Void)?
    private let events: EventRecorder?

    init(snapshot: ProductRuntimeSnapshot, events: EventRecorder? = nil) {
        self.snapshot = snapshot
        self.events = events
    }

    func start() async -> Bool {
        startCount += 1
        return startSucceeded
    }

    func productSnapshot() async -> ProductRuntimeSnapshot {
        snapshot
    }

    func performProductIntent(_ intent: ProductIntent) async -> ProductActionOutcome {
        intents.append(intent)
        if let intentGate { await intentGate.wait() }
        if intent == .restoreSystemDNS {
            events?.values.append("restoreSystemDNS")
            if outcome == .completed, restoreUpdatesSnapshot {
                snapshot = ProductRuntimeSnapshot(
                    configuration: snapshot.configuration,
                    proxy: ProxyControllerSnapshot(
                        state: .disabled,
                        targetProfileID: nil,
                        activeProfileID: nil,
                        activeGeneration: nil,
                        lastSwitchFailure: nil
                    ),
                    network: snapshot.network,
                    locationAuthorization: snapshot.locationAuthorization,
                    startupFailure: snapshot.startupFailure,
                    diagnostics: snapshot.diagnostics,
                    loggingMode: snapshot.loggingMode
                )
            }
        }
        return outcome
    }

    func setProductChangeHandler(_ handler: (@MainActor () -> Void)?) {
        changeHandler = handler
    }

    func restoreSystemDNSForTermination() async -> DNSProxyControllerState {
        terminationRestoreCount += 1
        return terminationRestoreState
    }

    func cancelTerminationRequest() async {
        terminationCancelCount += 1
    }

    func notifyChange() {
        changeHandler?()
    }
}

@MainActor
private final class FakeSystemExtensionController: SystemExtensionControlling {
    private let subject: CurrentValueSubject<SystemExtensionController.State, Never>
    var requestInProgress = false
    var installedVersion: SystemExtensionController.BundleVersion?
    var bundledVersion: SystemExtensionController.BundleVersion?
    var deactivationResult: SystemExtensionController.State?
    private(set) var deactivationCount = 0
    private(set) var activationCount = 0
    private let events: EventRecorder?

    var state: SystemExtensionController.State { subject.value }
    var statePublisher: AnyPublisher<SystemExtensionController.State, Never> {
        subject.eraseToAnyPublisher()
    }

    init(state: SystemExtensionController.State, events: EventRecorder? = nil) {
        subject = CurrentValueSubject(state)
        self.events = events
    }

    func synchronizeState() { subject.send(subject.value) }
    func activate() {
        activationCount += 1
        events?.values.append("activateSystemExtension")
        requestInProgress = true
        subject.send(.activating)
    }
    func deactivate() { }
    func deactivateAndWait() async -> SystemExtensionController.State {
        deactivationCount += 1
        events?.values.append("deactivateSystemExtension")
        let result = deactivationResult ?? state
        subject.send(result)
        return result
    }

    func send(_ state: SystemExtensionController.State) {
        subject.send(state)
    }
}

@MainActor
private final class EventRecorder {
    var values: [String] = []
}

@MainActor
private final class FakeDiagnosticExporter: DiagnosticExporting {
    private(set) var contents: String?

    func export(_ contents: String) async throws -> Bool {
        self.contents = contents
        return true
    }
}

private struct Fixture {
    let profile: DNSProfile
    let rule: DNSRule
    let snapshot: ProductRuntimeSnapshot

    init() throws {
        profile = try DNSProfile(
            name: "Office DNS",
            upstream: .plain(try PlainDNSConfiguration(serverAddress: IPAddress("192.0.2.53")))
        )
        rule = try DNSRule(
            name: "Studio Rule",
            conditions: RuleConditions(ssids: ["Studio"]),
            profileID: profile.id
        )
        let configuration = try AppConfiguration(
            profiles: [profile],
            rules: [rule],
            defaultProfileID: profile.id
        )
        snapshot = ProductRuntimeSnapshot(
            configuration: configuration,
            proxy: ProxyControllerSnapshot(
                state: .active(UUID()),
                targetProfileID: profile.id,
                activeProfileID: profile.id,
                activeGeneration: UUID(),
                lastSwitchFailure: nil
            ),
            network: NetworkContext(
                status: .satisfied,
                ssid: "Studio",
                ssidAvailability: .available,
                activeInterfaceTypes: [.wifi],
                addresses: []
            ),
            locationAuthorization: .authorized,
            startupFailure: nil,
            diagnostics: .unavailable("Not refreshed"),
            loggingMode: .default
        )
    }
}

private extension ProductRuntimeSnapshot {
    static let empty = ProductRuntimeSnapshot(
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
