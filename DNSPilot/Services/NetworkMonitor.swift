import AppKit
import CoreLocation
import CoreWLAN
import Darwin
import Foundation
import Network

enum NetworkPathStatusInput: Equatable, Sendable {
    case satisfied
    case requiresConnection
    case unsatisfied
}

enum NetworkInterfaceTypeInput: Equatable, Sendable {
    case wifi
    case wiredEthernet
    case cellular
    case loopback
    case other
}

struct NetworkPathInterfaceInput: Equatable, Sendable {
    let name: String
    let type: NetworkInterfaceTypeInput
    let isUsed: Bool
}

struct NetworkPathInput: Equatable, Sendable {
    let status: NetworkPathStatusInput
    let interfaces: [NetworkPathInterfaceInput]
}

enum NetworkAddressFamilyInput: Equatable, Sendable {
    case ipv4
    case ipv6
    case unsupported(Int32)
}

struct NetworkAddressInput: Equatable, Sendable {
    let interfaceName: String
    let family: NetworkAddressFamilyInput
    let literal: String
    let prefixLength: Int?
    let isUp: Bool
    let isLoopback: Bool

    init(
        interfaceName: String,
        family: NetworkAddressFamilyInput,
        literal: String,
        prefixLength: Int? = nil,
        isUp: Bool,
        isLoopback: Bool
    ) {
        self.interfaceName = interfaceName
        self.family = family
        self.literal = literal
        self.prefixLength = prefixLength
        self.isUp = isUp
        self.isLoopback = isLoopback
    }
}

enum LocationAuthorizationInput: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
}

struct SSIDInput: Equatable, Sendable {
    let authorization: LocationAuthorizationInput
    let ssid: String?
}

enum NetworkAddressLiteral {
    static func forParsing(_ literal: String, family: NetworkAddressFamilyInput) -> String {
        guard case .ipv6 = family, let zoneStart = literal.firstIndex(of: "%") else {
            return literal
        }
        return String(literal[..<zoneStart])
    }
}

enum NetworkContextBuilder {
    static func build(
        path: NetworkPathInput,
        addresses: [NetworkAddressInput],
        ssid: SSIDInput
    ) -> NetworkContext {
        let activeInterfaces = path.interfaces.filter(\.isUsed)
        let activeNames = Set(activeInterfaces.compactMap { candidate in
            Set(activeInterfaces.lazy.filter { $0.type == candidate.type }.map(\.name)).count == 1
                ? candidate.name
                : nil
        })
        let interfaceTypes = Set(activeInterfaces.map { mapInterfaceType($0.type) })
        let filteredAddresses = addresses.compactMap { input -> InterfaceAddress? in
            guard input.isUp, !input.isLoopback else { return nil }
            guard activeNames.contains(input.interfaceName) else { return nil }

            let expectedFamily: IPAddress.Family
            switch input.family {
            case .ipv4:
                expectedFamily = .ipv4
            case .ipv6:
                expectedFamily = .ipv6
            case .unsupported:
                return nil
            }
            let literal = NetworkAddressLiteral.forParsing(input.literal, family: input.family)
            guard let address = try? IPAddress(literal), address.family == expectedFamily else {
                return nil
            }
            guard !isMulticast(address) else { return nil }
            let maximumPrefixLength = address.family == .ipv4 ? 32 : 128
            let prefixLength = input.prefixLength.flatMap {
                (0...maximumPrefixLength).contains($0) ? $0 : nil
            }
            return InterfaceAddress(
                interfaceName: input.interfaceName,
                address: address,
                prefixLength: prefixLength
            )
        }

        let stableAddresses = Array(Set(filteredAddresses.map(StableInterfaceAddress.init)))
            .sorted()
            .map(\.value)
        let ssidState = mapSSID(wifiActive: interfaceTypes.contains(.wifi), input: ssid)

        return NetworkContext(
            status: mapStatus(path.status),
            ssid: ssidState.ssid,
            ssidAvailability: ssidState.availability,
            activeInterfaceTypes: interfaceTypes,
            addresses: stableAddresses
        )
    }

    private static func mapStatus(_ status: NetworkPathStatusInput) -> NetworkStatus {
        switch status {
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        case .unsatisfied: .unsatisfied
        }
    }

