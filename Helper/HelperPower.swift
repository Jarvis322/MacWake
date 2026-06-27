import Foundation

/// Root-only power management via `pmset` (macOS Energy Mode).
enum HelperPower {
    /// 0 = Automatic, 1 = Low Power, 2 = High Power.
    static func setEnergyMode(_ mode: Int) -> Bool {
        let low = (mode == 1) ? "1" : "0"
        let high = (mode == 2) ? "1" : "0"
        // lowpowermode exists on all modern Macs; highpowermode only on supported
        // MacBook Pros — its failure is harmless on machines that don't have it.
        let okLow = run(["-a", "lowpowermode", low])
        _ = run(["-a", "highpowermode", high])
        return okLow
    }

    private static func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}
