import Foundation
import Testing
@testable import DNSPilot

struct ConfigurationStoreTests {
    @Test func missingStoreProvidesCanonicalEmptyConfiguration() throws {
        try withTemporaryStore { store, _ in
            let result = try store.load()

            guard case let .missing(initial) = result else {
                Issue.record("Expected a missing configuration, got \(result)")
                return
            }
            #expect(initial.value == (try AppConfiguration()))
            #expect(initial.data == (try store.encode(initial.value)).data)
            #expect(initial.fingerprint == AppConfigurationFingerprint(data: initial.data))
        }
    }

    @Test func roundTripUsesCanonicalBytesAndOwnerOnlyPermissions() throws {
        try withTemporaryStore { store, directoryURL in
            let configuration = try populatedConfiguration()
            let persisted = try store.encode(configuration)

            try store.commit(persisted, replacing: nil)

            #expect(try store.load() == .loaded(persisted))
            let attributes = try FileManager.default.attributesOfItem(
                atPath: store.configurationURL.path
            )
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.uint16Value == 0o600)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
                    .sorted()
                    == [".configuration.lock", ConfigurationStore.configurationFileName]
            )
        }
    }

    @Test func canonicalFingerprintIgnoresSourceFormatting() throws {
        let configuration = try populatedConfiguration()
        let compact = try PersistedAppConfiguration(value: configuration)
        let object = try JSONSerialization.jsonObject(with: compact.data)
        let pretty = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )

        let normalized = try PersistedAppConfiguration(data: pretty)

        #expect(normalized.data == compact.data)
        #expect(normalized.fingerprint == compact.fingerprint)
    }

    @Test func newerSchemaIsClassifiedBeforeFullDecode() throws {
        try withTemporaryStore { store, directoryURL in
            let source = Data(#"{"schemaVersion":3,"operatingMode":{"kind":"future"}}"#.utf8)
            try source.write(to: store.configurationURL)

            #expect(try store.load() == .newerSchema(version: 3))
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
                    .sorted()
                    == [".configuration.lock", ConfigurationStore.configurationFileName]
            )
        }
    }

    @Test func schemaOneLoadsCanonicallyAndCanBeReplaced() throws {
        try withTemporaryStore { store, _ in
            let current = try store.encode(populatedConfiguration())
            var payload = try #require(
                JSONSerialization.jsonObject(with: current.data) as? [String: Any]
            )
            payload["schemaVersion"] = 1
            try JSONSerialization.data(withJSONObject: payload).write(to: store.configurationURL)

            guard case let .loaded(migrated) = try store.load() else {
                Issue.record("Expected migrated configuration")
                return
            }
            #expect(migrated.value.schemaVersion == AppConfiguration.currentSchemaVersion)
            #expect(migrated == current)

            let replacement = try store.encode(AppConfiguration())
            try store.commit(replacement, replacing: migrated.fingerprint)
            #expect(try store.load() == .loaded(replacement))
        }
    }

    @Test func corruptAndInvalidConfigurationsArePreservedExactly() throws {
        for source in try corruptSources() {
            try withTemporaryStore { store, _ in
                try source.write(to: store.configurationURL)

                let result = try store.load()

                guard case let .corrupt(artifactURL) = result else {
                    Issue.record("Expected corrupt configuration, got \(result)")
                    return
                }
                #expect(try Data(contentsOf: artifactURL) == source)
                #expect(try Data(contentsOf: store.configurationURL) == source)
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: artifactURL.path
                )
                let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
                #expect(permissions.uint16Value == 0o600)
            }
        }
    }

    @Test func repeatedCorruptLoadReusesTheSameRecoveryArtifact() throws {
        try withTemporaryStore { store, directoryURL in
            let source = Data("not-json".utf8)
            try source.write(to: store.configurationURL)

            let first = try store.load()
            let second = try store.load()

            #expect(first == second)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
                    .filter { $0.hasPrefix("configuration.corrupt.") }
                    .count == 1
            )
        }
    }

    @Test func newConfigurationReplacesOnlyTheMatchingPreservedCorruptSource() throws {
        try withTemporaryStore { store, _ in
            let source = Data("not-json".utf8)
            try source.write(to: store.configurationURL)
            guard case let .corrupt(artifactURL) = try store.load() else {
                Issue.record("Expected corrupt configuration")
                return
            }

            try store.replaceCorruptConfiguration(
                with: AppConfiguration(),
                matching: artifactURL
            )

            let expected = try store.encode(AppConfiguration())
            #expect(try store.load() == .loaded(expected))
            #expect(try Data(contentsOf: artifactURL) == source)
        }
    }

    @Test func newConfigurationRejectsAMismatchedRecoveryArtifact() throws {
        try withTemporaryStore { store, directoryURL in
            try Data("not-json".utf8).write(to: store.configurationURL)
            _ = try store.load()
            let unrelatedArtifact = directoryURL.appendingPathComponent("unrelated.json")
            try Data("other".utf8).write(to: unrelatedArtifact)

            #expect(throws: ConfigurationStoreError.recoveryArtifactConflict) {
                try store.replaceCorruptConfiguration(
                    with: AppConfiguration(),
                    matching: unrelatedArtifact
                )
            }
            #expect(try Data(contentsOf: store.configurationURL) == Data("not-json".utf8))
        }
    }

    @Test func compareAndSwapConflictPreservesCurrentConfiguration() throws {
        try withTemporaryStore { store, directoryURL in
            let first = try store.encode(populatedConfiguration())
            try store.commit(first, replacing: nil)
            let replacement = try store.encode(AppConfiguration())

            #expect(throws: ConfigurationStoreError.compareAndSwapConflict) {
                try store.commit(replacement, replacing: nil)
            }
            #expect(throws: ConfigurationStoreError.compareAndSwapConflict) {
                try store.commit(
                    replacement,
                    replacing: AppConfigurationFingerprint(data: Data("stale".utf8))
                )
            }
            #expect(try Data(contentsOf: store.configurationURL) == first.data)
            #expect(try temporaryFiles(in: directoryURL).isEmpty)
        }
    }

    @Test func writeSyncAndRenameFailuresNeverExposePartialConfiguration() throws {
        for failure in ConfigurationFailurePoint.allCases {
            try withTemporaryStore { baselineStore, directoryURL in
                let first = try baselineStore.encode(populatedConfiguration())
                try baselineStore.commit(first, replacing: nil)
                let replacement = try baselineStore.encode(AppConfiguration())
                let failingStore = ConfigurationStore(
                    directoryURL: directoryURL,
                    fileSystem: FailingConfigurationFileSystem(failure: failure)
                )

                #expect(throws: (any Error).self) {
                    try failingStore.commit(replacement, replacing: first.fingerprint)
                }

                let officialData = try Data(contentsOf: baselineStore.configurationURL)
                if failure == .directorySync {
                    #expect(officialData == first.data || officialData == replacement.data)
                } else {
                    #expect(officialData == first.data)
                }
                #expect(try temporaryFiles(in: directoryURL).isEmpty)
                let loaded = try baselineStore.load()
                #expect(loaded == .loaded(try PersistedAppConfiguration(data: officialData)))
            }
        }
    }

    @Test func concurrentCompareAndSwapAllowsExactlyOneCommit() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DNSPilot-ConfigurationStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ConfigurationStore(directoryURL: directoryURL)
        let original = try store.encode(populatedConfiguration())
        try store.commit(original, replacing: nil)
        let firstDraft = try store.encode(AppConfiguration())
        let secondDraft = try store.encode(
            AppConfiguration(profiles: [DNSProfile(name: "Second", upstream: .fixedCloudflare)])
        )

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for draft in [firstDraft, secondDraft] {
                group.addTask {
                    do {
                        try store.commit(draft, replacing: original.fingerprint)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await succeeded in group where succeeded {
                count += 1
            }
            return count
        }

        #expect(successes == 1)
    }

    private func withTemporaryStore(
        _ body: (ConfigurationStore, URL) throws -> Void
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DNSPilot-ConfigurationStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ConfigurationStore(directoryURL: directoryURL)
        try body(store, directoryURL)
    }

    private func populatedConfiguration() throws -> AppConfiguration {
        let profile = try DNSProfile(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            name: "Primary",
            upstream: .fixedCloudflare
        )
        let rule = try DNSRule(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            name: "Wi-Fi",
            conditions: RuleConditions(interfaceTypes: [.wifi]),
            profileID: profile.id
        )
        return try AppConfiguration(
            profiles: [profile],
            rules: [rule],
            defaultProfileID: profile.id,
            operatingMode: .manual(profileID: profile.id)
        )
    }

    private func corruptSources() throws -> [Data] {
        let malformed = Data("not-json".utf8)
        let valid = try PersistedAppConfiguration(value: populatedConfiguration()).data
        var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["defaultProfileID"] = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        let invalidReference = try JSONSerialization.data(withJSONObject: object)
        return [malformed, invalidReference]
    }

    private func temporaryFiles(in directoryURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            .filter { $0.hasPrefix(".configuration.") && $0.hasSuffix(".tmp") }
    }
}