    private static func mapInterfaceType(_ type: NetworkInterfaceTypeInput) -> NetworkInterfaceType {
        switch type {
        case .wifi: .wifi
        case .wiredEthernet: .wiredEthernet
        case .cellular, .loopback, .other: .other
        }
    }

    private static func mapSSID(
        wifiActive: Bool,
        input: SSIDInput
    ) -> (ssid: String?, availability: SSIDAvailability) {
        guard wifiActive else { return (nil, .notOnWiFi) }
        switch input.authorization {
        case .notDetermined:
            return (nil, .permissionNotDetermined)
        case .denied:
            return (nil, .permissionDenied)
        case .authorized:
            guard let ssid = input.ssid, !ssid.isEmpty else {
                return (nil, .temporarilyUnavailable)
            }
            return (ssid, .available)
        }
    }

    private static func isMulticast(_ address: IPAddress) -> Bool {
        switch address.family {
        case .ipv4:
            return address.bytes[0] >= 224 && address.bytes[0] <= 239
        case .ipv6:
            return address.bytes[0] == 0xff
        }
    }

    private struct StableInterfaceAddress: Hashable, Comparable {
        let value: InterfaceAddress

        init(_ value: InterfaceAddress) {
            self.value = value
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.value == rhs.value
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(value.interfaceName)
            hasher.combine(value.address)
            hasher.combine(value.prefixLength)
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.value.interfaceName != rhs.value.interfaceName {
                return lhs.value.interfaceName < rhs.value.interfaceName
            }
            if lhs.value.address.family != rhs.value.address.family {
                return lhs.value.address.family == .ipv4
            }
            if lhs.value.address != rhs.value.address {
                return lhs.value.address.bytes.lexicographicallyPrecedes(rhs.value.address.bytes)
            }
            return (lhs.value.prefixLength ?? -1) < (rhs.value.prefixLength ?? -1)
        }
    }
}

protocol NetworkPathSourcing: Sendable {
    func start(handler: @escaping @Sendable (NetworkPathInput) -> Void) async
    func stop() async
}

protocol NetworkContextCollecting: Sendable {
    func context(for path: NetworkPathInput) async -> NetworkContext
}

protocol NetworkContextResampleSourcing: Sendable {
    func startResampling(handler: @escaping @Sendable () -> Void) async
    func stopResampling() async
}

protocol NetworkMonitorSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct NetworkContextEvent: Equatable, Sendable {
    let context: NetworkContext
    let sessionEpoch: UInt64
}

struct ContinuousNetworkMonitorSleeper: NetworkMonitorSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

