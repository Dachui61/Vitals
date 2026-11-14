import Darwin
import Foundation

/// `/usr/lib/libSMC.dylib` 的会话封装。
///
/// macOS 27 给"死掉的经典 SMC 路径"配了继任者：dlopen 这个 dylib 之后，
/// `SMCReadKeyAsNumeric` 能**无特权**读到数值温度（票 01）。
///
/// 注意两件事：
/// - 键是**大端**打包的：`'T'<<24 | 'C'<<16 | '0'<<8 | 'P'`。
/// - 这是一个**私有 dylib**，符号可能随系统更新消失 → 打开失败必须能被上层降级处理。
public final class SMCSession {

    public enum Failure: Error, CustomStringConvertible {
        case dlopenFailed(String)
        case symbolMissing(String)
        case openFailed

        public var description: String {
            switch self {
            case let .dlopenFailed(detail): return "dlopen /usr/lib/libSMC.dylib 失败：\(detail)"
            case let .symbolMissing(name): return "libSMC.dylib 缺少符号 \(name)"
            case .openFailed: return "SMCOpenConnectionWithDefaultService() 返回 nil"
            }
        }
    }

    private typealias OpenDefaultService = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias ReadKeyAsNumeric = @convention(c) (
        UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<Double>?
    ) -> Int32
    private typealias GetKeyInfo = @convention(c) (
        UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?
    ) -> Int32
    private typealias GetKeyFromIndex = @convention(c) (
        UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>?
    ) -> Int32

    private let handle: UnsafeMutableRawPointer
    private let openDefault: OpenDefaultService
    private let readKey: ReadKeyAsNumeric
    private let keyInfo: GetKeyInfo
    private let keyFromIndex: GetKeyFromIndex?

    /// SMC 连接（由 libSMC 分配，不要释放）。
    public let connection: UnsafeMutableRawPointer

    public init() throws {
        guard let handle = dlopen("/usr/lib/libSMC.dylib", RTLD_NOW | RTLD_LOCAL) else {
            throw Failure.dlopenFailed(String(cString: dlerror()))
        }
        self.handle = handle

        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw Failure.symbolMissing(name)
            }
            return unsafeBitCast(pointer, to: type)
        }

        openDefault = try symbol("SMCOpenConnectionWithDefaultService", as: OpenDefaultService.self)
        readKey = try symbol("SMCReadKeyAsNumeric", as: ReadKeyAsNumeric.self)
        keyInfo = try symbol("SMCGetKeyInfo", as: GetKeyInfo.self)
        keyFromIndex = try? symbol("SMCGetKeyFromIndex", as: GetKeyFromIndex.self)

        guard let connection = openDefault() else { throw Failure.openFailed }
        self.connection = connection
    }

    deinit {
        dlclose(handle)
    }

    /// 4 字符键 → SMC 键值（大端）。
    public static func key(_ name: String) -> UInt32? {
        let bytes = Array(name.utf8)
        guard bytes.count == 4 else { return nil }
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    /// SMC 键值 → 4 字符名。
    public static func name(_ key: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((key >> 24) & 0xff), UInt8((key >> 16) & 0xff),
            UInt8((key >> 8) & 0xff), UInt8(key & 0xff)
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 读一个键的数值（温度键的单位是 °C）。读不到返回 nil。
    public func read(_ name: String) -> Double? {
        guard let key = Self.key(name) else { return nil }
        var numeric = [UInt8](repeating: 0, count: 24)
        var value: Double = 0
        let rc = numeric.withUnsafeMutableBytes { raw -> Int32 in
            readKey(connection, key, raw.baseAddress, &value)
        }
        guard rc == 0 else { return nil }
        return value
    }

    /// 键是否存在（`SMCGetKeyInfo` 返回 0 表示存在）。
    public func exists(_ name: String) -> Bool {
        guard let key = Self.key(name) else { return false }
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            keyInfo(connection, key, raw.baseAddress)
        }
        return rc == 0
    }

    /// 枚举全部键名（本机 2066 个）。仅探测时使用。
    public func allKeyNames(limit: Int = 4096) -> [String] {
        guard let keyFromIndex else { return [] }
        var names: [String] = []
        var key: UInt32 = 0
        for index in 0..<limit {
            let rc = keyFromIndex(connection, UInt32(index), &key)
            if rc == 0 {
                names.append(Self.name(key))
            } else if rc == -3 {
                break  // 越界：枚举结束
            }
        }
        return names
    }
}
