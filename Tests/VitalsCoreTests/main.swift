import Foundation
import VitalsCore

registerCoreTests()
registerSamplingTests()
registerAlertTests()

// VITALS_LIVE=1 时跑一次**真机采样**检查：打印实际读到的各项指标，
// 用来验证采样层在本机真的能取到数（而不是"编译通过"而已）。
if ProcessInfo.processInfo.environment["VITALS_LIVE"] == "1" {
    exit(Int32(runLiveCheck()))
} else {
    exit(Int32(runAllTests()))
}
