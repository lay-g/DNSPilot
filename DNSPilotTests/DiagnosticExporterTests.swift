import Foundation
import Testing
@testable import DNSPilot

@MainActor
struct DiagnosticExporterTests {
    @Test func createsOwnerOnlyDiagnosticExport() throws {
        try withTemporaryDirectory { directoryURL in
            let exportURL = directoryURL.appendingPathComponent("diagnostics.txt")

            try DiagnosticExporter.write("sensitive\n", to: exportURL)

            #expect(try String(contentsOf: exportURL, encoding: .utf8) == "sensitive\n")
            #expect(try permissions(of: exportURL) == 0o600)
        }
    }

    @Test func tightensExistingExportBeforeReplacingItsContents() throws {
        try withTemporaryDirectory { directoryURL in
            let exportURL = directoryURL.appendingPathComponent("diagnostics.txt")
            try "old contents that are longer".write(
                to: exportURL,
                atomically: false,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: exportURL.path
            )

            try DiagnosticExporter.write("new\n", to: exportURL)

            #expect(try String(contentsOf: exportURL, encoding: .utf8) == "new\n")
            #expect(try permissions(of: exportURL) == 0o600)
        }
    }

    private func permissions(of url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        return permissions.uint16Value
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try body(directoryURL)
    }
}
