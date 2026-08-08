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

    /// The true hardware minimum per fan, captured before we ever raise F0*Mn to force a
    /// speed. Lets us restore it, and keep reporting the real min while an override is live.
    /// The helper is a long-lived daemon, so this survives across XPC calls.
    private static var hardwareMin: [Int: Int] = [:]

    private static func fanLog(_ msg: String) { NSLog("[macwake.fan] %@", msg) }

    /// UInt32 four-char-code → readable string (e.g. 0x666C7420 → "flt ").
    private static func typeString(_ code: UInt32) -> String {
        let b = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                 UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: b, encoding: .ascii) ?? "?"
    }

    /// The fan mode key's casing is generation-specific: `F0Md` up to M4, lowercase `F0md`
    /// on M5 (Mac17,x). Only the name differs, so ask the SMC which one it has instead of
    /// guessing — the uppercase-only lookup made M5 report manual fan control as unsupported
    /// while the key sat right there under another name, and it also meant the restore path
    /// wrote a key that did not exist.
    private static func fanModeKey(_ conn: io_connect_t, _ index: Int) -> String? {
        for name in ["F\(index)Md", "F\(index)md"] where keyInfo(conn, name) != nil {
            return name
        }
        return nil
    }

    /// AppleSMC key attributes: 0x80 = readable, 0x40 = writable. The previous check tested
    /// 0x02, an unrelated flag, so every dump labelled writable keys read-only — including
    /// the charge-control dump added in 1.54.
    private static func accessSuffix(_ attributes: UInt8) -> String {
        var suffix = ""
        if attributes & 0x80 != 0 { suffix += "r" }
        if attributes & 0x40 != 0 { suffix += "w" }
        return suffix.isEmpty ? "-" : suffix
    }

    /// Dumps every fan key with its SMC type and current value, then probes a write to the
    /// keys manual control depends on. Read by the app's "Copy fan diagnostics" button —
    /// the only reliable way to see what a remote tester's daemon is actually doing.
    static func fanDiagnostics() -> String {
        guard let conn = open() else { return "SMC open() FAILED" }
        defer { IOServiceClose(conn) }
        var out = "uid=\(getuid()) euid=\(geteuid())\n"
        let count = Int(read(conn, "FNum"))
        out += "FNum=\(count)\n"
        // Enumerate every F* key the SMC exposes. If another tool drives these fans through
        // a key we don't know about, a diff of this dump before/after it runs reveals it.
        out += "--- all F* keys ---\n" + enumerateFanKeys(conn) + "--- end ---\n"
        for i in 0..<max(count, 1) {
            for suffix in ["Ac", "Mn", "Mx", "Tg", "Md", "Sf"] {
                let key = "F\(i)\(suffix)"
                if let info = keyInfo(conn, key) {
                    let type = typeString(info.dataType)
                    let value = type == "flt " || type == "fpe2" ? "\(readFanRPM(conn, key))" : "\(read(conn, key))"
                    out += "\(key) type=\(type) size=\(info.dataSize) value=\(value)\n"
                } else {
                    out += "\(key) ABSENT\n"
                }
            }
            // Live probe: a successful write proves nothing — only the fan's own RPM
            // afterwards shows whether the SMC honoured it. Drive it well above idle,
            // give the fan time to spin up, then measure.
            let hwMin = hardwareMin[i] ?? readFanRPM(conn, "F\(i)Mn")
            let maxRPM = readFanRPM(conn, "F\(i)Mx")
            // Remember what the fan was set to so the probe can put it back — a manual
            // override in progress must survive a diagnostics run.
            let priorTarget = readFanRPM(conn, "F\(i)Tg")
            let priorMin = readFanRPM(conn, "F\(i)Mn")
            // A target below what the fan is already doing can never show an increase, so
            // the probe returned "no change" on any Mac whose fans were spinning fast — a
            // false negative rather than a result. Aim above the current speed, still bounded
            // by the reported maximum.
            let currentRPM = readFanRPM(conn, "F\(i)Ac")
            let ceiling = maxRPM > hwMin ? maxRPM : 6000
            let probe = min(max(hwMin + 1800, currentRPM + 1200), ceiling)
            let wTg = writeFanRPM(conn, "F\(i)Tg", probe)
            let wMn = writeFanRPM(conn, "F\(i)Mn", probe)
            let modeKey = fanModeKey(conn, i)
            let wMd = modeKey.map { write(conn, $0, 1) } ?? false
            out += "probe F\(i): mode key \(modeKey ?? "ABSENT (neither Md nor md)")\n"
            out += "probe F\(i): target=\(probe) writeTg=\(wTg) writeMn=\(wMn) writeMd=\(wMd)\n"
            let rpmBefore = readFanRPM(conn, "F\(i)Ac")
            Thread.sleep(forTimeInterval: 4.0)
            let rpmAfter = readFanRPM(conn, "F\(i)Ac")
            out += "probe F\(i): RPM \(rpmBefore) -> \(rpmAfter) after 4s, Tg reads back \(readFanRPM(conn, "F\(i)Tg"))"
            out += rpmAfter > rpmBefore + 200 ? "  >>> FAN RESPONDED\n" : "  >>> no change\n"
            // Always restore what we found. Skipping this while a manual override was
            // active left the user's chosen target overwritten by the probe value.
            _ = writeFanRPM(conn, "F\(i)Tg", priorTarget)
            _ = writeFanRPM(conn, "F\(i)Mn", priorMin)
            if hardwareMin[i] == nil, let modeKey { _ = write(conn, modeKey, 0) }
            out += "probe F\(i): restored Tg=\(priorTarget) Mn=\(priorMin)\n"
        }
        out += chargeDiagnostics(conn)
        return out
    }

    /// Which mechanism this Mac's SMC offers for stopping charge, and which one we picked.
    ///
    /// The two differ in a way users feel: a charge-inhibit key holds the battery while the
    /// Mac stays on adapter power, whereas the adapter key cuts input so the battery
    /// actually drains to hold the limit. Reports on hardware where charge limiting behaved
    /// unexpectedly could not say which path was taken, so this reads them out directly.
    private static func chargeDiagnostics(_ conn: io_connect_t) -> String {
        var out = "--- charge control ---\n"
        out += "method=\(chargeControlMethod())\n"
        for key in ["CHTE", "CH0C", "CHIE", "CH0J"] {
            guard let info = keyInfo(conn, key) else {
                out += "\(key) ABSENT\n"
                continue
            }
            let writable = accessSuffix(info.dataAttributes)
            out += "\(key) type=\(typeString(info.dataType)) size=\(info.dataSize)"
            out += " attr=0x\(String(info.dataAttributes, radix: 16))\(writable) value=\(read(conn, key))\n"
        }
        // Probing the four keys we know about only ever confirms what we already guessed.
        // Newer Macs may expose a charge-inhibit key under a name nobody has seen yet, and
        // a machine that falls back to cutting adapter input is exactly where such a key
        // would be worth finding — so dump every CH* key the SMC actually has. Discovery
        // only: an unknown key is never written to, because writing SMC keys blind can
        // change hardware behaviour in ways we cannot predict.
        out += "--- all CH* keys ---\n" + enumerateChargeKeys(conn) + "--- end ---\n"
        return out
    }

    /// `"inhibit:<key>"`, `"adapter:<key>"` or `"none"` — see the protocol documentation.
    static func chargeControlMethod() -> String {
        switch method {
        case .inhibit(let key): return "inhibit:\(key)"
        case .adapter(let key, _): return "adapter:\(key)"
        case nil: return "none"
        }
    }

    private static func enumerateChargeKeys(_ conn: io_connect_t) -> String {
        var inp = SMCParamStruct()
        inp.key = fourCC("#KEY"); inp.data8 = 5
        if let info = keyInfo(conn, "#KEY") { inp.keyInfo.dataSize = info.dataSize }
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        guard IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz) == kIOReturnSuccess else {
            return "(key enumeration unavailable)\n"
        }
        let total = (UInt32(out.bytes.0) << 24) | (UInt32(out.bytes.1) << 16)
                  | (UInt32(out.bytes.2) << 8) | UInt32(out.bytes.3)
        var text = ""
        for index in 0..<Int(total) {
            var q = SMCParamStruct()
            q.data8 = 8
            q.data32 = UInt32(index)
            var r = SMCParamStruct(); var rs = MemoryLayout<SMCParamStruct>.stride
            guard IOConnectCallStructMethod(conn, 2, &q, MemoryLayout<SMCParamStruct>.stride, &r, &rs) == kIOReturnSuccess else { continue }
            let name = typeString(r.key)
            guard name.hasPrefix("CH") else { continue }
            guard let info = keyInfo(conn, name) else { continue }
            let writable = accessSuffix(info.dataAttributes)
            text += "\(name) \(typeString(info.dataType)) size=\(info.dataSize)"
            text += " attr=0x\(String(info.dataAttributes, radix: 16))\(writable) value=\(read(conn, name))\n"
        }
        return text.isEmpty ? "(no CH* keys found)\n" : text
    }

    /// Walks the SMC's key table and reports every key whose name starts with "F", with its
    /// type, write attribute and current value. Guessing key names only finds keys we already
    /// know; this shows what the machine actually has.
    private static func enumerateFanKeys(_ conn: io_connect_t) -> String {
        var inp = SMCParamStruct()
        inp.key = fourCC("#KEY"); inp.data8 = 5
        if let info = keyInfo(conn, "#KEY") { inp.keyInfo.dataSize = info.dataSize }
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        guard IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz) == kIOReturnSuccess else {
            return "(key enumeration unavailable)\n"
        }
        let total = (UInt32(out.bytes.0) << 24) | (UInt32(out.bytes.1) << 16)
                  | (UInt32(out.bytes.2) << 8) | UInt32(out.bytes.3)
        var text = ""
        for index in 0..<Int(total) {
            var q = SMCParamStruct()
            q.data8 = 8               // read key by index
            q.data32 = UInt32(index)
            var r = SMCParamStruct(); var rs = MemoryLayout<SMCParamStruct>.stride
            guard IOConnectCallStructMethod(conn, 2, &q, MemoryLayout<SMCParamStruct>.stride, &r, &rs) == kIOReturnSuccess else { continue }
            let name = typeString(r.key)
            guard name.hasPrefix("F") else { continue }
            guard let info = keyInfo(conn, name) else { continue }
            let type = typeString(info.dataType)
            let value = (type == "flt " || type == "fpe2") ? "\(readFanRPM(conn, name))" : "\(read(conn, name))"
            let writable = accessSuffix(info.dataAttributes)
            text += "\(name) \(type) size=\(info.dataSize) attr=0x\(String(info.dataAttributes, radix: 16))\(writable) value=\(value)\n"
        }
        return text.isEmpty ? "(no F* keys found)\n" : text
    }

    /// (fanCount, minRPM, maxRPM). Returns (0,0,0) on fanless Macs.
    static func getFanInfo() -> (count: Int, min: Int, max: Int) {
        guard let conn = open() else { return (0, 0, 0) }
        defer { IOServiceClose(conn) }
        let count = Int(read(conn, "FNum"))
        guard count > 0 else { return (0, 0, 0) }
        // Report the saved hardware min if we've overridden F0Mn, else read it live.
        let minRPM = hardwareMin[0] ?? readFanRPM(conn, "F0Mn")
        let maxRPM = readFanRPM(conn, "F0Mx")
        return (count, minRPM, maxRPM)
    }

    /// Force every fan to `rpm`, or restore automatic control.
    ///
    /// Apple Silicon has no working "forced target mode" (F0Md/F0Tg, the Intel path) —
    /// the SMC ignores it. The mechanism that actually works there, and what Macs Fan
    /// Control uses, is to raise the fan's MINIMUM (F0Mn): the system controller then
    /// keeps the fan at least that fast. We do both so Intel and Apple Silicon are covered,
    /// and log the full picture so a tester's Console reveals exactly what engaged.
    static func setFanManual(_ manual: Bool, rpm: Int) -> Bool {
        guard let conn = open() else { fanLog("open() failed"); return false }
        defer { IOServiceClose(conn) }
        let count = max(1, Int(read(conn, "FNum")))
        fanLog("setFanManual(manual=\(manual), rpm=\(rpm)) fans=\(count)")
        var ok = false
        for i in 0..<count {
            let before = readFanRPM(conn, "F\(i)Ac")
            if manual {
                if hardwareMin[i] == nil { hardwareMin[i] = readFanRPM(conn, "F\(i)Mn") }
                let hwMin = hardwareMin[i] ?? 0
                let maxReported = readFanRPM(conn, "F\(i)Mx")
                let maxRPM = maxReported > hwMin ? maxReported : max(hwMin, 8000)
                let clamped = min(max(rpm, hwMin), maxRPM)
                // F0Tg is the one key that accepts writes on Apple Silicon (F0Mn and F0Md
                // are read-only there); the others are best-effort for Intel, where forced
                // mode is what matters. Succeed if EITHER path took — gating on F0Mn made
                // every Apple Silicon call report failure even when the target was set.
                // Escalate through the known mechanisms and VERIFY each one by reading the
                // target back. A write call returning success is not proof: on Apple
                // Silicon the SMC accepts a fan write and silently discards it, which is
                // how manual mode looked enabled while the fan never moved.
                var took = writeFanRPM(conn, "F\(i)Tg", clamped) && readFanRPM(conn, "F\(i)Tg") == clamped
                if !took {
                    // Intel path: forced mode first, then the target.
                    if let modeKey = fanModeKey(conn, i) { _ = write(conn, modeKey, 1) }
                    took = writeFanRPM(conn, "F\(i)Tg", clamped) && readFanRPM(conn, "F\(i)Tg") == clamped
                }
                if !took {
                    // Older Macs gate manual control behind the FS! bitmask (one bit per fan).
                    let mask = read(conn, "FS! ")
                    _ = write(conn, "FS! ", mask | UInt8(1 << i))
                    took = writeFanRPM(conn, "F\(i)Tg", clamped) && readFanRPM(conn, "F\(i)Tg") == clamped
                }
                if !took {
                    // Some controllers only honour a raised floor.
                    took = writeFanRPM(conn, "F\(i)Mn", clamped) && readFanRPM(conn, "F\(i)Mn") == clamped
                }
                fanLog("F\(i) target=\(clamped) tookEffect=\(took) actualBefore=\(before)")
                ok = took || ok
            } else {
                // A zero target is what these keys hold when the system owns the fan, so
                // that — not the unwritable mode key — is how auto control is handed back.
                let okTg = writeFanRPM(conn, "F\(i)Tg", 0)
                if let hwMin = hardwareMin[i] { _ = writeFanRPM(conn, "F\(i)Mn", hwMin) }
                // Restore must use the same resolved key: writing the uppercase name on a
                // machine that only has the lowercase one silently skipped handing control back.
                if let modeKey = fanModeKey(conn, i) { _ = write(conn, modeKey, 0) }
                let mask = read(conn, "FS! ")
                _ = write(conn, "FS! ", mask & ~UInt8(1 << i))
                hardwareMin[i] = nil
                fanLog("F\(i) restore -> Tg=0 (\(okTg))")
                ok = okTg || ok
            }
        }
        return ok
    }

    /// Fan keys are `fpe2` (2-byte big-endian fixed-point, raw/4) on Intel but `flt `
    /// (4-byte little-endian Float32) on Apple Silicon. Decode per the key's reported
    /// type — an fpe2-only read returns garbage min/max on M-series Macs.
    private static func readFanRPM(_ conn: io_connect_t, _ key: String) -> Int {
        guard let info = keyInfo(conn, key) else { return 0 }
        var inp = SMCParamStruct()
        inp.key = fourCC(key); inp.keyInfo.dataSize = info.dataSize; inp.data8 = 5
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        guard r == kIOReturnSuccess && out.result == 0 else { return 0 }
        if info.dataType == fourCC("flt ") {
            var f: Float32 = 0
            withUnsafeMutableBytes(of: &f) { p in
                p[0] = out.bytes.0; p[1] = out.bytes.1; p[2] = out.bytes.2; p[3] = out.bytes.3
            }
            return f.isFinite && f >= 0 ? Int(f) : 0
        }
        let raw = (UInt32(out.bytes.0) << 8) | UInt32(out.bytes.1)
        return Int(raw / 4)
    }

    /// Encode the target RPM in the key's own type: Float32 LE on Apple Silicon
    /// (`flt `), fpe2 on Intel. Writing fpe2 bytes into an `flt ` key silently sets a
    /// garbage target — the reason manual fan control never engaged on M-series.
    private static func writeFanRPM(_ conn: io_connect_t, _ key: String, _ rpm: Int) -> Bool {
        guard let info = keyInfo(conn, key) else { return false }
        var inp = SMCParamStruct()
        inp.key = fourCC(key)
        inp.keyInfo.dataSize = info.dataSize
        inp.keyInfo.dataType = info.dataType
        inp.data8 = 6
        if info.dataType == fourCC("flt ") {
            let f = Float32(max(0, rpm))
            withUnsafeBytes(of: f) { p in
                inp.bytes.0 = p[0]; inp.bytes.1 = p[1]; inp.bytes.2 = p[2]; inp.bytes.3 = p[3]
            }
        } else {
            let raw = UInt32(max(0, rpm) * 4)
            inp.bytes.0 = UInt8((raw >> 8) & 0xFF)
            inp.bytes.1 = UInt8(raw & 0xFF)
        }
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
        if info.dataType == fourCC("flt ") {
            // Some Apple Silicon keys (e.g. F0Md on certain models) are Float32 — a raw
            // byte write would encode a denormal ≈ 0 and silently no-op.
            let f = Float32(value)
            withUnsafeBytes(of: f) { p in
                inp.bytes.0 = p[0]; inp.bytes.1 = p[1]; inp.bytes.2 = p[2]; inp.bytes.3 = p[3]
            }
        } else {
            inp.bytes.0 = value
        }
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        return r == kIOReturnSuccess && out.result == 0
    }
}
