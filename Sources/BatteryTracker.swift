import Foundation
import Cocoa
import IOKit.ps
import IOKit
import UserNotifications
import UniformTypeIdentifiers
import WidgetKit


extension Notification.Name {
    static let powerSourceChanged = Notification.Name("powerSourceChanged")
}

@MainActor
class BatteryTracker: ObservableObject {
    /// The app's single instance (a SwiftUI @StateObject), exposed for App Intents —
    /// same pattern as AppDelegate.shared. Weak: the view hierarchy owns it.
    static private(set) weak var sharedForIntents: BatteryTracker?

    @Published var currentBatteryLevel: Int = 100
    @Published var isPluggedIn: Bool = false
    @Published var currentSession: Session?
    @Published var history: [Session] = []
    @Published var chargeLimit: Int = 100
    /// This tick's raw ExternalChargeHold verdict — `nil` means nothing confirmed. Distinct
    /// from `chargeLimit` (which defaults display to 100) so ChargeLimitManager can drive
    /// its enforcing/yielded decision from the real signal, not a display convenience value.
    @Published var externalHoldPercent: Int?
    /// Recent samples for ExternalChargeHold, oldest first. ~3 minutes of history at the
    /// 30s heartbeat cadence — enough for the detector's stability window without holding
    /// a growing amount of history.
    private var externalHoldSamples: [ExternalChargeHold.Sample] = []
    @Published var appState: String = "active" // active, screenSleep, systemSleep, charging
    @Published var powerAdapterWatts: Int?
    @Published var dynamicWatts: Double?
    @Published var slowChargingAlert: String?
    @Published var powerAdapterName: String?
    @Published var isOriginalAppleAdapter: Bool = false
    @Published var batteryHealth: Int = 100
    @Published var rawBatteryHealth: Int?
    /// The capacity ratio before rounding, for the diagnostic readout. Never used as the
    /// headline value or on any summary surface.
    @Published var batteryHealthPrecise: Double?
    /// Recent capacity ratios, feeding the median behind the headline figure.
    private var healthSamples: [Double] = []
    /// When the headline last moved, so the once-a-day limit survives a relaunch.
    private var healthLastMovedAt: Date? {
        didSet { UserDefaults.standard.set(healthLastMovedAt, forKey: "healthLastMovedAt") }
    }
    @Published var batteryCycles: Int = 0
    @Published var batteryTemperature: Double = 0.0
    @Published var temperatureSamples: [Double] = []
    // System thermal sensors (Apple Silicon). nil = sensor not available on this Mac.
    @Published var cpuTemperature: Double? = nil
    @Published var gpuTemperature: Double? = nil
    @Published var ssdTemperature: Double? = nil
    @Published var adapterHistory: [PowerAdapterRecord] = []
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published var fanSpeedHistory: [FanSpeedSample] = []
    @Published var currentFanSpeed: Double? = nil
    @Published var hasFans: Bool = false
    @Published var healthHistory: [HealthRecord] = []
    @Published var continuousACAlert: Bool = false
    @Published var highTempAlert: Bool = false
    
    // Background tracking states
    private var lastTemperatureAlertSent: Date?
    private var acPowerStartTime: Date?
    private var lastContinuousACAlertSent: Date?
    
    @Published var showWidget: Bool = false {
        didSet {
            UserDefaults.standard.set(showWidget, forKey: "showWidget")
        }
    }
    @Published var isWidgetLocked: Bool = false {
        didSet {
            UserDefaults.standard.set(isWidgetLocked, forKey: "isWidgetLocked")
        }
    }
    @Published var enableAnimations: Bool = true {
        didSet {
            UserDefaults.standard.set(enableAnimations, forKey: "enableAnimations")
            if enableAnimations && isPluggedIn {
                startMenuBarAnimation()
            } else if !enableAnimations {
                stopMenuBarAnimation()
            }
        }
    }
    @Published var enableDynamicIsland: Bool = true {
        didSet {
            UserDefaults.standard.set(enableDynamicIsland, forKey: "enableDynamicIsland")
            DynamicIslandManager.shared.updateSettings(enabled: enableDynamicIsland)
            // The Shelf lives inside the island: with the island off there is no UI
            // surface for it AND its toggle row is hidden — never keep polling the
            // clipboard invisibly. Preference is preserved; polling resumes when the
            // island comes back on.
            ClipboardWatcher.shared.setEnabled(enableDynamicIsland && enableNotchShelf)
        }
    }
    /// Off by default — a trackpad click "thud" with no visible cause the first time you
    /// hover the notch is confusing for anyone who doesn't already know what it is.
    @Published var enableDynamicIslandHaptics: Bool = false {
        didSet {
            UserDefaults.standard.set(enableDynamicIslandHaptics, forKey: "enableDynamicIslandHaptics")
        }
    }
    /// On by default: the Shelf is what the expanded panel is for — a file drop tray and
    /// the last thing you copied. It does poll the clipboard, which is disclosed in the
    /// tour and in Settings, and switching it off stops the watcher entirely.
    @Published var enableNotchShelf: Bool = true {
        didSet {
            UserDefaults.standard.set(enableNotchShelf, forKey: "enableNotchShelf")
            ClipboardWatcher.shared.setEnabled(enableDynamicIsland && enableNotchShelf)
            DynamicIslandManager.shared.recomputeLayout()
        }
    }
    /// Custom low-battery warning (independent of macOS's built-in 10% alert).
    @Published var lowBatteryAlertEnabled: Bool = UserDefaults.standard.bool(forKey: "lowBatteryAlertEnabled") {
        didSet { UserDefaults.standard.set(lowBatteryAlertEnabled, forKey: "lowBatteryAlertEnabled") }
    }
    @Published var lowBatteryThreshold: Int = {
        let saved = UserDefaults.standard.integer(forKey: "lowBatteryThreshold")
        return saved == 0 ? 20 : min(50, max(5, saved))
    }() {
        didSet {
            let clamped = min(50, max(5, lowBatteryThreshold))
            if clamped != lowBatteryThreshold { lowBatteryThreshold = clamped; return }
            UserDefaults.standard.set(lowBatteryThreshold, forKey: "lowBatteryThreshold")
        }
    }
    /// One-shot latch so the alert fires once per discharge cycle, not every heartbeat.
    private var lowBatteryAlertFired = false

    @Published var animatedMenuBarIcon: String = "battery.100.bolt"
    @Published var usbPortInfo: String?