private enum ConfigurationFailurePoint: CaseIterable, Sendable {
    case write
    case partialWrite
    case fileSync
    case rename
    case directorySync
}

private struct FailingConfigurationFileSystem: ConfigurationFileSystem {
    let failure: ConfigurationFailurePoint
    private let base = LocalConfigurationFileSystem()

    func createDirectory(at url: URL) throws {
        try base.createDirectory(at: url)
    }

    func itemExists(at url: URL) -> Bool {
        base.itemExists(at: url)
    }

    func readFile(at url: URL) throws -> Data {
        try base.readFile(at: url)
    }

    func createFile(at url: URL, data: Data, permissions: UInt16) throws {
        if failure == .write { throw ConfigurationTestError.injected }
        if failure == .partialWrite {
            try base.createFile(
                at: url,
                data: data.prefix(max(1, data.count / 2)),
                permissions: permissions
            )
            throw ConfigurationTestError.injected
        }
        try base.createFile(at: url, data: data, permissions: permissions)
    }

    func synchronizeFile(at url: URL) throws {
        if failure == .fileSync { throw ConfigurationTestError.injected }
        try base.synchronizeFile(at: url)
    }

    func replaceAtomically(itemAt destinationURL: URL, withItemAt sourceURL: URL) throws {
        if failure == .rename { throw ConfigurationTestError.injected }
        try base.replaceAtomically(itemAt: destinationURL, withItemAt: sourceURL)
    }

    func synchronizeDirectory(at url: URL) throws {
        if failure == .directorySync { throw ConfigurationTestError.injected }
        try base.synchronizeDirectory(at: url)
    }

    func removeFileIfPresent(at url: URL) throws {
        try base.removeFileIfPresent(at: url)
    }
}

private enum ConfigurationTestError: Error {
    case injected
}
