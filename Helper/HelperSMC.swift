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
    private static var hardwareMinStorage: [Int: Int] = [:]

    /// Read from XPC threads (`getFanInfo`) while the fan queue mutates it, so it is guarded.
    private static var hardwareMin: HardwareMinAccess { HardwareMinAccess() }

    private struct HardwareMinAccess {
        subscript(index: Int) -> Int? {
            get { fanStateLock.lock(); defer { fanStateLock.unlock() }; return hardwareMinStorage[index] }
            nonmutating set {
                fanStateLock.lock(); defer { fanStateLock.unlock() }
                hardwareMinStorage[index] = newValue
            }
        }
    }

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

    /// Dumps every fan key with its SMC type and current value, then runs the real engage
    /// sequence against each fan and measures whether it responds. Read by the app's "Copy fan
    /// diagnostics" button — the only reliable way to see what a remote tester's daemon is
    /// actually doing. Runs on the fan queue so it can never interleave with a live request.
    static func fanDiagnostics(reply: @escaping (String) -> Void) {
        fanQueue.async { reply(fanDiagnosticsReport()) }
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    private static func fanDiagnosticsReport() -> String {
        guard let conn = open() else { return "SMC open() FAILED" }
        defer { IOServiceClose(conn) }
        var out = "uid=\(getuid()) euid=\(geteuid())\n"
        out += "model=\(sysctlString("hw.model")) chip=\(sysctlString("machdep.cpu.brand_string"))\n"
        let count = Int(read(conn, "FNum"))
        out += "FNum=\(count)\n"
        if let info = keyInfo(conn, "Ftst") {
            out += "Ftst type=\(typeString(info.dataType)) size=\(info.dataSize) attr=0x\(String(info.dataAttributes, radix: 16))\(accessSuffix(info.dataAttributes)) value=\(read(conn, "Ftst")) heldByDaemon=\(ftstHeld)\n"
        } else {
            out += "Ftst ABSENT (no unlock step on this Mac)\n"
        }
        // Enumerate every F* key the SMC exposes. If another tool drives these fans through
        // a key we don't know about, a diff of this dump before/after it runs reveals it.
        out += "--- all F* keys ---\n" + enumerateFanKeys(conn) + "--- end ---\n"
        for i in 0..<max(count, 1) {
            for suffix in ["Ac", "Mn", "Mx", "Tg", "Md", "md", "Sf"] {
                let key = "F\(i)\(suffix)"
                if let info = keyInfo(conn, key) {
                    let type = typeString(info.dataType)
                    let value = type == "flt " || type == "fpe2" ? "\(readFanRPM(conn, key))" : "\(read(conn, key))"
                    out += "\(key) type=\(type) size=\(info.dataSize) value=\(value)\n"
                } else if suffix != "Md" && suffix != "md" {
                    out += "\(key) ABSENT\n"
                }
            }
            if manualFans.contains(i) {
                out += "probe F\(i): skipped — manual control is active on this fan\n"
                continue
            }
            // Live probe through the real engage path: a successful write proves nothing —
            // only the fan's own RPM afterwards shows whether the SMC honoured it. A target
            // below what the fan is already doing can never show an increase, so aim above
            // the current speed, still bounded by the reported maximum.
            let hwMin = readFanRPM(conn, "F\(i)Mn")
            let maxRPM = readFanRPM(conn, "F\(i)Mx")
            let currentRPM = readFanRPM(conn, "F\(i)Ac")
            let ceiling = maxRPM > hwMin ? maxRPM : 6000
            let probe = min(max(hwMin + 1800, currentRPM + 1200), ceiling)
            let modeKey = fanModeKey(conn, i)
            out += "probe F\(i): mode key \(modeKey ?? "ABSENT (neither Md nor md)") mode=\(modeKey.flatMap { readMode(conn, $0) }.map(String.init) ?? "-")\n"
            let started = Date()
            let engaged = engageFan(conn, index: i, rpm: probe, generation: fanCurrentGeneration())
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            out += "probe F\(i): target=\(probe) engaged=\(engaged) after \(elapsed)s mode=\(modeKey.flatMap { readMode(conn, $0) }.map(String.init) ?? "-") Ftst=\(read(conn, "Ftst"))\n"
            if engaged {
                let rpmBefore = readFanRPM(conn, "F\(i)Ac")
                Thread.sleep(forTimeInterval: 4.0)
                let rpmAfter = readFanRPM(conn, "F\(i)Ac")
                out += "probe F\(i): RPM \(rpmBefore) -> \(rpmAfter) after 4s, Tg reads back \(readFanRPM(conn, "F\(i)Tg"))"
                out += rpmAfter > rpmBefore + 200 ? "  >>> FAN RESPONDED\n" : "  >>> no change\n"
                // Always hand the fan back — a probe must never leave a manual override behind.
                releaseFan(conn, index: i)
                out += "probe F\(i): released, mode=\(modeKey.flatMap { readMode(conn, $0) }.map(String.init) ?? "-")\n"
            }
        }
        giveBackFtstIfIdle(conn)
        out += "Ftst after probe=\(read(conn, "Ftst"))\n"
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
        out += "--- candidate firmware charge-limit keys (probe only, never written) ---\n"
        out += probeFirmwareChargeLimitKeys(conn)
        out += "--- end ---\n"
        return out
    }

    // MARK: - Firmware-managed charge limit (bfF0 / bfD0 / bfE0)
    //
    // On some firmware the SMC carries its own charge limit: `bfF0` is the mode (0 = off,
    // 2 = limit active), `bfD0` the upper bound and `bfE0` the lower, both percent as
    // little-endian ui32. The firmware then holds the battery in that band with the adapter
    // still connected — the one thing the adapter-cut path cannot do. The layout comes from
    // the open-source `batt` project and a live trace on an M4 Pro; none of it is documented by
    // Apple, so every step is read back and anything unexpected is released again.

    private static let firmwareModeKey = "bfF0"
    private static let firmwareUpperKey = "bfD0"
    private static let firmwareLowerKey = "bfE0"
    private static let firmwareModeActive: UInt8 = 2

    private static func readBytes(_ conn: io_connect_t, _ key: String) -> [UInt8]? {
        guard let info = keyInfo(conn, key), info.dataSize > 0, info.dataSize <= 32 else { return nil }
        var inp = SMCParamStruct()
        inp.key = fourCC(key); inp.keyInfo.dataSize = info.dataSize; inp.data8 = 5
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        guard r == kIOReturnSuccess && out.result == 0 else { return nil }
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.dataSize))) }
    }

    /// Writes exactly `bytes` — its length must equal the key's size, so a wrong-sized value is
    /// refused here instead of being half-applied.
    private static func writeBytes(_ conn: io_connect_t, _ key: String, _ bytes: [UInt8]) -> Bool {
        guard let info = keyInfo(conn, key), Int(info.dataSize) == bytes.count, bytes.count <= 32 else { return false }
        var inp = SMCParamStruct()
        inp.key = fourCC(key)
        inp.keyInfo.dataSize = info.dataSize
        inp.keyInfo.dataType = info.dataType
        inp.data8 = 6
        withUnsafeMutableBytes(of: &inp.bytes) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        return r == kIOReturnSuccess && out.result == 0
    }

    private static func littleEndian32(_ value: Int) -> [UInt8] {
        let v = UInt32(clamping: value)
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private static func firmwareLimitReadback(_ conn: io_connect_t) -> (mode: UInt8, upper: Int, lower: Int)? {
        guard let mode = readBytes(conn, firmwareModeKey)?.first,
              let upper = readBytes(conn, firmwareUpperKey), upper.count == 4,
              let lower = readBytes(conn, firmwareLowerKey), lower.count == 4 else { return nil }
        func value(_ b: [UInt8]) -> Int { Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24 }
        return (mode, value(upper), value(lower))
    }

    // The firmware limit outlives the process that set it (it clears only on reboot), so this
    // daemon records that IT applied it. /private/var/run is emptied at boot, the same moment
    // the firmware state goes away, so the record can never outlive what it describes. Only a
    // limit carrying this record is ever released or touched — another tool's limit (batt,
    // AlDente) is none of this daemon's business.
    private static let firmwareOwnershipMarker = "/private/var/run/com.jarvisit.macwake.firmware-limit"

    static var firmwareLimitOwned: Bool { FileManager.default.fileExists(atPath: firmwareOwnershipMarker) }

    private static func markFirmwareLimitOwned() {
        FileManager.default.createFile(atPath: firmwareOwnershipMarker, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    private static func clearFirmwareOwnership() {
        try? FileManager.default.removeItem(atPath: firmwareOwnershipMarker)
    }

    static func firmwareLimitSupported() -> Bool {
        guard let conn = open() else { return false }
        defer { IOServiceClose(conn) }
        return firmwareLimitReadback(conn) != nil
    }

    static func verifyFirmwareLimit(upper: Int, lower: Int) -> Bool {
        guard let conn = open() else { return false }
        defer { IOServiceClose(conn) }
        guard let state = firmwareLimitReadback(conn) else { return false }
        return state.mode == firmwareModeActive && state.upper == upper && state.lower == lower
    }

    /// Polls for the state to settle: a write and its readback are not atomic on this SMC.
    private static func awaitFirmwareState(_ conn: io_connect_t, timeout: TimeInterval = 0.6,
                                           _ matches: ((mode: UInt8, upper: Int, lower: Int)) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let state = firmwareLimitReadback(conn), matches(state) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        if let state = firmwareLimitReadback(conn) { return matches(state) }
        return false
    }

    static func setFirmwareLimit(upper: Int, lower: Int) -> Bool {
        guard (2...100).contains(upper), (1..<upper).contains(lower), let conn = open() else { return false }
        defer { IOServiceClose(conn) }
        guard let before = firmwareLimitReadback(conn) else { return false }
        // Something else already holds a firmware limit: taking it over would also erase it on
        // release. Leave it alone and let the caller fall back to another method.
        if before.mode != 0 && !firmwareLimitOwned {
            fanLog("firmware limit already active and not ours — left alone")
            return false
        }
        markFirmwareLimitOwned()
        let applied = writeBytes(conn, firmwareModeKey, [0])
            && writeBytes(conn, firmwareUpperKey, littleEndian32(upper))
            && writeBytes(conn, firmwareLowerKey, littleEndian32(lower))
            && writeBytes(conn, firmwareModeKey, [firmwareModeActive])
            && awaitFirmwareState(conn) { $0.mode == firmwareModeActive && $0.upper == upper && $0.lower == lower }
        if !applied {
            // Anything short of exactly the requested state: leave nothing half-set behind.
            _ = writeBytes(conn, firmwareModeKey, [0])
            clearFirmwareOwnership()
            fanLog("firmware limit \(lower)-\(upper) not confirmed — released")
        }
        return applied
    }

    /// Releases a firmware limit this daemon applied — and only that. True when there is nothing
    /// of ours left to release; false when it could not be confirmed released, in which case
    /// the record stays so a later call (or the next launch) tries again.
    @discardableResult
    static func releaseFirmwareLimit() -> Bool {
        guard firmwareLimitOwned else { return true }
        guard let conn = open() else { return false }
        defer { IOServiceClose(conn) }
        guard let state = firmwareLimitReadback(conn) else { return false }
        if state.mode != 0 {
            guard writeBytes(conn, firmwareModeKey, [0]),
                  awaitFirmwareState(conn, { $0.mode == 0 }) else { return false }
        }
        clearFirmwareOwnership()
        return true
    }

    /// A machine that falls back to cutting adapter input (CHIE/CH0J) drains the battery
    /// to hold a limit — there is no clean, adapter-powered hold on that path today. Whether
    /// a firmware-managed alternative exists on some Macs is an open question (see #19): the
    /// open-source `batt` project documents `bfF0`/`bfD0`/`bfE0` as a distinct charge-limit
    /// backend on newer firmware, separate from the CH* keys this codebase already knows.
    /// This probes their presence, type, size, and write attribute ONLY — it never writes
    /// them. An undocumented key accepting a write is not evidence it is safe to write;
    /// this codebase's existing boundary (see `enumerateChargeKeys`) is to never write a key
    /// it doesn't already understand, and that boundary applies here too. Purely diagnostic,
    /// so a report from affected hardware can inform whether supporting this is worthwhile.
    private static func probeFirmwareChargeLimitKeys(_ conn: io_connect_t) -> String {
        var out = ""
        for key in ["bfF0", "bfD0", "bfE0"] {
            guard let info = keyInfo(conn, key) else {
                out += "\(key) ABSENT\n"
                continue
            }
            let writable = accessSuffix(info.dataAttributes)
            out += "\(key) type=\(typeString(info.dataType)) size=\(info.dataSize)"
            out += " attr=0x\(String(info.dataAttributes, radix: 16))\(writable) value=\(read(conn, key))\n"
        }
        if let state = firmwareLimitReadback(conn) {
            out += "firmware limit state: mode=\(state.mode) upper=\(state.upper) lower=\(state.lower)\n"
        }
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

    // MARK: - Manual fan control
    //
    // How the SMC arbitrates the fans (cross-checked against four independent write-ups of
    // M1–M5 behaviour and one live M5 Pro trace, #16):
    //   * `F<n>Md` (`F<n>md` on M5) is a mode: 0 = automatic, 1 = manual target, 3 = "system",
    //     the state `thermalmonitord` holds the fans in on M3 and later. While a fan is in 3,
    //     a write to its mode or target key is refused (SMC result 0x82) or accepted and then
    //     reverted — which is exactly what made manual control look enabled while nothing moved.
    //   * `Ftst` is a diagnostic flag. Raising it asks `thermalmonitord` to stand down; some
    //     seconds later the fan drops from 3 to 0, after which the mode write succeeds. It has
    //     to STAY raised for as long as the fans are manual, and is reset by the SMC firmware
    //     across sleep. M1 and M5 accept the mode write directly (M5 has no `Ftst` at all).
    // So the sequence is: try the mode write; if the SMC refuses and `Ftst` exists, raise it and
    // retry until the mode takes; then set the target. Acceptance is the mode key reading back
    // as 1, not a successful write call.

    /// All fan SMC work runs here, one task at a time, so a slow unlock never blocks the XPC
    /// connection — a restore issued meanwhile is seen at once (see `fanGeneration`).
    private static let fanQueue = DispatchQueue(label: "com.jarvisit.macwake.helper.fan")
    private static let fanStateLock = NSLock()
    private static var fanGeneration = 0
    /// Fans this daemon has forced to manual; touched only on `fanQueue`.
    private static var manualFans = Set<Int>()
    /// True while this daemon is the one holding `Ftst` at 1; touched only on `fanQueue`.
    /// If someone else already raised it, it is theirs to lower.
    private static var ftstHeld = false

    /// How long to wait for `thermalmonitord` to release the fans after `Ftst` is raised.
    /// Reports measure 3–6 s typically and up to ~12.6 s, so this leaves headroom.
    private static let unlockTimeout: TimeInterval = 20
    private static let unlockPollInterval: TimeInterval = 0.1

    private static func fanCurrentGeneration() -> Int {
        fanStateLock.lock(); defer { fanStateLock.unlock() }
        return fanGeneration
    }

    private static func fanBumpGeneration() -> Int {
        fanStateLock.lock(); defer { fanStateLock.unlock() }
        fanGeneration += 1
        return fanGeneration
    }

    /// Entry point from XPC. Returns immediately; `reply` fires when the work is done, which
    /// for a manual request on M3/M4 can be several seconds. A restore bumps the generation
    /// before it is queued, so an unlock still in flight notices and gives up instead of
    /// finishing after the user has already switched manual control off.
    static func setFanManual(_ manual: Bool, rpm: Int, reply: @escaping (Bool) -> Void) {
        let generation = manual ? fanCurrentGeneration() : fanBumpGeneration()
        fanQueue.async {
            reply(performSetFanManual(manual, rpm: rpm, generation: generation))
        }
    }

    private static func performSetFanManual(_ manual: Bool, rpm: Int, generation: Int) -> Bool {
        guard let conn = open() else { fanLog("open() failed"); return false }
        defer { IOServiceClose(conn) }
        let count = max(1, Int(read(conn, "FNum")))
        fanLog("setFanManual(manual=\(manual), rpm=\(rpm)) fans=\(count)")
        guard manual else { return releaseFans(conn, count: count) }

        var ok = false
        for i in 0..<count {
            guard generation == fanCurrentGeneration() else {
                fanLog("manual request superseded before F\(i) — releasing")
                _ = releaseFans(conn, count: count)
                return false
            }
            ok = engageFan(conn, index: i, rpm: rpm, generation: generation) || ok
        }
        return ok
    }

    /// A write followed by an immediate readback is not proof of failure — a live SMC trace
    /// against real M5 Pro hardware showed the target key settling roughly 75-250ms after the
    /// write, not atomically with it. Checking once, right away, misreported a write that was
    /// genuinely taking effect as rejected. Poll for a bounded window instead of a single check.
    private static func writeAndVerify(_ conn: io_connect_t, _ key: String, _ value: Int, timeout: TimeInterval = 0.5, interval: TimeInterval = 0.05) -> Bool {
        guard writeFanRPM(conn, key, value) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readFanRPM(conn, key) == value { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        return readFanRPM(conn, key) == value
    }

    /// Mode keys are `ui8` on every Mac seen so far, but decode by the reported type so a
    /// Float32 variant can't read back as a garbage byte.
    private static func readMode(_ conn: io_connect_t, _ key: String) -> Int? {
        guard let info = keyInfo(conn, key) else { return nil }
        var inp = SMCParamStruct()
        inp.key = fourCC(key); inp.keyInfo.dataSize = info.dataSize; inp.data8 = 5
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        guard r == kIOReturnSuccess && out.result == 0 else { return nil }
        if info.dataType == fourCC("flt ") {
            var f: Float32 = 0
            withUnsafeMutableBytes(of: &f) { p in
                p[0] = out.bytes.0; p[1] = out.bytes.1; p[2] = out.bytes.2; p[3] = out.bytes.3
            }
            return f.isFinite ? Int(f) : nil
        }
        return Int(out.bytes.0)
    }

    /// Writes the mode and waits for it to read back — the write call alone is not evidence.
    private static func writeModeAndConfirm(_ conn: io_connect_t, _ key: String, _ mode: UInt8,
                                            timeout: TimeInterval = 0.4) -> Bool {
        guard write(conn, key, mode) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if readMode(conn, key) == Int(mode) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return readMode(conn, key) == Int(mode)
    }

    /// Puts one fan into manual mode, unlocking through `Ftst` when the system holds it.
    /// Returns false — leaving the fan as it was found — if that never succeeds.
    private static func takeManualMode(_ conn: io_connect_t, modeKey: String, generation: Int) -> Bool {
        // M1 and M5 accept this outright, and so does a fan the system has already released.
        if writeModeAndConfirm(conn, modeKey, 1) { fanLog("\(modeKey)=1 accepted directly"); return true }
        guard keyInfo(conn, "Ftst") != nil else {
            fanLog("\(modeKey) refused and this Mac has no Ftst")
            return false
        }
        if read(conn, "Ftst") == 0 {
            guard write(conn, "Ftst", 1) else { fanLog("Ftst write refused"); return false }
            ftstHeld = true
        }
        let started = Date()
        while Date().timeIntervalSince(started) < unlockTimeout {
            guard generation == fanCurrentGeneration() else {
                fanLog("unlock abandoned after \(String(format: "%.1f", Date().timeIntervalSince(started)))s — superseded")
                giveBackFtstIfIdle(conn)
                return false
            }
            if writeModeAndConfirm(conn, modeKey, 1, timeout: 0.3) {
                fanLog("\(modeKey)=1 accepted \(String(format: "%.1f", Date().timeIntervalSince(started)))s after Ftst")
                return true
            }
            Thread.sleep(forTimeInterval: unlockPollInterval)
        }
        fanLog("thermalmonitord did not release \(modeKey) within \(Int(unlockTimeout))s")
        giveBackFtstIfIdle(conn)
        return false
    }

    /// Lowers `Ftst` only if this daemon raised it and no fan is left in manual mode — while
    /// any fan is manual it must stay up, or the system reclaims that fan within seconds.
    private static func giveBackFtstIfIdle(_ conn: io_connect_t) {
        guard ftstHeld, manualFans.isEmpty else { return }
        _ = write(conn, "Ftst", 0)
        ftstHeld = false
    }

    private static func engageFan(_ conn: io_connect_t, index i: Int, rpm: Int, generation: Int) -> Bool {
        let before = readFanRPM(conn, "F\(i)Ac")
        if hardwareMin[i] == nil { hardwareMin[i] = readFanRPM(conn, "F\(i)Mn") }
        let hwMin = hardwareMin[i] ?? 0
        let maxReported = readFanRPM(conn, "F\(i)Mx")
        let maxRPM = maxReported > hwMin ? maxReported : max(hwMin, 8000)
        let clamped = min(max(rpm, hwMin), maxRPM)

        var took = false
        if let modeKey = fanModeKey(conn, i) {
            // Already ours and still manual (a slider drag re-applies the target): don't
            // repeat the unlock, just move the target.
            let alreadyManual = manualFans.contains(i) && readMode(conn, modeKey) == 1
            if alreadyManual || takeManualMode(conn, modeKey: modeKey, generation: generation) {
                took = writeAndVerify(conn, "F\(i)Tg", clamped)
                if took { manualFans.insert(i) }
            } else if keyInfo(conn, "Ftst") != nil {
                // A thermal-managed Mac that would not release the fan. A bare target write
                // "succeeds" there and is reverted moments later, so falling through to the
                // target-only path below would report a manual mode that never engaged.
                fanLog("F\(i) stays under system control")
            } else {
                took = legacyManual(conn, index: i, target: clamped)
            }
        } else {
            took = legacyManual(conn, index: i, target: clamped)
        }
        fanLog("F\(i) target=\(clamped) tookEffect=\(took) actualBefore=\(before)")
        if !took {
            // Every mechanism was tried and none settled — don't leave this fan half-manual
            // (a target write that lands after we've already given up). Hand it straight back
            // to automatic before reporting failure, so a caller that trusts a `false` reply
            // never has to roll back state we could have cleaned up ourselves.
            releaseFan(conn, index: i)
            giveBackFtstIfIdle(conn)
            fanLog("F\(i) rejected — restored automatic")
        }
        return took
    }

    /// Pre-Apple-Silicon and unusual Macs with no mode key: the old escalation, kept as it was.
    private static func legacyManual(_ conn: io_connect_t, index i: Int, target: Int) -> Bool {
        var took = writeAndVerify(conn, "F\(i)Tg", target)
        if !took {
            // Older Macs gate manual control behind the FS! bitmask (one bit per fan).
            let mask = read(conn, "FS! ")
            _ = write(conn, "FS! ", mask | UInt8(1 << i))
            took = writeAndVerify(conn, "F\(i)Tg", target)
        }
        if !took {
            // Some controllers only honour a raised floor.
            took = writeAndVerify(conn, "F\(i)Mn", target)
        }
        if took { manualFans.insert(i) }
        return took
    }

    /// Hands one fan back to the system. The mode goes first: with the mode still manual, a
    /// zero target would stop the fan outright for the instant before the mode flips.
    @discardableResult
    private static func releaseFan(_ conn: io_connect_t, index i: Int) -> Bool {
        var released = false
        if let modeKey = fanModeKey(conn, i) { released = write(conn, modeKey, 0) }
        let okTg = writeFanRPM(conn, "F\(i)Tg", 0)
        if let hwMin = hardwareMin[i] { _ = writeFanRPM(conn, "F\(i)Mn", hwMin) }
        let mask = read(conn, "FS! ")
        _ = write(conn, "FS! ", mask & ~UInt8(1 << i))
        hardwareMin[i] = nil
        manualFans.remove(i)
        return released || okTg
    }

    private static func releaseFans(_ conn: io_connect_t, count: Int) -> Bool {
        var ok = false
        for i in 0..<count { ok = releaseFan(conn, index: i) || ok }
        // Lowering Ftst last matters: the fans must be automatic before the system is let back in.
        giveBackFtstIfIdle(conn)
        fanLog("restore -> automatic (ok=\(ok), Ftst held=\(ftstHeld))")
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
