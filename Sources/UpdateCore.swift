import Foundation
import CryptoKit
import CoreFoundation
import zlib

/// Strict release-number parsing. Bundle versions omit the release tag's leading `v`.
struct UpdateVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { "\(major).\(minor).\(patch)" }
    var tag: String { "v\(description)" }

    static func parseBundleVersion(_ value: String?) -> UpdateVersion? {
        guard let value = value, !value.hasPrefix("v") else { return nil }
        return parse("v" + value)
    }

    static func parse(_ value: String?) -> UpdateVersion? {
        guard let value = value, value.utf8.count <= 60, value.first == "v" else { return nil }
        let components = value.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        var numbers: [Int] = []
        for component in components {
            guard !component.isEmpty, component.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  component.count == 1 || component.first != "0",
                  let number = Int(component), number >= 0 else { return nil }
            numbers.append(number)
        }
        return UpdateVersion(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct ReleaseUpdate {
    let version: UpdateVersion
    let assetURL: URL
    /// Lowercase, 64-character SHA-256 hex from the GitHub release asset metadata.
    let sha256: String
    let size: Int64
    let releaseURL: URL
    let releaseID: Int64
}

enum UpdateFeed {
    static let maximumArchiveSize: Int64 = 100 * 1024 * 1024

    /// Parse the one expected, zipped .app release asset. A GitHub-generated source archive
    /// or an older/current release means there is no applicable automatic update.
    static func parse(data: Data, currentVersion: UpdateVersion) throws -> ReleaseUpdate? {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw UpdateCoreError.invalidFeed("GitHub returned invalid release JSON.") }
        guard let release = value as? [String: Any],
              let tag = release["tag_name"] as? String,
              let version = UpdateVersion.parse(tag) else {
            throw UpdateCoreError.invalidFeed("GitHub release has no valid vX.Y.Z tag.")
        }
        guard let draft = strictBoolean(release["draft"]),
              let prerelease = strictBoolean(release["prerelease"]) else {
            throw UpdateCoreError.invalidFeed("GitHub release status fields are invalid.")
        }
        guard !draft, !prerelease, version > currentVersion else { return nil }

        guard let releaseID = strictInteger(release["id"]), releaseID > 0,
              let releaseString = release["html_url"] as? String,
              let releaseURL = URL(string: releaseString), isExpectedReleaseURL(releaseURL, tag: version.tag),
              let assets = release["assets"] as? [[String: Any]] else {
            throw UpdateCoreError.invalidFeed("GitHub release metadata is incomplete.")
        }

        let expectedName = "CPU-S2-\(version.tag).zip"
        let matches = assets.filter { ($0["name"] as? String) == expectedName }
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1, let asset = matches.first,
              let size = strictInteger(asset["size"]) else {
            throw UpdateCoreError.invalidFeed("Release must contain exactly one valid CPU-S2 ZIP asset.")
        }
        guard size > 0, size <= maximumArchiveSize else {
            throw UpdateCoreError.invalidFeed("Release ZIP size is outside the supported limit.")
        }
        guard let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") else {
            throw UpdateCoreError.invalidFeed("Release ZIP has no GitHub SHA-256 digest.")
        }
        let hash = String(digest.dropFirst("sha256:".count)).lowercased()
        guard hash.count == 64, hash.utf8.allSatisfy({ isHex($0) }) else {
            throw UpdateCoreError.invalidFeed("Release ZIP digest is not a SHA-256 value.")
        }
        guard let browserURLString = asset["browser_download_url"] as? String,
              let assetURL = URL(string: browserURLString),
              isExpectedAssetURL(assetURL, tag: version.tag, filename: expectedName) else {
            throw UpdateCoreError.invalidFeed("Release ZIP URL is not the expected GitHub asset.")
        }
        return ReleaseUpdate(version: version, assetURL: assetURL, sha256: hash, size: size,
                             releaseURL: releaseURL, releaseID: releaseID)
    }

    private static func strictInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.int64Value
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func isExpectedReleaseURL(_ url: URL, tag: String) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com" &&
        url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil &&
        url.path == "/GeekAudio/CPU-S2/releases/tag/\(tag)"
    }

    private static func isExpectedAssetURL(_ url: URL, tag: String, filename: String) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com" &&
        url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil &&
        url.path == "/GeekAudio/CPU-S2/releases/download/\(tag)/\(filename)"
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102) || (byte >= 65 && byte <= 70)
    }
}