    // Menu-bar appearance (what the menu-bar item shows). Defaults match prior behaviour.
    @Published var showMenuBarIcon: Bool = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }
    @Published var showMenuBarPercent: Bool = UserDefaults.standard.object(forKey: "showMenuBarPercent") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showMenuBarPercent, forKey: "showMenuBarPercent") }
    }
    @Published var showMenuBarPower: Bool = UserDefaults.standard.object(forKey: "showMenuBarPower") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBarPower, forKey: "showMenuBarPower") }
    }
    @Published var showMenuBarTemp: Bool = UserDefaults.standard.object(forKey: "showMenuBarTemp") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBarTemp, forKey: "showMenuBarTemp") }
    }
    @Published var showMenuBarTimeRemaining: Bool = UserDefaults.standard.object(forKey: "showMenuBarTimeRemaining") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showMenuBarTimeRemaining, forKey: "showMenuBarTimeRemaining") }
    }
    /// Spend fewer characters on the same metrics. Off by default: the existing layout stays
    /// exactly as it was, and this only ever shortens — it never wraps or reorders anything.
    @Published var menuBarCompact: Bool = UserDefaults.standard.bool(forKey: "menuBarCompact") {
        didSet { UserDefaults.standard.set(menuBarCompact, forKey: "menuBarCompact") }
    }
    
    private var lastStateChange: Date = Date()
    private var heartbeatTimer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var batterySamples: [BatterySample] = []
    private var lastRapidDrainAlert: Date?
    private var menuBarAnimationTimer: Timer?
    private let menuBarAnimationFrames = ["battery.0", "battery.25", "battery.50", "battery.75", "battery.100"]
    private var menuBarAnimationIndex = 0
    
    // Structs for state serialization
    struct FanSpeedSample: Codable, Identifiable {
        var id = UUID()
        var timestamp: Date
        var rpm: Double
    }

    struct Event: Codable, Identifiable {
        var id = UUID()
        var timestamp: Date
        var type: String // "unplugged", "plugged", "screenSleep", "screenWake", "systemSleep", "systemWake", "boot", "shutdown"
        var battery: Int
    }

    struct Session: Codable, Identifiable {
        var id: UUID
        var startTime: Date
        var endTime: Date?
        var startBattery: Int
        var endBatteryLevel: Int?
        var screenOnDuration: TimeInterval
        var sleepDuration: TimeInterval
        var shutdownDuration: TimeInterval
        var events: [Event]
        
        var rebootCount: Int {
            events.filter { $0.type == "boot" }.count
        }
        
        // Helper to reconstruct timeline segments for visual charts
        func getTimelineSegments(currentAppState: String, lastStateChange: Date) -> [TimelineSegment] {
            var segments: [TimelineSegment] = []
            guard !events.isEmpty else { return [] }
            
            // Sort events by timestamp
            let sortedEvents = events.sorted { $0.timestamp < $1.timestamp }
            
            // Loop through events to build segments
            for i in 0..<sortedEvents.count {
                let currentEvent = sortedEvents[i]
                let start = currentEvent.timestamp
                let end: Date
                
                if i < sortedEvents.count - 1 {
                    end = sortedEvents[i + 1].timestamp
                } else {
                    // For the last event, segment runs to the current time or session end time
                    end = endTime ?? Date()
                }
                
                // Determine the state of this interval
                let state: String
                switch currentEvent.type {
                case "unplugged", "screenWake", "systemWake", "boot":
                    state = "active"
                case "screenSleep", "systemSleep":
                    state = "sleep"
                case "shutdown", "reboot", "logout":
                    state = "shutdown"
                case "plugged":
                    state = "charging"
                default:
                    state = "unknown"
                }
                
                // Only add segments that have positive duration
                if end.timeIntervalSince(start) > 0 {
                    segments.append(TimelineSegment(startTime: start, endTime: end, state: state))
                }
            }
            
            return segments
        }
    }

    struct TimelineSegment: Identifiable {
        var id = UUID()
        var startTime: Date
        var endTime: Date
        var state: String // active, sleep, shutdown, charging
    }

    struct BatterySample: Codable, Identifiable {
        var id = UUID()
        var timestamp: Date
        var level: Int
    }

    struct PowerAdapterRecord: Codable, Identifiable {
        var id = UUID()
        var firstSeen: Date
        var lastSeen: Date
        var watts: Int
        var name: String?
        var seenCount: Int
        var manufacturer: String?

        var displayName: String {
            if let name = name {
                if name.contains("\(watts)W") || name.contains("\(watts) W") {
                    return name
                } else {
                    return "\(watts)W \(name)"
                }
            } else {
                return "\(watts)W"
            }
        }
    }

    struct HealthRecord: Codable, Identifiable {
        var id = UUID()
        var date: Date
        var health: Int
        var cycleCount: Int
    }

    struct GoalProgress: Identifiable {
        var id: String { title }
        var title: String
        var target: TimeInterval
        var actual: TimeInterval

        var progress: Double {
            guard target > 0 else { return 0 }
            return min(1, actual / target)
        }

        var isComplete: Bool {
            actual >= target
        }
    }

    struct PersistedData: Codable {
        var currentSession: Session?
        var history: [Session]
        var appState: String
        var lastStateChange: Date
        var lastHeartbeat: Date
        var batterySamples: [BatterySample]?
        var adapterHistory: [PowerAdapterRecord]?
        var lastRapidDrainAlert: Date?
        var fanSpeedHistory: [FanSpeedSample]?
        var healthHistory: [HealthRecord]?
        var acPowerStartTime: Date?
    }

    private var dataURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("MacWake")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        return folder.appendingPathComponent("data.json")
    }

    init() {
        BatteryTracker.sharedForIntents = self
        loadSettings()
        loadData()
        setupPowerMonitoring()
        setupWorkspaceNotifications()
        refreshNotificationStatus()
        startHeartbeat()
        
        // Check power status immediately
        initializePowerStatus()
        updatePowerAdapterDetails()
        recordBatterySample(level: currentBatteryLevel, timestamp: Date())
        updateFanSpeed()
        
        // Setup desktop widget manager
        WidgetManager.shared.setup(with: self)
        
        // Setup Dynamic Island manager — deferred to allow SwiftUI view hierarchy to fully initialize first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            DynamicIslandManager.shared.setup(with: self)
        }
    }

    private func updateFanSpeed() {
        // Fan/thermal reads go through the SMC, which the App Store sandbox blocks (and
        // AppleSMC access trips App Store's private-API scanner) — so this is compiled
        // out entirely on that build. hasFans stays false, currentFanSpeed nil.
        #if !APPSTORE
        let fanCount = SMCHelper.getFanCount()
        self.hasFans = fanCount > 0

        if fanCount > 0 {
            if let rpm = SMCHelper.getFanSpeed(fanIndex: 0) {
                self.currentFanSpeed = rpm

                let now = Date()
                if fanSpeedHistory.isEmpty || now.timeIntervalSince(fanSpeedHistory.last!.timestamp) >= 30 {
                    fanSpeedHistory.append(FanSpeedSample(timestamp: now, rpm: rpm))

                    if fanSpeedHistory.count > 120 {
                        fanSpeedHistory.removeFirst()
                    }
                }
            } else {
                self.currentFanSpeed = nil
            }
        } else {
            self.currentFanSpeed = nil
        }

        updateSystemSensors()
        #endif
    }

    #if !APPSTORE
    private func updateSystemSensors() {
        let sensors = ThermalSensors.shared
        guard sensors.isAvailable else { return }
        self.cpuTemperature = sensors.cpuTemperature
        self.gpuTemperature = sensors.gpuTemperature
        self.ssdTemperature = sensors.ssdTemperature

        // Fan-control safety failsafe: hand fans back to the system if it runs hot.
        let maxTemp = max(cpuTemperature ?? 0, gpuTemperature ?? 0, batteryTemperature)
        ChargeLimitManager.shared.fanTemperatureCheck(maxTempC: maxTemp)
    }
    #endif

    private func initializePowerStatus() {
        let level = getBatteryLevel()
        let plugged = isACPowerConnected()
        
        self.currentBatteryLevel = level
        self.isPluggedIn = plugged
        self.appState = plugged ? "charging" : "active"
        
        // Start menu bar animation if already plugged in
        if plugged {
            if enableAnimations {
                startMenuBarAnimation()
            }
            if acPowerStartTime == nil {
                acPowerStartTime = Date()
            }
        } else {
            acPowerStartTime = nil
            continuousACAlert = false
        }
        
        // If we are on battery and don't have a session, start one
        if !plugged && currentSession == nil {
            let now = Date()
            let newSession = Session(
                id: UUID(),
                startTime: now,
                endTime: nil,
                startBattery: level,
                endBatteryLevel: nil,
                screenOnDuration: 0,
                sleepDuration: 0,
                shutdownDuration: 0,
                events: [Event(timestamp: now, type: "unplugged", battery: level)]
            )
            self.currentSession = newSession
            self.lastStateChange = now
            saveData()
            print("First-run initialization: Started battery session at \(level)%")
        }
    }
    
    deinit {
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
    
    // Read macOS Golden Gate user charge limit
    func loadSettings() {
        // Restore the once-a-day limit; without this every relaunch would let the headline
        // move again, which is how a jittering value got back into the history.
        self.healthLastMovedAt = UserDefaults.standard.object(forKey: "healthLastMovedAt") as? Date
        self.showWidget = UserDefaults.standard.bool(forKey: "showWidget")
        self.isWidgetLocked = UserDefaults.standard.bool(forKey: "isWidgetLocked")
        if UserDefaults.standard.object(forKey: "enableAnimations") != nil {
            self.enableAnimations = UserDefaults.standard.bool(forKey: "enableAnimations")
        } else {
            self.enableAnimations = true
        }
        if UserDefaults.standard.object(forKey: "enableDynamicIsland") != nil {
            self.enableDynamicIsland = UserDefaults.standard.bool(forKey: "enableDynamicIsland")
        } else {
            self.enableDynamicIsland = true
        }
        self.enableDynamicIslandHaptics = UserDefaults.standard.bool(forKey: "enableDynamicIslandHaptics")
        // Guarded (unlike the simple assignments above) since this property's didSet does
        // real work (repositions the Dynamic Island window) — loadSettings() is called on
        // every heartbeat/power-status update, so an unconditional assignment would redo
        // that work every ~30s for no reason.
        // Only honour a stored value that actually exists: bool(forKey:) reports false for
        // a missing key, which would silently override the on-by-default Shelf on every
        // fresh install and for anyone who never touched the switch.
        if UserDefaults.standard.object(forKey: "enableNotchShelf") != nil {
            let storedNotchShelf = UserDefaults.standard.bool(forKey: "enableNotchShelf")
            if storedNotchShelf != enableNotchShelf {
                self.enableNotchShelf = storedNotchShelf
            }
        }
    }

    /// Rolling "last known-good" backup of data.json, refreshed on every successful save
    /// (see saveData()) so a corrupt/truncated data.json can actually be recovered from.
    private var backupDataURL: URL {
        dataURL.deletingPathExtension().appendingPathExtension("json.bak")
    }

    // Load data from file and perform recovery check
    private func loadData() {
        guard FileManager.default.fileExists(atPath: dataURL.path) else { return }
        if applyPersistedData(from: dataURL) {
            saveData() // persist the cleaned-up data (dedup'd history, reboot recovery, etc.)
            return
        }
        print("Failed to decode data.json — attempting recovery from backup")
        if applyPersistedData(from: backupDataURL) {
            print("Recovered history from data.json.bak")
            saveData()
            return
        }
        // Neither file decodes. Preserve the corrupt file for diagnostics and continue
        // with empty in-memory state rather than silently losing it with no trace.
        let corruptURL = dataURL.deletingPathExtension().appendingPathExtension("json.corrupt")
        try? FileManager.default.removeItem(at: corruptURL)
        try? FileManager.default.copyItem(at: dataURL, to: corruptURL)
    }

    /// Decodes `PersistedData` from `url` and applies it (including the reboot-recovery
    /// and history-cleanup passes). Returns false — leaving current state untouched — on
    /// any decode error, so the caller can fall back to an alternate source.
    private func applyPersistedData(from url: URL) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let persisted = try decoder.decode(PersistedData.self, from: data)
            self.history = persisted.history
            self.currentSession = persisted.currentSession
            self.appState = persisted.appState
            self.lastStateChange = persisted.lastStateChange
            self.batterySamples = persisted.batterySamples ?? []
            self.adapterHistory = persisted.adapterHistory ?? []
            self.lastRapidDrainAlert = persisted.lastRapidDrainAlert
            self.fanSpeedHistory = persisted.fanSpeedHistory ?? []
            self.healthHistory = Self.pruneNormalisedHealthEntries(persisted.healthHistory ?? [])
            self.acPowerStartTime = persisted.acPowerStartTime

            // Recovery Check: If there is an active session, check if we rebooted
            if var session = self.currentSession {
                if let bootTime = getSystemBootTime(), bootTime > persisted.lastHeartbeat {
                    print("System reboot detected. Boot time: \(bootTime), Last Heartbeat: \(persisted.lastHeartbeat)")

                    // 1. Close active tracking segment up to last heartbeat
                    let gap = persisted.lastHeartbeat.timeIntervalSince(persisted.lastStateChange)
                    if gap > 0 {
                        if persisted.appState == "active" {
                            session.screenOnDuration += gap
                        } else if persisted.appState == "screenSleep" || persisted.appState == "systemSleep" {
                            session.sleepDuration += gap
                        }
                    }

                    // 2. The time between last heartbeat and boot was shutdown
                    let shutdownGap = bootTime.timeIntervalSince(persisted.lastHeartbeat)
                    if shutdownGap > 0 {
                        session.shutdownDuration += shutdownGap
                    }

                    // 3. Log shutdown and boot events (avoid duplicates if already cleanly logged)
                    if session.events.last?.type != "shutdown" && session.events.last?.type != "reboot" && session.events.last?.type != "logout" {
                        session.events.append(Event(timestamp: persisted.lastHeartbeat, type: "shutdown", battery: session.events.last?.battery ?? 100))
                    }
                    session.events.append(Event(timestamp: bootTime, type: "boot", battery: getBatteryLevel()))

                    self.currentSession = session
                    self.lastStateChange = Date() // Fix: Start tracking from current launch time, not bootTime
                    self.appState = "active" // assume active on boot
                }
            }

            // Clean up any incorrect or low power adapter records (e.g., < 5W) from history
            self.adapterHistory.removeAll(where: { $0.watts < 5 })

            // Remove duplicate sessions from history (keeping only the first/most recent occurrence of each ID)
            var uniqueHistory: [Session] = []
            var seenIds = Set<UUID>()
            for session in self.history {
                if !seenIds.contains(session.id) {
                    uniqueHistory.append(session)
                    seenIds.insert(session.id)
                }
            }
            self.history = uniqueHistory
            return true
        } catch {
            print("Failed to decode \(url.lastPathComponent): \(error)")
            return false
        }
    }

    private func saveData() {
        let persisted = PersistedData(
            currentSession: currentSession,
            history: history,
            appState: appState,
            lastStateChange: lastStateChange,
            lastHeartbeat: Date(),
            batterySamples: batterySamples,
            adapterHistory: adapterHistory,
            lastRapidDrainAlert: lastRapidDrainAlert,
            fanSpeedHistory: fanSpeedHistory,
            healthHistory: healthHistory,
            acPowerStartTime: acPowerStartTime
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(persisted)
            // Keep a known-good backup one generation behind before overwriting, so a
            // crash/power-loss mid-write (data.json is rewritten every ~30s) leaves a
            // real recovery path instead of just a corrupt file (see loadData()).
            if FileManager.default.fileExists(atPath: dataURL.path) {
                try? FileManager.default.removeItem(at: backupDataURL)
                try? FileManager.default.copyItem(at: dataURL, to: backupDataURL)
            }
            try data.write(to: dataURL, options: .atomic)
        } catch {
            print("Failed to save data.json: \(error)")
        }
    }

    private func getSystemBootTime() -> Date? {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctl(&mib, u_int(mib.count), &bootTime, &size, nil, 0)
        if result == 0 {
            return Date(timeIntervalSince1970: Double(bootTime.tv_sec) + Double(bootTime.tv_usec) / 1_000_000.0)
        }
        return nil
    }

    // Monitor Power Source changes
    private func setupPowerMonitoring() {
        let opaqueTracker = Unmanaged.passUnretained(self).toOpaque()
        let runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let tracker = Unmanaged<BatteryTracker>.fromOpaque(context).takeUnretainedValue()
            
            // Run on MainActor since tracker is a MainActor class
            Task { @MainActor in
                tracker.updatePowerStatus()
            }
        }, opaqueTracker).takeRetainedValue()
        
        self.powerSourceRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    /// Appends a sample and recomputes `chargeLimit` from the rolling window. Called
    /// wherever level/plugged are freshly read, so the detector never lags behind the
    /// values already being shown elsewhere in the UI.
    private func recordExternalHoldSample(level: Int, plugged: Bool) {
        let sample = ExternalChargeHold.Sample(
            externallyConnected: plugged,
            isCharging: getIsCharging(),
            percent: level,
            macWakeIsHolding: ChargeLimitManager.shared.isHoldingChargeOff
        )
        externalHoldSamples.append(sample)
        if externalHoldSamples.count > 6 {
            externalHoldSamples.removeFirst(externalHoldSamples.count - 6)
        }
        let detected = ExternalChargeHold.detect(recentSamples: externalHoldSamples)
        externalHoldPercent = detected
        chargeLimit = detected ?? 100
    }

    private func updatePowerStatus() {
        loadSettings() // reload charge limit in case it changed
        let level = getBatteryLevel()
        let plugged = isACPowerConnected()
        
        let oldPlugged = self.isPluggedIn
        self.currentBatteryLevel = level
        self.isPluggedIn = plugged
        updatePowerAdapterDetails()
        recordBatterySample(level: level, timestamp: Date())
        recordExternalHoldSample(level: level, plugged: plugged)
        ChargeLimitManager.shared.evaluate(batteryLevel: level, isPluggedIn: plugged, externalHoldPercent: externalHoldPercent)
        
        // A charge-limit/sailing/calibration-induced adapter cutoff makes macOS report
        // "on battery" even though the cable is still attached — don't let that reset the
        // continuous-AC clock, or the "plugged in all day" reminder can never fire for
        // anyone running at the charge-limit ceiling.
        let physicallyPlugged = plugged || ChargeLimitManager.shared.isHoldingChargeOff
        if physicallyPlugged {
            if acPowerStartTime == nil {
                acPowerStartTime = Date()
            }
        } else {
            acPowerStartTime = nil
            continuousACAlert = false
        }
        
        if oldPlugged != plugged {
            // Suppress UI effects when the charge limiter itself flipped the adapter
            // (CHIE toggle looks like a plug/unplug but the user didn't touch the cable).
            let inducedByLimiter = ChargeLimitManager.shared.didInducePowerChange(within: 4)

            handlePowerSourceChange(toPlugged: plugged, batteryLevel: level)

            if !inducedByLimiter {
                // Handle animations on power state change
                if plugged {
                    DynamicIslandManager.shared.trigger(.charging)
                    if enableAnimations {
                        ChargingAnimationManager.shared.show(batteryLevel: level)
                        startMenuBarAnimation()
                    }
                } else {
                    stopMenuBarAnimation()
                }
            }
        }
    }

    private func getBatteryLevel() -> Int {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int
                let maxCapacity = description[kIOPSMaxCapacityKey] as? Int
                return (currentCapacity ?? 0) * 100 / max(1, maxCapacity ?? 100)
            }
        }
        return 100
    }

    private func getIsCharging() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                return description[kIOPSIsChargingKey] as? Bool ?? false
            }
        }
        return false
    }

    private func isACPowerConnected() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                if let state = description[kIOPSPowerSourceStateKey] as? String {
                    return state == kIOPSACPowerValue
                }
            }
        }
        return false
    }

    private func updatePowerAdapterDetails() {
        guard isACPowerConnected(),
              let unmanagedDetails = IOPSCopyExternalPowerAdapterDetails(),
              let details = unmanagedDetails.takeRetainedValue() as? [String: Any] else {
            powerAdapterWatts = nil
            powerAdapterName = nil
            isOriginalAppleAdapter = false
            // Battery temperature, cycle count, health, and discharge rate are
            // valid on battery too — keep refreshing them while unplugged.
            updateDynamicWatts()
            return
        }

        powerAdapterWatts = details["Watts"] as? Int
        powerAdapterName = details["Name"] as? String
        
        if let manufacturer = details["Manufacturer"] as? String {
            isOriginalAppleAdapter = manufacturer.lowercased().contains("apple")
        } else {
            isOriginalAppleAdapter = false
        }
        
        recordPowerAdapterIfNeeded()
        updateDynamicWatts()
        updateUSBPortInfo()
    }

    func updateDynamicWatts() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
        guard service != 0 else {
            dynamicWatts = nil
            slowChargingAlert = nil
            return
        }
        defer { IOObjectRelease(service) }
        
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        
        var wattsVal: Double? = nil
        if result == kIOReturnSuccess, let dict = properties?.takeRetainedValue() as? [String: Any] {
            // Read Temperature: IORegistry key (Intel Macs) or SMC TB0T (Apple Silicon).
            // SMC fallback is compiled out on the App Store build (sandbox/private-API).
            let rawTemp: Double?
            if let tempRaw = dict["Temperature"] as? Int {
                rawTemp = Double(tempRaw) / 100.0
            } else {
                #if !APPSTORE
                rawTemp = SMCHelper.getBatteryTemperature()
                #else
                rawTemp = nil
                #endif
            }
            if let temp = rawTemp, temp > -40 {
                batteryTemperature = temp
                temperatureSamples.append(temp)
                if temperatureSamples.count > 5 {
                    temperatureSamples.removeFirst()
                }
                ChargeLimitManager.shared.heatGuardCheck(batteryTempC: temp)
            }
            
            // Read CycleCount
            if let cycles = dict["CycleCount"] as? Int {
                batteryCycles = cycles
            }
            
            updateBatteryHealth(from: dict)
            
            // Calculate dynamic watts whether plugged in or not
            var calculatedWatts: Double = 0
            
            // 1. Try to get total system power in (Adapter draw)
            if let telemetry = dict["PowerTelemetryData"] as? [String: Any],
               let systemPowerIn = telemetry["SystemPowerIn"] as? NSNumber {
                calculatedWatts = systemPowerIn.doubleValue / 1000.0
            }
            
            // 2. If Adapter draw is near 0 (e.g., unplugged, or system cut off adapter power to discharge), 
            // fallback to battery discharge/charge rate
            if calculatedWatts < 1.0 {
                if let amperage = dict["InstantAmperage"] as? NSNumber,
                   let voltage = dict["Voltage"] as? NSNumber {
                    let watts = abs(amperage.doubleValue) * voltage.doubleValue / 1000000.0
                    calculatedWatts = max(calculatedWatts, watts)
                }
            }
            
            if calculatedWatts > 0 {
                wattsVal = calculatedWatts
            }
        }
        
        dynamicWatts = wattsVal
        checkAndRecordHealthHistory()
        checkTemperatureAlert()
        checkContinuousACAlert()
        checkSlowCharging()
        checkLowBatteryAlert()
        updateWidgetSnapshot()
    }

    /// Drops the bogus 100% rows the old MaxCapacity reading wrote into the decay log.
    /// Capacity doesn't recover, so a jump UP to exactly 100 from a materially lower
    /// reading was the normalised value, not a real measurement — one user's log ran
    /// 84% → 100% at an unchanged cycle count. Small upward wobble (recalibration) is
    /// left alone.
    private static func pruneNormalisedHealthEntries(_ records: [HealthRecord]) -> [HealthRecord] {
        var cleaned: [HealthRecord] = []
        for record in records {
            if record.health == 100, let previous = cleaned.last, previous.health < 95 { continue }
            cleaned.append(record)
        }
        return cleaned
    }

    private func updateBatteryHealth(from dict: [String: Any]) {
        // Where the real capacities live moved on Apple Silicon: some Macs still expose
        // them at the top level, others (M4 on macOS 26) only inside BatteryData, while
        // the top-level MaxCapacity is a normalised 100 on both. Look in both places or
        // the ratio silently goes missing and the normalised value takes over.
        let nested = dict["BatteryData"] as? [String: Any]
        func capacity(_ key: String) -> Int? {
            (dict[key] as? Int) ?? (nested?[key] as? Int)
        }
        let design = capacity("DesignCapacity")
        let nominalMax = capacity("NominalChargeCapacity")
        let rawMax = capacity("AppleRawMaxCapacity") ?? capacity("FullChargeCapacity")

        let ratio = BatteryHealthMath.ratio(nominal: nominalMax, liveMax: rawMax, design: design)

        batteryHealthPrecise = ratio?.value
        rawBatteryHealth = ratio.map { Int($0.value.rounded(.down)) }

        // Capacity ratio first. On Apple Silicon AppleSmartBattery's MaxCapacity is a
        // normalised value macOS pins at 100 regardless of wear — trusting it reported
        // 100% health on an 82%-worn battery while the raw ratio right below it was
        // correct. Keep MaxCapacity only as a last resort for Macs that expose no
        // capacity pair (older Intel models report it as a real percentage there).
        if let ratio {
            healthSamples.append(ratio.value)
            if healthSamples.count > BatteryHealthMath.sampleWindow {
                healthSamples.removeFirst(healthSamples.count - BatteryHealthMath.sampleWindow)
            }
            let now = Date()
            let settled = BatteryHealthMath.headline(
                samples: healthSamples,
                current: batteryHealth,
                lastMoved: healthLastMovedAt,
                now: now
            )
            if settled != batteryHealth {
                batteryHealth = settled
                healthLastMovedAt = now
            }
        } else if let reportedMaxCapacity = dict["MaxCapacity"] as? Int,
                  (0...100).contains(reportedMaxCapacity) {
            batteryHealth = reportedMaxCapacity
        }
    }

    /// Re-reads battery health/cycles on demand and logs a new decay entry if it changed.
    func recheckBatteryHealth() {
        updatePowerAdapterDetails()
    }

    private func checkAndRecordHealthHistory() {
        let currentHealth = self.batteryHealth
        let currentCycles = self.batteryCycles
        let now = Date()
        
        if healthHistory.isEmpty {
            healthHistory.append(HealthRecord(date: now, health: currentHealth, cycleCount: currentCycles))
            saveData()
        } else if let last = healthHistory.last, last.health != currentHealth {
            healthHistory.append(HealthRecord(date: now, health: currentHealth, cycleCount: currentCycles))
            saveData()
        }
    }
    
    /// Custom low-battery warning ahead of macOS's own 10% alert. Fires once per
    /// discharge cycle: re-arms when the Mac is plugged in or climbs 5 points back
    /// above the threshold (so hovering right at the threshold can't spam).
    private func checkLowBatteryAlert() {
        guard lowBatteryAlertEnabled else { return }
        let level = currentBatteryLevel
        let plugged = isPluggedIn || isACPowerConnected()

        if plugged || level > lowBatteryThreshold + 5 {
            lowBatteryAlertFired = false
            return
        }
        guard level <= lowBatteryThreshold, !lowBatteryAlertFired else { return }
        lowBatteryAlertFired = true
        Analytics.signal("alert.lowBattery")
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Low Battery"),
            message: String(format: String(localized: "LOW_BATTERY_FMT"), level),
            isWarning: true
        ))
        sendNotification(
            title: String(localized: "🪫 Low Battery"),
            body: String(format: String(localized: "LOW_BATTERY_BODY_FMT"), level)
        )
    }

    private func checkTemperatureAlert() {
        let temp = self.batteryTemperature
        if temp > 42.0 && (isPluggedIn || isACPowerConnected()) {
            if !highTempAlert {
                highTempAlert = true
                Analytics.signal("alert.highTemperature", parameters: ["temperature": String(format: "%.1f", temp)])
                DynamicIslandManager.shared.trigger(.alert(
                    title: String(localized: "High Battery Temperature"),
                    message: String(format: String(localized: "TEMP_REACHED_FMT"), temp),
                    isWarning: false
                ))
            }
            let now = Date()
            if lastTemperatureAlertSent == nil || now.timeIntervalSince(lastTemperatureAlertSent!) > 7200 {
                lastTemperatureAlertSent = now
                sendNotification(
                    title: String(localized: "⚠️ Battery Temperature High"),
                    body: String(format: String(localized: "TEMP_HIGH_BODY_FMT"), temp)
                )
            }
        } else {
            highTempAlert = false
        }
    }
    
    private func checkContinuousACAlert() {
        guard let startTime = acPowerStartTime else {
            continuousACAlert = false
            return
        }
        
        let duration = Date().timeIntervalSince(startTime)
        if duration >= 86400.0 && currentBatteryLevel >= 99 {
            if !continuousACAlert {
                continuousACAlert = true
                Analytics.signal("alert.pluggedInAllDay")
                DynamicIslandManager.shared.trigger(.alert(
                    title: String(localized: "Plugged In All Day"),
                    message: String(localized: "Your Mac has been plugged in for 24 hours. Discharge the battery."),
                    isWarning: true
                ))
            }
            let now = Date()
            if lastContinuousACAlertSent == nil || now.timeIntervalSince(lastContinuousACAlertSent!) > 86400 {
                lastContinuousACAlertSent = now
                sendNotification(
                    title: String(localized: "🔌 Always On Power"),
                    body: String(localized: "Your Mac has been plugged in and fully charged for 24 hours. Discharge the battery occasionally to protect battery health.")
                )
            }
        } else {
            continuousACAlert = false
        }
    }

    private func checkSlowCharging() {
        guard isPluggedIn || isACPowerConnected(),
              let watts = powerAdapterWatts,
              let dyn = dynamicWatts,
              currentBatteryLevel < 80 else {
            slowChargingAlert = nil
            return
        }
        
        // Define slow charging thresholds (extremely conservative to avoid false positives):
        // 1. If adapter is 80W+, and drawing less than 20W
        // 2. If adapter is 45W-79W, and drawing less than 12W
        // 3. If adapter is 30W-44W, and drawing less than 8W
        var isSlow = false
        if watts >= 80 && dyn < 20.0 {
            isSlow = true
        } else if watts >= 45 && watts < 80 && dyn < 12.0 {
            isSlow = true
        } else if watts >= 30 && watts < 45 && dyn < 8.0 {
            isSlow = true
        }
        
        if isSlow {
            slowChargingAlert = String(format: String(localized: "SLOW_CHARGING_FMT"), watts, dyn)
        } else {
            slowChargingAlert = nil
        }
    }

    private func recordPowerAdapterIfNeeded() {
        guard isPluggedIn, let watts = powerAdapterWatts else { return }
        guard watts >= 5 else { return } // Ignore very low power/unreliable adapter readings (e.g. 3W)

        let now = Date()
        let name = powerAdapterName
        
        var manufacturer: String? = nil
        if let unmanagedDetails = IOPSCopyExternalPowerAdapterDetails(),
           let details = unmanagedDetails.takeRetainedValue() as? [String: Any] {
            manufacturer = details["Manufacturer"] as? String
        }

        // Match on watts + name exactly (nil == nil is fine — two unnamed same-wattage
        // adapters can't be told apart anyway). The old `|| $0.name == nil || name == nil`
        // leniency merged a NAMED adapter into an unrelated UNNAMED one of the same
        // wattage (or vice versa), corrupting the displayed history.
        if let existingIndex = adapterHistory.firstIndex(where: {
            $0.watts == watts && $0.name == name
        }) {
            // If the existing record had no manufacturer but we now have one, update it
            if adapterHistory[existingIndex].manufacturer == nil && manufacturer != nil {
                adapterHistory[existingIndex].manufacturer = manufacturer
            }
            adapterHistory[existingIndex].lastSeen = now
            adapterHistory[existingIndex].seenCount += 1
            let record = adapterHistory.remove(at: existingIndex)
            adapterHistory.insert(record, at: 0)
        } else {
            adapterHistory.insert(
                PowerAdapterRecord(
                    firstSeen: now,
                    lastSeen: now,
                    watts: watts,
                    name: name,
                    seenCount: 1,
                    manufacturer: manufacturer
                ),
                at: 0
            )
        }

        if adapterHistory.count > 8 {
            adapterHistory.removeLast(adapterHistory.count - 8)
        }
    }

    // Handle plugging/unplugging
    private func handlePowerSourceChange(toPlugged plugged: Bool, batteryLevel: Int) {
        // Ignore self-induced adapter flips from the charge limiter. CHIE toggling
        // looks like unplug/plug, but the cable never moved — so it must not start or
        // close tracking sessions, or history fills with junk while holding the limit.
        if ChargeLimitManager.shared.didInducePowerChange(within: 4) {
            if plugged { updatePowerAdapterDetails() }
            return
        }

        let now = Date()

        // 1. Accumulate duration in current state
        transitionState(to: plugged ? "charging" : "active", timestamp: now)
        
        if plugged {
            updatePowerAdapterDetails()

            // Transitioned to AC: End battery tracking (save to history or mark complete)
            if var session = currentSession {
                session.endTime = now
                session.endBatteryLevel = batteryLevel
                session.events.append(Event(timestamp: now, type: "plugged", battery: batteryLevel))

                // Skip trivial sessions: no battery change and barely any time on battery
                // (e.g. a quick unplug/replug, or an app restart). These only clutter history.
                let totalDuration = now.timeIntervalSince(session.startTime)
                let drained = session.startBattery - batteryLevel
                let isTrivial = drained <= 0 && totalDuration < 120

                if isTrivial {
                    print("Skipped trivial session (\(Int(totalDuration))s, \(drained)% change).")
                } else {
                    history.insert(session, at: 0)
                    if history.count > 10 {
                        history.removeLast()
                    }
                    print("Session completed and saved. Screen Time: \(session.screenOnDuration)s")
                }

                self.currentSession = nil
            }
        } else {
            // Transitioned to Battery: always start a fresh session so each
            // unplug→plug interval is tracked on its own, regardless of charge level.
            let newSession = Session(
                id: UUID(),
                startTime: now,
                endTime: nil,
                startBattery: batteryLevel,
                endBatteryLevel: nil,
                screenOnDuration: 0,
                sleepDuration: 0,
                shutdownDuration: 0,
                events: [Event(timestamp: now, type: "unplugged", battery: batteryLevel)]
            )
            self.currentSession = newSession
            print("Started a new battery session at \(batteryLevel)%")
        }
        
        saveData()
    }

    // Setup Workspace notification observers (sleep/wake)
    private func setupWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStateTransition(to: "screenSleep")
            }
        }
        
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStateTransition(to: "active")
            }
        }
        
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStateTransition(to: "systemSleep")
                // The app control loop is suspended during sleep. A manual calibration
                // must synchronously release its forced-discharge state before that gap
                // can cross the 15% safety floor.
                ChargeLimitManager.shared.cancelCalibrationBeforeSleep()
            }
        }
        
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStateTransition(to: "active")
                // evaluate()/the heartbeat don't run while asleep, so charge-limit and
                // calibration state can be stale for the whole sleep duration otherwise —
                // re-sync immediately instead of waiting up to 30s for the next heartbeat.
                guard let self else { return }
                ChargeLimitManager.shared.evaluate(batteryLevel: self.getBatteryLevel(), isPluggedIn: self.isACPowerConnected(), externalHoldPercent: self.externalHoldPercent)
            }
        }
        
        // Observe application termination to detect and track system shutdown/reboot/logout
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemTermination()
            }
        }
    }

    private func handleSystemTermination() {
        let appleEvent = NSAppleEventManager.shared().currentAppleEvent
        var type = "shutdown"
        var isSystemEvent = false
        
        if let event = appleEvent {
            // kAEQuitReason keyword is 'howq' (0x686f7771)
            let reasonDesc = event.attributeDescriptor(forKeyword: AEKeyword(0x686f7771))
            if let reasonDesc = reasonDesc {
                isSystemEvent = true
                let reason = reasonDesc.typeCodeValue
                // kAERestart keyword 'rest' (0x72657374), kAEShutDown 'shut' (0x73687574), kAELogOut 'logo' (0x6c6f676f), kAEReallyLogOut 'rlgo' (0x726c676f)
                if reason == 0x72657374 {
                    type = "reboot"
                } else if reason == 0x73687574 {
                    type = "shutdown"
                } else if reason == 0x6c6f676f || reason == 0x726c676f {
                    type = "logout"
                }
            }
        }
        
        print("System termination event detected. isSystemEvent: \(isSystemEvent), type: \(type)")
        
        let now = Date()
        
        if isSystemEvent {
            transitionState(to: type, timestamp: now)
            
            if var session = currentSession {
                session.events.append(Event(timestamp: now, type: type, battery: getBatteryLevel()))
                self.currentSession = session
            }
        } else {
            // Normal app quit: run heartbeat to save latest active/sleep duration
            saveHeartbeat()
        }
        
        saveData()
    }

    private func handleStateTransition(to newState: String) {
        guard !isPluggedIn else {
            // If plugged into AC, we remain in "charging" state
            self.appState = "charging"
            return
        }
        
        let now = Date()
        let previousState = appState
        transitionState(to: newState, timestamp: now)
        
        // Log event in session
        if var session = currentSession {
            let type: String
            switch newState {
            case "screenSleep": type = "screenSleep"
            case "systemSleep": type = "systemSleep"
            case "active":
                type = previousState == "screenSleep" ? "screenWake" : "systemWake"
            default: type = "active"
            }
            session.events.append(Event(timestamp: now, type: type, battery: getBatteryLevel()))
            self.currentSession = session
        }
        
        saveData()
    }

    // Shared routine to handle transitioning state and updating counters
    private func transitionState(to newState: String, timestamp: Date) {
        let delta = timestamp.timeIntervalSince(lastStateChange)
        
        if var session = currentSession, delta > 0 {
            // Check old state
            if appState == "active" {
                session.screenOnDuration += delta
            } else if appState == "screenSleep" || appState == "systemSleep" {
                session.sleepDuration += delta
            }
            self.currentSession = session
        }
        
        self.appState = newState
        self.lastStateChange = timestamp
    }

    // Periodical timer to save heartbeat and verify stats
    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveHeartbeat()
            }
        }
    }

    private func saveHeartbeat() {
        let now = Date()
        
        loadSettings() // reload charge limit and other preferences
        
        let level = getBatteryLevel()
        let plugged = isACPowerConnected()
        recordExternalHoldSample(level: level, plugged: plugged)

        if plugged != isPluggedIn {
            currentBatteryLevel = level
            isPluggedIn = plugged
            updatePowerAdapterDetails()
            recordBatterySample(level: level, timestamp: now)
            handlePowerSourceChange(toPlugged: plugged, batteryLevel: level)
            return
        }

        currentBatteryLevel = level
        isPluggedIn = plugged
        // Refresh in both states: on battery this still updates temperature,
        // cycle count and health (it no longer early-returns without reading them).
        updatePowerAdapterDetails()
        recordBatterySample(level: level, timestamp: now)
        checkForRapidDrain(now: now)
        ChargeLimitManager.shared.evaluate(batteryLevel: level, isPluggedIn: plugged, externalHoldPercent: externalHoldPercent)

        let delta = now.timeIntervalSince(lastStateChange)
        
        if var session = currentSession, delta > 0 {
            if appState == "active" && !isPluggedIn {
                session.screenOnDuration += delta
                self.lastStateChange = now
                self.currentSession = session
            } else if (appState == "screenSleep" || appState == "systemSleep") && !isPluggedIn {
                session.sleepDuration += delta
                self.lastStateChange = now
                self.currentSession = session
            }
        }

        updateFanSpeed()
        
        saveData()
    }

    // Manual reset command
    // MARK: - WidgetKit snapshot

    /// Mirror of the struct in the widget extension (kept tiny and duplicated on purpose —
    /// the Widget target is a standalone module and the schema is six fields).
    private struct WidgetSnapshot: Codable {
        var level: Int; var isPluggedIn: Bool; var health: Int
        var temperature: Double; var limitEnabled: Bool; var limit: Int; var timestamp: Date
    }
    private var lastWidgetReload = Date.distantPast
    private var lastWidgetSnapshotKey = ""

    /// Writes the shared-container snapshot the WidgetKit extension renders from, and
    /// asks WidgetKit to reload — immediately on a meaningful change (level/power/limit),
    /// otherwise at most every 5 minutes so we stay well inside the reload budget.
    func updateWidgetSnapshot() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Distribution.appGroupID) else { return }
        let cl = ChargeLimitManager.shared
        let snap = WidgetSnapshot(
            level: currentBatteryLevel, isPluggedIn: isPluggedIn, health: batteryHealth,
            temperature: batteryTemperature, limitEnabled: cl.isEnabled && cl.helperStatus == .ready,
            limit: cl.limit, timestamp: Date()
        )
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: container.appendingPathComponent("widget-snapshot.json"), options: .atomic)
        }
        let key = "\(snap.level)|\(snap.isPluggedIn)|\(snap.limitEnabled)|\(snap.limit)"
        if key != lastWidgetSnapshotKey || Date().timeIntervalSince(lastWidgetReload) > 300 {
            lastWidgetSnapshotKey = key
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Exports battery data as CSV via a save panel: health/cycle history, session
    /// summaries, and the adapter log — one file with three labelled sections, so a
    /// spreadsheet import stays trivial.
    func exportDataAsCSV() {
        let iso = ISO8601DateFormatter()
        var csv = "# MacWake battery data export\n"

        csv += "\n[Health History]\ndate,health_percent,cycle_count\n"
        for r in healthHistory {
            csv += "\(iso.string(from: r.date)),\(r.health),\(r.cycleCount)\n"
        }

        csv += "\n[Sessions]\nstart,end,start_battery,end_battery,screen_on_minutes,sleep_minutes,shutdown_minutes,reboots\n"
        let allSessions = (currentSession.map { [$0] } ?? []) + history
        for s in allSessions {
            let end = s.endTime.map { iso.string(from: $0) } ?? ""
            let endLevel = s.endBatteryLevel.map(String.init) ?? ""
            csv += "\(iso.string(from: s.startTime)),\(end),\(s.startBattery),\(endLevel),"
            csv += "\(Int(s.screenOnDuration / 60)),\(Int(s.sleepDuration / 60)),\(Int(s.shutdownDuration / 60)),\(s.rebootCount)\n"
        }

        csv += "\n[Power Adapters]\nfirst_seen,last_seen,watts,name,manufacturer,times_seen\n"
        for a in adapterHistory {
            let name = (a.name ?? "").replacingOccurrences(of: ",", with: " ")
            let manufacturer = (a.manufacturer ?? "").replacingOccurrences(of: ",", with: " ")
            csv += "\(iso.string(from: a.firstSeen)),\(iso.string(from: a.lastSeen)),\(a.watts),\(name),\(manufacturer),\(a.seenCount)\n"
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacWake-Battery-Data.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        // Accessory apps don't get key-window focus for panels unless activated.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? csv.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    func resetCurrentSession() {
        let now = Date()
        let level = getBatteryLevel()
        
        if var session = currentSession {
            session.endTime = now
            session.endBatteryLevel = level
            session.events.append(Event(timestamp: now, type: "plugged", battery: level))
            history.insert(session, at: 0)
            if history.count > 10 {
                history.removeLast()
            }
        }
        
        let newSession = Session(
            id: UUID(),
            startTime: now,
            endTime: nil,
            startBattery: level,
            endBatteryLevel: nil,
            screenOnDuration: 0,
            sleepDuration: 0,
            shutdownDuration: 0,
            events: [Event(timestamp: now, type: "unplugged", battery: level)]
        )
        
        self.currentSession = newSession
        self.appState = isPluggedIn ? "charging" : "active"
        self.lastStateChange = now
        
        saveData()
    }

    func liveSession(_ session: Session) -> Session {
        guard session.id == currentSession?.id else { return session }

        var live = session
        let delta = Date().timeIntervalSince(lastStateChange)
        guard delta > 0 else { return live }

        if appState == "active" && !isPluggedIn {
            live.screenOnDuration += delta
        } else if (appState == "screenSleep" || appState == "systemSleep") && !isPluggedIn {
            live.sleepDuration += delta
        }

        return live
    }

    var recentSessionsIncludingCurrent: [Session] {
        var sessions = history
        if let currentSession {
            sessions.insert(liveSession(currentSession), at: 0)
        }
        return sessions
    }

    var weeklySummary: UsageSummary {
        let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return UsageSummary(sessions: recentSessionsIncludingCurrent.filter { $0.startTime >= weekStart })
    }

    var remainingBatteryEstimate: TimeInterval? {
        guard !isPluggedIn, currentBatteryLevel > 0 else { return nil }

        let currentEfficiency = currentSession.flatMap { session -> Double? in
            let live = liveSession(session)
            let used = max(0, live.startBattery - currentBatteryLevel)
            guard used >= 2 else { return nil }
            return (live.screenOnDuration / 60) / Double(used)
        }

        let minutesPerPercent = currentEfficiency ?? weeklySummary.averageMinutesPerPercent
        guard let minutesPerPercent, minutesPerPercent > 0 else { return nil }
        return Double(currentBatteryLevel) * minutesPerPercent * 60
    }

    var goalProgress: [GoalProgress] {
        let calendar = Calendar.current
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? dayStart

        return [
            GoalProgress(title: "Daily", target: 4 * 3600, actual: summarySince(dayStart).screenOnDuration),
            GoalProgress(title: "Weekly", target: 25 * 3600, actual: summarySince(weekStart).screenOnDuration),
            GoalProgress(title: "Monthly", target: 100 * 3600, actual: summarySince(monthStart).screenOnDuration)
        ]
    }

    private func summarySince(_ startDate: Date) -> UsageSummary {
        UsageSummary(sessions: recentSessionsIncludingCurrent.filter { ($0.endTime ?? Date()) >= startDate })
    }

    private func recordBatterySample(level: Int, timestamp: Date) {
        guard !isPluggedIn else {
            batterySamples.removeAll()
            return
        }

        if batterySamples.last?.level == level,
           let lastTimestamp = batterySamples.last?.timestamp,
           timestamp.timeIntervalSince(lastTimestamp) < 60 {
            return
        }

        batterySamples.append(BatterySample(timestamp: timestamp, level: level))

        let cutoff = timestamp.addingTimeInterval(-2 * 3600)
        batterySamples.removeAll { $0.timestamp < cutoff }
    }

    private func checkForRapidDrain(now: Date) {
        guard !isPluggedIn, batterySamples.count >= 2 else { return }

        let cutoff = now.addingTimeInterval(-10 * 60)
        guard let oldSample = batterySamples.last(where: { $0.timestamp <= cutoff }) else { return }

        let durationSeconds = now.timeIntervalSince(oldSample.timestamp)
        let minutes = Int(round(durationSeconds / 60))

        // Ensure we are comparing with a sample that is actually close to 10 minutes ago
        // (between 8 and 15 minutes) to avoid comparing with hours-old samples (e.g. after sleep)
        guard minutes >= 8 && minutes <= 15 else { return }

        let drop = oldSample.level - currentBatteryLevel
        let alertCooldownPassed = lastRapidDrainAlert.map { now.timeIntervalSince($0) > 30 * 60 } ?? true

        guard drop >= 5, alertCooldownPassed else { return }

        lastRapidDrainAlert = now
        Analytics.signal("alert.fastDrain", parameters: ["drop": "\(drop)", "minutes": "\(minutes)"])
        sendNotification(
            title: String(localized: "Wake: Fast Battery Drain"),
            body: String(format: String(localized: "DRAIN_BODY_FMT"), drop, minutes, currentBatteryLevel)
        )
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                self?.notificationStatus = settings.authorizationStatus
            }
        }
    }

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.notificationStatus = settings.authorizationStatus

                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.sendTestNotification()
                case .denied:
                    self.openNotificationSettings()
                case .notDetermined:
                    self.askForNotificationPermission()
                case .ephemeral:
                    self.sendTestNotification()
                @unknown default:
                    self.askForNotificationPermission()
                }
            }
        }
    }

    func sendTestNotification() {
        refreshNotificationStatus()
        sendNotification(title: String(localized: "Wake: Test Notification"), body: String(localized: "Notifications are working."))
    }

    private func askForNotificationPermission() {
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                print("Notification permission error: \(error)")
            } else {
                print("Notification permission granted: \(granted)")
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshNotificationStatus()
                NSApplication.shared.setActivationPolicy(previousPolicy)

                if granted {
                    self.sendNotification(title: String(localized: "Wake: Notifications Enabled"), body: String(localized: "Fast battery drain alerts are ready."))
                }
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Failed to send notification: \(error)")
            }
        }
    }
}

