import Foundation
import IOKit

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, 
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, 
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, 
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0
                )
}

class SMCHelper {
    private static let keyFanNumber = "FNum"
    private static let keyFanSpeedPattern = "F%dAc"
    private static let keyBatteryTemp = "TB0T"
    
    private static func stringToFourCharCode(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) + UInt32(char)
        }
        return result
    }

    private static func fourCharCodeToString(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func openSMC() -> io_connect_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        
        var connection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { return nil }
        return connection
    }

    private static func closeSMC(_ connection: io_connect_t) {
        IOServiceClose(connection)
    }

    private static func getKeyInfo(connection: io_connect_t, key: String) -> SMCKeyInfoData? {
        var input = SMCParamStruct()
        input.key = stringToFourCharCode(key)
        input.data8 = 9 // kSMCGetKeyInfo
        
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        
        let result = IOConnectCallStructMethod(
            connection,
            2, // kSMCHandleYPCEvent
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        
        guard result == kIOReturnSuccess && output.result == 0 else { return nil }
        return output.keyInfo
    }

    static func getFanCount() -> Int {
        guard let connection = openSMC() else { return 0 }
        defer { closeSMC(connection) }
        
        guard let info = getKeyInfo(connection: connection, key: keyFanNumber) else { return 0 }
        
        var input = SMCParamStruct()
        input.key = stringToFourCharCode(keyFanNumber)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5 // kSMCReadKey
        
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        
        let result = IOConnectCallStructMethod(
            connection,
            2,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        
        guard result == kIOReturnSuccess && output.result == 0 else { return 0 }
        return Int(output.bytes.0)
    }

    /// Battery temperature via SMC key TB0T (sp78 format), returns °C or nil.
    static func getBatteryTemperature() -> Double? {
        guard let connection = openSMC() else { return nil }
        defer { closeSMC(connection) }

        guard let info = getKeyInfo(connection: connection, key: keyBatteryTemp) else { return nil }

        var input = SMCParamStruct()
        input.key = stringToFourCharCode(keyBatteryTemp)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5 // kSMCReadKey

        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection, 2,
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outputSize
        )
        guard result == kIOReturnSuccess && output.result == 0 else { return nil }

        let typeStr = fourCharCodeToString(info.dataType)
        if typeStr == "sp78" {
            // signed fixed-point 7.8: high byte integer, low byte fraction /256
            let raw = Int16(bitPattern: UInt16(output.bytes.0) << 8 | UInt16(output.bytes.1))
            return Double(raw) / 256.0
        } else if typeStr == "flt " {
            var floatVal: Float32 = 0.0
            withUnsafeMutableBytes(of: &floatVal) { ptr in
                ptr[0] = output.bytes.0; ptr[1] = output.bytes.1
                ptr[2] = output.bytes.2; ptr[3] = output.bytes.3
            }
            let temp = Double(floatVal)
            guard temp > -40, temp < 150 else { return nil }
            return temp
        }
        return nil
    }

    static func getFanSpeed(fanIndex: Int) -> Double? {
        guard let connection = openSMC() else { return nil }
        defer { closeSMC(connection) }
        
        let key = String(format: keyFanSpeedPattern, fanIndex)
        guard let info = getKeyInfo(connection: connection, key: key) else { return nil }
        
        var input = SMCParamStruct()
        input.key = stringToFourCharCode(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5 // kSMCReadKey
        
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        
        let result = IOConnectCallStructMethod(
            connection,
            2,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        
        guard result == kIOReturnSuccess && output.result == 0 else { return nil }
        
        let typeStr = fourCharCodeToString(info.dataType)
        if typeStr == "fpe2" {
            let b0 = UInt32(output.bytes.0)
            let b1 = UInt32(output.bytes.1)
            let raw = (b0 << 8) | b1
            return Double(raw) / 4.0
        } else if typeStr == "flt " {
            var floatVal: Float32 = 0.0
            withUnsafeMutableBytes(of: &floatVal) { ptr in
                ptr[0] = output.bytes.0
                ptr[1] = output.bytes.1
                ptr[2] = output.bytes.2
                ptr[3] = output.bytes.3
            }
            return Double(floatVal)
        }

        return nil
    }
}
