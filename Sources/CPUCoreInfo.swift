import Foundation

/// System-reported core and thread counts; never determines sampling worker counts.
struct CPUCoreInfo {
    let physicalCores: Int
    let logicalThreads: Int
    let currentPhysicalCores: Int
    let maximumLogicalThreads: Int

    static func read() -> CPUCoreInfo {
        resolve(currentPhysicalCores: Engine.sysctlInt("hw.physicalcpu") ?? 0,
                maximumPhysicalCores: Engine.sysctlInt("hw.physicalcpu_max") ?? 0,
                currentLogicalThreads: Engine.sysctlInt("hw.logicalcpu") ?? 0,
                maximumLogicalThreads: Engine.sysctlInt("hw.logicalcpu_max") ?? 0)
    }

    /// Keep the available thread count separate from the system maximum.
    static func resolve(currentPhysicalCores: Int, maximumPhysicalCores: Int,
                        currentLogicalThreads: Int, maximumLogicalThreads: Int) -> CPUCoreInfo {
        func count(_ value: Int) -> Int { (1...4096).contains(value) ? value : 0 }
        let currentCores = count(currentPhysicalCores)
        let cores = max(currentCores, count(maximumPhysicalCores))
        let currentThreads = count(currentLogicalThreads)
        let maximumThreads = max(currentThreads, count(maximumLogicalThreads))
        let threads = currentThreads > 0 ? currentThreads : maximumThreads
        return CPUCoreInfo(physicalCores: cores, logicalThreads: threads,
                           currentPhysicalCores: currentCores, maximumLogicalThreads: maximumThreads)
    }

    var systemSummary: String {
        let cores = physicalCores > 0 ? "\(physicalCores) 核" : "核心不可用"
        let threads = logicalThreads > 0 ? "\(logicalThreads) 线程" : "线程不可用"
        return "\(cores) / \(threads)"
    }

    var display: String { systemSummary }
    var summary: String { systemSummary }

    var detail: String {
        ["总核心数采用系统报告的最大物理核心数；线程数采用当前可用逻辑线程数。",
         "系统当前物理核：\(currentPhysicalCores)；最大物理核：\(physicalCores)。",
         "系统当前线程：\(logicalThreads)；最大线程：\(maximumLogicalThreads)。"].joined(separator: "\n")
    }
}
