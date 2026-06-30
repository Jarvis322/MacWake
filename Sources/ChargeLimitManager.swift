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
            if sailingLower > limit - 5 { sailingLower = limit - 5 }
        }
    }

    /// Sailing Mode: let the battery drift down to `sailingLower` before topping back
    /// up to `limit`, instead of micro-charging at the ceiling. Fewer cycles, less heat.
    @Published var sailingEnabled: Bool {
        didSet { UserDefaults.standard.set(sailingEnabled, forKey: "sailingEnabled") }
    }

    @Published var sailingLower: Int {
        didSet {
            let clamped = min(limit - 5, max(40, sailingLower))
            if clamped != sailingLower { sailingLower = clamped; return }
            UserDefaults.standard.set(sailingLower, forKey: "sailingLower")
        }
    }

    /// Monthly Calibration: periodically let the battery charge fully to 100% to
    /// recalibrate its fuel gauge, then resume limiting.
    @Published var calibrationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(calibrationEnabled, forKey: "calibrationEnabled")
            // Turning the schedule off should also stop any calibration in progress.
            if !calibrationEnabled && calibrationActive { cancelCalibration() }
        }
    }

    @Published var calibrationIntervalDays: Int {
        didSet {
            let clamped = min(90, max(7, calibrationIntervalDays))
            if clamped != calibrationIntervalDays { calibrationIntervalDays = clamped; return }
            UserDefaults.standard.set(calibrationIntervalDays, forKey: "calibrationIntervalDays")
        }
    }

    enum CalibrationPhase { case discharge, charge, hold }
    @Published private(set) var calibrationActive = false
    @Published private(set) var calibrationPhase: CalibrationPhase = .discharge
    private var calibrationHoldStart: Date?
    private var calibrationStartedAt: Date?
    private let calibrationDischargeFloor = 15
    private let calibrationHoldSeconds: TimeInterval = 3600   // hold at 100% for 1 hour
    // Safety backstop: a normal cycle (drain to 15%, recharge to 100%, hold an hour)
    // should never take this long on AC. If it does — e.g. a genuine unplug mid-cycle
    // that the self-induced-discharge heuristic can't distinguish from our own cutoff —
    // abort rather than leave the battery parked low or charging paused indefinitely.
    private let calibrationMaxDuration: TimeInterval = 8 * 3600
    private(set) var lastCalibration: Date?

    // MARK: - Fan control (experimental; only meaningful on Macs with fans)

    /// Number of fans (0 = fanless — the UI hides fan control entirely).
    @Published private(set) var fanCount = 0
    @Published private(set) var fanMinRPM = 0
    @Published private(set) var fanMaxRPM = 0

    @Published var fanControlEnabled: Bool {
        didSet {
            UserDefaults.standard.set(fanControlEnabled, forKey: "fanControlEnabled")
            Task { await applyFan() }
        }
    }

    @Published var fanTargetRPM: Int {
        didSet {
            UserDefaults.standard.set(fanTargetRPM, forKey: "fanTargetRPM")
            if fanControlEnabled { Task { await applyFan() } }
        }
    }

    /// Safety: above this temperature we drop fan control back to automatic so a low
    /// manual speed can never cause overheating.
    private let fanFailsafeTempC: Double = 92

    // MARK: - Energy Mode (macOS pmset)

    /// 0 = Automatic, 1 = Low Power, 2 = High Power.
    @Published private(set) var energyMode: Int = 0
    /// True on Macs that expose High Power Mode (some MacBook Pros).
    @Published private(set) var highPowerSupported = false

    /// Hysteresis: resume charging only after dropping this far below the limit,
    /// to avoid rapid on/off oscillation around the threshold (non-sailing mode).
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
        let d = UserDefaults.standard
        self.isEnabled = d.bool(forKey: "chargeLimitEnabled")
        let savedLimit = d.integer(forKey: "chargeLimitValue")
        let lim = savedLimit == 0 ? 80 : min(95, max(50, savedLimit))
        self.limit = lim
        self.sailingEnabled = d.bool(forKey: "sailingEnabled")
        let savedLower = d.integer(forKey: "sailingLower")
        self.sailingLower = savedLower == 0 ? max(40, lim - 10) : min(lim - 5, max(40, savedLower))
        self.calibrationEnabled = d.bool(forKey: "calibrationEnabled")
        let savedInterval = d.integer(forKey: "calibrationIntervalDays")
        self.calibrationIntervalDays = savedInterval == 0 ? 30 : min(90, max(7, savedInterval))
        let savedCal = d.double(forKey: "lastCalibration")
        self.lastCalibration = savedCal == 0 ? nil : Date(timeIntervalSince1970: savedCal)
        self.fanControlEnabled = d.bool(forKey: "fanControlEnabled")
        self.fanTargetRPM = d.integer(forKey: "fanTargetRPM")
        refreshStatus()
    }

    // MARK: - Daemon lifecycle

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    private var didReconcile = false

    func refreshStatus() {
        switch service.status {
        case .enabled:
            helperStatus = .ready
            if lastAdapterEnabled == nil { syncAdapterState() }
            if fanCount == 0 { loadFanInfo() }
            readEnergyMode()
            if !didReconcile { didReconcile = true; reloadHelperIfOutdated() }
        case .requiresApproval:
            helperStatus = .requiresApproval
        default:
            helperStatus = .notInstalled
        }
    }

    /// After an app update the on-disk helper is new but the running daemon may still
    /// be the old binary (missing new XPC methods). Compare versions and re-register to
    /// load the current helper. Approval persists, so this is silent.
    private func reloadHelperIfOutdated() {
        guard let proxy = remoteProxy() else { return }
        proxy.getVersion { [weak self] version in
            guard version != kMacWakeHelperVersion else { return }
            Task { @MainActor in
                guard let self else { return }
                try? await self.service.unregister()
                try? self.service.register()
                self.connection?.invalidate()
                self.connection = nil
                // Re-query fan info against the freshly loaded daemon (older daemons
                // didn't implement getFanInfo, so fan control stayed hidden).
                self.fanCount = 0
                self.loadFanInfo()
            }
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

    /// Runs an XPC Bool-reply call but never hangs — resolves to false after `timeout`
    /// (e.g. if a stale daemon lacks a newly added method).
    private func xpcBool(timeout: TimeInterval = 3,
                         _ call: @escaping (@escaping (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var done = false
            func finish(_ v: Bool) {
                lock.lock(); defer { lock.unlock() }
                if done { return }; done = true
                cont.resume(returning: v)
            }
            call { finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Apply the desired charging state. Sailing Mode forces the adapter (CHIE) so the
    /// battery actively discharges to the lower bound; otherwise the chip's best
    /// charge-stop method is used.
    private func applyChargingAllowed(_ allowed: Bool) async {
        guard let proxy = remoteProxy() else { return }
        let ok = await xpcBool { reply in
            if self.sailingEnabled {
                proxy.setForceDischarge(!allowed, reply: reply)
            } else {
                proxy.setAdapterEnabled(allowed, reply: reply)
            }
        }
        if ok {
            lastAdapterEnabled = allowed
            lastToggleAt = Date()
        }
    }

    /// Clear every charge block (both CHTE inhibit and CHIE adapter-off) so charging
    /// can proceed no matter which method was last used.
    private func restoreCharging() async {
        guard let proxy = remoteProxy() else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proxy.setForceDischarge(false) { _ in cont.resume() }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proxy.setAdapterEnabled(true) { _ in cont.resume() }
        }
        lastAdapterEnabled = true
        lastToggleAt = Date()
    }

    /// Synchronous best-effort restore for app termination — clears charge blocks and
    /// returns fans to automatic before the process exits.
    func restoreChargingOnQuit() {
        guard let proxy = remoteProxy() else { return }
        let needsCharge = (lastAdapterEnabled == false)
        let needsFan = fanControlEnabled
        guard needsCharge || needsFan else { return }
        let sem = DispatchSemaphore(value: 0)
        proxy.setFanManual(false, rpm: 0) { _ in
            proxy.setForceDischarge(false) { _ in
                proxy.setAdapterEnabled(true) { _ in sem.signal() }
            }
        }
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

        // Deep calibration takes priority: drain to ~15%, charge to 100%, hold 1 hour.
        if calibrationActive {
            if let started = calibrationStartedAt, Date().timeIntervalSince(started) > calibrationMaxDuration {
                abortCalibration()
                return
            }
            switch calibrationPhase {
            case .discharge:
                if batteryLevel <= calibrationDischargeFloor {
                    calibrationPhase = .charge
                } else if lastAdapterEnabled != false {
                    Task { await forceDischarge(true) }   // actively drain on AC
                }
                return
            case .charge:
                if batteryLevel >= 100 {
                    calibrationPhase = .hold
                    calibrationHoldStart = Date()
                } else if lastAdapterEnabled != true {
                    // The discharge phase always cuts power via the adapter key
                    // (forceDischarge/CHIE), regardless of this chip's normal charge-stop
                    // method. applyChargingAllowed(true) only clears that normal method
                    // (e.g. CHTE on M1-M3) and would leave CHIE held off — the battery
                    // would never actually charge back up. restoreCharging() clears both.
                    Task { await restoreCharging() }
                }
                return
            case .hold:
                if let s = calibrationHoldStart, Date().timeIntervalSince(s) >= calibrationHoldSeconds {
                    finishCalibration()   // fall through to normal limiting
                } else {
                    if lastAdapterEnabled != true { Task { await restoreCharging() } }
                    return
                }
            }
        } else if calibrationEnabled, isCalibrationDue() {
            startCalibration()
            return
        }

        let lower = sailingEnabled ? sailingLower : (limit - hysteresis)

        let shouldChargeAllowed: Bool
        if batteryLevel >= limit {
            shouldChargeAllowed = false                       // at/over ceiling → stop
        } else if batteryLevel <= lower {
            shouldChargeAllowed = true                        // dropped below band → resume
        } else {
            return                                            // inside band → hold / drift
        }

        guard lastAdapterEnabled != shouldChargeAllowed else { return }

        // Hard backstop: never toggle faster than minToggleInterval.
        if let last = lastToggleAt, Date().timeIntervalSince(last) < minToggleInterval {
            return
        }

        Task { await applyChargingAllowed(shouldChargeAllowed) }
    }

    // MARK: - Calibration

    private func isCalibrationDue() -> Bool {
        guard let last = lastCalibration else { return true }
        let days = Date().timeIntervalSince(last) / 86400
        return days >= Double(calibrationIntervalDays)
    }

    /// Manually start a calibration cycle now (from the Settings button).
    func calibrateNow() {
        guard helperStatus == .ready else { return }
        startCalibration()
    }

    /// Force a force-discharge state via the adapter (CHIE), independent of sailing mode.
    private func forceDischarge(_ on: Bool) async {
        guard let proxy = remoteProxy() else { return }
        let ok = await xpcBool { reply in proxy.setForceDischarge(on, reply: reply) }
        if ok {
            lastAdapterEnabled = !on
            lastToggleAt = Date()
        }
    }

    private func startCalibration() {
        guard !calibrationActive else { return }
        calibrationActive = true
        calibrationPhase = .discharge
        calibrationHoldStart = nil
        calibrationStartedAt = Date()
        Task { await forceDischarge(true) }   // begin by draining
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Battery Calibration"),
            message: String(localized: "Discharging, then a full charge to recalibrate the battery."),
            isWarning: false
        ))
    }

    /// Cancel an in-progress calibration and resume normal charging/limiting.
    func cancelCalibration() {
        guard calibrationActive else { return }
        calibrationActive = false
        calibrationHoldStart = nil
        calibrationStartedAt = nil
        DynamicIslandManager.shared.dismiss()   // clear the calibration alert immediately
        Task { await restoreCharging() }
    }

    /// Safety backstop: a calibration cycle ran far longer than any normal AC cycle
    /// should, so stop draining/holding and restore normal charging.
    private func abortCalibration() {
        calibrationActive = false
        calibrationHoldStart = nil
        calibrationStartedAt = nil
        Task { await restoreCharging() }
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Calibration Stopped"),
            message: String(localized: "Calibration took too long and was stopped. Charging has resumed."),
            isWarning: true
        ))
    }

    private func finishCalibration() {
        calibrationActive = false
        calibrationHoldStart = nil
        calibrationStartedAt = nil
        lastCalibration = Date()
        UserDefaults.standard.set(lastCalibration!.timeIntervalSince1970, forKey: "lastCalibration")
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Calibration Complete"),
            message: String(localized: "Battery recalibrated. Charge limit resumed."),
            isWarning: false
        ))
    }

    // MARK: - Fan control

    /// Queries fan hardware info from the helper and (re)applies the saved fan setting.
    func loadFanInfo() {
        guard let proxy = remoteProxy() else { return }
        proxy.getFanInfo { [weak self] count, minRPM, maxRPM in
            Task { @MainActor in
                guard let self else { return }
                self.fanCount = count
                self.fanMinRPM = minRPM
                self.fanMaxRPM = maxRPM
                if self.fanTargetRPM == 0 {
                    // Safe default ~40% of max, never 0 (0 RPM would stop the fan).
                    self.fanTargetRPM = maxRPM > 0 ? max(minRPM, Int(Double(maxRPM) * 0.4)) : 2500
                }
                if self.fanControlEnabled, count > 0 { await self.applyFan() }
            }
        }
    }

    private func applyFan() async {
        guard helperStatus == .ready, fanCount > 0, let proxy = remoteProxy() else { return }
        let manual = fanControlEnabled
        let rpm = min(max(fanTargetRPM, fanMinRPM), fanMaxRPM == 0 ? fanTargetRPM : fanMaxRPM)
        _ = await xpcBool { reply in proxy.setFanManual(manual, rpm: rpm, reply: reply) }
    }

    func restoreFanAuto() {
        guard let proxy = remoteProxy() else { return }
        proxy.setFanManual(false, rpm: 0) { _ in }
    }

    /// Failsafe: called with the hottest sensor reading. If fan control is forcing a
    /// manual speed while the Mac runs hot, revert to automatic so it can cool.
    // MARK: - Energy Mode

    /// Reads the current macOS Energy Mode from `pmset -g custom` (no root needed).
    func readEnergyMode() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "custom"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            // Use the AC ("AC Power") block if present, else whatever is reported.
            let low = lastValue(of: "lowpowermode", in: out)
            let high = lastValue(of: "highpowermode", in: out)
            highPowerSupported = out.contains("highpowermode")
            if high == 1 { energyMode = 2 }
            else if low == 1 { energyMode = 1 }
            else { energyMode = 0 }
        } catch {
            // pmset unavailable — leave defaults.
        }
    }

    private func lastValue(of key: String, in text: String) -> Int {
        var result = 0
        for line in text.split(separator: "\n") where line.contains(key) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let v = parts.last, let n = Int(v) { result = n }
        }
        return result
    }

    /// Applies an Energy Mode via the helper (needs root). 0=Auto, 1=Low, 2=High.
    func setEnergyMode(_ mode: Int) {
        guard helperStatus == .ready, let proxy = remoteProxy() else { return }
        let target = (mode == 2 && !highPowerSupported) ? 0 : mode
        energyMode = target
        proxy.setEnergyMode(target) { [weak self] _ in
            Task { @MainActor in self?.readEnergyMode() }
        }
    }

    func fanTemperatureCheck(maxTempC: Double) {
        guard fanControlEnabled, fanCount > 0, maxTempC >= fanFailsafeTempC else { return }
        fanControlEnabled = false   // didSet restores auto
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Fan Control Paused"),
            message: String(localized: "High temperature — fans returned to automatic."),
            isWarning: true
        ))
    }
}
