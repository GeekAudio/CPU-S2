import Foundation

/// Hardware context only. SKU specifications never determine sampling worker counts.
struct CPUCoreInfo {
    enum Source: String { case systemPerformanceLevels, intelSpecification }

    struct Level {
        let name: String
        let physicalCores: Int
        let logicalThreads: Int
    }

    let physicalCores: Int
    let logicalThreads: Int
    let currentPhysicalCores: Int
    let maximumLogicalThreads: Int
    let performanceCores: Int?
    let efficiencyCores: Int?
    let source: Source?
    let processorNumber: String?
    let referenceURL: String?
    let specificationThreads: Int?

    static func read(processor: String, isAppleSilicon: Bool, isTranslated: Bool) -> CPUCoreInfo {
        let count = min(8, max(0, Engine.sysctlInt("hw.nperflevels") ?? 0))
        let levels = (0..<count).map { index in
            Level(name: Engine.sysctl("hw.perflevel\(index).name") ?? "",
                  physicalCores: Engine.sysctlInt("hw.perflevel\(index).physicalcpu") ?? 0,
                  logicalThreads: Engine.sysctlInt("hw.perflevel\(index).logicalcpu") ?? 0)
        }
        return resolve(processor: processor, vendor: Engine.sysctl("machdep.cpu.vendor") ?? "",
                       isAppleSilicon: isAppleSilicon, isTranslated: isTranslated,
                       currentPhysicalCores: Engine.sysctlInt("hw.physicalcpu") ?? 0,
                       maximumPhysicalCores: Engine.sysctlInt("hw.physicalcpu_max") ?? 0,
                       currentLogicalThreads: Engine.sysctlInt("hw.logicalcpu") ?? 0,
                       maximumLogicalThreads: Engine.sysctlInt("hw.logicalcpu_max") ?? 0,
                       levels: levels)
    }

    /// Pure resolution permits fixtures for disabled SMT/cores, spoofed topology and Rosetta.
    static func resolve(processor: String, vendor: String, isAppleSilicon: Bool, isTranslated: Bool,
                        currentPhysicalCores: Int, maximumPhysicalCores: Int,
                        currentLogicalThreads: Int, maximumLogicalThreads: Int,
                        levels: [Level] = []) -> CPUCoreInfo {
        func count(_ value: Int) -> Int { (1...4096).contains(value) ? value : 0 }
        let currentCores = count(currentPhysicalCores)
        let cores = max(currentCores, count(maximumPhysicalCores))
        let currentThreads = count(currentLogicalThreads)
        let maximumThreads = max(currentThreads, count(maximumLogicalThreads))
        let threads = currentThreads > 0 ? currentThreads : maximumThreads
        var p: Int?
        var e: Int?
        var source: Source?
        var number: String?
        var reference: String?
        var specificationThreads: Int?
        if !isAppleSilicon, !isTranslated, vendor == "GenuineIntel" {
            // Intel Hackintosh commonly exposes one "Standard" level; that is not a P-core count.
            // Accept named classes only when every level and the aggregate counts agree.
            var pCores = 0, eCores = 0, pThreads = 0, eThreads = 0
            var classified = !levels.isEmpty && levels.count <= 8
            var hasPerformance = false, hasEfficiency = false
            for level in levels {
                let name = level.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let physical = count(level.physicalCores), logical = count(level.logicalThreads)
                guard physical > 0, logical >= physical, logical <= 2 * physical else { classified = false; break }
                if name == "performance" {
                    hasPerformance = true; pCores += physical; pThreads += logical
                } else if name == "efficiency" {
                    hasEfficiency = true; eCores += physical; eThreads += logical
                } else { classified = false; break }
            }
            if classified, hasPerformance, hasEfficiency, eThreads == eCores,
               pCores + eCores == currentCores, pThreads + eThreads == currentThreads {
                p = pCores; e = eCores; source = .systemPerformanceLevels
            } else if let entry = IntelCoreCatalog.lookup(processor) {
                p = entry.performanceCores; e = entry.efficiencyCores
                source = .intelSpecification; number = entry.model
                reference = entry.referenceURL; specificationThreads = entry.maximumThreads
            }
        }
        return CPUCoreInfo(physicalCores: cores, logicalThreads: threads,
                           currentPhysicalCores: currentCores, maximumLogicalThreads: maximumThreads,
                           performanceCores: p, efficiencyCores: e, source: source,
                           processorNumber: number, referenceURL: reference,
                           specificationThreads: specificationThreads)
    }

    var systemSummary: String {
        let cores = physicalCores > 0 ? "\(physicalCores) 核" : "核心不可用"
        let threads = logicalThreads > 0 ? "\(logicalThreads) 线程" : "线程不可用"
        return "\(cores) / \(threads)"
    }

    var typeSummary: String? {
        guard let p = performanceCores, let e = efficiencyCores else { return nil }
        let types = e > 0 ? "\(p) 大核 + \(e) 小核" : "\(p) 大核 · 无小核"
        return source == .intelSpecification ? "标称 \(types)" : types
    }

    var display: String { typeSummary.map { "\($0)\n\(systemSummary)" } ?? systemSummary }
    var summary: String { typeSummary.map { "\(systemSummary) · \($0)" } ?? systemSummary }

    var detail: String {
        var lines = ["总核心数采用系统报告的最大物理核心数；线程数采用当前可用逻辑线程数。",
                     "系统当前物理核：\(currentPhysicalCores)；最大物理核：\(physicalCores)。",
                     "系统当前线程：\(logicalThreads)；最大线程：\(maximumLogicalThreads)。"]
        switch source {
        case .intelSpecification:
            lines.append("大核（P）与小核（E）来自 Intel \(processorNumber ?? "") 型号规格，不代表 BIOS / EFI 当前启用数量。")
            if let threads = specificationThreads { lines.append("型号标称最大线程数：\(threads)。") }
            if let url = referenceURL { lines.append(url) }
        case .systemPerformanceLevels:
            lines.append("大核（P）与小核（E）由系统 Performance / Efficiency 性能级别分别报告。")
        case nil:
            lines.append("系统未提供可靠的核型分类，保留总核心数与线程数，不根据线程数猜测大小核。")
        }
        return lines.joined(separator: "\n")
    }
}