actor NetworkMonitor {
    static let defaultDebounceDuration: Duration = .seconds(1)

    private let source: any NetworkPathSourcing
    private let collector: any NetworkContextCollecting
    private let resampleSource: (any NetworkContextResampleSourcing)?
    private let sleeper: any NetworkMonitorSleeping
    private let debounceDuration: Duration
    private let onContext: @Sendable (NetworkContextEvent) async -> Void

    private var desiredRunning = false
    private var guiSessionActive = true
    private var sourceRunning = false
    private var resampleSourceRunning = false
    private var deactivationInProgress = false
    private var epoch: UInt64 = 0
    private var sessionEpoch: UInt64 = 0
    private var latestPath: NetworkPathInput?
    private var lastEmittedContext: NetworkContext?
    private var nextSampleGeneration: UInt64 = 0
    private var latestScheduledSampleGeneration: UInt64 = 0
    private var resampleWaiters: [UUID: ResampleWaiter] = [:]
    private var debounceTask: Task<Void, Never>?
    private var deliveryTail: Task<Void, Never>?

    init(
        source: any NetworkPathSourcing,
        collector: any NetworkContextCollecting,
        debounceDuration: Duration = NetworkMonitor.defaultDebounceDuration,
        sleeper: any NetworkMonitorSleeping = ContinuousNetworkMonitorSleeper(),
        onContext: @escaping @Sendable (NetworkContextEvent) async -> Void
    ) {
        self.source = source
        self.collector = collector
        self.resampleSource = collector as? any NetworkContextResampleSourcing
        self.debounceDuration = debounceDuration
        self.sleeper = sleeper
        self.onContext = onContext
    }

    func start() async {
        desiredRunning = true
        guard guiSessionActive, !sourceRunning else { return }
        await activate()
    }

    func stop() async {
        desiredRunning = false
        await deactivate()
    }

    func setGUISessionActive(_ active: Bool) async -> UInt64? {
        guard guiSessionActive != active else { return sessionEpoch }
        sessionEpoch &+= 1
        let transitionEpoch = sessionEpoch
        guiSessionActive = active
        if active, desiredRunning {
            await activate()
        } else if !active {
            await deactivate()
        }
        guard sessionEpoch == transitionEpoch, guiSessionActive == active else { return nil }
        return transitionEpoch
    }

    func invalidateSession() -> UInt64 {
        sessionEpoch &+= 1
        return sessionEpoch
    }

    func handleWake() async {
        guard desiredRunning, guiSessionActive else { return }
        await deactivate()
        await activate()
    }

    func requestResample() async -> Bool {
        guard desiredRunning, guiSessionActive, sourceRunning, let latestPath else { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let sampleGeneration = scheduleCollection(path: latestPath, epoch: epoch)
                resampleWaiters[waiterID] = ResampleWaiter(
                    minimumSampleGeneration: sampleGeneration,
                    epoch: epoch,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelResampleWaiter(waiterID) }
        }
    }

    private func activate() async {
        guard desiredRunning, guiSessionActive, !sourceRunning else { return }
        epoch &+= 1
        let activeEpoch = epoch
        sourceRunning = true
        await source.start { [weak self] path in
            Task {
                await self?.receive(path, epoch: activeEpoch)
            }
        }
        guard epoch == activeEpoch, sourceRunning else { return }
        if let resampleSource {
            resampleSourceRunning = true
            await resampleSource.startResampling { [weak self] in
                Task {
                    await self?.receiveResample(epoch: activeEpoch)
                }
            }
            guard epoch == activeEpoch, sourceRunning else {
                resampleSourceRunning = false
                await resampleSource.stopResampling()
                return
            }
        }
    }

    private func deactivate() async {
        epoch &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        resumeResampleWaiters(success: false)
        latestPath = nil
        lastEmittedContext = nil
        guard !deactivationInProgress else { return }
        deactivationInProgress = true
        let wasSourceRunning = sourceRunning
        let wasResampleSourceRunning = resampleSourceRunning
        if wasResampleSourceRunning {
            await resampleSource?.stopResampling()
        }
        if wasSourceRunning {
            await source.stop()
        }
        sourceRunning = false
        resampleSourceRunning = false
        deactivationInProgress = false
        if desiredRunning, guiSessionActive {
            await activate()
        }
    }

    private func receive(_ path: NetworkPathInput, epoch callbackEpoch: UInt64) {
        guard callbackEpoch == epoch, sourceRunning, desiredRunning, guiSessionActive else { return }
        latestPath = path
        _ = scheduleCollection(path: path, epoch: callbackEpoch)
    }

    @discardableResult
    private func scheduleCollection(path: NetworkPathInput, epoch callbackEpoch: UInt64) -> UInt64 {
        debounceTask?.cancel()
        nextSampleGeneration &+= 1
        let sampleGeneration = nextSampleGeneration
        latestScheduledSampleGeneration = sampleGeneration
        let sleeper = sleeper
        let duration = debounceDuration
        debounceTask = Task { [weak self] in
            do {
                try await sleeper.sleep(for: duration)
                try Task.checkCancellation()
                await self?.emit(
                    path: path,
                    sampleGeneration: sampleGeneration,
                    epoch: callbackEpoch
                )
            } catch {
                // Cancellation is the normal path when a newer network snapshot arrives.
            }
        }
        return sampleGeneration
    }

    private func receiveResample(epoch callbackEpoch: UInt64) {
        guard callbackEpoch == epoch, let latestPath else { return }
        _ = scheduleCollection(path: latestPath, epoch: callbackEpoch)
    }

    private func emit(
        path: NetworkPathInput,
        sampleGeneration: UInt64,
        epoch expectedEpoch: UInt64
    ) async {
        guard
            expectedEpoch == epoch,
            sourceRunning,
            desiredRunning,
            guiSessionActive
        else { return }

        let context = await collector.context(for: path)
        guard
            expectedEpoch == epoch,
            sourceRunning,
            desiredRunning,
            guiSessionActive,
            sampleGeneration == latestScheduledSampleGeneration
        else { return }
        if context != lastEmittedContext {
            lastEmittedContext = context
            await deliver(
                NetworkContextEvent(context: context, sessionEpoch: sessionEpoch),
                epoch: expectedEpoch
            )
        }
        guard
            expectedEpoch == epoch,
            sourceRunning,
            desiredRunning,
            guiSessionActive,
            sampleGeneration == latestScheduledSampleGeneration
        else { return }
        resumeEligibleResampleWaiters(
            epoch: expectedEpoch,
            completedSampleGeneration: sampleGeneration
        )
    }

    private func deliver(_ event: NetworkContextEvent, epoch expectedEpoch: UInt64) async {
        let predecessor = deliveryTail
        let delivery = Task { [weak self] in
            await predecessor?.value
            await self?.deliverIfCurrent(event, epoch: expectedEpoch)
        }
        deliveryTail = delivery
        await delivery.value
    }

    private func deliverIfCurrent(_ event: NetworkContextEvent, epoch expectedEpoch: UInt64) async {
        guard
            expectedEpoch == epoch,
            sourceRunning,
            desiredRunning,
            guiSessionActive
        else { return }
        await onContext(event)
    }

    private func resumeEligibleResampleWaiters(
        epoch expectedEpoch: UInt64,
        completedSampleGeneration: UInt64
    ) {
        var retained: [UUID: ResampleWaiter] = [:]
        for (id, waiter) in resampleWaiters {
            if waiter.epoch == expectedEpoch,
               waiter.minimumSampleGeneration <= completedSampleGeneration {
                waiter.continuation.resume(returning: true)
            } else {
                retained[id] = waiter
            }
        }
        resampleWaiters = retained
    }

    private func cancelResampleWaiter(_ id: UUID) {
        resampleWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }

    private func resumeResampleWaiters(success: Bool) {
        let waiters = resampleWaiters.values
        resampleWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(returning: success) }
    }

    private struct ResampleWaiter {
        let minimumSampleGeneration: UInt64
        let epoch: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }
}

