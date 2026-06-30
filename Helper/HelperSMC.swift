import Foundation
import IOKit

// SMC param layout — must match the kernel's AppleSMC struct.
private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
private struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
        (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
}

/// Root-only SMC charge control, covering the full M-series. The clean charge-inhibit
/// keys (CHTE/CH0C) hold the battery on AC without discharging on M1/M2/M3; M4 lacks
/// them, so we fall back to disabling the power adapter (CHIE/CH0J) — a discharge-to-hold
/// approach. The chip-appropriate method is detected once at startup.
enum HelperSMC {
    /// How this Mac's SMC stops charging.
    private enum Method {
        /// Clean charge inhibit: 0 = allow charging, 1 = inhibit (stays on AC). CHTE/CH0C.
        case inhibit(key: String)
        /// Adapter disable: 0 = adapter on, `off` = adapter off (forces discharge). CHIE/CH0J.
        case adapter(key: String, off: UInt8)
    }

    /// Detected once; SMC key schema is fixed per machine.
    private static let method: Method? = detectMethod()

    /// The adapter (CHIE/CH0J) key + its "off" value, regardless of whether a cleaner
    /// charge-inhibit key exists. Used by force-discharge (Sailing Mode).
    private static let adapter: (key: String, off: UInt8)? = detectAdapter()

    private static func detectAdapter() -> (key: String, off: UInt8)? {
        guard let conn = open() else { return nil }
        defer { IOServiceClose(conn) }
        if available(conn, "CHIE") { return ("CHIE", 0x08) }
        if available(conn, "CH0J") { return ("CH0J", 0x20) }
        return nil
    }

    private static func detectMethod() -> Method? {
        guard let conn = open() else { return nil }
        defer { IOServiceClose(conn) }
        // Prefer clean charge-inhibit keys (M1/M2/M3), then adapter keys (M4).
        if available(conn, "CHTE") { return .inhibit(key: "CHTE") }
        if available(conn, "CH0C") { return .inhibit(key: "CH0C") }
        if available(conn, "CHIE") { return .adapter(key: "CHIE", off: 0x08) }
        if available(conn, "CH0J") { return .adapter(key: "CH0J", off: 0x20) }
        return nil
    }

    // MARK: - Public API (charging allowed = true means the battery may charge)

    static func setAdapterEnabled(_ allowed: Bool) -> Bool {
        guard let method = method, let conn = open() else { return false }
        defer { IOServiceClose(conn) }
        switch method {
        case .inhibit(let key):
            return write(conn, key, allowed ? 0x00 : 0x01)
        case .adapter(let key, let off):
            return write(conn, key, allowed ? 0x00 : off)
        }
    }

    static func getAdapterEnabled() -> Bool {
        guard let method = method, let conn = open() else { return true }
        defer { IOServiceClose(conn) }
        let key: String
        switch method {
        case .inhibit(let k): key = k
        case .adapter(let k, _): key = k
        }
        // For both methods, 0 means "charging allowed / adapter on".
        return read(conn, key) == 0
    }

    /// Always uses the adapter key (CHIE/CH0J) so the battery actively discharges,
    /// independent of the chip's preferred charge-stop method.
    static func setForceDischarge(_ discharging: Bool) -> Bool {
        guard let adapter = adapter, let conn = open() else { return false }
        defer { IOServiceClose(conn) }
        return write(conn, adapter.key, discharging ? adapter.off : 0x00)
    }

    // MARK: - Fan control (fan 0)

    /// (fanCount, minRPM, maxRPM). Returns (0,0,0) on fanless Macs.
    static func getFanInfo() -> (count: Int, min: Int, max: Int) {
        guard let conn = open() else { return (0, 0, 0) }
        defer { IOServiceClose(conn) }
        let count = Int(read(conn, "FNum"))
        guard count > 0 else { return (0, 0, 0) }
        let minRPM = Int(readFPE2(conn, "F0Mn"))
        let maxRPM = Int(readFPE2(conn, "F0Mx"))
        return (count, minRPM, maxRPM)
    }

