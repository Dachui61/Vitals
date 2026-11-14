// t20_smcproto.swift — Ticket 20, Avenue 2.
// Implements the "SMCSensorExchange" protocol that /usr/libexec/thermalmonitord
// uses against the AppleSMCKeysEndpoint IOKit service (IOUserClientClass=AppleSMCClient):
//
//   IOServiceMatching("AppleSMC") -> IOServiceOpen(type 0)
//   IOConnectCallScalarMethod(conn, 0, NULL, 0, NULL, 0)      // "begin"
//   IOConnectCallStructMethod(conn, 2, input168, 168, out168, &outCnt)
//   IOConnectCallScalarMethod(conn, 1, NULL, 0, NULL, 0)      // "end"
//
// request layout (reverse-engineered from thermalmonitord @0x10000feac):
//   +0x00 uint32  key 4CC
//   +0x04 .. +0x1b  zero
//   +0x1c uint8   key size in bytes
//   +0x1d .. +0x29  zero
//   +0x2a uint8   6
//   +0x2b .. +0x2f  zero
//   +0x30 bytes   key characters (size bytes)
//   total 0xa8 = 168
//
// Build:
//   swiftc -O -target arm64-apple-macosx27.0 -module-cache-path "$PWD/.modulecache" \
//     -Xcc -fmodules-cache-path="$PWD/.modulecache" scratch/t20_smcproto.swift \
//     -o scratch/t20_smcproto -framework IOKit
// Run: scratch/t20_smcproto <variant> <key>

import Foundation
import IOKit
import Darwin

func ioErr(_ kr: kern_return_t) -> String {
    if kr == kIOReturnSuccess { return "OK" }
    let hex = String(format: "0x%08x", UInt32(bitPattern: kr))
    switch kr {
    case kIOReturnNotPrivileged:   return "\(hex) NotPrivileged"
    case kIOReturnNotPermitted:    return "\(hex) NotPermitted"
    case kIOReturnExclusiveAccess: return "\(hex) ExclusiveAccess"
    case kIOReturnUnsupported:     return "\(hex) Unsupported"
    case kIOReturnBadArgument:     return "\(hex) BadArgument"
    case kIOReturnBusy:            return "\(hex) Busy"
    case kIOReturnNoMemory:        return "\(hex) NoMemory"
    case kIOReturnError:           return "\(hex) Error"
    default:                       return "\(hex) ?"
    }
}

