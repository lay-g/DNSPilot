import AGDnsProxy
import Foundation
import OSLog

enum DNSLogBridge {
    struct Configuration: Equatable, Sendable {
        let levelRawValue: Int
        let messagesArePublic: Bool
    }

    static var libraryVersion: String {
        AGDnsProxy.libraryVersion()
    }

    static func configuration(for mode: ProxyLoggingMode) -> Configuration {
        switch mode {
        case .default:
            Configuration(levelRawValue: 2, messagesArePublic: false)
        case .debug:
            Configuration(levelRawValue: 4, messagesArePublic: true)
        }
    }

    static func configure(process: String, mode: ProxyLoggingMode = .default) {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "DNSPilot",
            category: "DnsLibs.\(process)"
        )
        let configuration = configuration(for: mode)

        AGDnsLogger.setLevel(AGDnsLogLevel(rawValue: configuration.levelRawValue)!)
        AGDnsLogger.setCallback { level, message, length in
            guard length > 0 else { return }

            let bytes = UnsafeRawBufferPointer(start: message, count: Int(length))
            let text = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .newlines)

            log(
                text,
                level: level.rawValue,
                messagesArePublic: configuration.messagesArePublic,
                logger: logger
            )
        }

        logger.info("Loaded AGDnsProxy \(libraryVersion, privacy: .public)")
    }

    private static func log(
        _ message: String,
        level: Int,
        messagesArePublic: Bool,
        logger: Logger
    ) {
        if messagesArePublic {
            logPublic(message, level: level, logger: logger)
        } else {
            logPrivate(message, level: level, logger: logger)
        }
    }

    private static func logPublic(_ message: String, level: Int, logger: Logger) {
        switch level {
        case 0:
            logger.error("DnsLibs[\(level, privacy: .public)]: \(message, privacy: .public)")
        case 1:
            logger.warning("DnsLibs[\(level, privacy: .public)]: \(message, privacy: .public)")
        case 2:
            logger.info("DnsLibs[\(level, privacy: .public)]: \(message, privacy: .public)")
        default:
            logger.debug("DnsLibs[\(level, privacy: .public)]: \(message, privacy: .public)")
        }
    }

    private static func logPrivate(_ message: String, level: Int, logger: Logger) {
        switch level {
        case 0:
            logger.error("DnsLibs[\(level, privacy: .public)]: \(message, privacy: .private(mask: .hash))")
        case 1:
            logger.warning("DnsLibs[\(level, privacy: .public)]: \(message, privacy: .private(mask: .hash))")
        case 2:
            logger.info("DnsLibs[\(level, privacy: .public)]: \(message, privacy: .private(mask: .hash))")
        default:
            logger.debug("DnsLibs[\(level, privacy: .public)]: \(message, privacy: .private(mask: .hash))")
        }
    }
}
