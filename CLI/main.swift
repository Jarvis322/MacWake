import Foundation
import IOKit.ps
import MacWakeShared

// MARK: - Helper XPC client

private func helper() -> MacWakeHelperProtocol? {
    let conn = NSXPCConnection(machServiceName: kMacWakeHelperMachServiceName, options: .privileged)
    conn.remoteObjectInterface = NSXPCInterface(with: MacWakeHelperProtocol.self)
    conn.setCodeSigningRequirement(kMacWakeCodeSigningRequirement)
    conn.resume()
    return conn.remoteObjectProxyWithErrorHandler { _ in
        fail("the MacWake helper isn't available. Enable Charge Limiting in the MacWake app once, then retry.")
    } as? MacWakeHelperProtocol
}

private func callBool(_ block: (@escaping (Bool) -> Void) -> Void) -> Bool {
    let sem = DispatchSemaphore(value: 0)
    var result = false
    block { ok in result = ok; sem.signal() }
    _ = sem.wait(timeout: .now() + 5)
    return result
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

private func finish(_ ok: Bool, _ message: String) -> Never {
    print(ok ? message : "failed (is the helper running?)")
    exit(ok ? 0 : 1)
}

// MARK: - Battery status (no root needed)

private func batteryStatus() -> (level: Int, charging: Bool, plugged: Bool) {
    let snap = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let list = IOPSCopyPowerSourcesList(snap).takeRetainedValue() as Array
    for src in list {
        if let d = IOPSGetPowerSourceDescription(snap, src).takeUnretainedValue() as? [String: Any] {
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            return (cur * 100 / max(1, mx), charging, plugged)
        }
    }
    return (0, false, false)
}

private func usage() {
    print("""
    macwake — control Mac charging through the MacWake helper

    USAGE
      macwake status                 battery %, power source, charging state
      macwake charging on|off        allow or stop charging
      macwake adapter on|off         power adapter on, or off to discharge on AC
      macwake energy auto|low|high   set the macOS Energy Mode
      macwake fan auto|<rpm>         fan: automatic, or a manual target RPM

    Control commands need the MacWake background helper — enable Charge Limiting
    in the app once to install it.
    """)
}

// MARK: - Dispatch

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "status":
    let s = batteryStatus()
    let src = s.plugged ? "AC power" : "Battery"
    let chg = s.charging ? "charging" : (s.plugged ? "not charging" : "discharging")
    print("\(s.level)%  ·  \(src)  ·  \(chg)")

case "charging" where args.count == 2 && (args[1] == "on" || args[1] == "off"):
    guard let p = helper() else { exit(1) }
    let on = args[1] == "on"
    finish(callBool { p.setAdapterEnabled(on, reply: $0) }, "charging \(on ? "enabled" : "disabled")")

case "adapter" where args.count == 2 && (args[1] == "on" || args[1] == "off"):
    guard let p = helper() else { exit(1) }
    let off = args[1] == "off"
    finish(callBool { p.setForceDischarge(off, reply: $0) }, "adapter \(off ? "off — discharging" : "on")")

case "energy" where args.count == 2:
    guard let mode = ["auto": 0, "low": 1, "high": 2][args[1]] else { usage(); exit(1) }
    guard let p = helper() else { exit(1) }
    finish(callBool { p.setEnergyMode(mode, reply: $0) }, "energy mode: \(args[1])")

case "fan" where args.count == 2:
    guard let p = helper() else { exit(1) }
    if args[1] == "auto" {
        finish(callBool { p.setFanManual(false, rpm: 0, reply: $0) }, "fan: automatic")
    } else if let rpm = Int(args[1]), rpm >= 0 {
        finish(callBool { p.setFanManual(true, rpm: rpm, reply: $0) }, "fan: \(rpm) RPM")
    } else {
        usage(); exit(1)
    }

default:
    usage()
}
