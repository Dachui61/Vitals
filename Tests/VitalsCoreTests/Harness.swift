import Foundation

// MARK: - 极简测试运行器
//
// 这台机器只有 Xcode Command Line Tools：工具链里既没有 XCTest 也没有 swift-testing，
// 所以这里手写一个几十行的断言运行器。约定：
//   - `test("名字") { ... }` 注册一个用例
//   - `expect(...)` / `expectEqual(...)` 断言，失败抛错
//   - `main.swift` 负责跑完全部用例并以退出码表示成败（0 = 全过）

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct TestCase {
    let name: String
    let body: () throws -> Void
}

enum TestRegistry {
    static var cases: [TestCase] = []
}

func test(_ name: String, _ body: @escaping () throws -> Void) {
    TestRegistry.cases.append(TestCase(name: name, body: body))
}

func expect(_ condition: Bool, _ message: String = "断言失败") throws {
    if !condition { throw TestFailure(message: message) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") throws {
    if actual != expected {
        let detail = message.isEmpty ? "" : " — \(message)"
        throw TestFailure(message: "期望 \(expected)，实际 \(actual)\(detail)")
    }
}

/// 浮点比较留一点容差。
func expectClose(_ actual: Double, _ expected: Double, tolerance: Double = 0.0001, _ message: String = "") throws {
    if abs(actual - expected) > tolerance {
        let detail = message.isEmpty ? "" : " — \(message)"
        throw TestFailure(message: "期望 \(expected)±\(tolerance)，实际 \(actual)\(detail)")
    }
}

/// 跑完所有用例，打印结果，返回失败数。
@discardableResult
func runAllTests() -> Int {
    var failures: [(String, String)] = []
    print("VitalsCore 测试（\(TestRegistry.cases.count) 个用例）")
    for testCase in TestRegistry.cases {
        do {
            try testCase.body()
            print("  ✓ \(testCase.name)")
        } catch {
            let message = (error as? TestFailure)?.description ?? "\(error)"
            failures.append((testCase.name, message))
            print("  ✗ \(testCase.name)")
            print("      \(message)")
        }
    }
    if failures.isEmpty {
        print("全部通过 ✓")
        return 0
    }
    print("\n\(failures.count) 个用例失败 ✗")
    for (name, message) in failures {
        print("  - \(name): \(message)")
    }
    return 1
}
