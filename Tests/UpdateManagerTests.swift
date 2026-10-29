import Foundation
import CryptoKit
import zlib

@main
enum UpdateManagerTests {
    static var checks = 0
    static var failures: [String] = []

    static func main() {
        testAutomaticUpdatesCanBeDisabled()
        testCurrentReleaseDoesNotDownload()
        testHTTPErrorIsReported()
        testOversizedFeedIsRejected()
        testTurningOffAutomaticUpdatesCancelsPendingCheck()
        testRateLimitedAPIUsesVerifiedFallbackAndWaits()
        testFallbackWithoutMatchingChecksumReturnsIdle()
        testTurningOffAutomaticUpdatesCancelsEveryFallbackStage()
        testShutdownCancelsFallbackDownload()
        testInvalidArchiveDigestNeverReachesInstallerGate()
        testVerifiedArchiveWaitsAndAutomaticOffCancelsInstallation()

        if failures.isEmpty {
            print("PASS: \(checks) update-manager lifecycle checks; URLProtocol only, no public network or installation")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            fputs("\(failures.count) failure(s) across \(checks) update-manager checks\n", stderr)
            exit(1)
        }
    }

    private static func testAutomaticUpdatesCanBeDisabled() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.defaults.set(false, forKey: UpdateManager.automaticKey)
        fixture.manager.check(manual: false)
        expect(!fixture.manager.isBusy, "disabled automatic check remains idle")
        expect(StubURLProtocol.requestCount == 0, "disabled automatic check sends no request")
    }

    private static func testCurrentReleaseDoesNotDownload() {
        let fixture = Fixture()
        defer { fixture.close() }
        StubURLProtocol.setHandler { _ in .json(feed(tag: "v2.4.4")) }
        fixture.manager.check(manual: true)
        wait("same-version release check finishes") { !fixture.manager.isBusy && StubURLProtocol.requestCount == 1 }
        expect(isIdle(fixture.manager.state), "same-version release returns to idle")
        expect(StubURLProtocol.requestCount == 1, "same-version release does not request a ZIP")
        expect(fixture.messages.contains("当前 v2.4.4，没有可安装的新版。"),
               "manual check explains that no update is available")
    }

    private static func testHTTPErrorIsReported() {
        let fixture = Fixture()
        defer { fixture.close() }
        StubURLProtocol.setHandler { _ in .response(status: 503, body: Data("unavailable".utf8)) }
        fixture.manager.check(manual: true)
        wait("HTTP failure finishes") { isFailure(fixture.manager.state) }
        expect(isFailure(fixture.manager.state), "non-200 feed response fails")
        expect(zipRequestCount == 0, "HTTP failure does not request an app ZIP")
    }

    private static func testOversizedFeedIsRejected() {
        let fixture = Fixture()
        defer { fixture.close() }
        StubURLProtocol.setHandler { _ in
            .response(status: 200, body: Data("{}".utf8), headers: ["Content-Length": "2097153"])
        }
        fixture.manager.check(manual: true)
        wait("oversized feed is rejected") { isFailure(fixture.manager.state) }
        expect(isFailure(fixture.manager.state), "declared feed over 2 MiB is rejected")
        expect(zipRequestCount == 0, "oversized feed does not request an app ZIP")
    }

    private static func testTurningOffAutomaticUpdatesCancelsPendingCheck() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: UpdateManager.automaticKey)
        StubURLProtocol.setHandler { _ in .json(feed(tag: "v2.5.0"), delay: 0.35) }
        fixture.manager.check(manual: false)
        wait("automatic feed request begins") { StubURLProtocol.requestCount == 1 }
        fixture.manager.setAutomatic(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        expect(!fixture.manager.automaticEnabled, "automatic-update preference is off")
        expect(isIdle(fixture.manager.state), "canceled automatic check returns to idle")
        expect(StubURLProtocol.requestCount == 1, "canceled feed cannot start an asset download")
    }

    private static func testRateLimitedAPIUsesVerifiedFallbackAndWaits() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: UpdateManager.automaticKey)
        let archive = minimalValidUpdateZip()
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        fixture.manager.canInstall = { fixture.installGateCalls += 1; return false }
        fixture.manager.beforeInstall = { fixture.beforeInstallCalls += 1 }
        fixture.manager.onWillRestart = { fixture.restartCalls += 1 }
        StubURLProtocol.setHandler(fallbackHandler(archive: archive, digest: digest))

        fixture.manager.check(manual: false)
        wait("rate-limited API fallback verifies and prepares the release") { isWaiting(fixture.manager.state) }
        let requests = StubURLProtocol.requests
        expect(requests.count == 5, "rate-limited fallback performs API, release HEAD, manifest, size HEAD, and ZIP requests")
        if requests.count == 5 {
            expect((requests.map { ($0.httpMethod ?? "GET").uppercased() }) == ["GET", "HEAD", "GET", "HEAD", "GET"],
                   "fallback uses HEAD for the release tag and ZIP size")
            expect(requests[1].url?.absoluteString == "https://github.com/GeekAudio/CPU-S2/releases/latest",
                   "fallback resolves the public latest release endpoint")
            expect(requests[2].url?.path == "/GeekAudio/CPU-S2/releases/download/v2.5.1/SHA256SUMS.txt",
                   "fallback reads the release checksum manifest")
        }
        expect(fixture.installGateCalls > 0, "verified fallback candidate checks installation readiness")
        expect(fixture.beforeInstallCalls == 0 && fixture.restartCalls == 0,
               "fallback update waits without exporting or restarting when installation is unavailable")
    }

    private static func testFallbackWithoutMatchingChecksumReturnsIdle() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: UpdateManager.automaticKey)
        StubURLProtocol.setHandler { request in
            if request.url?.host == "api.github.com" {
                return .response(status: 403, body: Data())
            }
            if request.url?.path == "/GeekAudio/CPU-S2/releases/latest" {
                return .response(status: 200, body: Data(), responseURL: fallbackTagURL)
            }
            if request.url?.path.hasSuffix("/SHA256SUMS.txt") == true {
                let manifest = String(repeating: "a", count: 64) + "  CPU-S2-v2.5.1-source.zip\n"
                return .response(status: 200, body: Data(manifest.utf8))
            }
            return .response(status: 404, body: Data())
        }

        fixture.manager.check(manual: false)
        wait("fallback with no app checksum returns idle") { isIdle(fixture.manager.state) }
        expect(StubURLProtocol.requestCount == 3, "source-only checksum manifest does not request size or ZIP")
        expect(fixture.installGateCalls == 0 && fixture.beforeInstallCalls == 0 && fixture.restartCalls == 0,
               "no matching app ZIP checksum cannot reach installation")
    }

    private static func testTurningOffAutomaticUpdatesCancelsEveryFallbackStage() {
        let stages: [(name: String, method: String, count: Int)] = [
            ("release latest HEAD", "HEAD", 2), ("checksum manifest", "GET", 3),
            ("ZIP size HEAD", "HEAD", 4), ("ZIP download", "GET", 5)
        ]
        let archive = minimalValidUpdateZip()
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        for stage in stages {
            let fixture = Fixture()
            fixture.defaults.set(true, forKey: UpdateManager.automaticKey)
            fixture.manager.canInstall = { fixture.installGateCalls += 1; return false }
            fixture.manager.beforeInstall = { fixture.beforeInstallCalls += 1 }
            fixture.manager.onWillRestart = { fixture.restartCalls += 1 }
            StubURLProtocol.setHandler(fallbackHandler(archive: archive, digest: digest,
                                                       delayedPath: path(for: stage.name), delayedMethod: stage.method))
            fixture.manager.check(manual: false)
            wait("fallback reaches \(stage.name)") { StubURLProtocol.requestCount >= stage.count }
            fixture.manager.setAutomatic(false)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            expect(isIdle(fixture.manager.state), "turning off automatic updates cancels \(stage.name)")
            expect(StubURLProtocol.requestCount == stage.count, "canceled \(stage.name) cannot start a later fallback request")
            expect(fixture.installGateCalls == 0 && fixture.beforeInstallCalls == 0 && fixture.restartCalls == 0,
                   "canceled \(stage.name) cannot install or restart")
            fixture.close()
        }
    }

    private static func testShutdownCancelsFallbackDownload() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: UpdateManager.automaticKey)
        let archive = minimalValidUpdateZip()
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        fixture.manager.canInstall = { fixture.installGateCalls += 1; return false }
        fixture.manager.beforeInstall = { fixture.beforeInstallCalls += 1 }
        fixture.manager.onWillRestart = { fixture.restartCalls += 1 }
        StubURLProtocol.setHandler(fallbackHandler(archive: archive, digest: digest, delayedPath: zipPath, delayedMethod: "GET"))
        fixture.manager.check(manual: false)
        wait("fallback starts ZIP download") { StubURLProtocol.requestCount >= 5 }
        fixture.manager.shutdown()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        expect(StubURLProtocol.requestCount == 5, "shutdown cancels the fallback ZIP download")
        expect(!fixture.manager.isInstalling, "shutdown does not start installation")
        expect(fixture.installGateCalls == 0 && fixture.beforeInstallCalls == 0 && fixture.restartCalls == 0,
               "shutdown prevents installation callbacks")
    }

    private static let fallbackTagURL = URL(string: "https://github.com/GeekAudio/CPU-S2/releases/tag/v2.5.1")!
    private static let checksumsPath = "/GeekAudio/CPU-S2/releases/download/v2.5.1/SHA256SUMS.txt"
    private static let zipPath = "/GeekAudio/CPU-S2/releases/download/v2.5.1/CPU-S2-v2.5.1.zip"

    private static func path(for stage: String) -> String {
        switch stage {
        case "release latest HEAD": return "/GeekAudio/CPU-S2/releases/latest"
        case "checksum manifest": return checksumsPath
        case "ZIP size HEAD", "ZIP download": return zipPath
        default: preconditionFailure("Unknown fallback stage")
        }
    }

    private static func fallbackHandler(archive: Data, digest: String, delayedPath: String? = nil,
                                        delayedMethod: String? = nil) -> (URLRequest) -> StubURLProtocol.StubResponse {
        { request in
            let path = request.url?.path ?? ""
            let method = (request.httpMethod ?? "GET").uppercased()
            let delay = path == delayedPath && method == delayedMethod ? 0.25 : 0
            if request.url?.host == "api.github.com" { return .response(status: 403, body: Data()) }
            if path == "/GeekAudio/CPU-S2/releases/latest" {
                return .response(status: 200, body: Data(), delay: delay, responseURL: fallbackTagURL)
            }
            if path == checksumsPath {
                let manifest = "\(digest)  CPU-S2-v2.5.1.zip\n"
                return .response(status: 200, body: Data(manifest.utf8), delay: delay)
            }
            if path == zipPath, request.httpMethod?.uppercased() == "HEAD" {
                return .response(status: 200, body: Data(), headers: ["Content-Length": String(archive.count)], delay: delay)
            }
            if path == zipPath { return .response(status: 200, body: archive, delay: delay) }
            return .response(status: 404, body: Data())
        }
    }

    private static func testInvalidArchiveDigestNeverReachesInstallerGate() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.manager.canInstall = { fixture.installGateCalls += 1; return true }
        let archive = Data(repeating: 0x41, count: 64)
        StubURLProtocol.setHandler { request in
            if request.url?.host == "api.github.com" { return .json(feed(tag: "v2.5.0", archiveSize: archive.count)) }
            return .response(status: 200, body: archive)
        }
        fixture.manager.check(manual: true)
        wait("bad archive digest is rejected") { isFailure(fixture.manager.state) }
        expect(isFailure(fixture.manager.state), "download with a digest mismatch fails")
        expect(zipRequestCount == 1, "valid candidate starts exactly one ZIP download")
        expect(fixture.installGateCalls == 0, "unverified archive never reaches install readiness")
    }

    private static func testVerifiedArchiveWaitsAndAutomaticOffCancelsInstallation() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: UpdateManager.automaticKey)

        let archive = minimalValidUpdateZip()
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        fixture.manager.canInstall = { fixture.installGateCalls += 1; return false }
        fixture.manager.beforeInstall = { fixture.beforeInstallCalls += 1 }
        fixture.manager.onWillRestart = { fixture.restartCalls += 1 }
        StubURLProtocol.setHandler { request in
            if request.url?.host == "api.github.com" {
                return .json(feed(tag: "v2.5.0", archiveSize: archive.count, archiveDigest: digest))
            }
            return .response(status: 200, body: archive)
        }

        fixture.manager.check(manual: false)
        wait("verified ZIP waits while installation is unavailable") { isWaiting(fixture.manager.state) }
        expect(zipRequestCount == 1, "verified candidate downloads one asset")
        expect(fixture.installGateCalls > 0, "verified candidate checks installation readiness")
        expect(fixture.beforeInstallCalls == 0, "waiting update does not export a report before install")
        expect(fixture.restartCalls == 0, "waiting update does not restart the app")

        let gateCallsBeforeCancellation = fixture.installGateCalls
        fixture.manager.setAutomatic(false)
        expect(isIdle(fixture.manager.state), "turning off automatic updates cancels a prepared update")
        fixture.manager.installIfReady()
        expect(fixture.installGateCalls == gateCallsBeforeCancellation, "canceled update cannot re-enter install readiness")
        expect(fixture.beforeInstallCalls == 0 && fixture.restartCalls == 0,
               "canceled update does not export a report or restart")
    }

    private static func feed(tag: String, archiveSize: Int = 64,
                             archiveDigest: String = String(repeating: "0", count: 64)) -> Data {
        let name = "CPU-S2-\(tag).zip"
        let asset: [String: Any] = [
            "name": name,
            "size": archiveSize,
            "digest": "sha256:" + archiveDigest,
            "browser_download_url": "https://github.com/GeekAudio/CPU-S2/releases/download/\(tag)/\(name)"
        ]
        let object: [String: Any] = [
            "id": 987,
            "tag_name": tag,
            "draft": false,
            "prerelease": false,
            "html_url": "https://github.com/GeekAudio/CPU-S2/releases/tag/\(tag)",
            "assets": [asset]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func minimalValidUpdateZip() -> Data {
        struct Entry {
            let path: String
            let contents: Data
            let directory: Bool
            let mode: UInt16
        }
        let entries = [
            Entry(path: "CPU-S2.app/", contents: Data(), directory: true, mode: 0x41ed),
            Entry(path: "CPU-S2.app/Contents/Info.plist", contents: Data("fixture".utf8), directory: false, mode: 0x81a4)
        ]
        var bytes: [UInt8] = []
        var central: [UInt8] = []
        for entry in entries {
            let path = Array(entry.path.utf8)
            let payload = Array(entry.contents)
            let checksum = entry.contents.withUnsafeBytes { buffer in
                UInt32(truncatingIfNeeded: zlib.crc32(0, buffer.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(buffer.count)))
            }
            let offset = bytes.count
            append32(0x04034b50, to: &bytes)
            append16(20, to: &bytes); append16(0x0800, to: &bytes)
            append16(0, to: &bytes); append16(0, to: &bytes); append16(0, to: &bytes)
            append32(checksum, to: &bytes)
            append32(UInt32(payload.count), to: &bytes); append32(UInt32(payload.count), to: &bytes)
            append16(UInt16(path.count), to: &bytes); append16(0, to: &bytes)
            bytes += path; bytes += payload

            append32(0x02014b50, to: &central)
            append16(0x0314, to: &central); append16(20, to: &central)
            append16(0x0800, to: &central); append16(0, to: &central)
            append16(0, to: &central); append16(0, to: &central); append32(checksum, to: &central)
            append32(UInt32(payload.count), to: &central); append32(UInt32(payload.count), to: &central)
            append16(UInt16(path.count), to: &central); append16(0, to: &central)
            append16(0, to: &central); append16(0, to: &central); append16(0, to: &central)
            append32((UInt32(entry.mode) << 16) | (entry.directory ? 0x10 : 0), to: &central)
            append32(UInt32(offset), to: &central)
            central += path
        }
        let centralOffset = bytes.count
        bytes += central
        append32(0x06054b50, to: &bytes)
        append16(0, to: &bytes); append16(0, to: &bytes)
        append16(UInt16(entries.count), to: &bytes); append16(UInt16(entries.count), to: &bytes)
        append32(UInt32(central.count), to: &bytes); append32(UInt32(centralOffset), to: &bytes)
        append16(0, to: &bytes)
        return Data(bytes)
    }

    private static func append16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xff)); bytes.append(UInt8((value >> 8) & 0xff))
    }

    private static func append32(_ value: UInt32, to bytes: inout [UInt8]) {
        append16(UInt16(value & 0xffff), to: &bytes)
        append16(UInt16((value >> 16) & 0xffff), to: &bytes)
    }

    private static func wait(_ description: String, timeout: TimeInterval = 3, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        expect(condition(), description)
    }

    private static var zipRequestCount: Int {
        StubURLProtocol.requests.filter { $0.url?.path.hasSuffix(".zip") == true }.count
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }

    private static func isIdle(_ state: UpdateManager.State) -> Bool {
        if case .idle = state { return true }
        return false
    }

    private static func isFailure(_ state: UpdateManager.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private static func isWaiting(_ state: UpdateManager.State) -> Bool {
        if case .waiting = state { return true }
        return false
    }

    private final class Fixture {
        private let suiteName = "CPU-S2-UpdateManagerTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let manager: UpdateManager
        var messages: [String] = []
        var installGateCalls = 0
        var beforeInstallCalls = 0
        var restartCalls = 0

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            manager = UpdateManager(currentVersion: UpdateVersion.parse("v2.4.4")!,
                                    appURL: URL(fileURLWithPath: "/tmp/CPU-S2-UpdateManagerTests.app"),
                                    defaults: defaults, configuration: configuration)
            manager.onMessage = { [weak self] message in self?.messages.append(message) }
        }

        func close() {
            manager.shutdown()
            defaults.removePersistentDomain(forName: suiteName)
            StubURLProtocol.reset()
        }
    }
}

