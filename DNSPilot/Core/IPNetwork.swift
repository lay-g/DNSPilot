import Foundation

enum IPNetworkError: LocalizedError, Equatable, Sendable {
    case invalidCIDR(String)
    case invalidPrefixLength(Int, IPAddress.Family)

    var errorDescription: String? {
        switch self {
        case let .invalidCIDR(value):
            "Invalid IP network: \(value)."
        case let .invalidPrefixLength(prefixLength, family):
            "Invalid \(family == .ipv4 ? "IPv4" : "IPv6") prefix length: \(prefixLength)."
        }
    }
}

struct IPNetwork: Codable, Hashable, Sendable {
    let networkAddress: IPAddress
    let prefixLength: Int

    var stringValue: String {
        "\(networkAddress.stringValue)/\(prefixLength)"
    }

    init(_ cidr: String) throws {
        let components = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard
            components.count == 2,
            !components[0].isEmpty,
            let prefixLength = Int(components[1])
        else {
            throw IPNetworkError.invalidCIDR(cidr)
        }

        let address: IPAddress
        do {
            address = try IPAddress(String(components[0]))
        } catch {
            throw IPNetworkError.invalidCIDR(cidr)
        }

        try self.init(address: address, prefixLength: prefixLength)
    }

    init(address: IPAddress, prefixLength: Int) throws {
        let maximumPrefixLength = address.family == .ipv4 ? 32 : 128
        guard (0...maximumPrefixLength).contains(prefixLength) else {
            throw IPNetworkError.invalidPrefixLength(prefixLength, address.family)
        }

        self.prefixLength = prefixLength
        networkAddress = IPAddress(
            family: address.family,
            bytes: Self.masked(address.bytes, prefixLength: prefixLength)
        )
    }

    func contains(_ address: IPAddress) -> Bool {
        guard address.family == networkAddress.family else { return false }
        return Self.masked(address.bytes, prefixLength: prefixLength) == networkAddress.bytes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }

    private static func masked(_ bytes: [UInt8], prefixLength: Int) -> [UInt8] {
        var result = bytes
        let completeBytes = prefixLength / 8
        let remainingBits = prefixLength % 8

        if remainingBits > 0 {
            result[completeBytes] &= UInt8.max << (8 - remainingBits)
        }
        let firstZeroByte = completeBytes + (remainingBits > 0 ? 1 : 0)
        if firstZeroByte < result.count {
            for index in firstZeroByte..<result.count {
                result[index] = 0
            }
        }
        return result
    }
}
