import Foundation
import AppKit
import ServiceManagement
import MacWakeShared

/// Pure safety rules shared by the calibration state machine and its regression tests.
enum CalibrationRecovery {
    static func shouldRestoreImmediately(batteryLevel: Int, dischargeFloor: Int) -> Bool {
        batteryLevel <= dischargeFloor
    }

    static func shouldForceDischarge(batteryLevel: Int, dischargeFloor: Int, adapterEnabled: Bool?) -> Bool {
        batteryLevel > dischargeFloor && adapterEnabled != false
    }

    static func restoreSucceeded(forceDischargeCleared: Bool, chargingEnabled: Bool) -> Bool {
        forceDischargeCleared && chargingEnabled
    }
}

/// Rules for holding a charge limit, kept pure so the floors can be tested without an SMC.
///
/// On Macs whose SMC exposes no charge-inhibit key, stopping charge means cutting adapter
/// input, so every "pause" here is a real discharge. Anything that pauses charging
/// therefore needs a floor, and nothing may delay the recovery direction.
enum ChargeHoldRules {
    /// Heat Guard used to pause charging with no lower bound, so on adapter-cut hardware a
    /// hot battery drained until it cooled — reported reaching 73% under an 80% limit.
    static func heatGuardShouldRestore(batteryLevel: Int, lowerBound: Int) -> Bool {
        batteryLevel <= lowerBound
    }