extension BatteryTracker {
    struct UsageSummary {
        let sessionCount: Int
        let screenOnDuration: TimeInterval
        let totalDuration: TimeInterval
        let batteryUsed: Int
        let averageMinutesPerPercent: Double?
        let longestScreenOnDuration: TimeInterval

        init(sessions: [Session]) {
            sessionCount = sessions.count
            screenOnDuration = sessions.reduce(0) { $0 + $1.screenOnDuration }
            totalDuration = sessions.reduce(0) { $0 + $1.totalDuration }
            batteryUsed = sessions.reduce(0) { $0 + $1.batteryUsed }
            longestScreenOnDuration = sessions.map(\.screenOnDuration).max() ?? 0

            if batteryUsed > 0 {
                averageMinutesPerPercent = (screenOnDuration / 60) / Double(batteryUsed)
            } else {
                averageMinutesPerPercent = nil
            }
        }
    }

    /// Whether the menu-bar item is in the menu bar at all.
    ///
    /// Turning off every part used to force the icon back so the item could never
    /// become unreachable. The Dynamic Island is a second way into the app, so when
    /// it is on we honour an empty menu bar by removing the item outright rather than
    /// leaving a blank sliver behind.
    var menuBarItemVisible: Bool {
        MenuBarVisibility.itemVisible(
            contentEnabled: menuBarContentEnabled, dynamicIslandEnabled: enableDynamicIsland
        )
    }

