//
//  DNSPilotTests.swift
//  DNSPilotTests
//
//  Copyright 2026 DNSPilot Contributors.
//

import Foundation
import Testing
@testable import DNSPilot

struct DNSPilotTests {

    @Test func loadsLockedAGDnsProxyVersion() {
        #expect(DNSLogBridge.libraryVersion == "2.8.45")
    }

    @Test func mapsDefaultAndDebugDnsLibsLogging() {
        #expect(DNSLogBridge.configuration(for: .default) == .init(
            levelRawValue: 2,
            messagesArePublic: false
        ))
        #expect(DNSLogBridge.configuration(for: .debug) == .init(
            levelRawValue: 4,
            messagesArePublic: true
        ))
    }

    @Test func runtimeEvidencePropertyListRoundTrip() throws {
        let evidence = ProxyRuntimeEvidence(
            schemaVersion: ProxyRuntimeEvidence.currentSchemaVersion,
            generation: UUID(),
            udpFlowsOffered: 2,
            tcpFlowsOffered: 1,
            otherFlowsOffered: 0,
            flowsAccepted: 3,
            flowsRejected: 0,
            requestsProcessed: 4,
            startedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        let data = try PropertyListEncoder().encode(evidence)
        #expect(try PropertyListDecoder().decode(ProxyRuntimeEvidence.self, from: data) == evidence)
    }
}
