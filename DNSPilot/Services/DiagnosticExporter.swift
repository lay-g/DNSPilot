import AppKit
import Foundation

@MainActor
protocol DiagnosticExporting: AnyObject {
    func export(_ contents: String) async throws -> Bool
}

@MainActor
final class DiagnosticExporter: DiagnosticExporting {
    func export(_ contents: String) async throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DNSPilot-Diagnostics.txt"
        panel.canCreateDirectories = true
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return false }
        try Self.write(contents, to: url)
        return true
    }

    static func write(
        _ contents: String,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil, attributes: permissions)
            else { throw CocoaError(.fileWriteUnknown) }
        }
        try fileManager.setAttributes(permissions, ofItemAtPath: url.path)

        let data = Data(contents.utf8)
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }
}
