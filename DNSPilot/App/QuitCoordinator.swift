import Foundation

struct QuitCoordinator: Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case armed(deadline: Duration, keyReleased: Bool)
        case awaitingDiscardConfirmation
        case quitting
    }

    enum Action: Equatable, Sendable {
        case showConfirmationHUD
        case dismissConfirmationHUD
        case confirmDiscard
        case beginSafeQuit
    }

    private(set) var phase: Phase = .idle
    let confirmationWindow: Duration

    init(confirmationWindow: Duration = .seconds(2)) {
        self.confirmationWindow = confirmationWindow
    }

    mutating func commandQKeyDown(
        isRepeat: Bool,
        hasUnsavedDrafts: Bool,
        at now: Duration
    ) -> [Action] {
        var actions = expireIfNeeded(at: now)
        guard !isRepeat else { return actions }

        switch phase {
        case .idle:
            phase = .armed(deadline: now + confirmationWindow, keyReleased: false)
            actions.append(.showConfirmationHUD)
        case let .armed(deadline, keyReleased):
            guard keyReleased, now < deadline else { return actions }
            actions.append(.dismissConfirmationHUD)
            actions.append(contentsOf: requestQuit(hasUnsavedDrafts: hasUnsavedDrafts))
        case .awaitingDiscardConfirmation, .quitting:
            break
        }
        return actions
    }

    mutating func commandQKeyUp(at now: Duration) -> [Action] {
        let actions = expireIfNeeded(at: now)
        guard case let .armed(deadline, _) = phase else { return actions }
        phase = .armed(deadline: deadline, keyReleased: true)
        return actions
    }

    mutating func escape() -> [Action] {
        disarm()
    }

    mutating func lostKeyboardContext() -> [Action] {
        disarm()
    }

    mutating func timeout(at now: Duration) -> [Action] {
        expireIfNeeded(at: now)
    }

    mutating func menuQuit(hasUnsavedDrafts: Bool) -> [Action] {
        switch phase {
        case .quitting, .awaitingDiscardConfirmation:
            return []
        case .armed:
            var actions: [Action] = [.dismissConfirmationHUD]
            actions.append(contentsOf: requestQuit(hasUnsavedDrafts: hasUnsavedDrafts))
            return actions
        case .idle:
            return requestQuit(hasUnsavedDrafts: hasUnsavedDrafts)
        }
    }

    mutating func confirmDiscardAndQuit() -> [Action] {
        guard phase == .awaitingDiscardConfirmation else { return [] }
        phase = .quitting
        return [.beginSafeQuit]
    }

    mutating func cancelDiscard() -> [Action] {
        guard phase == .awaitingDiscardConfirmation else { return [] }
        phase = .idle
        return []
    }

    mutating func reset() {
        phase = .idle
    }

    private mutating func requestQuit(hasUnsavedDrafts: Bool) -> [Action] {
        if hasUnsavedDrafts {
            phase = .awaitingDiscardConfirmation
            return [.confirmDiscard]
        }
        phase = .quitting
        return [.beginSafeQuit]
    }

    private mutating func expireIfNeeded(at now: Duration) -> [Action] {
        guard case let .armed(deadline, _) = phase, now >= deadline else { return [] }
        phase = .idle
        return [.dismissConfirmationHUD]
    }

    private mutating func disarm() -> [Action] {
        guard case .armed = phase else { return [] }
        phase = .idle
        return [.dismissConfirmationHUD]
    }
}
