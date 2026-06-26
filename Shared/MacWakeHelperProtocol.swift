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

    /// Enable or disable the power adapter via SMC key CHIE.
    /// `enabled == false` cuts the adapter (battery discharges) to hold below the charge limit.
    /// `reply` returns true on a successful SMC write.
    func setAdapterEnabled(_ enabled: Bool, reply: @escaping (Bool) -> Void)

    /// Reads the current CHIE state. Returns true if the adapter is enabled (charging allowed).
    func getAdapterEnabled(reply: @escaping (Bool) -> Void)

    /// Unregisters and removes the helper (best-effort) before the app uninstalls it.
    func uninstall(reply: @escaping (Bool) -> Void)
}

/// Bumped whenever the helper's XPC surface or SMC logic changes, so the app can
/// re-register a newer daemon.
public let kMacWakeHelperVersion = "1"
