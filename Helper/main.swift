import Foundation
import MacWakeShared

// Privileged launchd daemon entry point. Listens on the shared Mach service
// and serves charge-control requests from the main app over XPC.
let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: kMacWakeHelperMachServiceName)
listener.delegate = delegate
listener.resume()

// A firmware charge limit this daemon applied before it died (crash, kill) has no owner now.
// Release it; the app re-applies it on its next evaluation if it still wants it.
_ = HelperSMC.releaseFirmwareLimit()

// Keep the daemon alive for incoming connections.
dispatchMain()
