import SwiftUI

enum ProfileTestStatus: Equatable {
    case testing
    case succeeded
    case failed(String)

    init?(_ outcome: ProductActionOutcome) {
        switch outcome {
        case .completed:
            self = .succeeded
        case let .failed(failure) where failure.reason != .cancelled:
            self = .failed(failure.profileTestStatusMessage)
        case .failed:
            return nil
        }
    }
}

private extension ProductActionFailure {
    var profileTestStatusMessage: String {
        switch reason {
        case .notReady:
            "DNSPilot is still starting."
        case .invalidConfiguration:
            "Check the Profile settings."
        case .recoveryRequired:
            "Reconcile the DNS Proxy state before testing."
        case .operationInProgress:
            "Another DNSPilot action is still running."
        case .upstreamTestUnclassified:
            "DnsLibs could not complete the test. Check the Profile settings and network."
        case .cancelled:
            "The test was cancelled."
        case .networkUnavailable, .conflict, .profileNotFound, .profileAlreadyExists,
             .invalidDeletionPlan, .persistenceFailed, .runtimePreparationFailed,
             .desiredConfigurationPersistenceFailed, .recoveryJournalWriteFailed,
             .runtimeRejected, .systemExtensionNotActive, .systemDNSRestoreUnconfirmed,
             .reconnectUnresolved, .systemExtensionOperationUnavailable, .restartRequired,
             .compatibilityUnavailable, .targetChanged, .managerStateUnavailable,
             .targetWriteFailed, .readinessTimedOut, .providerFailed, .unknown:
            message
        }
    }
}

struct ProfileTestStatusView: View {
    let status: ProfileTestStatus

    var body: some View {
        switch status {
        case .testing:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                Text("Testing...")
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        case .succeeded:
            Label("OK", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
