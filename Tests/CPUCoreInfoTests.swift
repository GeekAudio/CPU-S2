import Foundation

@main
enum CPUCoreInfoTests {
    static var checks = 0
    static var failures: [String] = []

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }

    static func resolve(_ brand: String = "12th Gen Intel(R) Core(TM) i7-12700K CPU @ 3.60GHz",
                        vendor: String = "GenuineIntel", apple: Bool = false, translated: Bool = false,
                        currentCores: Int = 8, maximumCores: Int = 12,
                        currentThreads: Int = 20, maximumThreads: Int = 20,
                        levels: [CPUCoreInfo.Level] = []) -> CPUCoreInfo {
        CPUCoreInfo.resolve(processor: brand, vendor: vendor, isAppleSilicon: apple,
                            isTranslated: translated, currentPhysicalCores: currentCores,
                            maximumPhysicalCores: maximumCores, currentLogicalThreads: currentThreads,
                            maximumLogicalThreads: maximumThreads, levels: levels)
    }

    static func main() {
        let host = resolve()
        expect(host.physicalCores == 12 && host.currentPhysicalCores == 8, "max physical cores correct the known 12700K Hackintosh mismatch")
        expect(host.logicalThreads == 20 && host.maximumLogicalThreads == 20, "current logical thread count remains separate")
        expect(host.performanceCores == 8 && host.efficiencyCores == 4, "known Intel SKU reports its specification P/E core counts")
        expect(host.typeSummary == "标称 8 大核 + 4 小核", "SKU core counts are explicitly labeled as specifications")
        expect(host.display == "标称 8 大核 + 4 小核\n12 核 / 20 线程", "two-line display separates type specification from system totals")
        expect(host.source == .intelSpecification && host.referenceURL?.contains("intel.com") == true,
               "SKU classification carries a first-party Intel reference")
        expect(host.detail.contains("不代表 BIOS / EFI 当前启用数量"), "details distinguish specification from firmware-enabled cores")

        let disabledE = resolve(currentCores: 8, maximumCores: 8, currentThreads: 16, maximumThreads: 16)
        expect(disabledE.physicalCores == 8 && disabledE.logicalThreads == 16,
               "disabled E-cores do not get added to current OS totals")
        expect(disabledE.performanceCores == 8 && disabledE.efficiencyCores == 4,
               "firmware-disabled cores remain visibly marked as nominal SKU specification")

        let disabledSMT = resolve(currentCores: 12, maximumCores: 12, currentThreads: 12, maximumThreads: 20)
        expect(disabledSMT.logicalThreads == 12 && disabledSMT.maximumLogicalThreads == 20,
               "disabled SMT uses current thread count instead of nominal threads")
        expect(disabledSMT.specificationThreads == 20, "specification thread count remains separately available")

        let performanceLevels = [CPUCoreInfo.Level(name: "Performance", physicalCores: 2, logicalThreads: 4),
                                 CPUCoreInfo.Level(name: "Efficiency", physicalCores: 4, logicalThreads: 4)]
        let systemClassified = resolve("Intel CPU", currentCores: 6, maximumCores: 6,
                                       currentThreads: 8, maximumThreads: 8, levels: performanceLevels)
        expect(systemClassified.source == .systemPerformanceLevels && systemClassified.performanceCores == 2 &&
               systemClassified.efficiencyCores == 4, "matching named system levels provide current P/E counts")
        expect(systemClassified.typeSummary == "2 大核 + 4 小核", "system-reported core counts are not mislabeled as SKU nominal")

        let standard = resolve("Intel CPU", currentCores: 8, maximumCores: 12,
                               currentThreads: 20, maximumThreads: 20,
                               levels: [.init(name: "Standard", physicalCores: 8, logicalThreads: 20)])
        expect(standard.performanceCores == nil && standard.efficiencyCores == nil,
               "a single Standard perflevel is not misread as P-core count")

        let inconsistent = resolve(currentCores: 8, maximumCores: 12, currentThreads: 20, maximumThreads: 20,
                                   levels: [.init(name: "Performance", physicalCores: 6, logicalThreads: 12),
                                            .init(name: "Efficiency", physicalCores: 2, logicalThreads: 2)])
        expect(inconsistent.source == .intelSpecification && inconsistent.performanceCores == 8 &&
               inconsistent.efficiencyCores == 4, "inconsistent active-level sums fall back to labeled SKU specification")

        let unknown = resolve("Intel(R) Core(TM) i7-8700 CPU", currentCores: 6, maximumCores: 6,
                              currentThreads: 12, maximumThreads: 12)
        expect(unknown.performanceCores == nil && unknown.efficiencyCores == nil && unknown.typeSummary == nil,
               "unknown legacy Intel processors do not get an invented P/E split")
        expect(unknown.display == "6 核 / 12 线程", "unclassified Intel retains the system core and thread totals")

        let amd = resolve(vendor: "AuthenticAMD")
        expect(amd.performanceCores == nil && amd.efficiencyCores == nil, "AMD never matches Intel SKU specifications")
        let silicon = resolve(apple: true)
        expect(silicon.performanceCores == nil && silicon.efficiencyCores == nil, "Apple Silicon uses its generic system counts")
        let rosetta = resolve(translated: true)
        expect(rosetta.performanceCores == nil && rosetta.efficiencyCores == nil, "translated Intel execution does not assert host P/E counts")
        let spoofedVendor = resolve(vendor: "intel-compatible")
        expect(spoofedVendor.performanceCores == nil, "vendor matching requires GenuineIntel")

        let standardIntel = IntelCoreCatalog.lookup("Intel(R) Core(TM) i5-12600 CPU @ 3.30GHz")
        let hybridIntel = IntelCoreCatalog.lookup("Intel(R) Core(TM) i5-12600K CPU @ 3.70GHz")
        expect(standardIntel?.performanceCores == 6 && standardIntel?.efficiencyCores == 0,
               "12th generation i5-12600 has no E-cores")
        expect(hybridIntel?.performanceCores == 6 && hybridIntel?.efficiencyCores == 4,
               "i5-12600K is distinguished from i5-12600")
        expect(IntelCoreCatalog.lookup("Intel Core i5-12600KF")?.efficiencyCores == 4,
               "K and KF variants map to verified shared core counts")
        expect(IntelCoreCatalog.lookup("Intel Core i5-12450H")?.performanceCores == 4 &&
               IntelCoreCatalog.lookup("Intel Core i5-12450H")?.efficiencyCores == 4,
               "mobile H-series SKU gets its own hybrid specification")
        expect(IntelCoreCatalog.lookup("Intel Core i5-12600KS") == nil &&
               IntelCoreCatalog.lookup("Intel Core i5-12600KXYZ") == nil,
               "partial SKU tokens do not match unsupported suffixes")

        let invalid = resolve("Intel Core i5-12600", currentCores: -1, maximumCores: -3,
                              currentThreads: -1, maximumThreads: 0)
        expect(invalid.physicalCores == 0 && invalid.logicalThreads == 0 && invalid.currentPhysicalCores == 0,
               "negative or unavailable sysctl counts are clamped to unavailable")
        let unreasonable = resolve("Intel Core i5-12600", currentCores: 5000, maximumCores: 6000,
                                   currentThreads: 9000, maximumThreads: 10000)
        expect(unreasonable.physicalCores == 0 && unreasonable.logicalThreads == 0,
               "unreasonable sysctl counts are rejected")
        let missingCurrent = resolve("Intel Core i5-12600", currentCores: 0, maximumCores: 6,
                                     currentThreads: 0, maximumThreads: 12)
        expect(missingCurrent.physicalCores == 6 && missingCurrent.logicalThreads == 12,
               "maximum counts are used only when current counts are missing")

        if failures.isEmpty {
            print("PASS: \(checks) CPU core topology checks; no probes or load were run")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            fputs("\(failures.count) failure(s) across \(checks) topology checks\n", stderr)
            exit(1)
        }
    }
}
