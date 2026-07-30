import Foundation

struct ProductDiagnosticReport: Equatable, Sendable {
    let summary: String
    let export: String

    static func make(
        configuration: AppConfiguration?,
        proxy: ProxyControllerSnapshot,
        network: NetworkContext?,
        systemExtensionDescription: String,
        systemExtensionVersion: String,
        diagnostics: ProductDiagnosticsSnapshot,
        loggingMode: ProxyLoggingMode,
        generatedAt: Date = Date()
    ) -> Self {
        let profiles = configuration?.profiles ?? []
        let displayNames = ProfileDisplayIdentity.displayNames(for: profiles)
        let activeName = proxy.activeProfileID.flatMap { displayNames[$0] } ?? "System DNS"
        var summaryLines = [
            "DNS Proxy: \(proxy.state.description)",
            "Active Profile: \(activeName)",
            "Network Status: \(network?.status.rawValue ?? "checking")",
            "System Extension: \(systemExtensionDescription)",
            "System Extension Version: \(systemExtensionVersion)",
            "DnsLibs: \(DNSLogBridge.libraryVersion)",
            "Debug Logging: \(loggingMode == .debug ? "On" : "Off")",
        ]
        appendRuntimeSummary(diagnostics, to: &summaryLines)

        var exportLines = summaryLines
        exportLines.insert("Generated At: \(generatedAt.ISO8601Format())", at: 0)
        appendSensitiveRuntimeDetails(diagnostics, to: &exportLines)
        exportLines.append("Operating Mode: \(operatingModeDescription(configuration?.operatingMode))")
        exportLines.append("Wi-Fi Name: \(network?.ssid ?? "unavailable")")
        exportLines.append("Interfaces: \(network?.activeInterfaceTypes.map(\.rawValue).sorted().joined(separator: ", ") ?? "")")
        exportLines.append("Addresses: \(network?.addresses.map { $0.address.stringValue }.joined(separator: ", ") ?? "")")
        if let failure = proxy.lastSwitchFailure {
            exportLines.append("Last Switch Error: \(failure.code.rawValue): \(failure.message)")
        }
        for profile in profiles {
            exportLines.append("Profile: \(profile.name) | \(upstreamDescription(profile.upstream))")
        }
        for rule in configuration?.rules ?? [] {
            exportLines.append("Rule: \(rule.name) | \(rule.conditions) | Profile \(rule.profileID.uuidString)")
        }
        return Self(
            summary: summaryLines.joined(separator: "\n"),
            export: exportLines.joined(separator: "\n") + "\n"
        )
    }

    private static func appendRuntimeSummary(
        _ diagnostics: ProductDiagnosticsSnapshot,
        to lines: inout [String]
    ) {
        switch diagnostics {
        case let .available(protocolVersion, _, _, phase, errorCode, _, sequence, _):
            lines.append("Runtime Protocol: \(protocolVersion.map(String.init) ?? "unavailable")")
            lines.append("Runtime Phase: \(phase.rawValue)")
            lines.append("Runtime Error: \(errorCode?.rawValue ?? "none")")
            lines.append("Transition Sequence: \(sequence.map(String.init) ?? "unavailable")")
        case let .unavailable(message):
            lines.append("Runtime Details: unavailable (\(message))")
        }
    }

    private static func appendSensitiveRuntimeDetails(
        _ diagnostics: ProductDiagnosticsSnapshot,
        to lines: inout [String]
    ) {
        guard case let .available(_, providerID, generation, _, _, fingerprint, _, quiesced)
            = diagnostics else { return }
        lines.append("Provider Instance: \(providerID?.uuidString ?? "unavailable")")
        lines.append("Active Generation: \(generation?.uuidString ?? "unavailable")")
        lines.append("Configuration Fingerprint: \(fingerprint?.rawValue ?? "unavailable")")
        lines.append("Last Quiesced Generation: \(quiesced?.uuidString ?? "unavailable")")
    }

    private static func operatingModeDescription(_ mode: OperatingMode?) -> String {
        switch mode {
        case .automatic: "Automatic"
        case let .manual(profileID): "Manual: \(profileID.uuidString)"
        case nil: "Unavailable"
        }
    }

    private static func upstreamDescription(_ upstream: DNSUpstream) -> String {
        switch upstream {
        case let .plain(configuration):
            "Plain DNS \(configuration.serverAddress.stringValue):\(configuration.port)"
        case let .tls(configuration):
            "DNS over TLS \(configuration.serverName):\(configuration.port) | Bootstrap \(configuration.bootstrapServers.map(\.stringValue).joined(separator: ", "))"
        case let .https(configuration):
            "DNS over HTTPS \(configuration.endpointURL.absoluteString) | Bootstrap \(configuration.bootstrapServers.map(\.stringValue).joined(separator: ", "))"
        }
    }
}