enum UpdateChecksum {
    /// Hash an already-downloaded file in bounded chunks.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matches(file: URL, expected: String) throws -> Bool {
        guard expected.count == 64, expected.utf8.allSatisfy({
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70)
        }) else { return false }
        return try sha256(of: file) == expected.lowercased()
    }
}

struct UpdateZipEntry {
    let path: String
    let isDirectory: Bool
    let uncompressedSize: Int64
}

enum UpdateZipArchive {
    static let maximumFileCount = 8192
    static let maximumArchiveSize: Int64 = 100 * 1024 * 1024
    static let maximumExpandedSize: Int64 = 512 * 1024 * 1024

    /// Inspect ZIP central and local headers before any extraction. Only the release's
    /// single root CPU-S2.app tree is accepted.
    static func validate(_ zipURL: URL, maxExpandedBytes: Int64 = maximumExpandedSize) throws -> [UpdateZipEntry] {
        guard maxExpandedBytes > 0, maxExpandedBytes <= maximumExpandedSize else {
            throw UpdateCoreError.invalidArchive("Expanded ZIP size limit is invalid.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        guard let fileSizeNumber = attributes[.size] as? NSNumber else {
            throw UpdateCoreError.invalidArchive("ZIP file size could not be read.")
        }
        let fileSize = fileSizeNumber.int64Value
        guard fileSize >= 22, fileSize <= maximumArchiveSize, fileSize <= Int64(Int.max) else {
            throw UpdateCoreError.invalidArchive("ZIP file size is outside the supported limit.")
        }
        let data: Data
        do { data = try Data(contentsOf: zipURL, options: [.mappedIfSafe]) }
        catch { throw UpdateCoreError.invalidArchive("ZIP file could not be read.") }
        guard Int64(data.count) == fileSize else { throw UpdateCoreError.invalidArchive("ZIP changed while it was inspected.") }

        guard let end = endRecord(in: data) else { throw UpdateCoreError.invalidArchive("ZIP end record is missing or malformed.") }
        guard read16(data, end + 4) == 0, read16(data, end + 6) == 0,
              read16(data, end + 8) == read16(data, end + 10) else {
            throw UpdateCoreError.invalidArchive("Multi-disk ZIP archives are not supported.")
        }
        let count = Int(read16(data, end + 10))
        let directorySize = Int(read32(data, end + 12))
        let directoryOffset = Int(read32(data, end + 16))
        guard count > 0, count <= maximumFileCount,
              directoryOffset >= 0, directorySize >= 0,
              directoryOffset <= data.count, directorySize <= data.count - directoryOffset,
              directoryOffset + directorySize == end else {
            throw UpdateCoreError.invalidArchive("ZIP central directory exceeds the supported limits.")
        }

        var cursor = directoryOffset
        let directoryEnd = directoryOffset + directorySize
        var entries: [UpdateZipEntry] = []
        var exactNames = Set<String>()
        var foldedNames = Set<String>()
        var pathKinds: [String: Bool] = [:] // true is a directory, false is a file
        var localOffsets = Set<Int>()
        var localSpans: [Range<Int>] = []
        var expandedTotal: Int64 = 0
        var actualExpandedTotal: Int64 = 0
        var rootDirectory = false

        for _ in 0..<count {
            guard cursor <= directoryEnd, directoryEnd - cursor >= 46,
                  read32(data, cursor) == 0x02014b50 else {
                throw UpdateCoreError.invalidArchive("ZIP central directory entry is malformed.")
            }
            let madeBy = read16(data, cursor + 4)
            let flags = read16(data, cursor + 8)
            let method = read16(data, cursor + 10)
            let expectedCRC = read32(data, cursor + 16)
            let compressedValue = read32(data, cursor + 20)
            let uncompressedValue = read32(data, cursor + 24)
            let compressed = Int64(compressedValue)
            let uncompressed = Int64(uncompressedValue)
            let nameLength = Int(read16(data, cursor + 28))
            let extraLength = Int(read16(data, cursor + 30))
            let commentLength = Int(read16(data, cursor + 32))
            let diskStart = read16(data, cursor + 34)
            let externalAttributes = read32(data, cursor + 38)
            let localOffset = Int(read32(data, cursor + 42))
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, recordLength <= directoryEnd - cursor else {
                throw UpdateCoreError.invalidArchive("ZIP entry lengths are invalid.")
            }
            guard diskStart == 0, compressed != Int64(UInt32.max), uncompressed != Int64(UInt32.max),
                  localOffset != Int(UInt32.max), (flags & 0x0001) == 0, (flags & 0x0040) == 0,
                  method == 0 || method == 8 else {
                throw UpdateCoreError.invalidArchive("Encrypted, ZIP64, split, or unsupported ZIP entry found.")
            }
            if method == 0 && compressedValue != uncompressedValue {
                throw UpdateCoreError.invalidArchive("Stored ZIP entries have inconsistent compressed and expanded sizes.")
            }
            let nameStart = cursor + 46
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            guard let rawName = String(data: nameData, encoding: .utf8),
                  rawName.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }), !rawName.contains("\\"), !rawName.contains("\0") else {
                throw UpdateCoreError.invalidArchive("ZIP contains an invalid UTF-8 or control-character path.")
            }
            try validateExtraFields(data, start: nameStart + nameLength, length: extraLength)
            let directory = rawName.hasSuffix("/")
            let path = directory ? String(rawName.dropLast()) : rawName
            try validatePath(path)

            let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let root = components.first, root == "CPU-S2.app", components.count >= 1 else {
                throw UpdateCoreError.invalidArchive("ZIP must contain only one CPU-S2.app root directory.")
            }
            if components.count == 1 {
                guard directory else { throw UpdateCoreError.invalidArchive("CPU-S2.app root must be a directory.") }
                rootDirectory = true
            }
            guard expandedTotal <= maxExpandedBytes - uncompressed else {
                throw UpdateCoreError.invalidArchive("ZIP expands beyond the supported size limit.")
            }
            expandedTotal += uncompressed
            if directory && uncompressed != 0 {
                throw UpdateCoreError.invalidArchive("ZIP directory entries must not contain data.")
            }
            guard exactNames.insert(path).inserted else {
                throw UpdateCoreError.invalidArchive("ZIP contains duplicate paths.")
            }
            let folded = path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard foldedNames.insert(folded).inserted else {
                throw UpdateCoreError.invalidArchive("ZIP contains paths that collide on a typical macOS volume.")
            }

            if components.count > 1 {
                for index in 1..<components.count {
                    let parent = components.prefix(index).joined(separator: "/")
                    if let kind = pathKinds[parent], !kind {
                        throw UpdateCoreError.invalidArchive("ZIP file path is also used as a directory.")
                    }
                    pathKinds[parent] = true
                }
            }
            if let kind = pathKinds[path], kind != directory {
                throw UpdateCoreError.invalidArchive("ZIP path has conflicting file and directory entries.")
            }
            pathKinds[path] = directory

            // Unix symlink/device entries can escape the extraction root; only regular files and directories are valid.
            let creatorOS = madeBy >> 8
            let unixMode = UInt16((externalAttributes >> 16) & 0xffff)
            if creatorOS == 3 || creatorOS == 19 {
                let fileType = unixMode & 0xf000
                guard fileType == 0 || (directory && fileType == 0x4000) || (!directory && fileType == 0x8000) else {
                    throw UpdateCoreError.invalidArchive("ZIP contains a symbolic link or special file.")
                }
            }

            guard localOffsets.insert(localOffset).inserted,
                  localOffset >= 0, localOffset <= directoryOffset, directoryOffset - localOffset >= 30,
                  read32(data, localOffset) == 0x04034b50 else {
                throw UpdateCoreError.invalidArchive("ZIP local file header is malformed or reused.")
            }
            let localFlags = read16(data, localOffset + 6)
            let localMethod = read16(data, localOffset + 8)
            let localCRC = read32(data, localOffset + 14)
            let localCompressed = read32(data, localOffset + 18)
            let localUncompressed = read32(data, localOffset + 22)
            let localNameLength = Int(read16(data, localOffset + 26))
            let localExtraLength = Int(read16(data, localOffset + 28))
            let localRecordLength = 30 + localNameLength + localExtraLength
            guard localFlags == flags, localMethod == method, localNameLength == nameLength,
                  localCompressed != UInt32.max, localUncompressed != UInt32.max,
                  localRecordLength <= directoryOffset - localOffset else {
                throw UpdateCoreError.invalidArchive("ZIP local and central file headers disagree.")
            }
            if (flags & 0x0008) == 0 {
                guard localCRC == expectedCRC, localCompressed == compressedValue,
                      localUncompressed == uncompressedValue else {
                    throw UpdateCoreError.invalidArchive("ZIP local and central sizes or CRC disagree.")
                }
            } else {
                guard (localCRC == 0 || localCRC == expectedCRC),
                      (localCompressed == 0 || localCompressed == compressedValue),
                      (localUncompressed == 0 || localUncompressed == uncompressedValue) else {
                    throw UpdateCoreError.invalidArchive("ZIP local header conflicts with its data descriptor.")
                }
            }
            let localNameStart = localOffset + 30
            guard data.subdata(in: localNameStart..<(localNameStart + localNameLength)) == nameData else {
                throw UpdateCoreError.invalidArchive("ZIP local and central paths disagree.")
            }
            try validateExtraFields(data, start: localNameStart + localNameLength, length: localExtraLength)
            let payloadStart = localOffset + localRecordLength
            guard compressed <= Int64(directoryOffset - payloadStart) else {
                throw UpdateCoreError.invalidArchive("ZIP compressed data exceeds the archive bounds.")
            }
            let payloadEnd = payloadStart + Int(compressed)
            var recordEnd = payloadEnd
            if (flags & 0x0008) != 0 {
                guard payloadEnd <= directoryOffset else {
                    throw UpdateCoreError.invalidArchive("ZIP data descriptor is truncated.")
                }
                let remaining = directoryOffset - payloadEnd
                let signedMatches = remaining >= 16 && read32(data, payloadEnd) == 0x08074b50 &&
                    read32(data, payloadEnd + 4) == expectedCRC &&
                    read32(data, payloadEnd + 8) == compressedValue &&
                    read32(data, payloadEnd + 12) == uncompressedValue
                let unsignedMatches = remaining >= 12 &&
                    read32(data, payloadEnd) == expectedCRC &&
                    read32(data, payloadEnd + 4) == compressedValue &&
                    read32(data, payloadEnd + 8) == uncompressedValue
                guard signedMatches || unsignedMatches else {
                    throw UpdateCoreError.invalidArchive("ZIP data descriptor fields do not match the central directory.")
                }
                recordEnd += signedMatches ? 16 : 12
            }

            let remainingExpandedLimit = maxExpandedBytes - actualExpandedTotal
            let actualSize: Int64
            if method == 0 {
                let checksum = checksumOfStoredData(data, range: payloadStart..<payloadEnd)
                guard checksum == expectedCRC else {
                    throw UpdateCoreError.invalidArchive("Stored ZIP entry CRC does not match its contents.")
                }
                actualSize = compressed
            } else {
                actualSize = try inflateRawAndValidate(data, range: payloadStart..<payloadEnd,
                                                       expectedSize: uncompressed,
                                                       maximumOutput: remainingExpandedLimit,
                                                       expectedCRC: expectedCRC)
            }
            guard actualSize == uncompressed, actualExpandedTotal <= maxExpandedBytes - actualSize else {
                throw UpdateCoreError.invalidArchive("ZIP entries expand beyond their declared or supported size.")
            }
            actualExpandedTotal += actualSize
            localSpans.append(localOffset..<recordEnd)
            entries.append(UpdateZipEntry(path: path, isDirectory: directory, uncompressedSize: uncompressed))
            cursor += recordLength
        }
        guard cursor == directoryEnd, rootDirectory, entries.contains(where: { $0.path == "CPU-S2.app/Contents/Info.plist" && !$0.isDirectory }) else {
            throw UpdateCoreError.invalidArchive("ZIP must contain a complete CPU-S2.app bundle.")
        }

