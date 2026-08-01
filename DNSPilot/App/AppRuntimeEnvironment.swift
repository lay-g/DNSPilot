import Foundation

enum AppRuntimeEnvironment {
    static let unitTestMarker = "DNSPILOT_UNIT_TEST_HOST"

    static var isUnitTestProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment[unitTestMarker] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
    }

    @MainActor
    static func defaultUserDefaults() -> UserDefaults {
        isUnitTestProcess ? unitTestDefaults : .standard
    }

    @MainActor
    private static let unitTestDefaults: UserDefaults = {
        let suiteName = "org.example.DNSPilot.UnitTests.\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }()
}