    /// Whether the user has any menu-bar content switched on — independent of whether that
    /// content has a value at this moment.
    ///
    /// Visibility must follow the preferences, not the rendered string. Keying it off the
    /// text meant an enabled metric with nothing to show yet — Time Remaining before an
    /// estimate exists, wattage while on battery, a temperature the Mac doesn't expose —
    /// read as "the user switched everything off" and removed the item, taking the only
    /// route back into Settings with it.
    var menuBarContentEnabled: Bool {
        MenuBarVisibility.contentEnabled(
            icon: showMenuBarIcon, percent: showMenuBarPercent, power: showMenuBarPower,
            timeRemaining: showMenuBarTimeRemaining, temperature: showMenuBarTemp
        )
    }

    /// Whether the item — when present — draws its icon. Text-only is a valid choice,
    /// but an item with no icon *and* no text would be invisible yet still clickable.
    var showsMenuBarIcon: Bool {
        MenuBarVisibility.showsIcon(iconEnabled: showMenuBarIcon, textIsEmpty: menuBarText.isEmpty)
    }

    var menuBarText: String {
        var parts: [String] = []

        if showMenuBarPercent {
            parts.append("\(currentBatteryLevel)%")
        }

        if showMenuBarPower {
            if isPluggedIn {
                if let dyn = dynamicWatts {
                    parts.append(MenuBarLabel.watts(dyn, compact: menuBarCompact))
                } else if let watts = powerAdapterWatts {
                    parts.append("\(watts)W")
                }
            } else if let session = currentSession {
                let delta = appState == "active" ? Date().timeIntervalSince(lastStateChange) : 0
                parts.append(MenuBarLabel.duration(
                    seconds: session.screenOnDuration + delta, compact: menuBarCompact
                ))
            }
        }

        if showMenuBarTimeRemaining, let remaining = remainingBatteryEstimate {
            // Keep the tilde even when compact: it is what separates a remaining estimate
            // from the elapsed screen-on time above it.
            parts.append("~" + MenuBarLabel.duration(seconds: remaining, compact: menuBarCompact))
        }

        // Fall back to the battery sensor: the CPU reading comes from the SMC, which the
        // sandboxed build has no access to, so this toggle could never show anything there.
        if showMenuBarTemp, let temp = cpuTemperature ?? (batteryTemperature > 0 ? batteryTemperature : nil) {
            parts.append(String(format: "%.0f°", temp))
        }

        return MenuBarLabel.join(parts, compact: menuBarCompact)
    }
    
