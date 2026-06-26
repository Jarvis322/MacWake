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

/// Root-only SMC access for charge control. Writing the adapter key (CHIE)
/// requires the privileged helper; the same write fails for the sandboxed/user app.
enum HelperSMC {
    /// Adapter enable/inhibit key on Apple Silicon (M-series). 0 = adapter on, 8 = adapter off.
    private static let keyAdapter = "CHIE"
    private static let adapterOff: UInt8 = 8
    private static let adapterOn: UInt8 = 0

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

    /// Writes CHIE. Returns true on success.
    static func setAdapterEnabled(_ enabled: Bool) -> Bool {
        guard let conn = open() else { return false }
        defer { IOServiceClose(conn) }
        guard let info = keyInfo(conn, keyAdapter) else { return false }

        var inp = SMCParamStruct()
        inp.key = fourCC(keyAdapter)
        inp.keyInfo.dataSize = info.dataSize
        inp.keyInfo.dataType = info.dataType
        inp.data8 = 6 // kSMCWriteKey
        inp.bytes.0 = enabled ? adapterOn : adapterOff

        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        return r == kIOReturnSuccess && out.result == 0
    }

    /// Reads CHIE. Returns true if the adapter is currently enabled (charging allowed).
    static func getAdapterEnabled() -> Bool {
        guard let conn = open() else { return true }
        defer { IOServiceClose(conn) }
        guard let info = keyInfo(conn, keyAdapter) else { return true }

        var inp = SMCParamStruct()
        inp.key = fourCC(keyAdapter)
        inp.keyInfo.dataSize = info.dataSize
        inp.data8 = 5 // kSMCReadKey
        var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParamStruct>.stride, &out, &sz)
        guard r == kIOReturnSuccess && out.result == 0 else { return true }
        return out.bytes.0 == adapterOn
    }
}
