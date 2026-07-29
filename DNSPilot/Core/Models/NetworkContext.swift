import Foundation

enum NetworkStatus: String, Codable, Equatable, Sendable {
    case satisfied
    case requiresConnection
    case unsatisfied
}

enum SSIDAvailability: String, Codable, Equatable, Sendable {
    case available
    case notOnWiFi
    case permissionNotDetermined
    case permissionDenied
    case temporarilyUnavailable
}

struct InterfaceAddress: Codable, Equatable, Sendable {
    let interfaceName: String
    let address: IPAddress
    let prefixLength: Int?

    init(interfaceName: String, address: IPAddress, prefixLength: Int? = nil) {
        self.interfaceName = interfaceName
        self.address = address
        self.prefixLength = prefixLength
    }
}

struct NetworkContext: Codable, Equatable, Sendable {
    let status: NetworkStatus
    let ssid: String?
    let ssidAvailability: SSIDAvailability
    let activeInterfaceTypes: Set<NetworkInterfaceType>
    let addresses: [InterfaceAddress]

    init(
        status: NetworkStatus,
        ssid: String?,
        ssidAvailability: SSIDAvailability,
        activeInterfaceTypes: Set<NetworkInterfaceType>,
        addresses: [InterfaceAddress]
    ) {
        self.status = status
        self.ssid = ssid
        self.ssidAvailability = ssidAvailability
        self.activeInterfaceTypes = activeInterfaceTypes
        self.addresses = addresses
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case ssid
        case ssidAvailability
        case activeInterfaceTypes
        case addresses
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(NetworkStatus.self, forKey: .status)
        ssid = try container.decodeIfPresent(String.self, forKey: .ssid)
        ssidAvailability = try container.decode(SSIDAvailability.self, forKey: .ssidAvailability)
        activeInterfaceTypes = Set(
            try container.decode([NetworkInterfaceType].self, forKey: .activeInterfaceTypes)
        )
        addresses = try container.decode([InterfaceAddress].self, forKey: .addresses)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(ssid, forKey: .ssid)
        try container.encode(ssidAvailability, forKey: .ssidAvailability)
        try container.encode(
            activeInterfaceTypes.sorted { $0.rawValue < $1.rawValue },
            forKey: .activeInterfaceTypes
        )
        try container.encode(addresses, forKey: .addresses)
    }
}