private final class StubURLProtocol: URLProtocol {
    struct StubResponse {
        let status: Int
        let headers: [String: String]
        let body: Data
        let delay: TimeInterval
        let responseURL: URL?

        static func json(_ data: Data, delay: TimeInterval = 0) -> StubResponse {
            response(status: 200, body: data, headers: ["Content-Type": "application/json"], delay: delay)
        }

        static func response(status: Int, body: Data, headers: [String: String] = [:], delay: TimeInterval = 0) -> StubResponse {
            response(status: status, body: body, headers: headers, delay: delay, responseURL: nil)
        }

        static func response(status: Int, body: Data, headers: [String: String] = [:], delay: TimeInterval = 0,
                             responseURL: URL?) -> StubResponse {
            var values = headers
            if values["Content-Length"] == nil { values["Content-Length"] = String(body.count) }
            return StubResponse(status: status, headers: values, body: body, delay: delay, responseURL: responseURL)
        }
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> StubResponse)?
    private static var requestTotal = 0
    private static var recordedRequests: [URLRequest] = []
    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requestTotal
    }
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }
    private let stateLock = NSLock()
    private var stopped = false

    static func setHandler(_ value: @escaping (URLRequest) -> StubResponse) {
        lock.lock(); handler = value; requestTotal = 0; recordedRequests = []; lock.unlock()
    }

    static func reset() {
        lock.lock(); handler = nil; requestTotal = 0; recordedRequests = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let response = Self.handler?(request)
        if response != nil {
            Self.requestTotal += 1
            Self.recordedRequests.append(request)
        }
        Self.lock.unlock()
        guard let response = response else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let deliver = { [weak self] in
            guard let self = self, !self.isStopped else { return }
            guard let url = response.responseURL ?? self.request.url,
                  let http = HTTPURLResponse(url: url, statusCode: response.status,
                                             httpVersion: "HTTP/1.1", headerFields: response.headers) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if !response.body.isEmpty { self.client?.urlProtocol(self, didLoad: response.body) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if response.delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + response.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        stateLock.lock(); stopped = true; stateLock.unlock()
    }

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopped
    }
}