protocol NetworkAddressSnapshotProviding: Sendable {
    func snapshot() -> [NetworkAddressInput]
}

protocol SSIDSnapshotProviding: Sendable {
    func snapshot(wifiActive: Bool) async -> SSIDInput
}

struct SystemNetworkContextCollector: NetworkContextCollecting, NetworkContextResampleSourcing {
    let addressProvider: any NetworkAddressSnapshotProviding
    let ssidProvider: any SSIDSnapshotProviding

    func context(for path: NetworkPathInput) async -> NetworkContext {
        let addresses = addressProvider.snapshot()
        let wifiActive = path.interfaces.contains { $0.isUsed && $0.type == .wifi }
        let ssid = await ssidProvider.snapshot(wifiActive: wifiActive)
        return NetworkContextBuilder.build(path: path, addresses: addresses, ssid: ssid)
    }

    func startResampling(handler: @escaping @Sendable () -> Void) async {
        await (ssidProvider as? any NetworkContextResampleSourcing)?.startResampling(handler: handler)
    }

    func stopResampling() async {
        await (ssidProvider as? any NetworkContextResampleSourcing)?.stopResampling()
    }
}

struct SystemNetworkAddressProvider: NetworkAddressSnapshotProviding {
    func snapshot() -> [NetworkAddressInput] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var result: [NetworkAddressInput] = []
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }
            guard let socketAddress = entry.ifa_addr else { continue }
            let family = Int32(socketAddress.pointee.sa_family)
            let inputFamily: NetworkAddressFamilyInput
            let length: socklen_t
            switch family {
            case AF_INET:
                inputFamily = .ipv4
                length = socklen_t(MemoryLayout<sockaddr_in>.size)
            case AF_INET6:
                inputFamily = .ipv6
                length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            default:
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socketAddress,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            let flags = Int32(bitPattern: entry.ifa_flags)
            result.append(NetworkAddressInput(
                interfaceName: String(cString: entry.ifa_name),
                family: inputFamily,
                literal: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                prefixLength: Self.prefixLength(
                    from: entry.ifa_netmask,
                    length: length,
                    family: inputFamily
                ),
                isUp: flags & IFF_UP != 0,
                isLoopback: flags & IFF_LOOPBACK != 0
            ))
        }
        return result
    }

    private static func prefixLength(
        from socketAddress: UnsafeMutablePointer<sockaddr>?,
        length: socklen_t,
        family: NetworkAddressFamilyInput
    ) -> Int? {
        guard let socketAddress else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            socketAddress,
            length,
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        ) == 0 else { return nil }
        let literal = String(
            decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard let mask = try? IPAddress(NetworkAddressLiteral.forParsing(literal, family: family)) else {
            return nil
        }

        return prefixLength(for: mask)
    }

    static func prefixLength(for mask: IPAddress) -> Int? {
        var prefixLength = 0
        var sawZero = false
        for byte in mask.bytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                let isOne = byte & (1 << bit) != 0
                if isOne {
                    guard !sawZero else { return nil }
                    prefixLength += 1
                } else {
                    sawZero = true
                }
            }
        }
        return prefixLength
    }
}

