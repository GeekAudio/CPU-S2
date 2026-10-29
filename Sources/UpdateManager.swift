import Foundation
import Darwin

/// Main-thread update lifecycle; networking uses public GitHub endpoints without credentials.
final class UpdateManager: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate {
    enum State {
        case idle, checking, downloading(Double), verifying, waiting, installing, failed(String)
        var message: String? {
            switch self {
            case .idle: return nil
            case .checking: return "正在检查更新…"
            case .downloading(let fraction): return "正在下载更新 · \(Int(fraction * 100))%"
            case .verifying: return "正在校验更新…"
            case .waiting: return "更新已就绪，将在当前操作结束后安装并重启"
            case .installing: return "正在安装更新，即将重启…"
            case .failed(let message): return message
            }
        }
        var fraction: Double? {
            if case .downloading(let value) = self { return value }
            return nil
        }
    }

    var onChange: ((State) -> Void)?
    var onMessage: ((String) -> Void)?
    var canInstall: (() -> Bool)?
    var beforeInstall: (() throws -> Void)?
    var onWillRestart: (() -> Void)?
    private(set) var state: State = .idle { didSet { onChange?(state) } }
    private let defaults: UserDefaults
    private let currentVersion: UpdateVersion
    private let appURL: URL
    private let configuration: URLSessionConfiguration
    private var session: URLSession!
    private var feedTask: URLSessionDataTask?
    private var downloadTask: URLSessionDownloadTask?
    private var latestTask: URLSessionDataTask?
    private var checksumTask: URLSessionDataTask?
    private var sizeTask: URLSessionDataTask?
    private var fallbackData = Data()
    private var fallbackVersion: UpdateVersion?
    private var fallbackSHA: String?
    private var fallbackResolved = false
    private var useFallback = false
    private var extractionProcess: Process?
    private var feedData = Data()
    private var feedResponseOK = false
    private var release: ReleaseUpdate?
    private var preparedApp: URL?
    private var workingDirectory: URL?
    private var periodicCheck: Timer?
    private var installWait: Timer?
    private var manual = false
    private var generation = UUID()
    static let automaticKey = "cpus2.automaticallyInstallUpdates"
    private static let checkedKey = "cpus2.lastSuccessfulUpdateCheck"
    private let maximumFeedBytes = 2 * 1024 * 1024

    var automaticEnabled: Bool { defaults.bool(forKey: Self.automaticKey) }
    var isInstalling: Bool { if case .installing = state { return true }; return false }
    var isBusy: Bool {
        switch state { case .checking, .downloading, .verifying, .waiting, .installing: return true; default: return false }
    }

    init(currentVersion: UpdateVersion, appURL: URL = Bundle.main.bundleURL,
         defaults: UserDefaults = .standard, configuration: URLSessionConfiguration = .ephemeral) {
        self.currentVersion = currentVersion
        self.appURL = appURL
        self.defaults = defaults
        self.configuration = configuration
        super.init()
        defaults.register(defaults: [Self.automaticKey: true])
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    func start() {
        scheduleChecks()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.check(manual: false) }
    }

