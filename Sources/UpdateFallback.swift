import Foundation

enum UpdateFallback {
    static let maximumChecksumsSize = 64 * 1024

    /// Resolve only the canonical tag URL emitted by this repository's Releases page.
    static func version(fromReleaseURL url: URL) -> UpdateVersion? {
        let prefix = "https://github.com/GeekAudio/CPU-S2/releases/tag/"
        let absolute = url.absoluteString
        guard absolute.hasPrefix(prefix),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return nil }

        let tag = String(absolute.dropFirst(prefix.count))
        guard let version = UpdateVersion.parse(tag), absolute == prefix + version.tag,
              components.percentEncodedPath == "/GeekAudio/CPU-S2/releases/tag/\(version.tag)" else { return nil }
        return version
    }

    /// Read only the exact application ZIP entry from a bounded sha256sum-style manifest.
    /// Other well-formed assets (including GitHub source ZIPs) are ignored.
    static func checksum(from data: Data, version: UpdateVersion) throws -> String? {
        guard data.count <= maximumChecksumsSize else {
            throw UpdateFallbackError.invalidManifest("SHA256SUMS.txt exceeds 64 KiB.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UpdateFallbackError.invalidManifest("SHA256SUMS.txt is not valid UTF-8.")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r"), normalized.unicodeScalars.allSatisfy({ $0.value <= 0x7f }) else {
            throw UpdateFallbackError.invalidManifest("SHA256SUMS.txt must use ASCII with LF or CRLF line endings.")
        }

        let expectedName = "CPU-S2-\(version.tag).zip"
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var found: String?
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                // A final newline is conventional; blank lines inside the manifest are not.
                guard index == lines.count - 1 else {
                    throw UpdateFallbackError.invalidManifest("SHA256SUMS.txt contains an empty line.")
                }
                continue
            }

            let bytes = Array(line.utf8)
            guard bytes.count >= 67,
                  bytes[64] == 0x20, bytes[65] == 0x20,
                  bytes[0..<64].allSatisfy(isHex),
                  let name = String(bytes: bytes[66...], encoding: .ascii),
                  !name.isEmpty,
                  name.first != " ", name.last != " ",
                  name.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }),
                  !name.contains("/"), !name.contains("\\") else {
                throw UpdateFallbackError.invalidManifest("SHA256SUMS.txt contains a malformed entry.")
            }

            guard name == expectedName else { continue }
            guard found == nil else {
                throw UpdateFallbackError.invalidManifest("SHA256SUMS.txt contains duplicate app ZIP entries.")
            }
            found = String(bytes: bytes[0..<64], encoding: .ascii)?.lowercased()
        }
        return found
    }

    static func assetURL(for version: UpdateVersion) -> URL {
        URL(string: "https://github.com/GeekAudio/CPU-S2/releases/download/\(version.tag)/CPU-S2-\(version.tag).zip")!
    }

    static func checksumsURL(for version: UpdateVersion) -> URL {
        URL(string: "https://github.com/GeekAudio/CPU-S2/releases/download/\(version.tag)/SHA256SUMS.txt")!
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66) || (byte >= 0x41 && byte <= 0x46)
    }
}

enum UpdateFallbackError: LocalizedError {
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case let .invalidManifest(message): return message
        }
    }
}
