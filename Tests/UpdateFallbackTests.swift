import Foundation

@main
enum UpdateFallbackTests {
    private static var checks = 0
    private static var failures: [String] = []

    static func main() throws {
        releaseURLChecks()
        try checksumChecks()

        if failures.isEmpty {
            print("PASS: \(checks) offline GitHub release fallback checks; no network access")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            fputs("\(failures.count) failure(s) across \(checks) fallback checks\n", stderr)
            exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }

    private static func releaseURLChecks() {
        let canonical = url("https://github.com/GeekAudio/CPU-S2/releases/tag/v2.5.1")
        let version = UpdateFallback.version(fromReleaseURL: canonical)
        expect(version?.description == "2.5.1" && version?.tag == "v2.5.1",
               "canonical GitHub release URL returns its numeric version")

        let invalidURLs = [
            "http://github.com/GeekAudio/CPU-S2/releases/tag/v2.5.1",
            "https://github.com.evil.example/GeekAudio/CPU-S2/releases/tag/v2.5.1",
            "https://evil.example/GeekAudio/CPU-S2/releases/tag/v2.5.1",
            "https://user@github.com/GeekAudio/CPU-S2/releases/tag/v2.5.1",
            "https://github.com:443/GeekAudio/CPU-S2/releases/tag/v2.5.1",
            "https://github.com/GeekAudio/CPU-S2/releases/tag/v2.5.1?download=1",
            "https://github.com/GeekAudio/CPU-S2/releases/tag/v2.5.1#release",
            "https://github.com/Other/CPU-S2/releases/tag/v2.5.1",
            "https://github.com/GeekAudio/Other/releases/tag/v2.5.1",
            "https://github.com/GeekAudio/CPU-S2/releases/tag/v2.5.1/",
            "https://github.com/GeekAudio/CPU-S2/releases/tag/v2.5.1-rc1",
            "https://github.com/GeekAudio/CPU-S2/releases/tag/v02.5.1",
            "https://github.com/GeekAudio/CPU-S2/releases/tag/v2.5.1%2Fextra"
        ]
        for value in invalidURLs {
            expect(UpdateFallback.version(fromReleaseURL: url(value)) == nil,
                   "reject non-canonical release URL \(value)")
        }

        let versionForURLs = UpdateVersion.parse("v2.5.1")!
        expect(UpdateFallback.assetURL(for: versionForURLs).absoluteString ==
               "https://github.com/GeekAudio/CPU-S2/releases/download/v2.5.1/CPU-S2-v2.5.1.zip",
               "asset URL points to the exact app ZIP")
        expect(UpdateFallback.checksumsURL(for: versionForURLs).absoluteString ==
               "https://github.com/GeekAudio/CPU-S2/releases/download/v2.5.1/SHA256SUMS.txt",
               "checksums URL points to the exact release manifest")
    }

    private static func checksumChecks() throws {
        let version = UpdateVersion.parse("v2.5.1")!
        let targetName = "CPU-S2-v2.5.1.zip"
        let sourceName = "CPU-S2-v2.5.1-source.zip"
        let hash = String(repeating: "A", count: 64)
        let sourceHash = String(repeating: "b", count: 64)

        let manifest = "\(sourceHash)  \(sourceName)\r\n\(hash)  \(targetName)\r\n"
        let selected = try UpdateFallback.checksum(from: Data(manifest.utf8), version: version)
        expect(selected == String(repeating: "a", count: 64), "CRLF manifest returns normalized app ZIP digest")

        let sourceOnly = "\(sourceHash)  \(sourceName)\n"
        let sourceResult = try UpdateFallback.checksum(from: Data(sourceOnly.utf8), version: version)
        expect(sourceResult == nil, "GitHub source ZIP is never selected as the app ZIP")

        let olderOnly = "\(hash)  CPU-S2-v2.5.0.zip\n"
        let olderResult = try UpdateFallback.checksum(from: Data(olderOnly.utf8), version: version)
        expect(olderResult == nil, "another version's checksum is ignored")
        let emptyResult = try UpdateFallback.checksum(from: Data(), version: version)
        expect(emptyResult == nil, "missing app ZIP entry reports no fallback update")

        try rejectsChecksum("\(hash)  \(targetName)\n\(hash)  \(targetName)\n", version,
                            "duplicate app ZIP entries")
        try rejectsChecksum("\(String(repeating: "z", count: 64))  \(targetName)\n", version,
                            "malformed digest for the app ZIP")
        try rejectsChecksum("\(hash) \(targetName)\n", version, "non-canonical checksum separator")
        try rejectsChecksum("\(hash)   \(targetName)\n", version, "ambiguous checksum filename spacing")
        try rejectsChecksum("\(hash)  \(targetName)\r", version, "bare carriage return")
        try rejectsChecksum("\(hash)  \(targetName)\n\n", version, "interior blank line")
        try rejectsChecksum("\(hash)  ../\(targetName)\n", version, "path in checksum filename")

        var invalidUTF8 = Data([0xff, 0xfe])
        try rejectsChecksum(invalidUTF8, version, "invalid UTF-8")
        invalidUTF8 = Data(repeating: 0x41, count: UpdateFallback.maximumChecksumsSize + 1)
        try rejectsChecksum(invalidUTF8, version, "manifest over 64 KiB")
    }

    private static func rejectsChecksum(_ text: String, _ version: UpdateVersion, _ message: String) throws {
        try rejectsChecksum(Data(text.utf8), version, message)
    }

    private static func rejectsChecksum(_ data: Data, _ version: UpdateVersion, _ message: String) throws {
        var rejected = false
        do { _ = try UpdateFallback.checksum(from: data, version: version) }
        catch { rejected = true }
        expect(rejected, "reject manifest with \(message)")
    }

    private static func url(_ value: String) -> URL {
        URL(string: value)!
    }
}
