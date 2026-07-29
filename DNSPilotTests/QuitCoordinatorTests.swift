import Foundation
import Testing
@testable import DNSPilot

struct QuitCoordinatorTests {
    @Test func firstPressOnlyArmsAndShowsHUD() {
        var coordinator = QuitCoordinator()
        #expect(coordinator.commandQKeyDown(
            isRepeat: false,
            hasUnsavedDrafts: false,
            at: .zero
        ) == [.showConfirmationHUD])
        #expect(coordinator.phase == .armed(deadline: .seconds(2), keyReleased: false))
    }

    @Test func secondIndependentPressWithinWindowBeginsSafeQuitOnce() {
        var coordinator = QuitCoordinator()
        _ = coordinator.commandQKeyDown(isRepeat: false, hasUnsavedDrafts: false, at: .zero)
        #expect(coordinator.commandQKeyUp(at: .milliseconds(100)).isEmpty)
        #expect(coordinator.commandQKeyDown(
            isRepeat: false,
            hasUnsavedDrafts: false,
            at: .milliseconds(500)
        ) == [.dismissConfirmationHUD, .beginSafeQuit])
        #expect(coordinator.commandQKeyDown(
            isRepeat: false,
            hasUnsavedDrafts: false,
            at: .seconds(1)
        ).isEmpty)
        #expect(coordinator.menuQuit(hasUnsavedDrafts: false).isEmpty)
    }

    @Test func keyUpIsRequiredAndAutoRepeatNeverConfirms() {
        var coordinator = QuitCoordinator()
        _ = coordinator.commandQKeyDown(isRepeat: false, hasUnsavedDrafts: false, at: .zero)
        #expect(coordinator.commandQKeyDown(
            isRepeat: true,
            hasUnsavedDrafts: false,
            at: .milliseconds(100)
        ).isEmpty)
        #expect(coordinator.commandQKeyDown(
            isRepeat: false,
            hasUnsavedDrafts: false,
            at: .milliseconds(200)
        ).isEmpty)
        #expect(coordinator.phase == .armed(deadline: .seconds(2), keyReleased: false))
    }

    @Test func exactDeadlineExpiresAndStartsASeparateConfirmation() {
        var coordinator = QuitCoordinator()
        _ = coordinator.commandQKeyDown(isRepeat: false, hasUnsavedDrafts: false, at: .zero)
        _ = coordinator.commandQKeyUp(at: .seconds(1))
        #expect(coordinator.commandQKeyDown(
            isRepeat: false,
            hasUnsavedDrafts: false,
            at: .seconds(2)
        ) == [.dismissConfirmationHUD, .showConfirmationHUD])
        #expect(coordinator.phase == .armed(deadline: .seconds(4), keyReleased: false))
    }

    @Test func timeoutEscapeAndLostContextDisarm() {
        var timeout = QuitCoordinator()
        _ = timeout.commandQKeyDown(isRepeat: false, hasUnsavedDrafts: false, at: .zero)
        #expect(timeout.timeout(at: .seconds(2)) == [.dismissConfirmationHUD])
        #expect(timeout.phase == .idle)

        var escape = QuitCoordinator()
        _ = escape.commandQKeyDown(isRepeat: false, hasUnsavedDrafts: false, at: .zero)
        #expect(escape.escape() == [.dismissConfirmationHUD])

        var lostContext = QuitCoordinator()
        _ = lostContext.commandQKeyDown(isRepeat: false, hasUnsavedDrafts: false, at: .zero)
        #expect(lostContext.lostKeyboardContext() == [.dismissConfirmationHUD])
    }

    @Test func menuQuitBypassesArmingButStillGatesUnsavedDrafts() {
        var coordinator = QuitCoordinator()
        #expect(coordinator.menuQuit(hasUnsavedDrafts: true) == [.confirmDiscard])
        #expect(coordinator.phase == .awaitingDiscardConfirmation)
        #expect(coordinator.confirmDiscardAndQuit() == [.beginSafeQuit])
        #expect(coordinator.confirmDiscardAndQuit().isEmpty)
    }

    @Test func keyboardConfirmationGatesDraftsBeforeSafeQuitBudget() {
        var coordinator = QuitCoordinator()
        _ = coordinator.commandQKeyDown(isRepeat: false, hasUnsavedDrafts: true, at: .zero)
        _ = coordinator.commandQKeyUp(at: .milliseconds(10))
        #expect(coordinator.commandQKeyDown(
            isRepeat: false,
            hasUnsavedDrafts: true,
            at: .milliseconds(20)
        ) == [.dismissConfirmationHUD, .confirmDiscard])
        #expect(coordinator.cancelDiscard().isEmpty)
        #expect(coordinator.phase == .idle)
    }
}
