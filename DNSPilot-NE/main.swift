import NetworkExtension

DNSLogBridge.configure(process: "SystemExtension")

let machXPCServer: MachXPCServer
do {
    machXPCServer = try MachXPCServer()
    machXPCServer.activate()
} catch {
    fatalError("Unable to start the runtime status service: \(error.localizedDescription)")
}

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
