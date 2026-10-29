import Foundation
import zlib

@main
enum UpdateCoreTests {
    static var checks = 0
    static var failures: [String] = []

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }

    static func main() throws {
        versionChecks()
        try feedChecks()
        try checksumChecks()
        try archiveChecks()

        if failures.isEmpty {
            print("PASS: \(checks) update feed, digest, and ZIP safety checks; no network access or CPU loads")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            fputs("\(failures.count) failure(s) across \(checks) update checks\n", stderr)
            exit(1)
        }
    }

    private static func versionChecks() {
        guard let current = UpdateVersion.parse("v2.4.4"),
              let earlier = UpdateVersion.parse("v2.4.9"),
              let newer = UpdateVersion.parse("v2.5.0"),
              let major = UpdateVersion.parse("v10.0.0") else {
            failures.append("valid versions parse"); return
        }
        expect(current.description == "2.4.4" && current.tag == "v2.4.4", "versions expose bundle and tag forms")
        expect(earlier > current, "patch components compare numerically")
        expect(newer > earlier && major > newer, "minor and major components compare numerically")
        let intMaximum = String(repeating: "\(Int.max).", count: 2) + "\(Int.max)"
        expect(UpdateVersion.parse("v\(intMaximum)") != nil,
               "three maximum-width numeric components are supported")
        for malformed in ["2.5.0", "vv2.5.0", "v2.5", "v2.5.0.1", "v02.5.0", "v2.05.0",
                           "v2.5.00", "v-1.5.0", "v2.5.0-rc1", "v9223372036854775808.0.0", ""] {
            expect(UpdateVersion.parse(malformed) == nil, "reject malformed version \(malformed)")
        }
    }

    private static func feedChecks() throws {
        let current = UpdateVersion.parse("v2.4.4")!
        let valid = feed(tag: "v2.5.0")
        let update = try UpdateFeed.parse(data: valid, currentVersion: current)
        expect(update?.version.description == "2.5.0", "new stable release is selected")
        expect(update?.releaseID == 4321 && update?.size == 1234, "release ID and asset size are retained")
        expect(update?.sha256 == String(repeating: "a", count: 64), "GitHub asset digest is normalized")
        expect(update?.assetURL.absoluteString == assetURL("v2.5.0").absoluteString,
               "asset URL is the exact GitHub release path")

        try expectAbsent(feed(tag: "v2.4.4"), current, "current version is not downloaded again")
        try expectAbsent(feed(tag: "v2.4.3"), current, "numerically older patch release is skipped")
        try expectAbsent(feed(tag: "v2.5.0", draft: true), current, "draft release is skipped")
        try expectAbsent(feed(tag: "v2.5.0", prerelease: true), current, "prerelease is skipped")
        try expectAbsent(feed(tag: "v2.5.0", assets: []), current, "source archives do not count as app update assets")
        try expectAbsent(feed(tag: "v2.5.0", assets: [asset(name: "CPU-S2-v2.5.0-source.zip")]), current,
                         "source ZIP is never selected as an app ZIP")

        try rejectsFeed(feed(tag: "2.5.0"), current, "malformed tag")
        try rejectsFeed(feed(tag: "v2.5.0", releaseURL: "https://attacker.example/release"), current, "untrusted release page")
        try rejectsFeed(feed(tag: "v2.5.0", assetURL: "http://github.com/GeekAudio/CPU-S2/releases/download/v2.5.0/CPU-S2-v2.5.0.zip"), current,
                        "non-HTTPS asset URL")
        try rejectsFeed(feed(tag: "v2.5.0", assetURL: "https://github.com.evil.example/GeekAudio/CPU-S2/releases/download/v2.5.0/CPU-S2-v2.5.0.zip"), current,
                        "lookalike GitHub host")
        try rejectsFeed(feed(tag: "v2.5.0", digest: nil), current, "missing release digest")
        try rejectsFeed(feed(tag: "v2.5.0", digest: "sha256:not-a-hash"), current, "malformed release digest")
        try rejectsFeed(feed(tag: "v2.5.0", size: 1234.5), current, "fractional asset size")
        try rejectsFeed(feed(tag: "v2.5.0", releaseID: 4321.5), current, "fractional release ID")
        try rejectsFeed(feed(tag: "v2.5.0", size: UpdateFeed.maximumArchiveSize + 1), current, "oversized download")
        try rejectsFeed(feed(tag: "v2.5.0", size: 0), current, "empty download")
        try rejectsFeed(feed(tag: "v2.5.0", duplicateAsset: true), current, "duplicate app ZIP asset")

        let malformed = Data("[]".utf8)
        var threw = false
        do { _ = try UpdateFeed.parse(data: malformed, currentVersion: current) }
        catch { threw = true }
        expect(threw, "non-object feed is rejected")
    }

    private static func checksumChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cpus2-update-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload.bin")
        try Data("abc".utf8).write(to: file)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let checksum = try UpdateChecksum.sha256(of: file)
        let valid = try UpdateChecksum.matches(file: file, expected: expected)
        let uppercase = try UpdateChecksum.matches(file: file, expected: expected.uppercased())
        let mismatch = try UpdateChecksum.matches(file: file, expected: String(repeating: "0", count: 64))
        let malformed = try UpdateChecksum.matches(file: file, expected: "short")
        expect(checksum == expected, "file is hashed using streaming SHA-256")
        expect(valid, "matching download digest is accepted")
        expect(uppercase, "uppercase GitHub digest hex is accepted")
        expect(!mismatch, "mismatching download digest is rejected")
        expect(!malformed, "malformed download digest is rejected")
    }

    private static func archiveChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cpus2-update-zips-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = ZipFixture(path: "CPU-S2.app/", directory: true)
        let info = ZipFixture(path: "CPU-S2.app/Contents/Info.plist", contents: Data("bundle".utf8))
        let valid = try archive([root, info], directory: directory, name: "valid.zip")
        let entries = try UpdateZipArchive.validate(valid)
        expect(entries.count == 2 && entries.contains(where: { $0.path == "CPU-S2.app/Contents/Info.plist" }),
               "single app bundle with a plist passes preflight")

        let deflated = try archive([root, ZipFixture(path: "CPU-S2.app/Contents/Info.plist",
                                                       contents: Data("bundle".utf8), method: 8)],
                                   directory: directory, name: "deflated.zip")
        let deflatedEntries = try UpdateZipArchive.validate(deflated)
        expect(deflatedEntries.count == 2, "valid raw-DEFLATE app bundle passes preflight")

        let described = try archive([root, ZipFixture(path: "CPU-S2.app/Contents/Info.plist",
                                                         contents: Data("bundle".utf8), usesDescriptor: true)],
                                    directory: directory, name: "descriptor.zip")
        let describedEntries = try UpdateZipArchive.validate(described)
        expect(describedEntries.count == 2, "valid ZIP data descriptor passes preflight")

        var didReject = false
        do { _ = try UpdateZipArchive.validate(valid, maxExpandedBytes: 2) }
        catch { didReject = true }
        expect(didReject, "expanded-size limit is enforced")

        try rejectsArchive([root, info, ZipFixture(path: "CPU-S2.app/../outside", contents: Data())], directory, "parent path traversal")
        try rejectsArchive([root, info, ZipFixture(path: "/CPU-S2.app/outside", contents: Data())], directory, "absolute path")
        try rejectsArchive([root, info, ZipFixture(path: "Other.app/Contents/Info.plist", contents: Data())], directory, "additional extraction root")
        try rejectsArchive([root, info, ZipFixture(path: "CPU-S2.app/contents/info.plist", contents: Data())], directory,
                           "case-insensitive path collision")
        try rejectsArchive([root, info, ZipFixture(path: "CPU-S2.app/Contents/link", directory: false,
                                                   unixMode: 0xa1ff)], directory, "symbolic link")
        try rejectsArchive([root, info, ZipFixture(path: "CPU-S2.app/Contents", contents: Data())], directory,
                           "parent directory reused as a file")
        try rejectsArchive([root, ZipFixture(path: "CPU-S2.app/Contents/Info.plist", contents: Data("bundle".utf8), method: 12)],
                           directory, "unsupported compression")
        try rejectsArchive([root, ZipFixture(path: "CPU-S2.app/Contents/Info.plist", contents: Data("bundle".utf8),
                                             crcOverride: 1)], directory, "bad CRC")
        try rejectsArchive([root, ZipFixture(path: "CPU-S2.app/Contents/Info.plist", contents: Data("bundle".utf8),
                                             method: 8, crcOverride: 1)], directory, "bad DEFLATE CRC")
        try rejectsArchive([root, ZipFixture(path: "CPU-S2.app/Contents/Info.plist", contents: Data("bundle".utf8),
                                             localCRCOverride: 1)], directory, "local-central CRC mismatch")
        try rejectsArchive([root, ZipFixture(path: "CPU-S2.app/Contents/Info.plist", contents: Data("bundle".utf8),
                                             localCompressedSize: 1)], directory, "local-central compressed-size mismatch")
        try rejectsArchive([root, ZipFixture(path: "CPU-S2.app/Contents/Info.plist", contents: Data("bundle".utf8),
                                             localUncompressedSize: 1)], directory, "local-central size mismatch")
        try rejectsArchive([root, ZipFixture(path: "CPU-S2.app/Contents/Info.plist", contents: Data("bundle".utf8),
                                             usesDescriptor: true, descriptorCRCOverride: 1)],
                           directory, "data descriptor CRC mismatch")
        try rejectsArchive([root, info,
                            ZipFixture(path: "CPU-S2.app/Contents/Inflated", contents: Data(repeating: 65, count: 128 * 1024),
                                       method: 8, centralUncompressedSize: 64)],
                           directory, "forged expanded size")
        try rejectsArchive([root, ZipFixture(path: "CPU-S2.app/Contents/Info.plist", contents: Data("bundle".utf8),
                                             centralExtra: [1, 0, 0, 0])], directory, "ZIP64 extra field")
        try rejectsArchive([info], directory, "missing root directory")
        try rejectsArchive([root, ZipFixture(path: "CPU-S2.app/Contents/Readme", contents: Data(),
                                             centralExtra: [0x75, 0x70, 1, 0, 0])], directory,
                           "overriding Unicode path extra field")
        var truncated = try Data(contentsOf: valid)
        truncated.removeLast(1)
        try truncated.write(to: directory.appendingPathComponent("truncated.zip"))
        didReject = false
        do { _ = try UpdateZipArchive.validate(directory.appendingPathComponent("truncated.zip")) }
        catch { didReject = true }
        expect(didReject, "truncated ZIP is rejected")
    }

    private static func rejectsFeed(_ data: Data, _ current: UpdateVersion, _ description: String) throws {
        var rejected = false
        do { _ = try UpdateFeed.parse(data: data, currentVersion: current) }
        catch { rejected = true }
        expect(rejected, "reject feed with \(description)")
    }

    private static func expectAbsent(_ data: Data, _ current: UpdateVersion, _ description: String) throws {
        let update = try UpdateFeed.parse(data: data, currentVersion: current)
        expect(update == nil, description)
    }

    private static func rejectsArchive(_ entries: [ZipFixture], _ directory: URL, _ description: String) throws {
        let file = try archive(entries, directory: directory, name: "rejected-\(checks).zip")
        var rejected = false
        do { _ = try UpdateZipArchive.validate(file) }
        catch { rejected = true }
        expect(rejected, "reject ZIP with \(description)")
    }

    private static func feed(tag: String, draft: Bool = false, prerelease: Bool = false,
                             assets: [[String: Any]]? = nil, releaseURL: String? = nil,
                             assetURL: String? = nil, digest: String? = "sha256:" + String(repeating: "A", count: 64),
                             size: Any = 1234, releaseID: Any = 4321, duplicateAsset: Bool = false) -> Data {
        var selectedAssets = assets ?? [asset(name: "CPU-S2-\(tag).zip", url: assetURL, digest: digest, size: size)]
        if duplicateAsset { selectedAssets.append(asset(name: "CPU-S2-\(tag).zip", url: assetURL, digest: digest, size: size)) }
        let object: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease,
                                     "id": releaseID, "html_url": releaseURL ?? "https://github.com/GeekAudio/CPU-S2/releases/tag/\(tag)",
                                     "assets": selectedAssets]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func asset(name: String, url: String? = nil, digest: String? = "sha256:" + String(repeating: "a", count: 64),
                              size: Any = 1234) -> [String: Any] {
        var result: [String: Any] = ["name": name, "size": size,
                                     "browser_download_url": url ?? assetURL(name.replacingOccurrences(of: "CPU-S2-", with: "").replacingOccurrences(of: ".zip", with: ""), filename: name).absoluteString]
        if let digest = digest { result["digest"] = digest }
        return result
    }

    private static func assetURL(_ tag: String, filename: String? = nil) -> URL {
        URL(string: "https://github.com/GeekAudio/CPU-S2/releases/download/\(tag)/\(filename ?? "CPU-S2-\(tag).zip")")!
    }

    private struct ZipFixture {
        let path: String
        let directory: Bool
        let contents: Data
        let unixMode: UInt16
        let method: UInt16
        let centralExtra: [UInt8]
        let crcOverride: UInt32?
        let localCRCOverride: UInt32?
        let localCompressedSize: UInt32?
        let localUncompressedSize: UInt32?
        let centralUncompressedSize: UInt32?
        let usesDescriptor: Bool
        let descriptorCRCOverride: UInt32?
        let descriptorCompressedSizeOverride: UInt32?
        let descriptorUncompressedSizeOverride: UInt32?
        let descriptorHasSignature: Bool

        init(path: String, directory: Bool = false, contents: Data = Data(), unixMode: UInt16? = nil,
             method: UInt16 = 0, centralExtra: [UInt8] = [], crcOverride: UInt32? = nil,
             localCRCOverride: UInt32? = nil, localCompressedSize: UInt32? = nil,
             localUncompressedSize: UInt32? = nil, centralUncompressedSize: UInt32? = nil,
             usesDescriptor: Bool = false, descriptorCRCOverride: UInt32? = nil,
             descriptorCompressedSizeOverride: UInt32? = nil, descriptorUncompressedSizeOverride: UInt32? = nil,
             descriptorHasSignature: Bool = true) {
            self.path = path
            self.directory = directory
            self.contents = contents
            self.unixMode = unixMode ?? (directory ? 0x41ed : 0x81a4)
            self.method = method
            self.centralExtra = centralExtra
            self.crcOverride = crcOverride
            self.localCRCOverride = localCRCOverride
            self.localCompressedSize = localCompressedSize
            self.localUncompressedSize = localUncompressedSize
            self.centralUncompressedSize = centralUncompressedSize
            self.usesDescriptor = usesDescriptor
            self.descriptorCRCOverride = descriptorCRCOverride
            self.descriptorCompressedSizeOverride = descriptorCompressedSizeOverride
            self.descriptorUncompressedSizeOverride = descriptorUncompressedSizeOverride
            self.descriptorHasSignature = descriptorHasSignature
        }
    }

    private static func archive(_ entries: [ZipFixture], directory: URL, name: String) throws -> URL {
        var bytes: [UInt8] = []
        var central: [UInt8] = []
        for entry in entries {
            let path = Array(entry.path.utf8)
            let payloadData = entry.method == 8 ? try deflateRaw(entry.contents) : entry.contents
            let payload = Array(payloadData)
            let checksum = entry.crcOverride ?? checksumOf(entry.contents)
            let declaredUncompressed = entry.centralUncompressedSize ?? UInt32(entry.contents.count)
            let localUncompressed = entry.localUncompressedSize ?? (entry.usesDescriptor ? 0 : declaredUncompressed)
            let flags: UInt16 = 0x0800 | (entry.usesDescriptor ? 0x0008 : 0)
            let localChecksum = entry.localCRCOverride ?? (entry.usesDescriptor ? 0 : checksum)
            let localCompressed = entry.localCompressedSize ?? (entry.usesDescriptor ? 0 : UInt32(payload.count))
            let offset = bytes.count
            append32(0x04034b50, to: &bytes)
            append16(20, to: &bytes); append16(flags, to: &bytes)
            append16(entry.method, to: &bytes); append16(0, to: &bytes); append16(0, to: &bytes)
            append32(localChecksum, to: &bytes)
            append32(localCompressed, to: &bytes); append32(localUncompressed, to: &bytes)
            append16(UInt16(path.count), to: &bytes); append16(0, to: &bytes)
            bytes += path; bytes += payload
            if entry.usesDescriptor {
                if entry.descriptorHasSignature { append32(0x08074b50, to: &bytes) }
                append32(entry.descriptorCRCOverride ?? checksum, to: &bytes)
                append32(entry.descriptorCompressedSizeOverride ?? UInt32(payload.count), to: &bytes)
                append32(entry.descriptorUncompressedSizeOverride ?? declaredUncompressed, to: &bytes)
            }

            append32(0x02014b50, to: &central)
            append16(0x0314, to: &central); append16(20, to: &central)
            append16(flags, to: &central); append16(entry.method, to: &central)
            append16(0, to: &central); append16(0, to: &central); append32(checksum, to: &central)
            append32(UInt32(payload.count), to: &central); append32(declaredUncompressed, to: &central)
            append16(UInt16(path.count), to: &central); append16(UInt16(entry.centralExtra.count), to: &central)
            append16(0, to: &central); append16(0, to: &central); append16(0, to: &central)
            append32((UInt32(entry.unixMode) << 16) | (entry.directory ? 0x10 : 0), to: &central)
            append32(UInt32(offset), to: &central)
            central += path; central += entry.centralExtra
        }
        let centralOffset = bytes.count
        bytes += central
        append32(0x06054b50, to: &bytes)
        append16(0, to: &bytes); append16(0, to: &bytes)
        append16(UInt16(entries.count), to: &bytes); append16(UInt16(entries.count), to: &bytes)
        append32(UInt32(central.count), to: &bytes); append32(UInt32(centralOffset), to: &bytes); append16(0, to: &bytes)
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private static func checksumOf(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(truncatingIfNeeded: zlib.crc32(0, bytes.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(bytes.count)))
        }
    }

    private static func deflateRaw(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
                                        Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw UpdateCoreError.invalidArchive("Test DEFLATE encoder could not initialize.") }
        defer { deflateEnd(&stream) }

        var input = Array(data)
        var output = [UInt8](repeating: 0, count: 64 * 1024)
        var compressed: [UInt8] = []
        var finished = false
        try input.withUnsafeMutableBufferPointer { inputBytes in
            try output.withUnsafeMutableBufferPointer { outputBytes in
                stream.next_in = inputBytes.baseAddress
                stream.avail_in = uInt(inputBytes.count)
                while !finished {
                    stream.next_out = outputBytes.baseAddress
                    stream.avail_out = uInt(outputBytes.count)
                    let status = deflate(&stream, Z_FINISH)
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw UpdateCoreError.invalidArchive("Test DEFLATE encoder failed.")
                    }
                    let produced = outputBytes.count - Int(stream.avail_out)
                    compressed.append(contentsOf: outputBytes.prefix(produced))
                    finished = status == Z_STREAM_END
                }
            }
        }
        return Data(compressed)
    }

    private static func append16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xff)); bytes.append(UInt8((value >> 8) & 0xff))
    }

    private static func append32(_ value: UInt32, to bytes: inout [UInt8]) {
        append16(UInt16(value & 0xffff), to: &bytes); append16(UInt16((value >> 16) & 0xffff), to: &bytes)
    }
}
