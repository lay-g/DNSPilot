import Foundation
import Testing
import AGDnsProxy
@testable import DNSPilot

struct DNSQueryTests {
    @Test func requestNormalizesOneTrailingDot() throws {
        let request = try DNSQueryRequest(
            domain: "example.com.",
            type: .a,
            upstream: .fixedCloudflare
        )

        #expect(request.domain == "example.com")
    }

    @Test(arguments: ["", ".", "example..com", "example com", "éxample.com"])
    func requestRejectsInvalidDomain(_ domain: String) {
        #expect(throws: DNSQueryRequestError.self) {
            try DNSQueryRequest(
                domain: domain,
                type: .a,
                upstream: .fixedCloudflare
            )
        }
    }

    @Test func encoderBuildsStandardSingleQuestion() throws {
        let request = try DNSQueryRequest(
            domain: "_sip._tcp.example.com",
            type: .srv,
            upstream: .fixedCloudflare
        )

        let data = DNSWireQueryEncoder.encode(request, identifier: 0x4711)

        #expect([UInt8](data) == [
            0x47, 0x11, 0x01, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x04, 0x5f, 0x73, 0x69, 0x70,
            0x04, 0x5f, 0x74, 0x63, 0x70,
            0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,
            0x03, 0x63, 0x6f, 0x6d,
            0x00, 0x00, 0x21, 0x00, 0x01,
        ])
    }

    @Test func queryTypesUseExpectedWireValues() {
        #expect(Dictionary(uniqueKeysWithValues: DNSQueryType.allCases.map {
            ($0.rawValue, $0.wireValue)
        }) == [
            "A": 1, "AAAA": 28, "CNAME": 5, "MX": 15, "TXT": 16,
            "NS": 2, "SOA": 6, "SRV": 33, "CAA": 257, "PTR": 12,
        ])
    }

    @Test func requestEventIsCopiedIntoAnImmutableResult() throws {
        let request = try DNSQueryRequest(
            domain: "example.com",
            type: .txt,
            upstream: .fixedCloudflare
        )
        let event = AGDnsRequestProcessedEvent()
        event.status = "NOERROR"
        event.answer = "example.com. 300 IN TXT \"value\""
        event.error = ""
        event.elapsed = 18
        event.bytesSent = 29
        event.bytesReceived = 64

        let result = try DNSQueryTester.snapshot(event, for: request)
        event.answer = "changed"

        #expect(result.status == "NOERROR")
        #expect(result.answer == "example.com. 300 IN TXT \"value\"")
        #expect(result.server == "DNS over HTTPS · cloudflare-dns.com")
        #expect(result.elapsedMilliseconds == 18)
        #expect(result.bytesSent == 29)
        #expect(result.bytesReceived == 64)
    }

    @Test func requestEventErrorIsNotPresentedAsAnAnswer() throws {
        let request = try DNSQueryRequest(
            domain: "example.com",
            type: .a,
            upstream: .fixedCloudflare
        )
        let event = AGDnsRequestProcessedEvent()
        event.error = "connection failed"

        #expect(throws: DNSQueryServiceError.exchangeFailed("connection failed")) {
            try DNSQueryTester.snapshot(event, for: request)
        }
    }
}
