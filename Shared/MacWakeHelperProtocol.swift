import Foundation

/// Mach service name shared between the app and the privileged helper daemon.
public let kMacWakeHelperMachServiceName = "com.jarvisit.macwake.helper"

/// Code-signing requirement both sides use to validate each other. Restricts XPC to the
/// three legitimate MacWake binaries — the app ("com.jarvisit.macwake"), the embedded CLI
/// ("macwake", its default --identifier since it isn't bundled), and the helper itself
/// ("MacWakeHelper") — all signed by this Developer ID team. A team-ID-only check would
/// let ANY binary this account ever signs talk to the privileged helper; pinning the
/// identifier too means an attacker needs a binary that impersonates one of these three
/// exact identities, not just any signature from the same team.
public let kMacWakeCodeSigningRequirement =
    "anchor apple generic and certificate leaf[subject.OU] = \"6NK6D7LL79\" and " +
    "(identifier \"com.jarvisit.macwake\" or identifier \"macwake\" or identifier \"MacWakeHelper\")"

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

    /// Sets the macOS Energy Mode via pmset. 0 = Automatic, 1 = Low Power, 2 = High Power.
    /// (High Power only applies on Macs that support it; the call is otherwise a no-op.)
    func setEnergyMode(_ mode: Int, reply: @escaping (Bool) -> Void)

    /// Unregisters and removes the helper (best-effort) before the app uninstalls it.
    func uninstall(reply: @escaping (Bool) -> Void)
}

/// Bumped whenever the helper's XPC surface or SMC logic changes, so the app can
/// re-register a newer daemon.
public let kMacWakeHelperVersion = "4"
