import Darwin
import Foundation

enum IPAddressError: LocalizedError, Equatable, Sendable {
    case invalidLiteral(String)

    var errorDescription: String? {
        switch self {
        case let .invalidLiteral(value):
            "Invalid IP address literal: \(value)."
        }
    }
}

struct IPAddress: Codable, Hashable, Sendable {
    enum Family: Hashable, Sendable {
        case ipv4
        case ipv6
    }

    let stringValue: String
    let family: Family
    let bytes: [UInt8]

    init(_ literal: String) throws {
        guard
            !literal.utf8.contains(0),
            !literal.contains("%"),
            !literal.contains("["),
            !literal.contains("]")
        else {
            throw IPAddressError.invalidLiteral(literal)
        }

        if let parsed = Self.parseIPv4(literal) {
            stringValue = parsed.stringValue
            family = .ipv4
            bytes = parsed.bytes
        } else if let parsed = Self.parseIPv6(literal) {
            stringValue = parsed.stringValue
            family = .ipv6
            bytes = parsed.bytes
        } else {
            throw IPAddressError.invalidLiteral(literal)
        }
    }

    init(family: Family, bytes: [UInt8]) {
        let expectedCount = family == .ipv4 ? 4 : 16
        precondition(bytes.count == expectedCount, "Invalid byte count for IP address family")

        self.family = family
        self.bytes = bytes
        let systemFamily = family == .ipv4 ? AF_INET : AF_INET6
        let bufferSize = family == .ipv4 ? Int(INET_ADDRSTRLEN) : Int(INET6_ADDRSTRLEN)
        guard let stringValue = Self.format(bytes: bytes, family: systemFamily, bufferSize: bufferSize) else {
            preconditionFailure("Valid fixed-length IP address bytes must be formattable")
        }
        self.stringValue = stringValue
    }

    var isIPv6: Bool {
        family == .ipv6
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }

    private static func parseIPv4(_ literal: String) -> (stringValue: String, bytes: [UInt8])? {
        var address = in_addr()
        let parsed = literal.withCString { inet_pton(AF_INET, $0, &address) }
        guard parsed == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard let stringValue = format(bytes: bytes, family: AF_INET, bufferSize: Int(INET_ADDRSTRLEN)) else {
            return nil
        }
        return (stringValue, bytes)
    }

    private static func parseIPv6(_ literal: String) -> (stringValue: String, bytes: [UInt8])? {
        var address = in6_addr()
        let parsed = literal.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard let stringValue = format(bytes: bytes, family: AF_INET6, bufferSize: Int(INET6_ADDRSTRLEN)) else {
            return nil
        }
        return (stringValue, bytes)
    }

    private static func format(
        bytes: [UInt8],
        family: Int32,
        bufferSize: Int
    ) -> String? {
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let result = bytes.withUnsafeBytes { addressBytes in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                inet_ntop(
                    family,
                    addressBytes.baseAddress,
                    bufferPointer.baseAddress,
                    socklen_t(bufferPointer.count)
                )
            }
        }
        guard result != nil else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
