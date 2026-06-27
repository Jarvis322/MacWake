import Foundation
import MacWakeShared

/// Implements the XPC protocol, running as root inside the launchd daemon.
final class HelperService: NSObject, MacWakeHelperProtocol {
    func getVersion(reply: @escaping (String) -> Void) {
        reply(kMacWakeHelperVersion)
    }

    func setAdapterEnabled(_ enabled: Bool, reply: @escaping (Bool) -> Void) {
        reply(HelperSMC.setAdapterEnabled(enabled))
    }

    func getAdapterEnabled(reply: @escaping (Bool) -> Void) {
        reply(HelperSMC.getAdapterEnabled())
    }

    func setForceDischarge(_ discharging: Bool, reply: @escaping (Bool) -> Void) {
        reply(HelperSMC.setForceDischarge(discharging))
    }

    func getFanInfo(reply: @escaping (Int, Int, Int) -> Void) {
        let info = HelperSMC.getFanInfo()
        reply(info.count, info.min, info.max)
    }

    func setFanManual(_ manual: Bool, rpm: Int, reply: @escaping (Bool) -> Void) {
        reply(HelperSMC.setFanManual(manual, rpm: rpm))
    }

    func uninstall(reply: @escaping (Bool) -> Void) {
        // Always restore charging before the app tears the helper down,
        // so we never leave the machine discharging on AC.
        _ = HelperSMC.setAdapterEnabled(true)
        reply(true)
    }
}

/// Accepts XPC connections, but only from binaries matching our Developer ID requirement.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Reject any caller not signed by our team (macOS 13+).
        newConnection.setCodeSigningRequirement(kMacWakeCodeSigningRequirement)

        newConnection.exportedInterface = NSXPCInterface(with: MacWakeHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}
