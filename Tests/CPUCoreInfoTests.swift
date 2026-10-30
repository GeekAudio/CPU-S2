import Foundation

@main
enum CPUCoreInfoTests {
    static var checks = 0
    static var failures: [String] = []

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }

    static func resolve(currentCores: Int = 8, maximumCores: Int = 12,
                        currentThreads: Int = 20, maximumThreads: Int = 20) -> CPUCoreInfo {
        CPUCoreInfo.resolve(currentPhysicalCores: currentCores,
                            maximumPhysicalCores: maximumCores,
                            currentLogicalThreads: currentThreads,
                            maximumLogicalThreads: maximumThreads)
    }

    static func main() {
        let host = resolve()
        expect(host.physicalCores == 12 && host.currentPhysicalCores == 8,
               "maximum physical-core count corrects the known Hackintosh under-report")
        expect(host.logicalThreads == 20 && host.maximumLogicalThreads == 20,
               "current logical-thread count remains separate from the maximum")
        expect(host.systemSummary == "12 核 / 20 线程" && host.display == "12 核 / 20 线程" &&
               host.summary == "12 核 / 20 线程",
               "hardware display and summary show only total cores and threads")
        expect(host.detail.contains("当前物理核：8") && host.detail.contains("最大物理核：12") &&
               host.detail.contains("当前线程：20") && host.detail.contains("最大线程：20"),
               "hover detail reports current and maximum system counts")
        expect(!host.detail.contains("大核") && !host.detail.contains("小核") && !host.detail.contains("P/E"),
               "hardware detail contains no core-type classification")

        let disabledSMT = resolve(currentCores: 12, maximumCores: 12,
                                  currentThreads: 12, maximumThreads: 20)
        expect(disabledSMT.physicalCores == 12 && disabledSMT.logicalThreads == 12 &&
               disabledSMT.maximumLogicalThreads == 20,
               "reported current thread count is retained when SMT is disabled")

        let invalid = resolve(currentCores: -1, maximumCores: -3,
                              currentThreads: -1, maximumThreads: 0)
        expect(invalid.physicalCores == 0 && invalid.logicalThreads == 0 &&
               invalid.currentPhysicalCores == 0,
               "negative or unavailable system counts are clamped to unavailable")

        let unreasonable = resolve(currentCores: 5000, maximumCores: 6000,
                                   currentThreads: 9000, maximumThreads: 10000)
        expect(unreasonable.physicalCores == 0 && unreasonable.logicalThreads == 0,
               "unreasonable system counts are rejected")

        let missingCurrent = resolve(currentCores: 0, maximumCores: 6,
                                     currentThreads: 0, maximumThreads: 12)
        expect(missingCurrent.physicalCores == 6 && missingCurrent.logicalThreads == 12,
               "maximum counts are used when current system counts are unavailable")

        let missingMaximum = resolve(currentCores: 6, maximumCores: 0,
                                     currentThreads: 12, maximumThreads: 0)
        expect(missingMaximum.physicalCores == 6 && missingMaximum.logicalThreads == 12,
               "current counts remain available when maximum counts are unavailable")

        if failures.isEmpty {
            print("PASS: \(checks) CPU core/thread count checks; no probes or load were run")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            fputs("\(failures.count) failure(s) across \(checks) core/thread checks\n", stderr)
            exit(1)
        }
    }
}
