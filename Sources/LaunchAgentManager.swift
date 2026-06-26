import Foundation
import ServiceManagement

struct LaunchAgentManager {
    static let label = "com.macwake"
    private static let legacyLabels = ["com.antigravity.macwake"]
    
    private static var plistURL: URL {
        let libraryDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return libraryDirectory.appendingPathComponent("LaunchAgents").appendingPathComponent("\(label).plist")
    }
    
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
    
    static func setEnabled(_ enable: Bool) {
        cleanupLegacyLaunchAgents()

        do {
            if enable {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
        }
    }

    private static func cleanupLegacyLaunchAgents() {
        let libraryDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let launchAgentsDirectory = libraryDirectory.appendingPathComponent("LaunchAgents")

        for legacyLabel in legacyLabels {
            let url = launchAgentsDirectory.appendingPathComponent("\(legacyLabel).plist")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", "-w", url.path]
            try? process.run()
            process.waitUntilExit()

            do {
                try FileManager.default.removeItem(at: url)
                print("Removed legacy LaunchAgent: \(legacyLabel)")
            } catch {
                print("Failed to remove legacy LaunchAgent \(legacyLabel): \(error)")
            }
        }
    }
}
