import Foundation
import Cocoa
import IOKit.ps
import IOKit
import UserNotifications

extension Notification.Name {
    static let powerSourceChanged = Notification.Name("powerSourceChanged")
}

@MainActor
class BatteryTracker: ObservableObject {
    @Published var currentBatteryLevel: Int = 100
    @Published var isPluggedIn: Bool = false
    @Published var currentSession: Session?
    @Published var history: [Session] = []
    @Published var chargeLimit: Int = 100
    @Published var appState: String = "active" // active, screenSleep, systemSleep, charging
    @Published var powerAdapterWatts: Int?
    @Published var dynamicWatts: Double?
    @Published var slowChargingAlert: String?
    @Published var powerAdapterName: String?
    @Published var isOriginalAppleAdapter: Bool = false
    @Published var batteryHealth: Int = 100
    @Published var batteryCycles: Int = 0
    @Published var batteryTemperature: Double = 0.0
    @Published var temperatureSamples: [Double] = []
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
        }
    }
    @Published var animatedMenuBarIcon: String = "battery.100.bolt"
    @Published var usbPortInfo: String?
    
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
    }
    
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
        
        // Use UserDefaults to read the value from cfprefsd (memory cache)
        if let defaults = UserDefaults(suiteName: "com.apple.batteryui.charging.mac") {
            let priorLimit = defaults.integer(forKey: "com.apple.batteryui.charging.mac.prior.limit")
            var finalLimit = priorLimit > 0 ? priorLimit : 100
            
            // Check if limit is actively enforced by powerd
            let powerdPath = "/Library/Preferences/com.apple.powerd.charging.plist"
            if let dict = NSDictionary(contentsOfFile: powerdPath) as? [String: Any],
               let policiesData = dict["policies"] as? Data {
                do {
                    if let unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, NSDictionary.self, NSString.self, NSNumber.self, NSDate.self], from: policiesData) as? NSArray {
                        if unarchived.count == 0 {
                            finalLimit = 100
                        }
                    }
                } catch {
                    // If it throws an error (e.g. unknown custom class), it means policies exist and are active.
                }
            } else {
                // If powerd charging plist is missing, we can assume no active policy.
                finalLimit = 100
            }
            
            self.chargeLimit = finalLimit
        } else {
            self.chargeLimit = 100
        }
    }

    // Load data from file and perform recovery check
    private func loadData() {
        if FileManager.default.fileExists(atPath: dataURL.path) {
            do {
                let data = try Data(contentsOf: dataURL)
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
                self.healthHistory = persisted.healthHistory ?? []
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
                
                // Save cleaned data
                saveData()
            } catch {
                print("Failed to decode data.json: \(error)")
            }
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
            try data.write(to: dataURL)
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

    private func updatePowerStatus() {
        loadSettings() // reload charge limit in case it changed
        let level = getBatteryLevel()
        let plugged = isACPowerConnected()
        
        let oldPlugged = self.isPluggedIn
        self.currentBatteryLevel = level
        self.isPluggedIn = plugged
        updatePowerAdapterDetails()
        recordBatterySample(level: level, timestamp: Date())
        
        if plugged {
            if acPowerStartTime == nil {
                acPowerStartTime = Date()
            }
        } else {
            acPowerStartTime = nil
            continuousACAlert = false
        }
        
        if oldPlugged != plugged {
            handlePowerSourceChange(toPlugged: plugged, batteryLevel: level)
            
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

    private func getBatteryLevel() -> Int {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int
                let maxCapacity = description[kIOPSMaxCapacityKey] as? Int
                return (currentCapacity ?? 0) * 100 / (maxCapacity ?? 100)
            }
        }
        return 100
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
            dynamicWatts = nil
            isOriginalAppleAdapter = false
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
            // Read Temperature (divided by 100.0)
            if let tempRaw = dict["Temperature"] as? Int {
                let temp = Double(tempRaw) / 100.0
                batteryTemperature = temp
                // append sample
                DispatchQueue.main.async {
                    self.temperatureSamples.append(temp)
                    if self.temperatureSamples.count > 5 {
                        self.temperatureSamples.removeFirst()
                    }
                }
            }
            
            // Read CycleCount
            if let cycles = dict["CycleCount"] as? Int {
                batteryCycles = cycles
            }
            
            // Read Battery Health
            if let nominalMax = dict["NominalChargeCapacity"] as? Int,
               let design = dict["DesignCapacity"] as? Int, design > 0 {
                batteryHealth = min(100, nominalMax * 100 / design)
            } else if let rawMax = dict["AppleRawMaxCapacity"] as? Int,
                      let design = dict["DesignCapacity"] as? Int, design > 0 {
                batteryHealth = min(100, rawMax * 100 / design)
            } else if let maxCap = dict["MaxCapacity"] as? Int {
                batteryHealth = maxCap
            }
            
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
    
    private func checkTemperatureAlert() {
        let temp = self.batteryTemperature
        if temp > 38.0 && (isPluggedIn || isACPowerConnected()) {
            if !highTempAlert {
                DynamicIslandManager.shared.trigger(.alert(
                    title: "Yüksek Pil Sıcaklığı",
                    message: String(format: "Pil sıcaklığı %.1f°C seviyesine ulaştı.", temp),
                    isWarning: false
                ))
            }
            highTempAlert = true
            let now = Date()
            if lastTemperatureAlertSent == nil || now.timeIntervalSince(lastTemperatureAlertSent!) > 7200 {
                lastTemperatureAlertSent = now
                sendNotification(
                    title: "⚠️ Pil Sıcaklığı Yüksek!",
                    body: String(format: "Pil sıcaklığı %.1f°C seviyesine ulaştı. Sağlığını korumak için prizden çekmeniz önerilir.", temp)
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
                DynamicIslandManager.shared.trigger(.alert(
                    title: "Sürekli Prizde Kullanım",
                    message: "Mac'iniz 24 saattir prizde. Pili deşarj edin.",
                    isWarning: true
                ))
            }
            continuousACAlert = true
            let now = Date()
            if lastContinuousACAlertSent == nil || now.timeIntervalSince(lastContinuousACAlertSent!) > 86400 {
                lastContinuousACAlertSent = now
                sendNotification(
                    title: "🔌 Sürekli Prizde Kullanım Uyarısı",
                    body: "Mac'iniz 24 saattir kesintisiz prizde ve dolu durumda. Pil sağlığını korumak için deşarj etmeniz önerilir."
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
            slowChargingAlert = String(format: "%dW adaptör bağlı ancak sadece %.1fW güç çekiliyor. Kablonuzu, portunuzu veya bağlantı istasyonunuzu (hub) kontrol edin.", watts, dyn)
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

        if let existingIndex = adapterHistory.firstIndex(where: { 
            $0.watts == watts && ($0.name == name || $0.name == nil || name == nil)
        }) {
            // If the existing record had no name but we now have one, update it
            if adapterHistory[existingIndex].name == nil && name != nil {
                adapterHistory[existingIndex].name = name
            }
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
                
                // Add to history
                history.insert(session, at: 0)
                // Limit history to 10 entries
                if history.count > 10 {
                    history.removeLast()
                }
                
                self.currentSession = session
                print("Session completed and saved. Screen Time: \(session.screenOnDuration)s")
            }
        } else {
            // Transitioned to Battery: Start or resume tracking
            let threshold = chargeLimit - 3
            if batteryLevel >= threshold || currentSession == nil {
                // Start a brand new session
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
            } else {
                // Resume existing session
                if var session = currentSession {
                    // Remove old version from history since we are resuming it
                    history.removeAll(where: { $0.id == session.id })
                    session.endTime = nil
                    session.endBatteryLevel = nil
                    session.events.append(Event(timestamp: now, type: "unplugged", battery: batteryLevel))
                    self.currentSession = session
                    print("Resumed battery session at \(batteryLevel)%")
                }
            }
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
            }
        }
        
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStateTransition(to: "active")
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
        if plugged {
            updatePowerAdapterDetails()
        }
        recordBatterySample(level: level, timestamp: now)
        checkForRapidDrain(now: now)

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
        sendNotification(
            title: "MacWake: Fast battery drain",
            body: "Battery dropped \(drop)% in \(minutes) minutes. Current level: \(currentBatteryLevel)%."
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
        sendNotification(title: "MacWake test", body: "Notifications are working.")
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
                    self.sendNotification(title: "MacWake notifications enabled", body: "Fast battery drain alerts are ready.")
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

    var menuBarText: String {
        if isPluggedIn {
            if let dyn = dynamicWatts {
                return String(format: "%.1fW", dyn)
            } else if let watts = powerAdapterWatts {
                return "\(watts)W"
            }
        } else {
            if let session = currentSession {
                let delta = appState == "active" ? Date().timeIntervalSince(lastStateChange) : 0
                let total = session.screenOnDuration + delta
                let hours = Int(total) / 3600
                let minutes = (Int(total) % 3600) / 60
                if hours > 0 {
                    return "\(hours)h \(minutes)m"
                } else {
                    return "\(minutes)m"
                }
            }
        }
        return ""
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
