import AppKit
import Synchronization

final class DNSRestoreOperation: Sendable {
    private enum State {
        case running([UUID: CheckedContinuation<DNSProxyControllerState?, Never>])
        case finished(DNSProxyControllerState)
    }

    private let state = Mutex(State.running([:]))

    private var isRunning: Bool {
        state.withLock { state in
            if case .running = state { return true }
            return false
        }
    }

    func reusableForNewTerminationAttempt() -> DNSRestoreOperation? {
        isRunning ? self : nil
    }

    static func start(
        _ operation: @escaping @Sendable () async -> DNSProxyControllerState
    ) -> DNSRestoreOperation {
        let restore = DNSRestoreOperation()
        Task {
            await restore.finish(with: operation())
        }
        return restore
    }

    func value(timeout: Duration) async -> DNSProxyControllerState? {
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let result = state.withLock { state -> DNSProxyControllerState? in
                switch state {
                case var .running(waiters):
                    waiters[waiterID] = continuation
                    state = .running(waiters)
                    return nil
                case let .finished(result):
                    return result
                }
            }
            if let result {
                continuation.resume(returning: result)
                return
            }

            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.timeout(waiterID)
            }
        }
    }

    private func finish(with result: DNSProxyControllerState) {
        let waiters = state.withLock { state -> [CheckedContinuation<
            DNSProxyControllerState?,
            Never
        >] in
            guard case let .running(waiters) = state else { return [] }
            state = .finished(result)
            return Array(waiters.values)
        }
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func timeout(_ waiterID: UUID) {
        let waiter = state.withLock { state -> CheckedContinuation<
            DNSProxyControllerState?,
            Never
        >? in
            guard case var .running(waiters) = state else { return nil }
            let waiter = waiters.removeValue(forKey: waiterID)
            state = .running(waiters)
            return waiter
        }
        waiter?.resume(returning: nil)
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private static let terminationDecisionTimeout = Duration.seconds(5)

    private var terminationTask: Task<Void, Never>?
    private var dnsRestoreOperation: DNSRestoreOperation?
    private var terminationPending = false
    private weak var appState: AppState?
    private var quitCoordinator = QuitCoordinator()
    private let clock = ContinuousClock()
    private lazy var clockOrigin = clock.now
    private var quitTimeoutTask: Task<Void, Never>?
    private var keyEventMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var quitHUD: NSPanel?
    private var terminationAlert: NSAlert?
    private var terminationAlertAction: ((Int) -> Void)?
    private var pendingPrimaryWindowRequest = false
    private var suppressAutomaticWindows = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installQuitEventHandling()
        if !LoginItemLaunchDetector.currentProcessWasLaunchedAsLoginItem() {
            requestPrimaryWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyEventMonitor { NSEvent.removeMonitor(keyEventMonitor) }
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        dismissTerminationAlert()
    }

    func configure(appState: AppState, suppressAutomaticWindows: Bool = false) {
        self.appState = appState
        self.suppressAutomaticWindows = suppressAutomaticWindows
        appState.setQuitHandler { [weak self] in
            self?.requestMenuQuit()
        }
        guard pendingPrimaryWindowRequest else { return }
        pendingPrimaryWindowRequest = false
        if !suppressAutomaticWindows { appState.requestPrimaryWindow() }
    }

    private func requestMenuQuit() {
        applyQuitActions(quitCoordinator.menuQuit(
            hasUnsavedDrafts: appState?.hasUnsavedDrafts == true
        ))
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if appState?.presentedProductWindow != nil { return true }
        requestPrimaryWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DNSPILOT_DEBUG_LOCAL
        if EnabledManagerGateAProbe.isRequested() {
            return .terminateCancel
        }
        #endif
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        if appState?.hasUnsavedDrafts == true {
            presentUnsavedDraftConfirmation(for: sender)
            return .terminateLater
        }
        beginDNSRestore(for: sender)
        return .terminateLater
    }

    private func installQuitEventHandling() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyQuitActions(self.quitCoordinator.lostKeyboardContext())
            }
        }
    }

    private func requestPrimaryWindow() {
        guard !suppressAutomaticWindows else { return }
        guard let appState else {
            pendingPrimaryWindowRequest = true
            return
        }
        appState.requestPrimaryWindow()
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 {
            applyQuitActions(quitCoordinator.escape())
            return event
        }
        guard event.charactersIgnoringModifiers?.lowercased() == "q",
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else {
            return event
        }
        let now = clockOrigin.duration(to: clock.now)
        switch event.type {
        case .keyDown:
            let actions = quitCoordinator.commandQKeyDown(
                isRepeat: event.isARepeat,
                hasUnsavedDrafts: appState?.hasUnsavedDrafts == true,
                at: now
            )
            applyQuitActions(actions)
            return nil
        case .keyUp:
            applyQuitActions(quitCoordinator.commandQKeyUp(at: now))
            return nil
        default:
            return event
        }
    }

    private func applyQuitActions(_ actions: [QuitCoordinator.Action]) {
        for action in actions {
            switch action {
            case .showConfirmationHUD:
                showQuitHUD()
                scheduleQuitTimeout()
            case .dismissConfirmationHUD:
                dismissQuitHUD()
            case .confirmDiscard:
                presentCoordinatedDraftConfirmation()
            case .beginSafeQuit:
                NSApp.terminate(nil)
            }
        }
    }

    private func presentCoordinatedDraftConfirmation() {
        guard appState?.hasUnsavedDrafts == true else {
            NSApp.terminate(nil)
            return
        }
        presentTerminationAlert(
            style: .warning,
            message: "Discard unsaved changes and quit?",
            information: "Unsaved Profile or Rule changes will be discarded before System DNS is restored.",
            buttons: ["Discard Changes and Quit", "Cancel Quit"]
        ) { [weak self] buttonIndex in
            guard let self else { return }
            if buttonIndex == 0 {
                appState?.discardDraft()
                _ = quitCoordinator.confirmDiscardAndQuit()
                NSApp.terminate(nil)
            } else {
                _ = quitCoordinator.cancelDiscard()
                dismissQuitHUD()
            }
        }
    }

    private func scheduleQuitTimeout() {
        quitTimeoutTask?.cancel()
        quitTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let now = clockOrigin.duration(to: clock.now)
            applyQuitActions(quitCoordinator.timeout(at: now))
        }
    }

    private func showQuitHUD() {
        let message = "Press Command-Q again to quit DNSPilot"
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.frame = NSRect(x: 18, y: 12, width: 300, height: 24)

        let panel = quitHUD ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 336, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView?.addSubview(label)
        panel.isOpaque = false
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - panel.frame.width / 2,
                y: screen.visibleFrame.maxY - panel.frame.height - 28
            ))
        }
        quitHUD = panel
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: NSApp!,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Press Command-Q again within two seconds to quit DNSPilot",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func dismissQuitHUD() {
        quitTimeoutTask?.cancel()
        quitTimeoutTask = nil
        quitHUD?.orderOut(nil)
    }

    private func presentUnsavedDraftConfirmation(for application: NSApplication) {
        presentTerminationAlert(
            style: .warning,
            message: "Discard unsaved changes and quit?",
            information: "Unsaved Profile or Rule changes will be discarded before System DNS is restored.",
            buttons: ["Discard Changes and Quit", "Cancel Quit"]
        ) { [weak self, weak application] buttonIndex in
            guard let self, let application else { return }
            if buttonIndex == 0 {
                appState?.discardDraft()
                beginDNSRestore(for: application)
            } else {
                finishTermination(for: application, shouldTerminate: false)
            }
        }
    }

    private func beginDNSRestore(for application: NSApplication) {
        let existingRestore = dnsRestoreOperation?.reusableForNewTerminationAttempt()
        if existingRestore == nil {
            dnsRestoreOperation = nil
        }
        let restore = existingRestore ?? DNSRestoreOperation.start { @MainActor [weak self] in
            guard let appState = self?.appState else {
                return .recoveryRequired("DNSPilot runtime is unavailable during termination.")
            }
            return await appState.restoreSystemDNSForTermination()
        }
        dnsRestoreOperation = restore

        terminationTask = Task { [weak self, weak application] in
            guard let self, let application, terminationPending else { return }
            let state = await restore.value(timeout: Self.terminationDecisionTimeout)
            guard terminationPending else { return }
            terminationTask = nil

            guard let state else {
                presentRestoreFailure(
                    .recoveryRequired(
                        "System DNS restoration did not complete before the quit safety deadline."
                    ),
                    for: application
                )
                return
            }
            if state == .disabled {
                finishTermination(for: application, shouldTerminate: true)
                return
            }

            if existingRestore != nil {
                dnsRestoreOperation = nil
                beginDNSRestore(for: application)
                return
            }

            dnsRestoreOperation = nil
            presentRestoreFailure(state, for: application)
        }
    }

    private func finishTermination(
        for application: NSApplication,
        shouldTerminate: Bool
    ) {
        guard terminationPending else { return }
        terminationPending = false
        terminationTask = nil
        dnsRestoreOperation = nil
        dismissTerminationAlert()
        if !shouldTerminate {
            quitCoordinator.reset()
            dismissQuitHUD()
        }
        application.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    private func presentRestoreFailure(
        _ state: DNSProxyControllerState,
        for application: NSApplication
    ) {
        guard terminationPending else { return }
        presentTerminationAlert(
            style: .critical,
            message: "System DNS could not be restored",
            information: state.description
                + " Retry before quitting. Force Quit may leave the DNS Proxy enabled.",
            buttons: ["Retry", "Quit Anyway", "Cancel Quit"]
        ) { [weak self, weak application] buttonIndex in
            guard let self, let application else { return }
            switch buttonIndex {
            case 0:
                beginDNSRestore(for: application)
            case 1:
                finishTermination(for: application, shouldTerminate: true)
            default:
                terminationTask = Task { [weak self, weak application] in
                    guard let self, let application, terminationPending else { return }
                    await appState?.cancelTerminationRequest()
                    finishTermination(
                        for: application,
                        shouldTerminate: false
                    )
                }
            }
        }
    }

    private func presentTerminationAlert(
        style: NSAlert.Style,
        message: String,
        information: String,
        buttons: [String],
        action: @escaping (Int) -> Void
    ) {
        dismissTerminationAlert()

        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = information
        alert.showsSuppressionButton = false
        for (index, title) in buttons.enumerated() {
            let button = alert.addButton(withTitle: title)
            button.tag = index
            button.target = self
            button.action = #selector(handleTerminationAlertButton(_:))
        }

        terminationAlert = alert
        terminationAlertAction = action
        alert.layout()
        alert.window.level = .modalPanel
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.window.contentView?.layoutSubtreeIfNeeded()
        alert.window.center()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func handleTerminationAlertButton(_ sender: NSButton) {
        let action = terminationAlertAction
        dismissTerminationAlert()
        action?(sender.tag)
    }

    private func dismissTerminationAlert() {
        terminationAlert?.window.orderOut(nil)
        terminationAlert = nil
        terminationAlertAction = nil
    }
}
