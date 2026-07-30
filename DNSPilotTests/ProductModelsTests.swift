import Foundation
import Testing
@testable import DNSPilot

struct ProductModelsTests {
    @Test func profileDraftPreservesIdentityAndInactiveTransportFields() throws {
        let id = UUID()
        let draft = ProfileDraft(
            id: id,
            name: "  Office DNS  ",
            transport: .plain,
            plainServerAddress: " 2001:db8::53 ",
            plainPort: 5353,
            endpointURL: "https://unused.example.test/dns-query",
            bootstrapServers: ["192.0.2.1"]
        )

        let profile = try draft.profile()
        #expect(profile.id == id)
        #expect(profile.name == "Office DNS")
        guard case let .plain(configuration) = profile.upstream else {
            Issue.record("Expected Plain DNS")
            return
        }
        #expect(configuration.serverAddress.stringValue == "2001:db8::53")
        #expect(configuration.port == 5353)
    }

    @Test func profileDraftReportsTypedFieldFailures() {
        #expect(throws: ProfileDraftError.emptyName) {
            try ProfileDraft(name: " ", transport: .plain, plainServerAddress: "192.0.2.1").profile()
        }
        #expect(throws: ProfileDraftError.invalidServerAddress("not-an-ip")) {
            try ProfileDraft(name: "DNS", transport: .plain, plainServerAddress: "not-an-ip").profile()
        }
        #expect(throws: ProfileDraftError.invalidPort(0)) {
            try ProfileDraft(
                name: "DNS",
                transport: .plain,
                plainServerAddress: "192.0.2.1",
                plainPort: 0
            ).profile()
        }
        #expect(throws: ProfileDraftError.missingBootstrapServers) {
            try ProfileDraft(
                name: "DoH",
                endpointURL: "https://dns.example.test/dns-query"
            ).profile()
        }
        #expect(throws: ProfileDraftError.invalidServerName("bad host")) {
            try ProfileDraft(
                name: "DoT",
                transport: .tls,
                dotServerName: "bad host",
                bootstrapServers: ["192.0.2.1"]
            ).profile()
        }
    }

    @Test func dotProfileDraftRoundTripsAllFields() throws {
        let profile = try ProfileDraft(
            name: "Private DoT",
            transport: .tls,
            dotServerName: "DNS.Example.Test",
            dotPort: 8853,
            bootstrapServers: ["192.0.2.53"]
        ).profile()
        let draft = ProfileDraft(profile: profile)

        #expect(draft.transport == .tls)
        #expect(draft.dotServerName == "dns.example.test")
        #expect(draft.dotPort == 8853)
        #expect(draft.bootstrapServers == ["192.0.2.53"])
        #expect(try draft.profile() == profile)
    }

    @Test func ruleDraftNormalizesSubnetsAndPreservesSSIDCase() throws {
        let profileID = UUID()
        let rule = try RuleDraft(
            name: "  Office  ",
            ssids: [" Studio ", ""],
            interfaceTypes: [.wifi],
            subnets: ["192.0.2.99/24"],
            profileID: profileID
        ).rule()

        #expect(rule.name == "Office")
        #expect(rule.conditions.ssids == ["Studio"])
        #expect(rule.conditions.subnets.map(\.stringValue) == ["192.0.2.0/24"])
        #expect(rule.profileID == profileID)
    }

    @Test func ruleDraftRequiresNameConditionsProfileAndValidCIDR() {
        let profileID = UUID()
        #expect(throws: RuleDraftError.emptyName) {
            try RuleDraft(name: " ", ssids: ["Studio"], profileID: profileID).rule()
        }
        #expect(throws: RuleDraftError.missingProfile) {
            try RuleDraft(name: "Office", ssids: ["Studio"]).rule()
        }
        #expect(throws: RuleDraftError.missingConditions) {
            try RuleDraft(name: "Office", profileID: profileID).rule()
        }
        #expect(throws: RuleDraftError.invalidSubnet("invalid")) {
            try RuleDraft(name: "Office", subnets: ["invalid"], profileID: profileID).rule()
        }
    }

    @Test func onboardingDerivesSystemStepsAndKeepsStableSetupProfileID() throws {
        let id = UUID()
        var progress = OnboardingProgress(setupProfileID: id)
        #expect(progress.currentStep(
            isSetupProfileConfigured: false,
            isSystemExtensionInstalled: false,
            isDNSProxyActive: false
        ) == .introduction)

        progress.introductionCompleted = true
        progress.locationStepCompleted = true
        #expect(progress.currentStep(
            isSetupProfileConfigured: true,
            isSystemExtensionInstalled: false,
            isDNSProxyActive: false
        ) == .systemExtension)
        #expect(progress.currentStep(
            isSetupProfileConfigured: true,
            isSystemExtensionInstalled: true,
            isDNSProxyActive: true
        ) == .complete)

        let decoded = try JSONDecoder().decode(
            OnboardingProgress.self,
            from: JSONEncoder().encode(progress)
        )
        #expect(decoded.setupProfileID == id)
    }

    @Test func onboardingStopsAtTheFirstIncompleteStep() {
        let id = UUID()
        let cases: [(OnboardingProgress, Bool, Bool, Bool, OnboardingStep)] = [
            (OnboardingProgress(setupProfileID: id), false, false, false, .introduction),
            (OnboardingProgress(setupProfileID: id, introductionCompleted: true), false, false, false, .profile),
            (OnboardingProgress(setupProfileID: id, introductionCompleted: true), true, false, false, .location),
            (OnboardingProgress(setupProfileID: id, introductionCompleted: true, locationStepCompleted: true), true, false, false, .systemExtension),
            (OnboardingProgress(setupProfileID: id, introductionCompleted: true, locationStepCompleted: true), true, true, false, .dnsProxy),
            (OnboardingProgress(setupProfileID: id, introductionCompleted: true, locationStepCompleted: true), true, true, true, .complete),
        ]

        for (progress, profile, extensionInstalled, proxy, expected) in cases {
            #expect(progress.currentStep(
                isSetupProfileConfigured: profile,
                isSystemExtensionInstalled: extensionInstalled,
                isDNSProxyActive: proxy
            ) == expected)
        }
    }

    @Test func menuPresentationSeparatesTargetAndActiveAndRedactsDoHDetails() throws {
        let first = try DNSProfile(
            name: "Office",
            upstream: .https(try DoHConfiguration(
                endpointURL: #require(URL(string: "https://dns.example.test/private?token=secret")),
                bootstrapServers: [IPAddress("192.0.2.1")]
            ))
        )
        let second = try DNSProfile(
            name: "Office",
            upstream: .plain(try PlainDNSConfiguration(serverAddress: IPAddress("198.51.100.53")))
        )
        let configuration = try AppConfiguration(
            profiles: [first, second],
            defaultProfileID: first.id,
            operatingMode: .automatic
        )
        let presentation = MenuBarPresentation.make(
            configuration: configuration,
            proxy: ProxyControllerSnapshot(
                state: .preparing(UUID()),
                targetProfileID: second.id,
                activeProfileID: first.id,
                activeGeneration: UUID(),
                lastSwitchFailure: nil
            ),
            network: NetworkContext(
                status: .satisfied,
                ssid: "Studio",
                ssidAvailability: .available,
                activeInterfaceTypes: [.wifi],
                addresses: []
            )
        )

        #expect(presentation.statusText.contains("Office · Plain DNS"))
        #expect(presentation.profileLines.count == 2)
        #expect(presentation.networkText == "Network: Studio - Wi-Fi")
        #expect(!presentation.profileLines.joined().contains("private"))
        #expect(!presentation.profileLines.joined().contains("secret"))
        #expect(presentation.proxyCommand == .unavailable)
    }

    @Test func profileDeletionBlocksOnlyATargetThatDiffersFromActive() {
        let profileID = UUID()
        let activeProfileID = UUID()

        #expect(ProfileDeletionPolicy.isPendingTarget(
            profileID: profileID,
            targetProfileID: profileID,
            activeProfileID: activeProfileID
        ))
        #expect(!ProfileDeletionPolicy.isPendingTarget(
            profileID: profileID,
            targetProfileID: profileID,
            activeProfileID: profileID
        ))
        #expect(!ProfileDeletionPolicy.isPendingTarget(
            profileID: profileID,
            targetProfileID: nil,
            activeProfileID: activeProfileID
        ))
    }

    @Test func degradedMenuDoesNotOfferRedundantSystemDNSRestore() throws {
        let profile = try DNSProfile(
            name: "Office",
            upstream: .plain(try PlainDNSConfiguration(serverAddress: IPAddress("192.0.2.53")))
        )
        let configuration = try AppConfiguration(
            profiles: [profile],
            defaultProfileID: profile.id
        )

        let presentation = MenuBarPresentation.make(
            configuration: configuration,
            proxy: ProxyControllerSnapshot(
                state: .degraded("System DNS is active"),
                targetProfileID: profile.id,
                activeProfileID: nil,
                activeGeneration: nil,
                lastSwitchFailure: nil
            ),
            network: nil
        )

        #expect(presentation.proxyCommand == .unavailable)
    }

    @Test func diagnosticSummaryIsRedactedWhileExplicitExportRetainsDetails() throws {
        let providerID = UUID()
        let generation = UUID()
        let quiescedGeneration = UUID()
        let fingerprint = ProxyConfigurationFingerprint(data: Data("private".utf8))
        let profile = try DNSProfile(
            name: "Private Resolver",
            upstream: .https(try DoHConfiguration(
                endpointURL: #require(URL(string: "https://dns.example.test/private?token=secret")),
                bootstrapServers: [IPAddress("192.0.2.53")]
            ))
        )
        let configuration = try AppConfiguration(
            profiles: [profile],
            defaultProfileID: profile.id
        )
        let report = ProductDiagnosticReport.make(
            configuration: configuration,
            proxy: ProxyControllerSnapshot(
                state: .active(UUID()),
                targetProfileID: nil,
                activeProfileID: profile.id,
                activeGeneration: UUID(),
                lastSwitchFailure: nil
            ),
            network: NetworkContext(
                status: .satisfied,
                ssid: "Private Studio",
                ssidAvailability: .available,
                activeInterfaceTypes: [.wifi],
                addresses: [InterfaceAddress(
                    interfaceName: "en0",
                    address: try IPAddress("198.51.100.9"),
                    prefixLength: 24
                )]
            ),
            systemExtensionDescription: "Active",
            systemExtensionVersion: "1.0 (1)",
            diagnostics: .available(
                runtimeControlProtocolVersion: 3,
                providerInstanceID: providerID,
                activeGeneration: generation,
                phase: .ready,
                errorCode: nil,
                configurationFingerprint: fingerprint,
                transitionSequence: 9,
                lastQuiescedGeneration: quiescedGeneration
            ),
            loggingMode: .debug,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(!report.summary.contains("Private Studio"))
        #expect(!report.summary.contains("198.51.100.9"))
        #expect(!report.summary.contains("token=secret"))
        #expect(!report.summary.contains("192.0.2.53"))
        #expect(!report.summary.contains(providerID.uuidString))
        #expect(!report.summary.contains(generation.uuidString))
        #expect(!report.summary.contains(fingerprint.rawValue))
        #expect(!report.summary.contains(quiescedGeneration.uuidString))
        #expect(report.export.contains("Private Studio"))
        #expect(report.export.contains("198.51.100.9"))
        #expect(report.export.contains("token=secret"))
        #expect(report.export.contains("192.0.2.53"))
        #expect(report.export.contains(providerID.uuidString))
        #expect(report.export.contains(generation.uuidString))
        #expect(report.export.contains(fingerprint.rawValue))
        #expect(report.export.contains(quiescedGeneration.uuidString))
    }
}
