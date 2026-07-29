import NetworkExtension

enum DNSProxyExtensionRuntime {
    static let lifecycle = ProxyLifecycleController(
        service: DNSProxyEngine(),
        statusRecorder: RuntimeStatusStore.shared
    )
    static let runtimeControlHandler = ProxyRuntimeControlHandler(
        providerInstanceID: RuntimeStatusStore.shared.providerInstanceID,
        lifecycle: lifecycle
    )
}

private enum DNSProxyProviderError: LocalizedError {
    case missingVendorData
    case missingConfigurationData
    case configurationTooLarge

    var errorDescription: String? {
        switch self {
        case .missingVendorData:
            "The DNS proxy start options do not contain VendorData."
        case .missingConfigurationData:
            "VendorData does not contain the active DNS proxy configuration."
        case .configurationTooLarge:
            "The active DNS proxy configuration exceeds the supported size."
        }
    }
}

final class DNSProxyProvider: NEDNSProxyProvider {
    private let lifecycle = DNSProxyExtensionRuntime.lifecycle

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let configuration: PersistedProxyConfiguration
        do {
            guard
                let vendorData = options?[ActiveProxyConfiguration.vendorDataOptionKey]
                    as? [String: Any]
            else {
                throw DNSProxyProviderError.missingVendorData
            }
            guard
                let data = vendorData[ActiveProxyConfiguration.providerConfigurationKey] as? Data
            else {
                throw DNSProxyProviderError.missingConfigurationData
            }
            guard data.count <= DNSProxyXPCContract.maximumConfigurationSize else {
                throw DNSProxyProviderError.configurationTooLarge
            }

            configuration = try PersistedProxyConfiguration(data: data)
        } catch {
            RuntimeStatusStore.shared.update(
                generation: nil,
                phase: .failed,
                errorCode: .invalidConfiguration
            )
            completionHandler(error)
            return
        }

        do {
            try lifecycle.start(configuration: configuration)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        lifecycle.stop()
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {}

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        lifecycle.handle(flow)
    }
}