    /// Force fan 0 to `rpm` (manual, clamped to the fan's reported min/max) or restore
    /// automatic control.
    static func setFanManual(_ manual: Bool, rpm: Int) -> Bool {
        guard let conn = open() else { return false }
        defer { IOServiceClose(conn) }
        if manual {
            let minRPM = Int(readFPE2(conn, "F0Mn"))
            let maxReported = Int(readFPE2(conn, "F0Mx"))
            // Fall back to a sane ceiling if the chip didn't report a usable max.
            let maxRPM = maxReported > minRPM ? maxReported : max(minRPM, 8000)
            let clamped = min(max(rpm, minRPM), maxRPM)
            let okTarget = writeFPE2(conn, "F0Tg", clamped)
            let okMode = write(conn, "F0Md", 1)   // forced
            return okTarget && okMode
        } else {
            return write(conn, "F0Md", 0)          // auto
        }
    }

    /// fpe2: unsigned fixed-point, value = raw / 4, big-endian 2 bytes.
    private static func readFPE2(_ conn: io_connect_t, _ key: String) -> Int {
        guard let info = keyInfo(conn, key) else { return 0 }
        var inp = SMCParamStruct()
        inp.key = fourCC(key); inp.keyInfo.dataSize = info.dataSize; inp.data8 = 5
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        guard r == kIOReturnSuccess && out.result == 0 else { return 0 }
        let raw = (UInt32(out.bytes.0) << 8) | UInt32(out.bytes.1)
        return Int(raw / 4)
    }

    private static func writeFPE2(_ conn: io_connect_t, _ key: String, _ rpm: Int) -> Bool {
        guard let info = keyInfo(conn, key) else { return false }
        let raw = UInt32(max(0, rpm) * 4)
        var inp = SMCParamStruct()
        inp.key = fourCC(key)
        inp.keyInfo.dataSize = info.dataSize
        inp.keyInfo.dataType = info.dataType
        inp.data8 = 6
        inp.bytes.0 = UInt8((raw >> 8) & 0xFF)
        inp.bytes.1 = UInt8(raw & 0xFF)
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        return r == kIOReturnSuccess && out.result == 0
    }

    // MARK: - SMC primitives

    private static func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for c in s.utf8.prefix(4) { r = (r << 8) + UInt32(c) }
        return r
    }

    private static func open() -> io_connect_t? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
        return conn
    }

    private static func keyInfo(_ conn: io_connect_t, _ key: String) -> SMCKeyInfoData? {
        var inp = SMCParamStruct(); inp.key = fourCC(key); inp.data8 = 9 // kSMCGetKeyInfo
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        guard r == kIOReturnSuccess && out.result == 0 else { return nil }
        return out.keyInfo
    }

    /// A key counts as available only if it exists with a non-zero size.
    private static func available(_ conn: io_connect_t, _ key: String) -> Bool {
        guard let info = keyInfo(conn, key) else { return false }
        return info.dataSize > 0
    }

    private static func read(_ conn: io_connect_t, _ key: String) -> UInt8 {
        guard let info = keyInfo(conn, key) else { return 0 }
        var inp = SMCParamStruct()
        inp.key = fourCC(key)
        inp.keyInfo.dataSize = info.dataSize
        inp.data8 = 5 // kSMCReadKey
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        guard r == kIOReturnSuccess && out.result == 0 else { return 0 }
        return out.bytes.0
    }

    /// Writes the low byte (rest zero) — valid for the ui8/ui32 charge keys we use.
    private static func write(_ conn: io_connect_t, _ key: String, _ value: UInt8) -> Bool {
        guard let info = keyInfo(conn, key) else { return false }
        var inp = SMCParamStruct()
        inp.key = fourCC(key)
        inp.keyInfo.dataSize = info.dataSize
        inp.keyInfo.dataType = info.dataType
        inp.data8 = 6 // kSMCWriteKey
        inp.bytes.0 = value
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        return r == kIOReturnSuccess && out.result == 0
    }
}
