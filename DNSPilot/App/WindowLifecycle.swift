import AppKit
import SwiftUI

enum ProductWindowDestination: Equatable, Sendable {
    case setup
    case main
}

struct ProductWindowRequest: Equatable, Identifiable, Sendable {
    let id = UUID()
    let destination: ProductWindowDestination
}

enum ProductWindowPolicy {
    static let onboardingCompletedKey = "onboarding.completed"
    static let introductionCompletedKey = "onboarding.introductionCompleted"
    static let locationStepCompletedKey = "onboarding.locationStepCompleted"
    static let setupProfileIDKey = "onboarding.setupProfileID"
    static let migrationEvaluatedKey = "onboarding.migrationEvaluated"
    static let navigationSectionKey = "window.navigationSection"
    static let settingsSectionKey = "settings.selectedSection"
    static let debugLoggingModeKey = "diagnostics.debugLoggingMode"

    static func primaryDestination(onboardingCompleted: Bool) -> ProductWindowDestination {
        onboardingCompleted ? .main : .setup
    }
}

struct WindowFrameAutosaveView: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        AutosaveView(name: name)
    }

    func updateNSView(_ nsView: NSView, context: Context) { }

    private final class AutosaveView: NSView {
        let autosaveName: String

        init(name: String) {
            autosaveName = name
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.setFrameAutosaveName(autosaveName)
        }
    }
}

enum LoginItemLaunchDetector {
    static func currentProcessWasLaunchedAsLoginItem() -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return isLoginItem(
            isOpenApplicationEvent: event?.eventID == kAEOpenApplication,
            launchReason: event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        )
    }

    static func isLoginItem(
        isOpenApplicationEvent: Bool,
        launchReason: UInt32?
    ) -> Bool {
        isOpenApplicationEvent && launchReason == keyAELaunchedAsLogInItem
    }
}