    func setAutomatic(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.automaticKey)
        scheduleChecks()
        if enabled { check(manual: false) }
        else if !manual && !isInstalling { cancelPending() }
    }

    func shutdown() {
        generation = UUID()
        periodicCheck?.invalidate(); installWait?.invalidate()
        stopExtraction()
        cancelFallbackTasks()
        feedTask = nil; downloadTask = nil
        session.invalidateAndCancel()
        // The independent installer owns the prepared bundle once it has acknowledged READY.
        if !isInstalling { removeWorkingDirectory() }
    }

    private func scheduleChecks() {
        periodicCheck?.invalidate(); periodicCheck = nil
        guard automaticEnabled else { return }
        periodicCheck = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in self?.check(manual: false) }
    }

    func check(manual requested: Bool) {
        guard !isBusy else {
            if requested { onMessage?(state.message ?? "更新正在进行。") }
            return
        }
        if !requested {
            guard automaticEnabled else { return }
            if let previous = defaults.object(forKey: Self.checkedKey) as? Date,
               Date().timeIntervalSince(previous) >= 0, Date().timeIntervalSince(previous) < 60 * 60 { return }
        }
        manual = requested
        generation = UUID()
        removeWorkingDirectory()
        feedData.removeAll(keepingCapacity: false); feedResponseOK = false; useFallback = false
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/GeekAudio/CPU-S2/releases/latest")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CPU-S2/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        state = .checking
        feedTask = session.dataTask(with: request)
        feedTask?.resume()
    }

    private func cancelPending() {
        generation = UUID()
        feedTask?.cancel(); downloadTask?.cancel()
        cancelFallbackTasks()
        feedTask = nil; downloadTask = nil
        stopExtraction()
        installWait?.invalidate(); installWait = nil
        preparedApp = nil; release = nil
        removeWorkingDirectory()
        state = .idle
    }

    private func fail(_ message: String) {
        feedTask?.cancel(); downloadTask?.cancel()
        cancelFallbackTasks()
        feedTask = nil; downloadTask = nil
        stopExtraction()
        installWait?.invalidate(); installWait = nil
        preparedApp = nil; release = nil
        removeWorkingDirectory()
        state = .failed(message)
        if manual { onMessage?(message) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if dataTask === latestTask {
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let url = response.url, let version = UpdateFallback.version(fromReleaseURL: url) {
                fallbackResolved = true; fallbackVersion = version
            }
            completionHandler(.cancel)
            return
        }
        if dataTask === checksumTask {
            let valid = (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= 65_536
            completionHandler(valid ? .allow : .cancel)
            return
        }
        if dataTask === sizeTask {
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let version = fallbackVersion, let hash = fallbackSHA,
               response.expectedContentLength > 0, response.expectedContentLength <= UpdateFeed.maximumArchiveSize {
                sizeTask = nil
                completionHandler(.cancel)
                beginDownload(ReleaseUpdate(version: version, assetURL: UpdateFallback.assetURL(for: version),
                                            sha256: hash, size: response.expectedContentLength,
                                            releaseURL: URL(string: "https://github.com/GeekAudio/CPU-S2/releases/tag/\(version.tag)")!, releaseID: 0))
                return
            }
            completionHandler(.cancel)
            return
        }
        if dataTask === feedTask, let http = response as? HTTPURLResponse, [403, 429].contains(http.statusCode) { useFallback = true }
        guard dataTask === feedTask, let http = response as? HTTPURLResponse,
              http.statusCode == 200, response.expectedContentLength <= Int64(maximumFeedBytes) else {
            completionHandler(.cancel)
            return
        }
        feedResponseOK = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if dataTask === checksumTask {
            guard fallbackData.count + data.count <= 65_536 else { fail("更新校验清单过大，已停止更新。"); return }
            fallbackData.append(data)
            return
        }
        guard dataTask === feedTask else { return }
        guard feedData.count + data.count <= maximumFeedBytes else {
            fail("更新信息过大，请稍后重试。")
            return
        }
        feedData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { completionHandler(nil); return }
        if task === feedTask { completionHandler(url.host == "api.github.com" ? request : nil); return }
        if task === latestTask {
            completionHandler(UpdateFallback.version(fromReleaseURL: url) != nil ? request : nil)
            return
        }
        let hosts = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"]
        let assetTask = task === downloadTask || task === checksumTask || task === sizeTask
        completionHandler(assetTask && hosts.contains(url.host ?? "") ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task === feedTask {
            feedTask = nil
            if useFallback || error != nil { startFallback(); return }
            guard error == nil, feedResponseOK else { fail("暂时无法检查更新，可从 CPU-S2 菜单重试。"); return }
            do {
                let candidate = try UpdateFeed.parse(data: feedData, currentVersion: currentVersion)
                defaults.set(Date(), forKey: Self.checkedKey)
                feedData.removeAll(keepingCapacity: false)
                guard let candidate = candidate else {
                    state = .idle
                    if manual { onMessage?("当前 v\(currentVersion)，没有可安装的新版。") }
                    return
                }
                beginDownload(candidate)
            } catch { fail("更新信息无法验证：\(error.localizedDescription)") }
        } else if task === latestTask {
            latestTask = nil
            guard fallbackResolved, let version = fallbackVersion else { fail("暂时无法检查更新，可从 CPU-S2 菜单重试。"); return }
            guard version > currentVersion else { noUpdate(); return }
            fallbackData.removeAll(keepingCapacity: false)
            checksumTask = session.dataTask(with: publicRequest(UpdateFallback.checksumsURL(for: version)))
            checksumTask?.resume()
        } else if task === checksumTask {
            checksumTask = nil
            guard error == nil, let version = fallbackVersion else { fail("暂时无法读取更新校验清单。"); return }
            do {
                guard let hash = try UpdateFallback.checksum(from: fallbackData, version: version) else { noUpdate(); return }
                fallbackSHA = hash
                var request = publicRequest(UpdateFallback.assetURL(for: version))
                request.httpMethod = "HEAD"
                sizeTask = session.dataTask(with: request)
                sizeTask?.resume()
            } catch { fail("更新校验清单无法验证。") }
        } else if task === sizeTask {
            sizeTask = nil
            fail("无法确定更新文件大小，已保持当前版本。")
        } else if task === downloadTask, error != nil {
            downloadTask = nil
            fail("更新下载未完成，请稍后重试。")
        }
    }

    private func publicRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("CPU-S2/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func startFallback() {
        fallbackResolved = false; fallbackVersion = nil; fallbackSHA = nil
        var request = publicRequest(URL(string: "https://github.com/GeekAudio/CPU-S2/releases/latest")!)
        request.httpMethod = "HEAD"
        latestTask = session.dataTask(with: request)
        latestTask?.resume()
    }

    private func noUpdate() {
        defaults.set(Date(), forKey: Self.checkedKey)
        state = .idle
        if manual { onMessage?("当前 v\(currentVersion)，没有可安装的新版。") }
    }

    private func beginDownload(_ candidate: ReleaseUpdate) {
        do {
            defaults.set(Date(), forKey: Self.checkedKey)
            release = candidate
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cpus2-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            workingDirectory = folder
            state = .downloading(0)
            downloadTask = session.downloadTask(with: publicRequest(candidate.assetURL))
            downloadTask?.resume()
        } catch { fail("无法创建更新下载目录：\(error.localizedDescription)") }
    }

    private func cancelFallbackTasks() {
        latestTask?.cancel(); checksumTask?.cancel(); sizeTask?.cancel()
        latestTask = nil; checksumTask = nil; sizeTask = nil
        fallbackVersion = nil; fallbackSHA = nil; fallbackData.removeAll(keepingCapacity: false)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard downloadTask === self.downloadTask, let release = release else { return }
        guard totalBytesWritten <= release.size, totalBytesExpectedToWrite <= 100 * 1024 * 1024 else {
            fail("更新文件大小不符，已停止下载。")
            return
        }
        state = .downloading(min(1, max(0, Double(totalBytesWritten) / Double(release.size))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard downloadTask === self.downloadTask, let candidate = release, let folder = workingDirectory else { return }
        self.downloadTask = nil
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            fail("更新服务器未返回有效安装包。")
            return
        }
        let archive = folder.appendingPathComponent("update.zip")
        do { try FileManager.default.moveItem(at: location, to: archive) }
        catch { fail("无法保存更新安装包：\(error.localizedDescription)"); return }
        state = .verifying
        let transaction = generation
        DispatchQueue.global(qos: .utility).async {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
                guard (attributes[.size] as? NSNumber)?.int64Value == candidate.size,
                      try UpdateChecksum.matches(file: archive, expected: candidate.sha256) else {
                    throw UpdateManagerError("安装包的大小或 SHA-256 校验不符。")
                }
                _ = try UpdateZipArchive.validate(archive)
                let expanded = folder.appendingPathComponent("expanded", isDirectory: true)
                try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-x", "-k", "--norsrc", "--noextattr", "--noacl", archive.path, expanded.path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try DispatchQueue.main.sync {
                    guard transaction == self.generation else { throw UpdateManagerError("更新已取消。") }
                    try process.run()
                    self.extractionProcess = process
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 30
                while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                    throw UpdateManagerError("解压安装包超时。")
                }
                process.waitUntilExit()
                DispatchQueue.main.sync { if self.extractionProcess === process { self.extractionProcess = nil } }
                guard process.terminationStatus == 0 else { throw UpdateManagerError("安装包无法解压。") }
                let app = expanded.appendingPathComponent("CPU-S2.app", isDirectory: true)
                DispatchQueue.main.async {
                    guard transaction == self.generation else { try? FileManager.default.removeItem(at: folder); return }
                    self.preparedApp = app
                    self.installIfReady()
                }
            } catch {
                DispatchQueue.main.async {
                    guard transaction == self.generation else { try? FileManager.default.removeItem(at: folder); return }
                    self.fail("更新校验失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func installIfReady() {
        guard let app = preparedApp, let release = release, !isInstalling else { return }
        guard canInstall?() == true else {
            state = .waiting
            if installWait == nil {
                installWait = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.installIfReady() }
            }
            return
        }
        installWait?.invalidate(); installWait = nil
        do { try beforeInstall?() }
        catch { fail("更新前未能保存检测结果：\(error.localizedDescription)"); return }
        state = .installing
        DispatchQueue.global(qos: .utility).async {
            do {
                try UpdateInstaller.launchVerified(appURL: app, expectedVersion: release.version.description, currentAppURL: self.appURL)
                DispatchQueue.main.async { self.onWillRestart?() }
            } catch {
                DispatchQueue.main.async { self.fail("自动安装未完成：\(error.localizedDescription)") }
            }
        }
    }

    private func removeWorkingDirectory() {
        if let folder = workingDirectory { try? FileManager.default.removeItem(at: folder) }
        workingDirectory = nil
    }

    private func stopExtraction() {
        guard let process = extractionProcess else { return }
        extractionProcess = nil
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

private struct UpdateManagerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
