#if !APPSTORE
import Foundation
import IOKit

// MARK: - Private IOHIDEventSystem API (Apple Silicon thermal sensors)
// These symbols live in IOKit but are not exposed in the public Swift overlay.
// Used by Stats / iStat Menus to read SoC/NAND temperatures on Apple Silicon.

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject?, _ matching: CFDictionary?) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject?) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject?, _ key: CFString) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject?, _ type: Int64, _ options: Int32, _ timeout: Int64) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject?, _ field: Int32) -> Double

/// Reads Apple Silicon temperature sensors (SoC die, NAND/SSD, and GPU where exposed)
/// via the private IOHIDEventSystemClient thermal-sensor interface.
final class ThermalSensors {
    static let shared = ThermalSensors()

    private let kIOHIDEventTypeTemperature: Int64 = 15
    private let tempField: Int32

    private var client: AnyObject?
    private var services: [AnyObject] = []
    private var names: [String] = []   // name per service, index-aligned with `services`

    /// Whether the private API initialized and found any temperature sensors.
    private(set) var isAvailable = false

    private init() {
        tempField = Int32(kIOHIDEventTypeTemperature << 16)
        setup()
    }

    private func setup() {
        guard let clientU = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
        let c = clientU.takeRetainedValue()
        let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x05]
        _ = IOHIDEventSystemClientSetMatching(c, matching as CFDictionary)

        guard let servicesU = IOHIDEventSystemClientCopyServices(c) else { return }
        let svcs = servicesU.takeRetainedValue() as [AnyObject]

        client = c
        services = svcs
        names = svcs.map { svc in
            guard let nU = IOHIDServiceClientCopyProperty(svc, "Product" as CFString) else { return "" }
            return (nU.takeRetainedValue() as? String) ?? ""
        }
        isAvailable = !svcs.isEmpty
    }

    private func read(_ service: AnyObject) -> Double? {
        guard let eU = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0) else { return nil }
        let ev = eU.takeRetainedValue()
        let v = IOHIDEventGetFloatValue(ev, tempField)
        // Discard invalid / out-of-range readings.
        guard v.isFinite, v > 0, v < 120 else { return nil }
        return v
    }

    /// Average of all sensors whose name matches any of the given substrings (case-insensitive).
    private func average(matching substrings: [String]) -> Double? {
        var sum = 0.0
        var count = 0
        for (i, name) in names.enumerated() {
            let lower = name.lowercased()
            guard substrings.contains(where: { lower.contains($0) }) else { continue }
            if let v = read(services[i]) {
                sum += v
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    /// SoC / CPU die temperature — average of the PMU "tdie" sensors.
    var cpuTemperature: Double? { average(matching: ["tdie"]) }

    /// GPU temperature — only some Apple Silicon variants expose discrete GPU sensors
    /// (e.g. "Tg.."). Returns nil on unified-SoC machines that don't.
    var gpuTemperature: Double? { average(matching: ["tgpu", "gpu"]) }

    /// SSD / NAND flash temperature — average of the "NAND" channel sensors.
    var ssdTemperature: Double? { average(matching: ["nand", "ssd"]) }
}

#endif