    var currentScreenOnSeconds: TimeInterval {
        guard let session = currentSession else { return 0 }
        let delta = appState == "active" ? Date().timeIntervalSince(lastStateChange) : 0
        return session.screenOnDuration + delta
    }

    var menuBarIcon: String {
        if isPluggedIn {
            return "battery.100.bolt"
        } else {
            if currentBatteryLevel < 20 {
                return "battery.25"
            } else if currentBatteryLevel < 50 {
                return "battery.50"
            } else if currentBatteryLevel < 80 {
                return "battery.75"
            } else {
                return "battery.100"
            }
        }
    }
    
    var effectiveMenuBarIcon: String {
        if enableAnimations && isPluggedIn {
            return animatedMenuBarIcon
        }
        return menuBarIcon
    }
    
    // MARK: - Menu Bar Animation
    private func startMenuBarAnimation() {
        guard menuBarAnimationTimer == nil else { return }
        menuBarAnimationIndex = 0
        menuBarAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.menuBarAnimationIndex = (self.menuBarAnimationIndex + 1) % self.menuBarAnimationFrames.count
                self.animatedMenuBarIcon = self.menuBarAnimationFrames[self.menuBarAnimationIndex]
            }
        }
    }
    
    private func stopMenuBarAnimation() {
        menuBarAnimationTimer?.invalidate()
        menuBarAnimationTimer = nil
        animatedMenuBarIcon = menuBarIcon
    }
    
    // MARK: - USB Port Detection
    private func updateUSBPortInfo() {
        guard isPluggedIn else {
            usbPortInfo = nil
            return
        }
        
        // Query IORegistry for USB-C / Thunderbolt port info
        var portName: String? = nil
        
        // Check for Thunderbolt controllers
        let matchDict = IOServiceMatching("AppleThunderboltHAL")
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)
        
        if result == kIOReturnSuccess {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                   let dict = properties?.takeRetainedValue() as? [String: Any] {
                    if let locationID = dict["locationID"] as? Int {
                        // Left ports typically have lower location IDs
                        let side = locationID % 2 == 0 ? "Left" : "Right"
                        portName = "\(side) USB-C"
                    }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        
        // Fallback: check power adapter details for port hints
        if portName == nil {
            if let unmanagedDetails = IOPSCopyExternalPowerAdapterDetails(),
               let details = unmanagedDetails.takeRetainedValue() as? [String: Any] {
                let adapterID = details["AdapterID"] as? Int
                let family = details["FamilyCode"] as? Int
                
                // Family code can help identify Thunderbolt vs USB-C
                if let family = family {
                    switch family {
                    case 0xE000...0xEFFF:
                        portName = "Thunderbolt"
                    default:
                        portName = "USB-C"
                    }
                } else if adapterID != nil {
                    portName = "USB-C"
                }
            }
        }
        
        // MagSafe detection
        if portName == nil {
            if let unmanagedDetails = IOPSCopyExternalPowerAdapterDetails(),
               let details = unmanagedDetails.takeRetainedValue() as? [String: Any],
               let name = details["Name"] as? String {
                if name.lowercased().contains("magsafe") {
                    portName = "MagSafe"
                }
            }
        }
        
        usbPortInfo = portName
    }
}