    /// The anti-flapping interval must gate only the stop direction. Rate-limiting a restore
    /// leaves the Mac draining on adapter power for another window, which is what let the
    /// level overshoot the lower bound.
    static func toggleIsRateLimited(chargingAllowed: Bool, sinceLastToggle: TimeInterval?,
                                    minimumInterval: TimeInterval) -> Bool {
        guard !chargingAllowed, let sinceLastToggle else { return false }
        return sinceLastToggle < minimumInterval
    }
}

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
            if !isEnabled {
                // A calibration in progress would otherwise be stranded: evaluate() bails
                // at its `isEnabled` guard, so calibrationActive never clears and even the
                // timeout backstop stops firing. Cancelling also restores charging.
                if calibrationActive { cancelCalibration() }
                else { Task { await self.restoreCharging() } }
            }
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

    /// One-shot "charge to 100% this once" override (e.g. before travel). Cleared
    /// automatically when the battery reaches 100% or on cancel; deliberately NOT
    /// persisted so a forgotten override can't outlive a relaunch.
    @Published var topUpActive = false

    // MARK: - Manual discharge

    /// Actively drain the battery on AC down to a chosen level. The limit alone can only
    /// stop charging, so a Mac that has sat plugged in at 95% has no way down without
    /// unplugging — this runs the adapter cut (CHIE) until the target is reached, then
    /// hands control straight back to the normal limit.
    @Published private(set) var dischargeActive = false
    @Published var dischargeTarget: Int {
        didSet {
            let clamped = min(95, max(dischargeFloor, dischargeTarget))
            if clamped != dischargeTarget { dischargeTarget = clamped; return }
            UserDefaults.standard.set(dischargeTarget, forKey: "dischargeTarget")
        }
    }
    /// Never drain below this, however low the user drags the slider.
    private let dischargeFloor = 20

    func startDischarge() {
        guard helperStatus == .ready, !dischargeActive else { return }
        dischargeActive = true
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Discharging"),
            message: String(format: String(localized: "DISCHARGE_STARTED_FMT"), dischargeTarget),
            isWarning: false
        ))
        Task { _ = await forceDischarge(true) }
    }

    func cancelDischarge() { finishDischarge(reachedTarget: false) }

    private func finishDischarge(reachedTarget: Bool) {
        guard dischargeActive else { return }
        dischargeActive = false
        Task { await restoreCharging() }
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Discharging"),
            message: reachedTarget
                ? String(format: String(localized: "DISCHARGE_DONE_FMT"), dischargeTarget)
                : String(localized: "Discharge cancelled. Charging resumed."),
            isWarning: false
        ))
    }

    /// Start/cancel the one-shot full charge.
    func topUp(_ on: Bool) {
        guard helperStatus == .ready else { return }
        topUpActive = on
        if on {
            Task { await restoreCharging() }   // clear any active charge block right away
            DynamicIslandManager.shared.trigger(.alert(
                title: String(localized: "Topping Up"),
                message: String(localized: "Charging to 100% this once, then the limit resumes."),
                isWarning: false
            ))
        }
        // On cancel the next evaluate() tick re-applies the normal limit.
    }

    /// Scheduled full charge: hold the normal limit overnight, then start charging early
    /// enough that the battery lands at 100% around the chosen time (e.g. "ready by 9:00").
    /// After the target window passes, normal limiting resumes automatically.
    @Published var scheduledChargeEnabled: Bool {
        didSet { UserDefaults.standard.set(scheduledChargeEnabled, forKey: "scheduledChargeEnabled") }
    }
    /// Minutes past midnight (local), e.g. 540 = 09:00.
    @Published var scheduledChargeMinutes: Int {
        didSet {
            let clamped = min(1439, max(0, scheduledChargeMinutes))
            if clamped != scheduledChargeMinutes { scheduledChargeMinutes = clamped; return }
            UserDefaults.standard.set(scheduledChargeMinutes, forKey: "scheduledChargeMinutes")
        }
    }
    /// True while inside the pre-target charge window (drives the UI status line).
    @Published private(set) var scheduledChargeActive = false
    private var scheduledChargeAnnounced = false

    /// Conservative start time: ~2.5 min per missing percent + 15 min buffer. Charging
    /// slows near 100%, so err on the early side — landing full a bit before the target
    /// beats landing at 92% when the user unplugs. The window opens `lead` before the
    /// target and stays open 2h past it, so a Mac that reaches 100% at 08:40 holds full
    /// through 09:00 instead of instantly drifting back down to the limit. Today's AND
    /// tomorrow's occurrences are both checked: today's covers the hold-past-target
    /// stretch after the time passes, tomorrow's covers leads that span midnight.
    /// The target we've committed to charging for, if any. Latching is essential: the
    /// lead is sized off `missing`, which shrinks as the battery fills, pushing the
    /// open-boundary (`target - lead`) LATER in real time. Without a latch, a Mac that
    /// charges faster than the clock re-crosses that moving boundary and stutters —
    /// pause/resume/pause near ~95% — flapping the SMC and Dynamic Island. Once the
    /// window opens for a target, we hold it open through the post-target window.
    private var scheduledWindowLatch: Date?

    private func scheduledChargeWindow(batteryLevel: Int, now: Date = Date()) -> Bool {
        guard scheduledChargeEnabled else { scheduledWindowLatch = nil; return false }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = scheduledChargeMinutes / 60
        comps.minute = scheduledChargeMinutes % 60
        guard let todayTarget = cal.date(from: comps) else { return false }

        let missing = max(0, 100 - batteryLevel)
        let leadSeconds = Double(missing) * 150 + 900

        for dayOffset in 0...1 {
            guard let target = cal.date(byAdding: .day, value: dayOffset, to: todayTarget) else { continue }
            let closeAt = target.addingTimeInterval(2 * 3600)
            // Already committed to this target and still within its window → stay open,
            // regardless of how far the shrinking lead has drifted the open-boundary.
            if scheduledWindowLatch == target, now <= closeAt {
                return true
            }
            if now >= target.addingTimeInterval(-leadSeconds), now <= closeAt {
                scheduledWindowLatch = target
                return true
            }
        }
        scheduledWindowLatch = nil
        return false
    }

    /// Heat Guard: pause charging while the battery runs hot (charging heat is a major
    /// driver of battery wear), resume automatically once it cools back down.
    @Published var heatGuardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(heatGuardEnabled, forKey: "heatGuardEnabled")
            if !heatGuardEnabled && heatGuardPaused { heatGuardPaused = false }
        }
    }
    @Published private(set) var heatGuardPaused = false
    private let heatGuardPauseTempC: Double = 40
    private let heatGuardResumeTempC: Double = 37   // hysteresis so it can't flap

    /// Called whenever a fresh battery temperature is read. Only flips the paused flag —
    /// evaluate() owns the actual SMC toggling, so all charging decisions stay in one place.
    func heatGuardCheck(batteryTempC: Double) {
        guard heatGuardEnabled, helperStatus == .ready, !calibrationActive else { return }
        if !heatGuardPaused, batteryTempC >= heatGuardPauseTempC {
            heatGuardPaused = true
            DynamicIslandManager.shared.trigger(.alert(
                title: String(localized: "Heat Guard"),
                message: String(format: String(localized: "HEATGUARD_PAUSED_FMT"), batteryTempC),
                isWarning: true
            ))
        } else if heatGuardPaused, batteryTempC <= heatGuardResumeTempC {
            heatGuardPaused = false
            DynamicIslandManager.shared.trigger(.alert(
                title: String(localized: "Heat Guard"),
                message: String(localized: "Battery cooled down — charging resumed."),
                isWarning: false
            ))
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
    // If the helper is unreachable (mid-restart, stuck, connection dropped), forceDischarge
    // retries every evaluate() tick with no bound otherwise — surface a stop instead of
    // silently retrying forever with no diagnostic.
    private var calibrationXPCFailureCount = 0
    private let calibrationXPCFailureLimit = 6

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

    /// True for as long as we are holding the adapter off ourselves (at the charge-limit
    /// ceiling, or during sailing/calibration force-discharge) — not just briefly after the
    /// toggle. macOS reports "on battery" in this state even though the cable is still
    /// physically connected; callers tracking continuous-AC time should treat this the same
    /// as plugged in, the same way `evaluate()`'s own `physicallyPlugged` check does.
    var isHoldingChargeOff: Bool { lastAdapterEnabled == false }

    private init() {
        let d = UserDefaults.standard
        self.isEnabled = d.bool(forKey: "chargeLimitEnabled")
        let savedLimit = d.integer(forKey: "chargeLimitValue")
        let lim = savedLimit == 0 ? 80 : min(95, max(50, savedLimit))
        self.limit = lim
        self.sailingEnabled = d.bool(forKey: "sailingEnabled")
        let savedLower = d.integer(forKey: "sailingLower")
        self.sailingLower = savedLower == 0 ? max(40, lim - 10) : min(lim - 5, max(40, savedLower))
        self.fanControlEnabled = d.bool(forKey: "fanControlEnabled")
        self.fanTargetRPM = d.integer(forKey: "fanTargetRPM")
        self.heatGuardEnabled = d.bool(forKey: "heatGuardEnabled")
        self.scheduledChargeEnabled = d.bool(forKey: "scheduledChargeEnabled")
        let savedSchedule = d.object(forKey: "scheduledChargeMinutes") as? Int
        self.scheduledChargeMinutes = savedSchedule.map { min(1439, max(0, $0)) } ?? 540   // default 09:00
        let savedDischarge = d.object(forKey: "dischargeTarget") as? Int
        self.dischargeTarget = savedDischarge.map { min(95, max(20, $0)) } ?? 60
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
            if holdCutsAdapter == nil { loadChargeControlMethod() }
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
                // Reuse the manual path rather than repeating the sequence: unregistering
                // while our XPC connection still holds the daemon leaves launchd with the
                // old job, and this copy had the invalidate *after* the re-register, so the
                // automatic reconcile silently did nothing. A machine could sit on an
                // outdated daemon indefinitely — which is exactly what the version constant
                // exists to prevent.
                _ = await self.forceReloadHelper()
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
    ///
    /// A failed write must NOT update `lastAdapterEnabled`: claiming the adapter is back
    /// while it's still cut makes the control loop believe there's nothing to do, and the
    /// Mac keeps running down the battery. Leaving the old state means the guard in
    /// evaluate() — and the calibration charge phase — retry on the next tick.
    @discardableResult
    private func restoreCharging() async -> Bool {
        guard let proxy = remoteProxy() else { return false }
        let dischargeCleared = await xpcBool { reply in
            proxy.setForceDischarge(false, reply: reply)
        }
        let chargingAllowed = await xpcBool { reply in
            proxy.setAdapterEnabled(true, reply: reply)
        }
        guard CalibrationRecovery.restoreSucceeded(
            forceDischargeCleared: dischargeCleared,
            chargingEnabled: chargingAllowed
        ) else { return false }
        lastAdapterEnabled = true
        lastToggleAt = Date()
        return true
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
        // Manual discharge outranks everything below: the user asked for a specific level
        // right now, so neither the standing limit nor Sailing Mode should fight it.
        if dischargeActive {
            if batteryLevel <= dischargeTarget {
                finishDischarge(reachedTarget: true)
            } else if lastAdapterEnabled != false {
                Task { _ = await forceDischarge(true) }
            }
            return
        }

        if calibrationActive {
            if let started = calibrationStartedAt, Date().timeIntervalSince(started) > calibrationMaxDuration {
                abortCalibration(reason: .timeout)
                return
            }
            switch calibrationPhase {
            case .discharge:
                if CalibrationRecovery.shouldRestoreImmediately(
                    batteryLevel: batteryLevel,
                    dischargeFloor: calibrationDischargeFloor
                ) {
                    // Restore power in THIS evaluation. Only flipping the phase here left
                    // the adapter cut until the next 30-second tick, and the battery kept
                    // draining through that window — reported reaching 8–9% on a 15% floor.
                    calibrationPhase = .charge
                    Task { await restoreCharging() }
                } else if CalibrationRecovery.shouldForceDischarge(
                    batteryLevel: batteryLevel,
                    dischargeFloor: calibrationDischargeFloor,
                    adapterEnabled: lastAdapterEnabled
                ) {
                    Task {
                        let ok = await forceDischarge(true)   // actively drain on AC
                        if ok {
                            self.calibrationXPCFailureCount = 0
                        } else {
                            self.calibrationXPCFailureCount += 1
                            if self.calibrationXPCFailureCount >= self.calibrationXPCFailureLimit {
                                self.abortCalibration(reason: .helperUnreachable)
                            }
                        }
                    }
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
        }

        // Heat Guard outranks Top Up and normal limiting (never outranks calibration —
        // heatGuardCheck skips while calibrating so a hot charge phase can't stall it
        // forever; the calibration timeout still applies).
        let lower = sailingEnabled ? sailingLower : (limit - hysteresis)

        if heatGuardPaused {
            // Where the SMC has no clean charge-inhibit key, "stop charging" cuts adapter
            // input and the battery genuinely drains. Heat Guard therefore needs a floor:
            // without one a hot battery kept discharging until it cooled, with no lower
            // bound at all — reported dropping to 73% under an 80% limit. A warm battery is
            // a smaller problem than an unbounded discharge, so at the floor we let it
            // charge again and leave Heat Guard to re-pause once it has room.
            if ChargeHoldRules.heatGuardShouldRestore(batteryLevel: batteryLevel, lowerBound: lower) {
                if lastAdapterEnabled != true { Task { await restoreCharging() } }
            } else if lastAdapterEnabled != false {
                Task { await applyChargingAllowed(false) }
            }
            return
        }

        // Scheduled full charge ("ready by 09:00"): inside the pre-target window, charge
        // to 100% like a Top Up; outside it, fall through to normal limiting.
        let inScheduledWindow = scheduledChargeWindow(batteryLevel: batteryLevel)
        if scheduledChargeActive != inScheduledWindow { scheduledChargeActive = inScheduledWindow }
        if inScheduledWindow {
            if !scheduledChargeAnnounced, batteryLevel < 100 {
                scheduledChargeAnnounced = true
                DynamicIslandManager.shared.trigger(.alert(
                    title: String(localized: "Scheduled Charge"),
                    message: String(localized: "Charging to 100% for your scheduled time."),
                    isWarning: false
                ))
            }
            if batteryLevel < 100, lastAdapterEnabled != true {
                Task { await restoreCharging() }
            }
            return
        } else {
            scheduledChargeAnnounced = false
        }

        // One-shot Top Up: charge past the limit to 100% this once (e.g. before travel),
        // then automatically resume normal limiting. Not persisted — a relaunch clears it.
        if topUpActive {
            if batteryLevel >= 100 {
                topUpActive = false
                DynamicIslandManager.shared.trigger(.alert(
                    title: String(localized: "Fully Charged"),
                    message: String(localized: "Top Up complete — the charge limit is back on."),
                    isWarning: false
                ))
                // fall through to normal limiting below
            } else {
                if lastAdapterEnabled != true { Task { await restoreCharging() } }
                return
            }
        }

        let shouldChargeAllowed: Bool
        if batteryLevel >= limit {
            shouldChargeAllowed = false                       // at/over ceiling → stop
        } else if batteryLevel <= lower {
            shouldChargeAllowed = true                        // dropped below band → resume
        } else {
            return                                            // inside band → hold / drift
        }

        guard lastAdapterEnabled != shouldChargeAllowed else { return }

        // Hard backstop against flapping — but only in the direction that stops charging.
        // Rate-limiting a *restore* leaves the Mac draining on AC for another window, which
        // is how the drop overshot the lower bound. Same mistake the calibration floor made.
        if ChargeHoldRules.toggleIsRateLimited(
            chargingAllowed: shouldChargeAllowed,
            sinceLastToggle: lastToggleAt.map { Date().timeIntervalSince($0) },
            minimumInterval: minToggleInterval
        ) {
            return
        }

        Task { await applyChargingAllowed(shouldChargeAllowed) }
    }

    // MARK: - Calibration


    /// Manually start a calibration cycle now (from the Settings button).
    func calibrateNow(batteryLevel: Int) {
        guard helperStatus == .ready else { return }
        startCalibration(batteryLevel: batteryLevel)
    }

    /// Force a force-discharge state via the adapter (CHIE), independent of sailing mode.
    @discardableResult
    private func forceDischarge(_ on: Bool) async -> Bool {
        guard let proxy = remoteProxy() else { return false }
        let ok = await xpcBool { reply in proxy.setForceDischarge(on, reply: reply) }
        if ok {
            lastAdapterEnabled = !on
            lastToggleAt = Date()
        }
        return ok
    }

    /// A battery already at or below the safety floor must never be drained further, so
    /// the discharge phase is skipped and the cycle starts by charging to 100%.
    private func startCalibration(batteryLevel: Int) {
        guard !calibrationActive else { return }
        let alreadyAtFloor = CalibrationRecovery.shouldRestoreImmediately(
            batteryLevel: batteryLevel,
            dischargeFloor: calibrationDischargeFloor
        )
        calibrationActive = true
        calibrationPhase = alreadyAtFloor ? .charge : .discharge
        calibrationHoldStart = nil
        calibrationStartedAt = Date()
        calibrationXPCFailureCount = 0
        if alreadyAtFloor {
            Task { await restoreCharging() }
        } else {
            Task { await forceDischarge(true) }   // begin by draining
        }
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Battery Calibration"),
            message: String(localized: alreadyAtFloor
                            ? "Charging to 100% to recalibrate the battery."
                            : "Discharging, then a full charge to recalibrate the battery."),
            isWarning: false
        ))
    }

    private func endCalibration() {
        calibrationActive = false
        calibrationHoldStart = nil
        calibrationStartedAt = nil
        calibrationXPCFailureCount = 0
        DynamicIslandManager.shared.dismiss()
    }

    /// Cancel an in-progress calibration and resume normal charging/limiting.
    func cancelCalibration() {
        guard calibrationActive else { return }
        endCalibration()
        Task { await restoreCharging() }
    }

    /// Sleep suspends the app-side control loop, so release forced discharge before
    /// the system can sleep past the calibration floor.
    func cancelCalibrationBeforeSleep() {
        guard calibrationActive else { return }
        endCalibration()
        restoreChargingSynchronously()
    }

    private func restoreChargingSynchronously() {
        guard let proxy = remoteProxy() else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var forceDischargeCleared = false
        var chargingEnabled = false
        proxy.setForceDischarge(false) { cleared in
            forceDischargeCleared = cleared
            proxy.setAdapterEnabled(true) { enabled in
                chargingEnabled = enabled
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + 2) == .success,
              CalibrationRecovery.restoreSucceeded(
                forceDischargeCleared: forceDischargeCleared,
                chargingEnabled: chargingEnabled
              ) else { return }
        lastAdapterEnabled = true
        lastToggleAt = Date()
    }

    private enum CalibrationAbortReason { case timeout, helperUnreachable }

    /// Safety backstop: either the cycle ran far longer than any normal AC cycle should
    /// (e.g. a genuine unplug mid-cycle), or the helper stopped responding to repeated
    /// force-discharge calls — either way, stop draining/holding and restore normal
    /// charging rather than retrying silently forever.
    private func abortCalibration(reason: CalibrationAbortReason) {
        calibrationActive = false
        calibrationHoldStart = nil
        calibrationStartedAt = nil
        calibrationXPCFailureCount = 0
        Task { await restoreCharging() }
        let message: String
        switch reason {
        case .timeout:
            message = String(localized: "Calibration took too long and was stopped. Charging has resumed.")
        case .helperUnreachable:
            message = String(localized: "Calibration was stopped because the helper stopped responding. Charging has resumed.")
        }
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Calibration Stopped"),
            message: message,
            isWarning: true
        ))
    }

    private func finishCalibration() {
        calibrationActive = false
        calibrationHoldStart = nil
        calibrationStartedAt = nil
        calibrationXPCFailureCount = 0
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

    /// True when the last attempt to force a fan speed didn't take on this Mac, so the UI
    /// can say so instead of leaving a slider that does nothing.
    /// Whether holding the limit on this Mac means cutting adapter input — i.e. the battery
    /// actually discharges — rather than inhibiting charge while staying on adapter power.
    /// `nil` until the helper has answered. Detected from SMC key availability per machine,
    /// so it cannot be inferred from the chip name.
    @Published private(set) var holdCutsAdapter: Bool?

    private func loadChargeControlMethod() {
        guard let proxy = remoteProxy() else { return }
        proxy.chargeControlMethod { [weak self] method in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // "none" leaves this nil: there is no hold to describe.
                if method.hasPrefix("adapter:") { self.holdCutsAdapter = true }
                else if method.hasPrefix("inhibit:") { self.holdCutsAdapter = false }
            }
        }
    }

    @Published private(set) var fanControlUnsupported = false

    private func applyFan() async {
        guard helperStatus == .ready, fanCount > 0, let proxy = remoteProxy() else { return }
        let manual = fanControlEnabled
        let rpm = min(max(fanTargetRPM, fanMinRPM), fanMaxRPM == 0 ? fanTargetRPM : fanMaxRPM)
        let applied = await xpcBool { reply in proxy.setFanManual(manual, rpm: rpm, reply: reply) }
        guard manual else { fanControlUnsupported = false; return }
        // The helper now verifies its own writes by reading the target back, so a false
        // here means this Mac's SMC refuses fan control — don't pretend it's on.
        fanControlUnsupported = !applied
        if !applied { fanControlEnabled = false }
    }

    func restoreFanAuto() {
        guard let proxy = remoteProxy() else { return }
        proxy.setFanManual(false, rpm: 0) { _ in }
    }

    /// Builds a copyable fan report and puts it on the pasteboard. Console logging proved
    /// useless for remote debugging — it can't tell you whether the daemon even reloaded —
    /// so this asks the running daemon directly and shows its answer, including the helper
    /// version actually serving XPC versus the one this app expects.
    func copyFanDiagnostics() async -> String {
        var report = """
        MacWake fan diagnostics
        app \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") \
        (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))
        expects helper v\(kMacWakeHelperVersion)
        helperStatus=\(helperStatus)
        fanCount=\(fanCount) min=\(fanMinRPM) max=\(fanMaxRPM)
        manualEnabled=\(fanControlEnabled) target=\(fanTargetRPM)

        """
        guard let proxy = remoteProxy() else {
            report += "XPC: no connection to the daemon"
            copyToPasteboard(report)
            return report
        }
        report += processStalenessReport() + "\n"
        var daemonReport = await askDaemonForDiagnostics(proxy)
        // A stale daemon can't answer, and asking the tester to press Reload first proved
        // unreliable — so remediate here and report both attempts.
        if daemonReport.hasPrefix("XPC:") {
            report += daemonReport + "\n\nforcing reload…\n"
            report += await forceReloadHelper() + "\n\n"
            if let fresh = remoteProxy() {
                daemonReport = await askDaemonForDiagnostics(fresh)
            } else {
                daemonReport = "XPC: no connection after reload"
            }
        }
        report += daemonReport
        copyToPasteboard(report)
        return report
    }

    private func askDaemonForDiagnostics(_ proxy: MacWakeHelperProtocol) async -> String {
        await withCheckedContinuation { cont in
            var resumed = false
            proxy.fanDiagnostics { text in
                guard !resumed else { return }; resumed = true
                cont.resume(returning: text)
            }
            // An old daemon has no fanDiagnostics selector: the call fails via the
            // connection's error handler, so don't hang the button forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                guard !resumed else { return }; resumed = true
                cont.resume(returning: "XPC: no reply in 20s — the running daemon is OLD (no fanDiagnostics).")
            }
        }
    }

    /// Compares when the running daemon process started against when the on-disk helper
    /// binary was last written. A process older than the binary is proof it's stale — the
    /// question no XPC call can answer once the daemon is too old to respond.
    private func processStalenessReport() -> String {
        #if !APPSTORE
        let helperPath = Bundle.main.bundlePath + "/Contents/MacOS/MacWakeHelper"
        let mtime = (try? FileManager.default.attributesOfItem(atPath: helperPath)[.modificationDate] as? Date) ?? nil

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid,lstart,comm"]
        let pipe = Pipe()
        p.standardOutput = pipe
        var line = "(daemon process not found)"
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            if let match = out.split(separator: "\n").first(where: { $0.contains("MacWakeHelper") }) {
                line = match.trimmingCharacters(in: .whitespaces)
            }
        }
        let mtimeText = mtime.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        return "on-disk helper mtime: \(mtimeText)\nrunning daemon: \(line)"
        #else
        return ""
        #endif
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Forces the daemon to be torn down and re-registered, regardless of version, and
    /// reports each step. Order matters: our live XPC connection keeps the old process
    /// alive, so it must be invalidated BEFORE unregistering, and launchd needs a moment
    /// to actually reap the job before a re-register loads the new binary. The previous
    /// version unregistered first and swallowed every error with `try?`, which is why a
    /// tester's daemon silently stayed on the original binary.
    @discardableResult
    func forceReloadHelper() async -> String {
        var log = ""
        connection?.invalidate()
        connection = nil
        log += "connection invalidated\n"

        do { try await service.unregister(); log += "unregister ok\n" }
        catch { log += "unregister FAILED: \(error.localizedDescription)\n" }

        // Wait for launchd to drop the job rather than assuming it's instant.
        for _ in 0..<20 {
            if service.status != .enabled { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        log += "status after unregister: \(service.status.rawValue)\n"

        do { try service.register(); log += "register ok\n" }
        catch { log += "register FAILED: \(error.localizedDescription)\n" }

        log += "status after register: \(service.status.rawValue)"
        refreshStatus()
        fanCount = 0
        loadFanInfo()
        return log
    }

    /// Failsafe: called with the hottest sensor reading. If fan control is forcing a
    /// manual speed while the Mac runs hot, revert to automatic so it can cool.
    // MARK: - Energy Mode

    /// Reads the current macOS Energy Mode from `pmset -g custom` (no root needed).
    /// Energy Mode is a helper-backed feature; the App Store build has no helper and can't
    /// spawn subprocesses in the sandbox, so this whole path (Process/pmset) is compiled out.
    func readEnergyMode() {
        #if !APPSTORE
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
        #endif
    }

    #if !APPSTORE
    private func lastValue(of key: String, in text: String) -> Int {
        var result = 0
        for line in text.split(separator: "\n") where line.contains(key) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let v = parts.last, let n = Int(v) { result = n }
        }
        return result
    }
    #endif

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