        // Local records must stay before the central directory and may not overlap one another.
        let sortedSpans = localSpans.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<sortedSpans.count where sortedSpans[index - 1].upperBound > sortedSpans[index].lowerBound {
            throw UpdateCoreError.invalidArchive("ZIP entries overlap in the local file data.")
        }
        return entries
    }

    private static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), path.precomposedStringWithCanonicalMapping == path else {
            throw UpdateCoreError.invalidArchive("ZIP path is absolute, empty, or not Unicode-normalized.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw UpdateCoreError.invalidArchive("ZIP path contains an empty, current, or parent directory component.")
        }
    }

    private static func validateExtraFields(_ data: Data, start: Int, length: Int) throws {
        guard start >= 0, length >= 0, start <= data.count, length <= data.count - start else {
            throw UpdateCoreError.invalidArchive("ZIP extra-field lengths are malformed.")
        }
        var cursor = start
        let end = start + length
        while cursor < end {
            guard end - cursor >= 4 else { throw UpdateCoreError.invalidArchive("ZIP extra field is truncated.") }
            let identifier = read16(data, cursor)
            let fieldLength = Int(read16(data, cursor + 2))
            guard fieldLength <= end - cursor - 4, identifier != 0x0001, identifier != 0x7075 else {
                throw UpdateCoreError.invalidArchive("ZIP64 or overriding Unicode path extra field is unsupported.")
            }
            cursor += 4 + fieldLength
        }
    }

    private static func checksumOfStoredData(_ data: Data, range: Range<Int>) -> UInt32 {
        var checksum = zlib.crc32(0, nil, 0)
        var offset = range.lowerBound
        data.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return }
            while offset < range.upperBound {
                let chunkSize = min(64 * 1024, range.upperBound - offset)
                let chunk = baseAddress.advanced(by: offset).assumingMemoryBound(to: Bytef.self)
                checksum = zlib.crc32(checksum, chunk, uInt(chunkSize))
                offset += chunkSize
            }
        }
        return UInt32(truncatingIfNeeded: checksum)
    }

    /// Inflate a raw DEFLATE member into a fixed-size output buffer. Actual expanded
    /// bytes and CRC are checked before the installer passes the archive to ditto.
    private static func inflateRawAndValidate(_ data: Data, range: Range<Int>, expectedSize: Int64,
                                              maximumOutput: Int64, expectedCRC: UInt32) throws -> Int64 {
        var stream = z_stream()
        let initialized = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else {
            throw UpdateCoreError.invalidArchive("Raw DEFLATE decoder could not be initialized.")
        }
        defer { inflateEnd(&stream) }

        let bufferSize = 64 * 1024
        var inputBuffer = [UInt8](repeating: 0, count: bufferSize)
        var outputBuffer = [UInt8](repeating: 0, count: bufferSize)
        var inputOffset = range.lowerBound
        var outputSize: Int64 = 0
        var checksum = zlib.crc32(0, nil, 0)
        var finished = false

        try inputBuffer.withUnsafeMutableBufferPointer { inputBytes in
            try outputBuffer.withUnsafeMutableBufferPointer { outputBytes in
                guard let inputBase = inputBytes.baseAddress, let outputBase = outputBytes.baseAddress else {
                    throw UpdateCoreError.invalidArchive("DEFLATE buffers could not be allocated.")
                }
                stream.next_in = inputBase
                stream.avail_in = 0

                while !finished {
                    if stream.avail_in == 0, inputOffset < range.upperBound {
                        let chunkSize = min(bufferSize, range.upperBound - inputOffset)
                        for index in 0..<chunkSize { inputBytes[index] = data[inputOffset + index] }
                        inputOffset += chunkSize
                        stream.next_in = inputBase
                        stream.avail_in = uInt(chunkSize)
                    }

                    stream.next_out = outputBase
                    stream.avail_out = uInt(bufferSize)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    let produced = bufferSize - Int(stream.avail_out)
                    if produced > 0 {
                        let producedSize = Int64(produced)
                        guard outputSize <= expectedSize - producedSize,
                              outputSize <= maximumOutput - producedSize else {
                            throw UpdateCoreError.invalidArchive("DEFLATE output exceeds its declared or supported size.")
                        }
                        checksum = zlib.crc32(checksum, outputBase, uInt(produced))
                        outputSize += producedSize
                    }

                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0, inputOffset == range.upperBound else {
                            throw UpdateCoreError.invalidArchive("DEFLATE member has trailing compressed bytes.")
                        }
                        finished = true
                    } else if status != Z_OK {
                        throw UpdateCoreError.invalidArchive("ZIP contains a malformed or truncated DEFLATE member.")
                    } else if produced == 0, stream.avail_in == 0, inputOffset == range.upperBound {
                        throw UpdateCoreError.invalidArchive("ZIP DEFLATE member ended before its stream terminator.")
                    }
                }
            }
        }

        guard outputSize == expectedSize, UInt32(truncatingIfNeeded: checksum) == expectedCRC else {
            throw UpdateCoreError.invalidArchive("DEFLATE output size or CRC does not match the ZIP directory.")
        }
        return outputSize
    }

    private static func endRecord(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let first = max(0, data.count - 22 - 65_535)
        for offset in stride(from: data.count - 22, through: first, by: -1) {
            guard read32(data, offset) == 0x06054b50 else { continue }
            let commentLength = Int(read16(data, offset + 20))
            if offset + 22 + commentLength == data.count { return offset }
        }
        return nil
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}

enum UpdateCoreError: LocalizedError {
    case invalidFeed(String)
    case invalidArchive(String)

    var errorDescription: String? {
        switch self {
        case let .invalidFeed(message), let .invalidArchive(message): return message
        }
    }
}
