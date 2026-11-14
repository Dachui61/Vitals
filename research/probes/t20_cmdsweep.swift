// t20_cmdsweep.swift — Ticket 20, Avenue 2.
// Sweep the byte at request offset 0x2a (the "command" byte found in thermalmonitord)
// for selector 2 of the AppleSMC user client and dump whatever comes back.
//
// Build:
//   swiftc -O -target arm64-apple-macosx27.0 -module-cache-path "$PWD/.modulecache" \
//     -Xcc -fmodules-cache-path="$PWD/.modulecache" scratch/t20_cmdsweep.swift \
//     -o scratch/t20_cmdsweep -framework IOKit
// Run: scratch/t20_cmdsweep [key]

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
func hexDump(_ b: [UInt8], _ from: Int, _ n: Int) -> String {
    (from..<min(from+n, b.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
}

var iter: io_iterator_t = 0
guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iter) == kIOReturnSuccess else { exit(2) }
defer { IOObjectRelease(iter) }
var conn: io_connect_t = 0
var found = false
while true {
    let s = IOIteratorNext(iter)
    if s == 0 { break }
    var c: io_connect_t = 0
    if IOServiceOpen(s, mach_task_self_, 0, &c) == kIOReturnSuccess { conn = c; found = true; break }
    IOObjectRelease(s)
}
guard found else { print("cannot open"); exit(3) }
print("conn=\(conn) uid=\(getuid()) key=\(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tp09")")

func makeReq(_ key: String, cmd: UInt8, sizeByte: UInt8? = nil, charsAt: Int = 0x30) -> [UInt8] {
    var req = [UInt8](repeating: 0, count: 168)
    let v = le4(key)
    withUnsafeBytes(of: v.littleEndian) { req.replaceSubrange(0..<4, with: $0) }
    req[0x1c] = sizeByte ?? UInt8(key.utf8.count)
    req[0x2a] = cmd
    let kb = Array(key.utf8)
    for (i, b) in kb.enumerated() where charsAt + i < req.count { req[charsAt + i] = b }
    return req
}

print("\n=== command byte @0x2a sweep (0...255), key Tp09 ===")
var okCmds: [UInt8] = []
for cmd in UInt8(0)...255 {
    var req = makeReq("Tp09", cmd: cmd)
    var out = [UInt8](repeating: 0, count: 168)
    var outCnt = 168
    let kr = req.withUnsafeMutableBytes { ip -> kern_return_t in
        out.withUnsafeMutableBytes { op -> kern_return_t in
            IOConnectCallStructMethod(conn, 2, ip.baseAddress!, 168, op.baseAddress!, &outCnt)
        }
    }
    if kr == kIOReturnSuccess {
        okCmds.append(cmd)
        let nonzero = out.contains { $0 != 0 }
        print("  cmd \(cmd): OK outCnt=\(outCnt) nonzero=\(nonzero)  [00..3f]=\(hexDump(out, 0, 0x40))")
    } else {
        print("  cmd \(cmd): \(ioErr(kr))")
    }
}
print("OK commands: \(okCmds)")

IOServiceClose(conn)