extension BatteryTracker.Session {
    var totalDuration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    var batteryUsed: Int {
        max(0, startBattery - (endBatteryLevel ?? events.last?.battery ?? startBattery))
    }

    var screenMinutesPerPercent: Double? {
        guard batteryUsed > 0 else { return nil }
        return (screenOnDuration / 60) / Double(batteryUsed)
    }
}

/// Battery-health arithmetic, kept pure so the two metrics can be regression-tested
/// without an IORegistry snapshot.
///
/// Two different numbers are in play and must not be conflated:
/// * the **capacity ratio** MacWake shows — wear, derived from the controller's capacities;
/// * `MaxCapacity`, which Apple Silicon pins at 100 regardless of wear, so it is only a
///   last resort for Macs that expose no capacity pair at all.
enum BatteryHealthMath {
    struct Ratio: Equatable {
        let value: Double
        /// Which field the ratio came from. This selects the numerator only — it says
        /// nothing about stability, because no capacity field is stable (see `headline`).
        let isLiveEstimate: Bool
    }

    /// `nominal` is the better numerator and always wins; `liveMax` (FullChargeCapacity /
    /// AppleRawMaxCapacity) is a coarser re-estimate used when nothing better is exposed.
    ///
    /// Neither is authoritative for a *displayed* figure. `NominalChargeCapacity` was
    /// assumed to be the controller's settled value in 1.52; it is not. On one Mac here it
    /// moved 4820 → 4766 mAh in a few hours with the cycle count unchanged — 1.2 points of
    /// ratio — and a reporter saw it swing between 5997 and 6156 (95% ↔ 98%), recovering
    /// each time as the battery changed state.
    static func ratio(nominal: Int?, liveMax: Int?, design: Int?) -> Ratio? {
        guard let design, design > 0 else { return nil }
        if let nominal {
            return Ratio(value: min(100, Double(nominal) * 100 / Double(design)), isLiveEstimate: false)
        }
        if let liveMax {
            return Ratio(value: min(100, Double(liveMax) * 100 / Double(design)), isLiveEstimate: true)
        }
        return nil
    }

