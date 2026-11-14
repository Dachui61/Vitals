// t20_openmatrix.swift — Ticket 20: for every candidate temperature-ish IOKit service,
// try IOServiceOpen with every user-client type 0..31 and report the error codes.
// Also try the temperature read command (selector 2, cmd byte 6) on each open type.
//
// Build:
//   swiftc -O -target arm64-apple-macosx27.0 -module-cache-path "$PWD/.modulecache" \
//     -Xcc -fmodules-cache-path="$PWD/.modulecache" scratch/t20_openmatrix.swift \
//     -o scratch/t20_openmatrix -framework IOKit
// Run: scratch/t20_openmatrix

import Foundation
import IOKit
import Darwin

func ioErr(_ kr: kern_return_t) -> String {
    if kr == kIOReturnSuccess { return "OK" }
    let hex = String(format: "0x%08x", UInt32(bitPattern: kr))
    switch kr {
    case kIOReturnNotPrivileged:   return "NotPrivileged"
    case kIOReturnNotPermitted:    return "NotPermitted"
    case kIOReturnExclusiveAccess: return "ExclusiveAccess"
    case kIOReturnUnsupported:     return "Unsupported"
    case kIOReturnBadArgument:     return "BadArgument"
    case kIOReturnBusy:            return "Busy"
    case kIOReturnNoMemory:        return "NoMemory"
    case kIOReturnError:           return "Error"
    default:                       return hex
    }
}
func le4(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for (i, c) in s.utf8.enumerated() { v |= UInt32(c) << (8 * UInt32(i)) }
    return v
}

let classes = [
    "AppleSMCSensorDispatcher", "AppleSMCKeysEndpoint", "AppleSMC", "AppleSMCFamily",
    "AppleSMCInterface", "AppleSMCEventBuffer", "AppleSMCEmbeddedFunction", "ApplePPMSMCInterface",
    "AppleSMCPowerOut", "AppleSMCBinaryLogDriver", "ApplePMGRTempSensor", "AppleDieTempController",
    "AppleT700XTempSensor", "AppleARMPMUTempSensor", "AppleSCCTempSensor", "AppleT8020MTRTempSensor",
    "AppleT8015TempSensor", "AMCTempSensor", "AppleVTempDispatcher", "AppleCLPC", "AppleCLPCUserClient",
    "AppleTempSensorUserClient", "ApplePMGRTempUserClient", "AppleDieTempControllerUserClient",
    "IOReportUserClient", "IOReportHub", "AppleEmbeddedNVMeTemperatureSensor", "AppleARMPerformanceController",
]

func makeReq(_ key: String, cmd: UInt8) -> [UInt8] {
    var req = [UInt8](repeating: 0, count: 168)
    let v = le4(key)
    withUnsafeBytes(of: v.littleEndian) { req.replaceSubrange(0..<4, with: $0) }
    req[0x1c] = UInt8(key.utf8.count)
    req[0x2a] = cmd
    let kb = Array(key.utf8)
    for (i, b) in kb.enumerated() { req[0x30 + i] = b }
    return req
}

for cls in classes {
    var iter: io_iterator_t = 0
    let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter)
    if kr != kIOReturnSuccess || iter == 0 {
        print("\(cls): no matching service")
        continue
    }
    defer { IOObjectRelease(iter) }
    var svcIdx = 0
    while true {
        let svc = IOIteratorNext(iter)
        if svc == 0 { break }
        defer { IOObjectRelease(svc) }
        svcIdx += 1
        var opened: [(UInt32, io_connect_t)] = []
        var errors: [String] = []
        for t in UInt32(0)..<32 {
            var c: io_connect_t = 0
            let k = IOServiceOpen(svc, mach_task_self_, t, &c)
            if k == kIOReturnSuccess { opened.append((t, c)) } else { errors.append("t\(t):\(ioErr(k))") }
        }
        if opened.isEmpty {
            print("\(cls)[\(svcIdx)]: NO type opens. errors: \(Array(Set(errors)).sorted().joined(separator: " "))")
        } else {
            for (t, c) in opened {
                var req = makeReq("Tp09", cmd: 6)
                var out = [UInt8](repeating: 0, count: 168)
                var outCnt = 168
                let r = req.withUnsafeMutableBytes { ip -> kern_return_t in
                    out.withUnsafeMutableBytes { op -> kern_return_t in
                        IOConnectCallStructMethod(c, 2, ip.baseAddress!, 168, op.baseAddress!, &outCnt)
                    }
                }
                // also try the plain scalar/struct selectors
                var s0 = IOConnectCallScalarMethod(c, 0, nil, 0, nil, nil)
                var s1 = IOConnectCallScalarMethod(c, 1, nil, 0, nil, nil)
                print("\(cls)[\(svcIdx)] type=\(t): sel2(cmd6)=\(ioErr(r))  scalar0=\(ioErr(s0)) scalar1=\(ioErr(s1))")
                IOServiceClose(c)
            }
            print("   (other types refused: \(Array(Set(errors)).sorted().joined(separator: " ")))")
        }
    }
}
