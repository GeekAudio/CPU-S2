import Foundation

/// Intel's published core counts by exact processor number.
/// These are SKU specifications; firmware may disable cores and the catalog does
/// not claim to enumerate the currently enabled P/E cores.
enum IntelCoreCatalog {
    struct Entry {
        let model: String
        let performanceCores: Int
        let efficiencyCores: Int
        let maximumThreads: Int
        let referenceURL: String

        var totalCores: Int { performanceCores + efficiencyCores }
    }

    private struct Family {
        let referenceURL: String
        let rows: [(tokens: [String], p: Int, e: Int, threads: Int)]
    }

    private static let families: [Family] = [
        Family(referenceURL: "https://cdrdv2-public.intel.com/754040/CPM-21-02_12thGen_QuickRefGuide_P2_v2.pdf", rows: [
            // The Intel SKU chart explicitly names each of these desktop parts.
            ( ["i9-12900k", "i9-12900kf"], 8, 8, 24 ),
            ( ["i9-12900", "i9-12900f"], 8, 8, 24 ),
            ( ["i7-12700k", "i7-12700kf"], 8, 4, 20 ),
            ( ["i7-12700", "i7-12700f"], 8, 4, 20 ),
            ( ["i5-12600k", "i5-12600kf"], 6, 4, 16 ),
            ( ["i5-12600", "i5-12500", "i5-12400", "i5-12400f"], 6, 0, 12 ),
            ( ["i3-12300"], 4, 0, 8 ),
            ( ["i3-12100", "i3-12100f"], 4, 0, 8 ),
        ]),
        Family(referenceURL: "https://www.intel.com/content/www/us/en/products/sku/225916/intel-core-i912900ks-processor-30m-cache-up-to-5-50-ghz/specifications.html", rows: [
            ( ["i9-12900ks"], 8, 8, 24 ),
        ]),
        Family(referenceURL: "https://download.intel.com/newsroom/2022/client-computing/12th-gen-intel-mobile-product-brief.pdf", rows: [
            // H-series SKU comparison chart in Intel's 12th Gen mobile brief.
            ( ["i9-12900hk", "i9-12900h", "i7-12800h", "i7-12700h"], 6, 8, 20 ),
            ( ["i7-12650h"], 6, 4, 16 ),
            ( ["i5-12600h", "i5-12500h"], 4, 8, 16 ),
            ( ["i5-12450h"], 4, 4, 12 ),
        ]),
        Family(referenceURL: "https://cdrdv2-public.intel.com/844360/Intel-Core-Desktop-Boxed-Processors-HD-GFX-List.pdf", rows: [
            // Intel's desktop SKU chart gives core and thread counts per named SKU.
            ( ["i9-13900ks", "i9-13900k", "i9-13900kf"], 8, 16, 32 ),
            ( ["i9-13900", "i9-13900f", "i9-13900t"], 8, 16, 32 ),
            ( ["i7-13700k", "i7-13700kf"], 8, 8, 24 ),
            ( ["i7-13700", "i7-13700f", "i7-13700t"], 8, 8, 24 ),
            ( ["i5-13600k", "i5-13600kf", "i5-13600", "i5-13600t"], 6, 8, 20 ),
            ( ["i5-13500", "i5-13500t"], 6, 8, 20 ),
            ( ["i5-13400", "i5-13400f", "i5-13400t"], 6, 4, 16 ),
            ( ["i3-13100", "i3-13100f", "i3-13100t"], 4, 0, 8 ),
            ( ["i9-14900ks", "i9-14900k", "i9-14900kf"], 8, 16, 32 ),
            ( ["i9-14900", "i9-14900f", "i9-14900t"], 8, 16, 32 ),
            ( ["i7-14700k", "i7-14700kf"], 8, 12, 28 ),
            ( ["i7-14700", "i7-14700f", "i7-14700t"], 8, 12, 28 ),
            ( ["i5-14600k", "i5-14600kf", "i5-14600", "i5-14600t"], 6, 8, 20 ),
            ( ["i5-14500", "i5-14500t"], 6, 8, 20 ),
            ( ["i5-14400", "i5-14400f", "i5-14400t"], 6, 4, 16 ),
            ( ["i3-14100", "i3-14100f", "i3-14100t"], 4, 0, 8 ),
        ]),
        Family(referenceURL: "https://www.intel.com/content/www/us/en/products/docs/processors/core-ultra/core-ultra-desktop-processors-series-2-brief.html", rows: [
            // These seven full names appear in the mainstream SKU chart.
            ( ["ultra 9 285"], 8, 16, 24 ),
            ( ["ultra 7 265", "ultra 7 265f"], 8, 12, 20 ),
            ( ["ultra 5 245", "ultra 5 235"], 6, 8, 14 ),
            ( ["ultra 5 225", "ultra 5 225f"], 6, 4, 10 ),
        ]),
        Family(referenceURL: "https://www.intel.com/content/www/us/en/support/articles/000099656/processors.html", rows: [
            // The official boxed K/KF chart lists these variants and counts.
            ( ["ultra 9 285k"], 8, 16, 24 ),
            ( ["ultra 7 265k", "ultra 7 265kf"], 8, 12, 20 ),
            ( ["ultra 5 245k", "ultra 5 245kf"], 6, 8, 14 ),
            ( ["ultra 7 270k plus"], 8, 16, 24 ),
            ( ["ultra 5 250k plus", "ultra 5 250kf plus"], 6, 12, 18 ),
        ]),
        Family(referenceURL: "https://www.intel.com/content/www/us/en/products/sku/241059/intel-core-ultra-9-processor-285t-36m-cache-up-to-5-40-ghz/specifications.html", rows: [
            ( ["ultra 9 285t"], 8, 16, 24 ),
        ]),
        Family(referenceURL: "https://www.intel.com/content/www/us/en/products/sku/241065/intel-core-ultra-7-processor-265t-30m-cache-up-to-5-30-ghz/specifications.html", rows: [
            ( ["ultra 7 265t"], 8, 12, 20 ),
        ]),
        Family(referenceURL: "https://www.intel.com/content/www/us/en/products/sku/241872/intel-core-ultra-5-processor-235t-24m-cache-up-to-5-00-ghz/specifications.html", rows: [
            ( ["ultra 5 235t"], 6, 8, 14 ),
        ])
    ]

    static func lookup(_ brand: String) -> Entry? {
        let normalized = brand.lowercased()
        guard normalized.contains("intel"), normalized.contains("core") else { return nil }

        for family in families {
            for row in family.rows {
                for token in row.tokens {
                    guard containsWholeToken(token, in: normalized) else { continue }
                    let model = token.hasPrefix("ultra ")
                        ? "Core Ultra \(token.dropFirst(6).uppercased())"
                        : "Core \(token.prefix(1))\(token.dropFirst().uppercased())"
                    return Entry(model: model.uppercased(), performanceCores: row.p,
                                 efficiencyCores: row.e, maximumThreads: row.threads,
                                 referenceURL: family.referenceURL)
                }
            }
        }
        return nil
    }

    private static func containsWholeToken(_ token: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        guard let expression = try? NSRegularExpression(pattern: "(?<![a-z0-9])\(escaped)(?![a-z0-9])") else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }
}
