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
        // Answers later, from the fan queue: taking a fan over can wait several seconds for
        // the system to let go, and this call must not hold up the ones behind it.
        HelperSMC.setFanManual(manual, rpm: rpm, reply: reply)
    }

    func setEnergyMode(_ mode: Int, reply: @escaping (Bool) -> Void) {
        reply(HelperPower.setEnergyMode(mode))
    }

    func fanDiagnostics(reply: @escaping (String) -> Void) {
        HelperSMC.fanDiagnostics { report in
            reply("helper v\(kMacWakeHelperVersion)\n" + report)
        }
    }

    func chargeControlMethod(reply: @escaping (String) -> Void) {
        reply(HelperSMC.chargeControlMethod())
    }

    func firmwareLimitSupported(reply: @escaping (Bool) -> Void) {
        reply(HelperSMC.firmwareLimitSupported())
    }

    // The connection that holds the firmware limit. The limit is enforced by firmware and would
    // outlive an app that crashed or was force-quit, so when this connection goes away without
    // releasing, the daemon releases for it (see `connectionEnded`).
    private let ownerLock = NSLock()
    private weak var firmwareOwner: NSXPCConnection?

    private func setFirmwareOwner(_ connection: NSXPCConnection?) {
        ownerLock.lock(); defer { ownerLock.unlock() }
        firmwareOwner = connection
    }

    func setFirmwareLimit(upper: Int, lower: Int, reply: @escaping (Bool) -> Void) {
        let applied = HelperSMC.setFirmwareLimit(upper: upper, lower: lower)
        if applied { setFirmwareOwner(NSXPCConnection.current()) }
        reply(applied)
    }

    func verifyFirmwareLimit(upper: Int, lower: Int, reply: @escaping (Bool) -> Void) {
        let intact = HelperSMC.verifyFirmwareLimit(upper: upper, lower: lower)
        // A reconnected app that finds its limit still in place takes the limit back over.
        if intact, HelperSMC.firmwareLimitOwned { setFirmwareOwner(NSXPCConnection.current()) }
        reply(intact)
    }

    /// Called when any client connection ends. Only the one that applied the limit matters, and
    /// a replacement connection that already took over is left alone.
    func connectionEnded(_ connection: NSXPCConnection) {
        ownerLock.lock()
        let wasOwner = firmwareOwner === connection
        if wasOwner { firmwareOwner = nil }
        ownerLock.unlock()
        if wasOwner { _ = HelperSMC.releaseFirmwareLimit() }
    }

    func releaseFirmwareLimit(reply: @escaping (Bool) -> Void) {
        let released = HelperSMC.releaseFirmwareLimit()
        if released { setFirmwareOwner(nil) }
        reply(released)
    }

    func exitForUpdate(reply: @escaping (Bool) -> Void) {
        reply(true)
        // Answer first, then step aside: launchd owns this job and will start the newer
        // binary when the app reconnects. Restore charging on the way out so a limit that
        // was holding the adapter off can never outlive the process.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            _ = HelperSMC.setForceDischarge(false)
            _ = HelperSMC.setAdapterEnabled(true)
            _ = HelperSMC.releaseFirmwareLimit()   // enforced by firmware: must not outlive us
            exit(0)
        }
    }

    func uninstall(reply: @escaping (Bool) -> Void) {
        // Always restore charging before the app tears the helper down,
        // so we never leave the machine discharging on AC.
        _ = HelperSMC.setAdapterEnabled(true)
        _ = HelperSMC.releaseFirmwareLimit()
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
        newConnection.invalidationHandler = { [weak service, weak newConnection] in
            guard let service, let newConnection else { return }
            service.connectionEnded(newConnection)
        }
        newConnection.resume()
        return true
    }
}
