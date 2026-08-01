import AGDnsProxy
import Foundation
import Testing
@testable import DNSPilot

struct ReloadCoordinatorTests {
    @Test func reloadScopeMapsToLockedAGDnsOptions() {
        #expect(DNSProxyReloadScope().agDnsReapplyOptions.rawValue == 0)
        #expect(DNSProxyReloadScope.settings.agDnsReapplyOptions.rawValue == 1)
        #expect(DNSProxyReloadScope.filters.agDnsReapplyOptions.rawValue == 2)
        #expect(DNSProxyReloadScope.all.agDnsReapplyOptions.rawValue == 3)
    }

    @Test func plannerSeparatesEngineLoggingAndIdentityChanges() throws {
        let profileID = UUID()
        let old = try makeLifecycleConfiguration(profileID: profileID)
        let settingsTarget = try makeLifecycleConfiguration(
            profileID: profileID,
            address: "9.9.9.9"
        )
        let settingsPlan = DNSProxyReloadPlan(active: old, target: settingsTarget)

        #expect(settingsPlan.scope == .settings)
        #expect(!settingsPlan.loggingModeChanged)
        #expect(settingsPlan.target == settingsTarget)

        let loggingTarget = try makeLifecycleConfiguration(
            profileID: profileID,
            loggingMode: .debug
        )
        let loggingPlan = DNSProxyReloadPlan(active: old, target: loggingTarget)
        #expect(loggingPlan.scope.isEmpty)
        #expect(loggingPlan.loggingModeChanged)

        let cacheTarget = try makeLifecycleConfiguration(
            profileID: profileID,
            dnsCacheConfiguration: DNSCacheConfiguration(
                isEnabled: false,
                maximumEntries: 1_000
            )
        )
        let cachePlan = DNSProxyReloadPlan(active: old, target: cacheTarget)
        #expect(cachePlan.scope == .settings)
        #expect(!cachePlan.loggingModeChanged)

        let identityTarget = try makeLifecycleConfiguration(
            profileID: profileID,
            address: "1.1.1.1"
        )
        let identityPlan = DNSProxyReloadPlan(active: old, target: identityTarget)
        #expect(identityPlan.scope.isEmpty)
        #expect(!identityPlan.loggingModeChanged)
    }

    @Test func successfulApplyForwardsExactPlanWithoutRollback() throws {
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let plan = DNSProxyReloadPlan(
            target: target,
            scope: [.settings, .filters],
            loggingModeChanged: true
        )
        let service = FakeDNSProxyService()

        let outcome = ReloadCoordinator().apply(
            plan: plan,
            active: old,
            service: service
        )

        #expect(outcome == .applied(target))
        #expect(service.snapshot.reapplyPlans == [plan])
        #expect(service.snapshot.stopCount == 0)
    }

    @Test func unchangedFailureDoesNotAttemptRollback() throws {
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let plan = DNSProxyReloadPlan(active: old, target: target)
        let service = FakeDNSProxyService(reapplySteps: [
            .fail(.unchanged("target rejected before engine mutation")),
        ])

        let outcome = ReloadCoordinator().apply(
            plan: plan,
            active: old,
            service: service
        )

        #expect(outcome == .rejectedUnchanged(
            active: old,
            reason: "target rejected before engine mutation"
        ))
        #expect(service.snapshot.reapplyPlans == [plan])
        #expect(service.snapshot.stopCount == 0)
    }

    @Test func uncertainFailureRollsBackWithOldExactConfigurationAndScope() throws {
        let old = try makeLifecycleConfiguration(loggingMode: .default)
        let target = try makeLifecycleConfiguration(
            address: "9.9.9.9",
            loggingMode: .debug
        )
        let plan = DNSProxyReloadPlan(
            target: target,
            scope: [.settings, .filters],
            loggingModeChanged: true
        )
        let service = FakeDNSProxyService(reapplySteps: [
            .fail(.engineMayHaveMutated("target failed")),
            .succeed,
        ])

        let outcome = ReloadCoordinator().apply(
            plan: plan,
            active: old,
            service: service
        )

        #expect(outcome == .rejectedRolledBack(active: old, reason: "target failed"))
        #expect(service.snapshot.reapplyPlans == [
            plan,
            DNSProxyReloadPlan(
                target: old,
                scope: plan.scope,
                loggingModeChanged: true
            ),
        ])
        #expect(service.snapshot.stopCount == 0)
    }

    @Test func rollbackFailureStopsServiceAndReportsBothFailures() throws {
        let old = try makeLifecycleConfiguration()
        let target = try makeLifecycleConfiguration(address: "9.9.9.9")
        let plan = DNSProxyReloadPlan(active: old, target: target)
        let service = FakeDNSProxyService(reapplySteps: [
            .fail(.engineMayHaveMutated("target failed")),
            .fail(.engineMayHaveMutated("rollback failed")),
        ])

        let outcome = ReloadCoordinator().apply(
            plan: plan,
            active: old,
            service: service
        )

        #expect(outcome == .unrecoverable(
            targetReason: "target failed",
            rollbackReason: "rollback failed"
        ))
        #expect(service.snapshot.stopCount == 1)
    }
}