    /// Number of recent samples kept for the median. Enough to span a stretch of tick
    /// intervals without pretending to be a long-term record.
    static let sampleWindow = 120

    /// Wear is a weeks-scale quantity, so the headline is deliberately slow: it is the
    /// median of recent samples, must clear the shown value by a full point, and may move
    /// at most once a day. Deriving it from a single sample is what let the controller's
    /// state-dependent recalculation write "wear" that recovered minutes later.
    ///
    /// Damping applies on every path. Gating it on `isLiveEstimate` — as 1.52 did — left
    /// the `NominalChargeCapacity` path undamped, and that field drifts too.
    ///
    /// - Parameters:
    ///   - samples: recent ratio values, oldest first.
    ///   - current: the integer on screen.
    ///   - lastMoved: when the headline last changed; `nil` means it has never been set, so
    ///     the first real reading is adopted at once rather than sitting on the 100% default.
    static func headline(samples: [Double], current: Int, lastMoved: Date?, now: Date,
                         minimumInterval: TimeInterval = 24 * 3600) -> Int {
        guard let middle = median(samples) else { return current }
        let candidate = Int(middle.rounded(.down))
        guard candidate != current else { return current }
        guard let lastMoved else { return candidate }
        // A full point of separation, so a value sitting near a boundary can't flip back.
        guard abs(middle - Double(current)) >= 1.0 else { return current }
        guard now.timeIntervalSince(lastMoved) >= minimumInterval else { return current }
        return candidate
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// Menu-bar visibility rules, kept pure so the lock-out case can be regression-tested.
///
/// The rule must depend on what the user switched on, never on whether those parts happen to
/// have a value right now — deriving it from the rendered text removed the item (and with it
/// the only route to Settings) whenever an enabled metric had nothing to show.
enum MenuBarVisibility {
    static func contentEnabled(icon: Bool, percent: Bool, power: Bool,
                               timeRemaining: Bool, temperature: Bool) -> Bool {
        icon || percent || power || timeRemaining || temperature
    }

    static func itemVisible(contentEnabled: Bool, dynamicIslandEnabled: Bool) -> Bool {
        contentEnabled || !dynamicIslandEnabled
    }

    /// An item with content enabled but no value yet still needs something clickable, so the
    /// icon stands in until the text arrives.
    static func showsIcon(iconEnabled: Bool, textIsEmpty: Bool) -> Bool {
        iconEnabled || textIsEmpty
    }
}

/// Menu-bar label formatting, kept pure so the widths are testable.
///
/// The macOS menu bar is shared, horizontally constrained space. With every metric switched
/// on the default label runs to roughly 24 characters, which crowds neighbouring items — so
/// Compact keeps the same metrics and only spends fewer characters on them. It is opt-in:
/// the default layout is unchanged, and nothing ever wraps or re-arranges on its own.
enum MenuBarLabel {
    /// `"3h 20m"` normally, `"3:20"` compact. Under an hour both read `"20m"` — a bare
    /// `"0:20"` would be mistaken for 20 hours at a glance.
    static func duration(seconds: Double, compact: Bool) -> String {
        let minutes = max(0, Int(seconds) / 60)
        let hours = minutes / 60, rest = minutes % 60
        guard hours > 0 else { return "\(rest)m" }
        return compact ? String(format: "%d:%02d", hours, rest) : "\(hours)h \(rest)m"
    }

    /// `"12.4W"` normally, `"12W"` compact — a tenth of a watt is not worth two characters
    /// in a space this tight.
    static func watts(_ value: Double, compact: Bool) -> String {
        compact ? String(format: "%.0fW", value) : String(format: "%.1fW", value)
    }

    /// Compact halves the gap; two spaces are what make the default label read as separate
    /// values rather than one run-on string.
    static func join(_ parts: [String], compact: Bool) -> String {
        parts.joined(separator: compact ? " " : "  ")
    }
}

/// Which charge limit is actually in effect, and where it comes from — kept pure so the
/// two sources can be regression-tested without a running charge-limit manager.
///
/// Two independent limits exist and were being shown as one unlabeled figure: MacWake's own
/// helper-enforced limit (`ChargeLimitManager.limit`, from `chargeLimitValue`), and whatever
/// else appears to be holding the battery (`BatteryTracker.chargeLimit`, from
/// `ExternalChargeHold` — observed behavior, not a read of Apple's actual configuration).
/// The external reading defaults to 100 when nothing is detected holding, so "MacWake
/// limiting at 80%, nothing else detected" rendered as "Limit: 100%" right next to a
/// settings card reading "Stop at 80%" — an unlabeled contradiction on the same screen, not
/// a wrong number.
enum ChargeLimitSource: Equatable {
    /// MacWake's own limit, enforced by the helper. Wins whenever it is actually active.
    case macWake(Int)
    /// The macOS-native policy, shown only when MacWake's own limit isn't the one holding —
    /// otherwise the two would describe the same charge as if they were one setting.
    case macOSNative(Int)
    /// MacWake's limit is configured and enabled, but a confirmed external hold means
    /// something else is actively holding the battery right now — kept separate from
    /// `.macWake` so nothing ever claims MacWake is enforcing while it has deliberately
    /// stepped back to avoid two controllers fighting over the same key. The user's
    /// configuration (`macWakeLimit`) is preserved here precisely so the UI can say it's
    /// still set, just not the one currently in charge.
    case yielded(externalPercent: Int, macWakeLimit: Int)
    /// Neither is enforcing anything below 100%.
    case none

    /// `yieldedPercent` is `ChargeControlOwnership`'s own retained last-confirmed value, not
    /// a live detector reading — passing the raw current reading here is what previously let
    /// the grace period display a false "holding at 100%" the moment a single tick came back
    /// ambiguous, while the real, still-yielded-to hold was at some other percent entirely.
    static func resolve(macWakeEnabled: Bool, macWakeReady: Bool, macWakeLimit: Int,
                        nativeLimit: Int, yieldedPercent: Int?) -> ChargeLimitSource {
        if macWakeEnabled, macWakeReady, let yieldedPercent {
            return .yielded(externalPercent: yieldedPercent, macWakeLimit: macWakeLimit)
        }
        if macWakeEnabled, macWakeReady { return .macWake(macWakeLimit) }
        if nativeLimit < 100 { return .macOSNative(nativeLimit) }
        return .none
    }
}

/// State for a button that runs a slow async call (an XPC round trip that can take
/// 20–40 seconds through a timeout-and-retry path) and needs to show progress, refuse
/// overlapping requests, and become reusable again afterwards.
enum AsyncCopyState: Equatable {
    case idle, running, copied

    /// Whether tapping the button in this state should start new work. `running` refuses a
    /// second request; `copied` allows a fresh cycle without waiting out the display window.
    var canStart: Bool { self != .running }
}

/// Drives one `AsyncCopyState` button: run the call, hand the result to the caller to place
/// on the clipboard, show success briefly, then revert to idle so the action can be repeated.
///
/// Both diagnostic-copy buttons in Settings (fan diagnostics, helper reload) used to set a
/// `Bool` to true and never back — reusing them meant the label stayed on "Copied" forever,
/// and neither showed any feedback during collection, which on a stale helper's timeout path
/// can take tens of seconds and looks exactly like a frozen button.
@MainActor
final class AsyncCopyController: ObservableObject {
    @Published private(set) var state: AsyncCopyState = .idle

    private let revertDelayNanoseconds: UInt64
    private var revertTask: Task<Void, Never>?

    init(revertDelayNanoseconds: UInt64 = 2_000_000_000) {
        self.revertDelayNanoseconds = revertDelayNanoseconds
    }

    /// Runs `work`, passes its result to `onSuccess` (e.g. writing the clipboard) while still
    /// showing progress, then reverts to idle after a brief success display. A tap that
    /// arrives while already running is a no-op rather than a second, overlapping request.
    ///
    /// Returns as soon as `state` becomes `.copied` — the revert to idle runs in a detached
    /// timer rather than being awaited here, so a caller (or a test) observing the result of
    /// `run()` sees the success state deterministically rather than racing a sleep.
    func run(_ work: () async -> String, onSuccess: (String) -> Void = { _ in }) async {
        guard state.canStart else { return }
        revertTask?.cancel()
        state = .running
        let result = await work()
        onSuccess(result)
        state = .copied
        revertTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.revertDelayNanoseconds)
            guard !Task.isCancelled else { return }
            if self.state == .copied { self.state = .idle }
        }
    }
}

