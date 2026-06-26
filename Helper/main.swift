import Foundation
import MacWakeShared

// Privileged launchd daemon entry point. Listens on the shared Mach service
// and serves charge-control requests from the main app over XPC.
let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: kMacWakeHelperMachServiceName)
listener.delegate = delegate
listener.resume()

// Keep the daemon alive for incoming connections.
dispatchMain()