@MainActor
final class SystemSSIDSnapshotProvider: NSObject, SSIDSnapshotProviding, NetworkContextResampleSourcing,
    @MainActor CLLocationManagerDelegate
{
    private let locationManager: CLLocationManager
    private let wifiClient: CWWiFiClient
    private var resampleHandler: (@Sendable () -> Void)?

    override init() {
        locationManager = CLLocationManager()
        wifiClient = CWWiFiClient.shared()
        super.init()
        locationManager.delegate = self
    }

    func snapshot(wifiActive: Bool) async -> SSIDInput {
        let authorization = authorizationStatus()
        let ssid = wifiActive && authorization == .authorized
            ? wifiClient.interface()?.ssid()
            : nil
        return SSIDInput(authorization: authorization, ssid: ssid)
    }

    func authorizationStatus() -> LocationAuthorizationInput {
        if !CLLocationManager.locationServicesEnabled() {
            return .denied
        }
        return switch locationManager.authorizationStatus {
        case .authorized, .authorizedAlways:
            .authorized
        case .notDetermined:
            .notDetermined
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startResampling(handler: @escaping @Sendable () -> Void) {
        resampleHandler = handler
    }

    func stopResampling() {
        resampleHandler = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        resampleHandler?()
    }
}

actor SystemNetworkPathSource: NetworkPathSourcing {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.dnspilot.network-path-monitor")

    func start(handler: @escaping @Sendable (NetworkPathInput) -> Void) {
        monitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            handler(Self.copy(path))
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    private nonisolated static func copy(_ path: NWPath) -> NetworkPathInput {
        let status: NetworkPathStatusInput = switch path.status {
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        case .unsatisfied: .unsatisfied
        @unknown default: .unsatisfied
        }
        let interfaces = path.availableInterfaces.map { interface in
            let type: NetworkInterfaceTypeInput = switch interface.type {
            case .wifi: .wifi
            case .wiredEthernet: .wiredEthernet
            case .cellular: .cellular
            case .loopback: .loopback
            case .other: .other
            @unknown default: .other
            }
            return NetworkPathInterfaceInput(
                name: interface.name,
                type: type,
                isUsed: path.usesInterfaceType(interface.type)
            )
        }
        return NetworkPathInput(status: status, interfaces: interfaces)
    }
}

@MainActor
final class NetworkMonitorWorkspaceAdapter: NSObject {
    private let monitor: NetworkMonitor
    private let onSessionChange: @MainActor (Bool, UInt64) -> Void
    private var isObserving = false

    init(
        monitor: NetworkMonitor,
        onSessionChange: @escaping @MainActor (Bool, UInt64) -> Void = { _, _ in }
    ) {
        self.monitor = monitor
        self.onSessionChange = onSessionChange
    }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func stop() {
        guard isObserving else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        isObserving = false
    }

    @objc private func sessionDidResignActive() {
        Task {
            if let epoch = await monitor.setGUISessionActive(false) {
                onSessionChange(false, epoch)
            }
        }
    }

    @objc private func sessionDidBecomeActive() {
        Task {
            if let epoch = await monitor.setGUISessionActive(true) {
                onSessionChange(true, epoch)
            }
        }
    }

    @objc private func systemDidWake() {
        Task { await monitor.handleWake() }
    }
}
