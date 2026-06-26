import Foundation
import ServiceManagement
import MacWakeShared

/// Manages the privileged helper daemon and drives charge limiting by toggling
/// the power adapter (SMC key CHIE) through the helper.
///
/// Apple Silicon (M-series) has no clean "inhibit charge but stay on AC" SMC key
/// that is writable on M4, so we hold the battery near the limit by cutting the
/// adapter (discharge) above the target and re-enabling it once it dips below —
/// the same discharge-to-hold strategy AlDente uses where no inhibit key exists.
@MainActor
final class ChargeLimitManager: ObservableObject {
    static let shared = ChargeLimitManager()

    enum HelperStatus {
        case notInstalled      // daemon not registered
        case requiresApproval  // registered, waiting for user approval in System Settings
        case ready             // registered and enabled
    }

    @Published private(set) var helperStatus: HelperStatus = .notInstalled

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "chargeLimitEnabled")
            if !isEnabled { Task { await self.restoreCharging() } }
        }
    }

    @Published var limit: Int {
        didSet {
            let clamped = min(95, max(50, limit))
            if clamped != limit { limit = clamped; return }
            UserDefaults.standard.set(limit, forKey: "chargeLimitValue")
        }
    }

    /// Hysteresis: resume charging only after dropping this far below the limit,
    /// to avoid rapid on/off oscillation around the threshold.
    private let hysteresis = 5

    /// Minimum time between adapter toggles, a hard backstop against oscillation.
    private let minToggleInterval: TimeInterval = 90

    private let plistName = "com.jarvisit.macwake.helper.plist"
    private var connection: NSXPCConnection?
    private var lastAdapterEnabled: Bool?
    private var lastToggleAt: Date?

    /// True briefly after we flip the adapter, so BatteryTracker can suppress the
    /// charging animation / Dynamic Island for our own induced power-source changes.
    func didInducePowerChange(within seconds: TimeInterval) -> Bool {
        guard let t = lastToggleAt else { return false }
        return Date().timeIntervalSince(t) < seconds
    }

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "chargeLimitEnabled")
        let savedLimit = UserDefaults.standard.integer(forKey: "chargeLimitValue")
        self.limit = savedLimit == 0 ? 80 : min(95, max(50, savedLimit))
        refreshStatus()
    }

    // MARK: - Daemon lifecycle

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    func refreshStatus() {
        switch service.status {
        case .enabled:
            helperStatus = .ready
            if lastAdapterEnabled == nil { syncAdapterState() }
        case .requiresApproval:
            helperStatus = .requiresApproval
        default:
            helperStatus = .notInstalled
        }
    }

    /// Reads the helper's real CHIE state to seed `lastAdapterEnabled`, so a fresh
    /// launch reconciles with whatever the daemon left set (e.g. after a crash/quit).
    private func syncAdapterState() {
        guard let proxy = remoteProxy() else { return }
        proxy.getAdapterEnabled { [weak self] enabled in
            Task { @MainActor in
                guard let self else { return }
                if self.lastAdapterEnabled == nil { self.lastAdapterEnabled = enabled }
            }
        }
    }

    /// Registers the daemon. First call usually lands in `.requiresApproval`,
    /// so we also open System Settings for the user to flip the switch.
    func install() {
        do {
            try service.register()
        } catch {
            print("ChargeLimit: register failed: \(error)")
        }
        refreshStatus()
        if helperStatus == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func uninstall() {
        Task {
            await restoreCharging()
            if let proxy = remoteProxy() {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    proxy.uninstall { _ in cont.resume() }
                }
            }
            try? await service.unregister()
            connection?.invalidate()
            connection = nil
            refreshStatus()
        }
    }

    // MARK: - XPC

    private func remoteProxy() -> MacWakeHelperProtocol? {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: kMacWakeHelperMachServiceName, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: MacWakeHelperProtocol.self)
            conn.setCodeSigningRequirement(kMacWakeCodeSigningRequirement)
            conn.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            conn.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            conn.resume()
            connection = conn
        }
        return connection?.remoteObjectProxyWithErrorHandler { err in
            print("ChargeLimit: XPC error: \(err)")
        } as? MacWakeHelperProtocol
    }

    private func setAdapter(enabled: Bool) async {
        guard let proxy = remoteProxy() else { return }
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            proxy.setAdapterEnabled(enabled) { success in cont.resume(returning: success) }
        }
        if ok {
            lastAdapterEnabled = enabled
            lastToggleAt = Date()
        }
    }

    private func restoreCharging() async {
        await setAdapter(enabled: true)
    }

    /// Synchronous best-effort restore for app termination — blocks briefly so the
    /// adapter is re-enabled before the process exits.
    func restoreChargingOnQuit() {
        guard lastAdapterEnabled == false, let proxy = remoteProxy() else { return }
        let sem = DispatchSemaphore(value: 0)
        proxy.setAdapterEnabled(true) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }

    // MARK: - Control loop

    /// Called by BatteryTracker whenever battery state updates.
    ///
    /// Note: when we hold the limit by cutting the adapter (CHIE=8), macOS reports
    /// "battery power" even though the charger is physically attached. We must NOT
    /// treat that self-induced state as a real unplug, or we'd flip the adapter back
    /// on immediately and oscillate. `lastAdapterEnabled == false` means we are the
    /// ones holding, so the charger is still physically connected.
    func evaluate(batteryLevel: Int, isPluggedIn: Bool) {
        guard helperStatus == .ready, isEnabled else {
            if lastAdapterEnabled == false { Task { await restoreCharging() } }
            return
        }

        let physicallyPlugged = isPluggedIn || (lastAdapterEnabled == false)
        guard physicallyPlugged else {
            // Genuinely on battery — re-enable so the next real plug-in charges.
            if lastAdapterEnabled == false { Task { await restoreCharging() } }
            return
        }

        let shouldChargeAllowed: Bool
        if batteryLevel >= limit {
            shouldChargeAllowed = false                       // at/over limit → stop
        } else if batteryLevel <= limit - hysteresis {
            shouldChargeAllowed = true                        // dropped below band → resume
        } else {
            return                                            // inside hysteresis band → hold
        }

        guard lastAdapterEnabled != shouldChargeAllowed else { return }

        // Hard backstop: never toggle faster than minToggleInterval.
        if let last = lastToggleAt, Date().timeIntervalSince(last) < minToggleInterval {
            return
        }

        Task { await setAdapter(enabled: shouldChargeAllowed) }
    }
}
