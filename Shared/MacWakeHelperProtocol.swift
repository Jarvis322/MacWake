import Foundation

/// Mach service name shared between the app and the privileged helper daemon.
public let kMacWakeHelperMachServiceName = "com.jarvisit.macwake.helper"

/// Code-signing requirement both sides use to validate each other.
/// Restricts XPC to binaries signed by this Developer ID team.
public let kMacWakeCodeSigningRequirement =
    "anchor apple generic and certificate leaf[subject.OU] = \"6NK6D7LL79\""

/// XPC interface exposed by the root helper to the main app.
@objc public protocol MacWakeHelperProtocol {
    /// Returns the helper's bundle version so the app can detect a stale daemon.
    func getVersion(reply: @escaping (String) -> Void)

    /// Allow or stop charging using the best method for this chip (clean charge-inhibit
    /// CHTE/CH0C where available, otherwise adapter disable CHIE/CH0J).
    /// `enabled == false` stops charging. `reply` returns true on a successful SMC write.
    func setAdapterEnabled(_ enabled: Bool, reply: @escaping (Bool) -> Void)

    /// Reads the current charging-allowed state. Returns true if charging is allowed.
    func getAdapterEnabled(reply: @escaping (Bool) -> Void)

    /// Force the power adapter off/on via CHIE/CH0J on every chip, so the battery
    /// actively discharges. Used by Sailing Mode to drift the battery down to the lower
    /// bound even on Macs whose default method is a non-discharging charge inhibit.
    /// `discharging == true` cuts the adapter. `reply` returns true on a successful write.
    func setForceDischarge(_ discharging: Bool, reply: @escaping (Bool) -> Void)

    /// Returns (fanCount, minRPM, maxRPM) for fan 0, or (0,0,0) on fanless Macs.
    func getFanInfo(reply: @escaping (Int, Int, Int) -> Void)

    /// Force fan 0 to a manual target RPM, or return it to automatic system control.
    /// `manual == false` restores auto (SMC F0Md = 0). `reply` true on success.
    func setFanManual(_ manual: Bool, rpm: Int, reply: @escaping (Bool) -> Void)

    /// Unregisters and removes the helper (best-effort) before the app uninstalls it.
    func uninstall(reply: @escaping (Bool) -> Void)
}

/// Bumped whenever the helper's XPC surface or SMC logic changes, so the app can
/// re-register a newer daemon.
public let kMacWakeHelperVersion = "3"
