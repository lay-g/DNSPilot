import CryptoKit
import Foundation

struct ProxyConfigurationFingerprint: RawRepresentable, Codable, Hashable, Sendable {
    private static let encodedLength = 64

    let rawValue: String

    init?(rawValue: String) {
        guard
            rawValue.utf8.count == Self.encodedLength,
            rawValue.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            })
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    init(data: Data) {
        rawValue = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let fingerprint = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a 64-character lowercase SHA-256 fingerprint."
            )
        }
        self = fingerprint
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct PersistedProxyConfiguration: Equatable, Sendable {
    let value: ActiveProxyConfiguration
    let data: Data
    let fingerprint: ProxyConfigurationFingerprint

    init(data: Data) throws {
        value = try ActiveProxyConfiguration.decodePropertyList(data)
        self.data = data
        fingerprint = ProxyConfigurationFingerprint(data: data)
    }

    init(value: ActiveProxyConfiguration) throws {
        try self.init(data: value.propertyListData())
    }
}