/// Whether something other than MacWake is currently holding the battery below full,
/// inferred from public IOKit/IOPS data only — no private preference reads.
///
/// This replaces reading `com.apple.batteryui.charging.mac` and `/Library/Preferences/
/// com.apple.powerd.charging.plist`, which had two problems: neither can be read on the
/// sandboxed Mac App Store build (no file or shared-preference sandbox exception is
/// granted, so the signal silently collapsed to "never active" there), and the reading
/// itself inferred "policy active" from whether decoding an undocumented blob happened to
/// throw — a signal with no defined meaning, wrong in either direction on any macOS
/// revision that changes the archive format. This detector uses only APIs the app already
/// calls successfully on both distribution channels.
enum ExternalChargeHold {
    struct Sample: Equatable {
        let externallyConnected: Bool
        let isCharging: Bool
        let percent: Int
        /// True while MacWake's own limit is the one cutting the adapter — excluded, or
        /// MacWake would "detect" its own hold as an external one.
        let macWakeIsHolding: Bool
    }

    /// A held level only counts once several consecutive samples agree on the *same*
    /// percent — not just "plugged in and not charging," which a battery that's merely
    /// draining while unable to charge (bad adapter, thermal fault) would also match.
    /// Ambiguous or insufficient data always resolves to `nil`: a false positive would
    /// have MacWake silently stop protecting the battery, a false negative just leaves it
    /// doing what it already does today, so the failure direction is fixed on purpose.
    static func detect(recentSamples: [Sample], minimumStableSamples: Int = 3) -> Int? {
        guard recentSamples.count >= minimumStableSamples else { return nil }
        let window = recentSamples.suffix(minimumStableSamples)
        guard let level = window.first?.percent, level > 0, level < 100 else { return nil }
        let held = window.allSatisfy { sample in
            sample.externallyConnected && !sample.isCharging
                && !sample.macWakeIsHolding && sample.percent == level
        }
        return held ? level : nil
    }
}
