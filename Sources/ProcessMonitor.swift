import Foundation
import AppKit
import Darwin

struct ProcessUsage: Identifiable {
    let id: Int32
    let name: String
    let cpuPercent: Double
    let memoryMB: Double

    var icon: NSImage {
        NSRunningApplication(processIdentifier: id)?.icon
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
    }
}

/// Samples per-process CPU and memory usage via `top`, similar to Activity Monitor / iStat Menus'
/// "top processes" list. Only runs while the Monitor tab is visible — `top -l 2 -s 1` takes ~1s
/// per sample, so it's throttled rather than polled continuously.
@MainActor
final class ProcessMonitor: ObservableObject {
    static let shared = ProcessMonitor()

    @Published var topByCPU: [ProcessUsage] = []
    @Published var topByMemory: [ProcessUsage] = []
    @Published var isLoading = false

    private var isSampling = false

    private init() {}

    func refresh() {
        guard !isSampling else { return }
        isSampling = true
        isLoading = true

        Task.detached(priority: .utility) {
            let usages = Self.sampleProcesses()
            await MainActor.run {
                self.topByCPU = Array(usages.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(8))
                self.topByMemory = Array(usages.sorted { $0.memoryMB > $1.memoryMB }.prefix(8))
                self.isLoading = false
                self.isSampling = false
            }
        }
    }

    nonisolated private static func sampleProcesses() -> [ProcessUsage] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        // Two samples 1s apart give a meaningful %CPU delta instead of an instantaneous spike.
        task.arguments = ["-l", "2", "-s", "1", "-o", "cpu", "-n", "60", "-stats", "pid,command,cpu,mem"]

        let outPipe = Pipe()
        task.standardOutput = outPipe
        // Discard stderr directly instead of piping it: an unread Pipe can fill its OS
        // buffer and make `top` block on write, which would hang readDataToEndOfFile()
        // below forever.
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return []
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        // top -l 2 prints two full samples back-to-back, each starting with its own "PID
        // COMMAND ..." header line (with no blank line separating the samples). Use the
        // LAST header so only the second, more accurate sample's rows are parsed.
        let headerRegex = try! NSRegularExpression(pattern: #"^PID\s+COMMAND"#, options: [.anchorsMatchLines])
        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let lastHeaderMatch = headerRegex.matches(in: output, range: fullRange).last,
              let headerRange = Range(lastHeaderMatch.range, in: output) else { return [] }
        let rowsText = output[headerRange.upperBound...]

        let rowRegex = try! NSRegularExpression(
            pattern: #"^\s*(\d+)\s+(.+?)\s+([\d.]+)\s+([\d.]+[KMGT]?[+\-]?)\s*$"#
        )

        var results: [ProcessUsage] = []
        for line in rowsText.split(separator: "\n") {
            let s = String(line)
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            guard let match = rowRegex.firstMatch(in: s, range: range) else { continue }
            guard
                let pidRange = Range(match.range(at: 1), in: s),
                let nameRange = Range(match.range(at: 2), in: s),
                let cpuRange = Range(match.range(at: 3), in: s),
                let memRange = Range(match.range(at: 4), in: s),
                let pid = Int32(s[pidRange]),
                let cpu = Double(s[cpuRange])
            else { continue }

            let truncatedName = String(s[nameRange]).trimmingCharacters(in: .whitespaces)
            let memoryMB = parseMemoryMB(String(s[memRange]))
            let name = displayName(forPID: pid, fallback: truncatedName)
            results.append(ProcessUsage(id: pid, name: name, cpuPercent: cpu, memoryMB: memoryMB))
        }
        return results
    }

    /// `top`'s COMMAND column truncates at a fixed width (e.g. "Google Chrome He" instead of
    /// "Google Chrome Helper (Renderer)"). Resolve the real name the same way Activity Monitor
    /// does: the running app's localized name when there is one, otherwise the untruncated
    /// executable name via libproc.
    nonisolated private static func displayName(forPID pid: Int32, fallback: String) -> String {
        if let appName = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return appName
        }
        if let path = pidExecutablePath(pid) {
            return (path as NSString).lastPathComponent
        }
        return fallback
    }

    nonisolated private static func pidExecutablePath(_ pid: Int32) -> String? {
        var buffer = [Int8](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    nonisolated private static func parseMemoryMB(_ raw: String) -> Double {
        var s = raw
        if s.hasSuffix("+") || s.hasSuffix("-") { s.removeLast() }
        var unit: Character = "B"
        if let last = s.last, "KMGT".contains(last) {
            unit = last
            s.removeLast()
        }
        guard let value = Double(s) else { return 0 }
        switch unit {
        case "K": return value / 1024
        case "M": return value
        case "G": return value * 1024
        case "T": return value * 1024 * 1024
        default: return value / 1_000_000 // raw bytes
        }
    }
}