func hexDump(_ b: [UInt8], _ n: Int) -> String {
    (0..<min(n, b.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
}

func le(_ s: String) -> UInt32 {
    // 'T' | 'C'<<8 | '0'<<16 | 'P'<<24  (classic SMC packing: char0 in LOW byte)
    var v: UInt32 = 0
    for (i, c) in s.utf8.enumerated() { v |= UInt32(c) << (8 * UInt32(i)) }
    return v
}
func be(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    let bytes = Array(s.utf8)
    for (i, c) in bytes.enumerated() { v |= UInt32(c) << (8 * UInt32(bytes.count - 1 - i)) }
    return v
}

let args = CommandLine.arguments
let variant = args.count > 1 ? args[1] : "A"
let keyStr = args.count > 2 ? args[2] : "Tp09"

// open the endpoint
var iter: io_iterator_t = 0
guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iter) == kIOReturnSuccess else {
    print("no AppleSMC"); exit(2)
}
defer { IOObjectRelease(iter) }
var conn: io_connect_t = 0
var svc: io_service_t = 0
var found = false
while true {
    let s = IOIteratorNext(iter)
    if s == 0 { break }
    var c: io_connect_t = 0
    if IOServiceOpen(s, mach_task_self_, 0, &c) == kIOReturnSuccess {
        conn = c; svc = s; found = true; break
    }
    IOObjectRelease(s)
}
guard found else { print("cannot open AppleSMC user client"); exit(3) }
print("opened conn=\(conn)")

// "begin" scalar call (selector 0)
var scalarOut: UInt64 = 0
var scalarCnt: UInt32 = UInt32(MemoryLayout<UInt32>.size)
let kr0a = IOConnectCallScalarMethod(conn, 0, nil, 0, nil, nil)
print("scalar sel0 (all NULL): \(ioErr(kr0a))")
let kr0 = IOConnectCallScalarMethod(conn, 0, nil, 0, &scalarOut, &scalarCnt)
print("scalar sel0 (out ptr): \(ioErr(kr0)) out=\(scalarOut) cnt=\(scalarCnt)")

// build the 168-byte request
var req = [UInt8](repeating: 0, count: 168)
let keyBytes = Array(keyStr.utf8)
switch variant {
case "A":                      // 4CC little-endian char packing, size@0x1c, ver@0x2a, chars@0x30
    let v = le(keyStr)
    withUnsafeBytes(of: v.littleEndian) { req.replaceSubrange(0..<4, with: $0) }
    req[0x1c] = UInt8(keyBytes.count)
    req[0x2a] = 6
    for (i, b) in keyBytes.enumerated() { req[0x30 + i] = b }
case "B":                      // 4CC big-endian char packing
    let v = be(keyStr)
    withUnsafeBytes(of: v.littleEndian) { req.replaceSubrange(0..<4, with: $0) }
    req[0x1c] = UInt8(keyBytes.count)
    req[0x2a] = 6
    for (i, b) in keyBytes.enumerated() { req[0x30 + i] = b }
case "C":                      // chars at +0x00, size at +0x1c, ver at +0x2a
    for (i, b) in keyBytes.enumerated() { req[i] = b }
    req[0x1c] = UInt8(keyBytes.count)
    req[0x2a] = 6
case "D":                      // only 4CC + size + chars@0x30, no version byte
    let v = le(keyStr)
    withUnsafeBytes(of: v.littleEndian) { req.replaceSubrange(0..<4, with: $0) }
    req[0x1c] = UInt8(keyBytes.count)
    for (i, b) in keyBytes.enumerated() { req[0x30 + i] = b }
case "E":                      // classic SMCKeyData_t (132 bytes) for reference
    let v = le(keyStr)
    withUnsafeBytes(of: v.littleEndian) { req.replaceSubrange(0..<4, with: $0) }
    req[4] = 1
default:
    print("unknown variant"); exit(1)
}

var out = [UInt8](repeating: 0, count: 168)
var outCnt = 168
let kr = req.withUnsafeMutableBytes { ip -> kern_return_t in
    out.withUnsafeMutableBytes { op -> kern_return_t in
        IOConnectCallStructMethod(conn, 2, ip.baseAddress!, 168, op.baseAddress!, &outCnt)
    }
}
print("struct sel2 (variant \(variant), key \(keyStr)): \(ioErr(kr)) outCnt=\(outCnt)")
if kr == kIOReturnSuccess {
    print("out[0x00..0x40]: \(hexDump(out, 0x40))")
    print("out[0x40..0x80]: \(hexDump(Array(out[0x40..<0x80]), 0x40))")
    print("out[0x80..0xa8]: \(hexDump(Array(out[0x80..<0xa8]), 0x28))")
    // interpret 4-byte groups as float / int
    print("--- float interpretations ---")
    for off in stride(from: 0, to: 0xa8 - 3, by: 4) {
        let f = Float(bitPattern: UInt32(out[off]) | UInt32(out[off+1]) << 8 | UInt32(out[off+2]) << 16 | UInt32(out[off+3]) << 24)
        let i = Int(Int32(UInt32(out[off]) | UInt32(out[off+1]) << 8 | UInt32(out[off+2]) << 16 | UInt32(out[off+3]) << 24))
        if f.isFinite && abs(f) > 0.001 && abs(f) < 1000 {
            print("  +\(String(format: "%02x", off)): float=\(f)  int32=\(i)")
        }
    }
    print("--- u16 values ---")
    var line = ""
    for off in stride(from: 0, to: 0xa8, by: 2) {
        let v = UInt16(out[off]) | UInt16(out[off+1]) << 8
        if v != 0 { line += " +\(String(format: "%02x", off)):\(v)" }
    }
    print(line)
}

// "end" scalar call (selector 1)
var so2: UInt64 = 0
var sc2: UInt32 = UInt32(MemoryLayout<UInt32>.size)
let kr1a = IOConnectCallScalarMethod(conn, 1, nil, 0, nil, nil)
print("scalar sel1 (all NULL): \(ioErr(kr1a))")
let kr1 = IOConnectCallScalarMethod(conn, 1, nil, 0, &so2, &sc2)
print("scalar sel1 (out ptr): \(ioErr(kr1))")
IOServiceClose(conn)
