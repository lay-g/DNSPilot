import Foundation

enum DNSQueryType: String, CaseIterable, Equatable, Identifiable, Sendable {
    case a = "A"
    case aaaa = "AAAA"
    case cname = "CNAME"
    case mx = "MX"
    case txt = "TXT"
    case ns = "NS"
    case soa = "SOA"
    case srv = "SRV"
    case caa = "CAA"
    case ptr = "PTR"

    var id: Self { self }

    var wireValue: UInt16 {
        switch self {
        case .a: 1
        case .ns: 2
        case .cname: 5
        case .soa: 6
        case .ptr: 12
        case .mx: 15
        case .txt: 16
        case .aaaa: 28
        case .srv: 33
        case .caa: 257
        }
    }
}

enum DNSQueryRequestError: LocalizedError, Equatable, Sendable {
    case emptyDomain
    case invalidDomain(String)

    var errorDescription: String? {
        switch self {
        case .emptyDomain:
            "Enter a domain name."
        case let .invalidDomain(value):
            "Enter a valid ASCII DNS name: \(value)."
        }
    }
}

struct DNSQueryRequest: Equatable, Sendable {
    let domain: String
    let type: DNSQueryType
    let upstream: DNSUpstream

    init(domain: String, type: DNSQueryType, upstream: DNSUpstream) throws {
        var normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        guard !normalized.isEmpty else { throw DNSQueryRequestError.emptyDomain }

        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        let isValid = labels.allSatisfy { label in
            let bytes = label.utf8
            guard !bytes.isEmpty, bytes.count <= 63 else { return false }
            return bytes.allSatisfy { byte in
                byte >= 0x61 && byte <= 0x7a
                    || byte >= 0x41 && byte <= 0x5a
                    || byte >= 0x30 && byte <= 0x39
                    || byte == 0x2d
                    || byte == 0x5f
            }
        }
        let wireNameLength = labels.reduce(1) { $0 + 1 + $1.utf8.count }
        guard isValid, wireNameLength <= 255 else {
            throw DNSQueryRequestError.invalidDomain(domain)
        }

        self.domain = normalized
        self.type = type
        self.upstream = upstream
    }
}

struct DNSQueryResult: Equatable, Sendable {
    let domain: String
    let type: DNSQueryType
    let status: String
    let answer: String
    let server: String
    let elapsedMilliseconds: Int
    let bytesSent: Int
    let bytesReceived: Int
}

enum DNSQueryServiceError: Error, Equatable, Sendable {
    case unavailable
    case initializationFailed(String)
    case exchangeFailed(String)
    case timedOut

    var userMessage: String {
        switch self {
        case .unavailable:
            "DNS testing is unavailable."
        case .initializationFailed:
            "DNSPilot could not initialize the selected DNS server."
        case .exchangeFailed:
            "The selected DNS server could not complete the query."
        case .timedOut:
            "The DNS server did not complete the query within 5 seconds."
        }
    }

    var diagnosticDescription: String {
        switch self {
        case .unavailable:
            "DNS query service is unavailable"
        case let .initializationFailed(description), let .exchangeFailed(description):
            description
        case .timedOut:
            "DNS query did not produce a request event before the host deadline"
        }
    }
}

enum DNSWireQueryEncoder {
    static func encode(_ request: DNSQueryRequest, identifier: UInt16) -> Data {
        var bytes: [UInt8] = [
            UInt8(identifier >> 8), UInt8(identifier & 0xff),
            0x01, 0x00,
            0x00, 0x01,
            0x00, 0x00,
            0x00, 0x00,
            0x00, 0x00,
        ]
        for label in request.domain.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes.append(0)
        bytes.append(UInt8(request.type.wireValue >> 8))
        bytes.append(UInt8(request.type.wireValue & 0xff))
        bytes.append(contentsOf: [0x00, 0x01])
        return Data(bytes)
    }
}
