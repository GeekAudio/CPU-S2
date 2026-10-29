import Foundation
import Darwin

/// Same-volume application replacement. Every rollback copy is kept in a hidden sibling directory.
enum UpdateInstallerCore {
    struct Request {
        let candidate: URL
        let target: URL
        let expectedVersion: String
        let parentPID: Int32
    }

    struct LaunchAcknowledgement {
        let pid: Int32
        let token: String
        let version: String
        let bundlePath: String
    }

    enum InstallError: LocalizedError {
        case invalid(String)
        case parentMismatch
        case parentTimeout
        case relaunch(String)
        case commandTimeout(String)
        case rollback(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return reason
            case .parentMismatch: return "自动更新器不是由 CPU-S2 启动的。"
            case .parentTimeout: return "等待 CPU-S2 退出超时，当前版本没有更改。"
            case .relaunch(let reason): return "新版本未能启动：\(reason)"
            case .commandTimeout(let command): return "更新操作超时：\(command)"
            case .rollback(let reason): return "安装失败且恢复旧版本时遇到问题：\(reason)"
            }
        }
    }

    static func validate(_ request: Request) throws {
        let candidate = try applicationDirectory(request.candidate, purpose: "更新包")
        let target = try applicationDirectory(request.target, purpose: "当前安装")
        guard candidate.lastPathComponent == "CPU-S2.app", target.lastPathComponent == "CPU-S2.app" else {
            throw InstallError.invalid("只接受名为 CPU-S2.app 的更新包和安装位置。")
        }
        guard candidate != target else { throw InstallError.invalid("更新包不能指向正在使用的应用。") }
        try validateVersion(request.expectedVersion)
        try validateBundle(at: candidate, expectedVersion: request.expectedVersion)
        try validateCurrentBundle(at: target)
        try ensureWritableVolume(containing: target)
        guard let installedVersion = bundleVersion(at: target),
              compareVersions(request.expectedVersion, installedVersion) == .orderedDescending else {
            throw InstallError.invalid("当前应用已经是此版本或更新版本。")
        }
    }

    /// The helper calls this only after the parent process is known to be exiting.
    /// Tests can skip waiting and relaunch while operating entirely inside a temporary directory.
    static func perform(_ request: Request, waitForParent: Bool = true, relaunch: Bool = true,
                        parentWasValidated: Bool = false,
                        acknowledgementTimeout: TimeInterval = 20,
                        afterInstall: (() throws -> Void)? = nil) throws {
        if waitForParent && !parentWasValidated { try validateParent(request) }

        // The helper has already completed this check before READY. Revalidate after the
        // parent exits inside the recovery scope below, so a late failure restarts the old app.
        if !waitForParent || !parentWasValidated { try validate(request) }
        if waitForParent { try waitUntilParentExits(request.parentPID, timeout: 90) }
        let parentHasExited = waitForParent

        let parent = request.target.deletingLastPathComponent()
        let id = UUID().uuidString.lowercased()
        let stageRoot = parent.appendingPathComponent(".cpus2-update-\(id).stage", isDirectory: true)
        let backupRoot = parent.appendingPathComponent(".cpus2-update-\(id).backup", isDirectory: true)
        let failedRoot = parent.appendingPathComponent(".cpus2-update-\(id).failed", isDirectory: true)
        let stagedApp = stageRoot.appendingPathComponent("CPU-S2.app", isDirectory: true)
        let backupApp = backupRoot.appendingPathComponent("CPU-S2.app", isDirectory: true)
        let failedApp = failedRoot.appendingPathComponent("CPU-S2.app", isDirectory: true)

        var stageCreated = false
        var backupCreated = false
        var oldMovedToBackup = false
        do {
            // Download caches can change while the app exits; repeat all validation before staging.
            try validate(request)
            try createPrivateDirectory(stageRoot)
            stageCreated = true
            _ = try runCommand("/usr/bin/ditto", ["--noextattr", request.candidate.path, stagedApp.path], timeout: 120)
            try validateBundle(at: stagedApp, expectedVersion: request.expectedVersion)

            try createPrivateDirectory(backupRoot)
            backupCreated = true
            try FileManager.default.moveItem(at: request.target, to: backupApp)
            oldMovedToBackup = true

            try FileManager.default.moveItem(at: stagedApp, to: request.target)
            try validateBundle(at: request.target, expectedVersion: request.expectedVersion)
            try afterInstall?()
            if relaunch {
                try launch(request.target,
                           acknowledgementURL: stageRoot.appendingPathComponent("ack.json"),
                           token: id, expectedVersion: request.expectedVersion,
                           acknowledgementTimeout: acknowledgementTimeout)
            }
        } catch {
            let installError = error
            var recoveryFailure: Error?
            do {
                // A move may report failure after changing the directory entries; inspect both paths.
                let backupExists = fileExists(backupApp)
                if backupExists || oldMovedToBackup {
                    if fileExists(request.target) {
                        do {
                            try createPrivateDirectory(failedRoot)
                            try FileManager.default.moveItem(at: request.target, to: failedApp)
                        } catch {
                            // The private stage directory is another safe place to preserve a rejected app.
                            let preserved = stageRoot.appendingPathComponent("CPU-S2.failed.app", isDirectory: true)
                            guard stageCreated, !fileExists(preserved) else { throw error }
                            try FileManager.default.moveItem(at: request.target, to: preserved)
                        }
                    }
                    if backupExists {
                        try FileManager.default.moveItem(at: backupApp, to: request.target)
                    }
                    try validateCurrentBundle(at: request.target)
                }
            } catch {
                recoveryFailure = error
            }

            // Any error after the old app has exited must make a best effort to reopen it.
            if parentHasExited && relaunch && fileExists(request.target) {
                do {
                    try validateCurrentBundle(at: request.target)
                    try launch(request.target)
                } catch {
                    if recoveryFailure == nil { recoveryFailure = error }
                }
            }

            if stageCreated { try? removeOwnedDirectory(stageRoot) }
            if backupCreated && !fileExists(backupApp) { try? removeOwnedDirectory(backupRoot) }
            if let recoveryFailure {
                throw InstallError.rollback("\(recoveryFailure.localizedDescription)；原始错误：\(installError.localizedDescription)")
            }
            throw installError
        }

        // Keep the hidden backup so a failed first launch can be recovered manually.
        if stageCreated { try? removeOwnedDirectory(stageRoot) }
    }

    /// Verify the live caller before READY is sent to the app. Once the app exits,
    /// macOS can reparent this helper, so this identity check must happen first.
    static func validateParent(_ request: Request) throws {
        guard request.parentPID > 1, request.parentPID == getppid(),
              parentApplicationURL(pid: request.parentPID)?.path == canonical(request.target).path else {
            throw InstallError.parentMismatch
        }
    }

    /// Called by the newly launched app after its normal launch configuration is ready.
    /// Invalid or ordinary launches are ignored; writes are restricted to this install's
    /// private staging sibling directory and are exclusive, no-follow file creations.
    @discardableResult
    static func acknowledgeLaunch(arguments: [String] = CommandLine.arguments,
                                  currentAppURL: URL = Bundle.main.bundleURL) -> Bool {
        guard let (ackURL, token) = launchAcknowledgementArguments(arguments) else { return false }
        do {
            let appURL = try applicationDirectory(currentAppURL, purpose: "当前安装")
            try validateCurrentBundle(at: appURL)
            guard parentApplicationURL(pid: getpid())?.path == canonical(appURL).path,
                  let values = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  values["CFBundleIdentifier"] as? String == "com.cpus2.CPU-S2",
                  let version = values["CFBundleShortVersionString"] as? String else { return false }

            try validateAcknowledgementDirectory(ackURL, targetURL: appURL, token: token)
            let data = try JSONSerialization.data(withJSONObject: [
                "pid": Int(getpid()),
                "token": token,
                "version": version,
                "bundlePath": canonical(appURL).path
            ], options: [.sortedKeys])
            guard data.count <= 4096 else { return false }
            try writeAcknowledgement(data, to: ackURL)
            return true
        } catch {
            return false
        }
    }

    /// Parse and validate an acknowledgement file without trusting its PID yet.
    /// The helper separately verifies that PID's live executable path.
    static func readLaunchAcknowledgement(at ackURL: URL, targetURL: URL,
                                          expectedVersion: String, token: String) throws -> LaunchAcknowledgement {
        try validateAcknowledgementDirectory(ackURL, targetURL: targetURL, token: token)
        let descriptor = open(ackURL.path, O_RDONLY | O_NOFOLLOW, 0)
        guard descriptor >= 0 else { throw InstallError.invalid("启动确认文件尚未写入。") }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o600,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096 else {
            throw InstallError.invalid("启动确认文件权限或大小无效。")
        }

        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw InstallError.invalid("无法读取启动确认文件。")
            }
            if count == 0 { break }
            offset += count
        }
        guard offset == bytes.count,
              let json = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let pidNumber = json["pid"] as? NSNumber,
              let version = json["version"] as? String,
              let receivedToken = json["token"] as? String,
              let bundlePath = json["bundlePath"] as? String,
              let pidValue = Int32(exactly: pidNumber.intValue), pidValue > 1 else {
            throw InstallError.invalid("启动确认内容不完整。")
        }
        let expectedBundlePath = canonical(targetURL).path
        guard version == expectedVersion, receivedToken.lowercased() == token.lowercased(),
              canonical(URL(fileURLWithPath: bundlePath, isDirectory: true)).path == expectedBundlePath else {
            throw InstallError.invalid("启动确认与本次更新不匹配。")
        }
        return LaunchAcknowledgement(pid: pidValue, token: receivedToken,
                                     version: version, bundlePath: bundlePath)
    }

    static func validateAcknowledgedProcess(_ acknowledgement: LaunchAcknowledgement, targetURL: URL) throws {
        let executableBundle = parentApplicationURL(pid: acknowledgement.pid)
        let expectedBundle = canonical(targetURL)
        let alive = kill(acknowledgement.pid, 0)
        guard acknowledgement.pid != getpid(), alive == 0,
              executableBundle?.path == expectedBundle.path else {
            throw InstallError.relaunch("启动确认进程与新应用路径不符。")
        }
    }

    /// Keep a small persistent diagnostic for helper failures, even when the app has exited.
    static func recordFailure(_ message: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CPU-S2", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return }

        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == getuid() else { return }

        let logURL = directory.appendingPathComponent("Updater.log")
        let descriptor = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_uid == getuid() else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeMessage = message.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let data = Data("[\(timestamp)] \(safeMessage)\n".utf8)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                written += count
            }
        }
    }

    static func applicationDirectory(_ url: URL, purpose: String) throws -> URL {
        let path = url.standardizedFileURL.path
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            throw InstallError.invalid("\(purpose)必须是真实的应用文件夹。")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func validateVersion(_ value: String) throws {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              fields.allSatisfy({ Int($0) != nil }) else {
            throw InstallError.invalid("更新版本号格式无效。")
        }
    }

    static func validateBundle(at url: URL, expectedVersion: String) throws {
        _ = try applicationDirectory(url, purpose: "更新包")
        try validateVersion(expectedVersion)
        try validateBundleLayout(at: url)
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let values = NSDictionary(contentsOf: plist) as? [String: Any],
              values["CFBundleIdentifier"] as? String == "com.cpus2.CPU-S2",
              values["CFBundleExecutable"] as? String == "CPU-S2",
              values["CFBundleShortVersionString"] as? String == expectedVersion,
              values["CFBundlePackageType"] as? String == "APPL" else {
            throw InstallError.invalid("更新包不是版本 \(expectedVersion) 的 CPU-S2 应用。")
        }
        let executable = url.appendingPathComponent("Contents/MacOS/CPU-S2")
        var fileInfo = stat()
        guard lstat(executable.path, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              (fileInfo.st_mode & S_IFMT) != S_IFLNK,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InstallError.invalid("更新包缺少可执行的 CPU-S2 程序。")
        }
        let architectures = try command("/usr/bin/lipo", ["-archs", executable.path], timeout: 15)
        let wanted = hostArchitecture
        guard architectures.split(whereSeparator: \.isWhitespace).contains(Substring(wanted)) else {
            throw InstallError.invalid("更新包不支持本机架构 \(wanted)。")
        }
        let helper = url.appendingPathComponent("Contents/Helpers/CPU-S2UpdaterHelper")
        var helperInfo = stat()
        guard lstat(helper.path, &helperInfo) == 0,
              (helperInfo.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw InstallError.invalid("更新包缺少可运行的自动更新组件。")
        }
        let helperArchitectures = try command("/usr/bin/lipo", ["-archs", helper.path], timeout: 15)
        guard helperArchitectures.split(whereSeparator: \.isWhitespace).contains(Substring(wanted)) else {
            throw InstallError.invalid("更新包中的自动更新组件不支持本机架构 \(wanted)。")
        }
        _ = try command("/usr/bin/codesign", ["--verify", "--strict", "--all-architectures", helper.path], timeout: 30)
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", url.path], timeout: 45)
    }

    static func validateCurrentBundle(at url: URL) throws {
        _ = try applicationDirectory(url, purpose: "当前安装")
        try validateBundleLayout(at: url)
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let values = NSDictionary(contentsOf: plist) as? [String: Any],
              values["CFBundleIdentifier"] as? String == "com.cpus2.CPU-S2",
              values["CFBundleExecutable"] as? String == "CPU-S2",
              values["CFBundlePackageType"] as? String == "APPL" else {
            throw InstallError.invalid("当前安装位置不是 CPU-S2.app。")
        }
        let executable = url.appendingPathComponent("Contents/MacOS/CPU-S2")
        var fileInfo = stat()
        guard lstat(executable.path, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InstallError.invalid("当前安装缺少可执行的 CPU-S2 程序。")
        }
    }

    private static func bundleVersion(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let values = NSDictionary(contentsOf: plist) as? [String: Any] else { return nil }
        return values["CFBundleShortVersionString"] as? String
    }

    private static func validateBundleLayout(at url: URL) throws {
        let required: [(String, mode_t)] = [
            ("Contents", S_IFDIR),
            ("Contents/Info.plist", S_IFREG),
            ("Contents/MacOS", S_IFDIR),
            ("Contents/MacOS/CPU-S2", S_IFREG)
        ]
        for (relative, expectedType) in required {
            let path = url.appendingPathComponent(relative).path
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == expectedType else {
                throw InstallError.invalid("应用包包含缺失或不安全的路径：\(relative)。")
            }
        }
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = numericVersion(lhs), let right = numericVersion(rhs) else { return .orderedSame }
        for index in 0..<3 {
            if left[index] < right[index] { return .orderedAscending }
            if left[index] > right[index] { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericVersion(_ value: String) -> [UInt64]? {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let values = fields.compactMap { UInt64($0) }
        return values.count == 3 ? values : nil
    }

    private static var hostArchitecture: String {
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0, arm == 1 { return "arm64" }
        return "x86_64"
    }

    private static func ensureWritableVolume(containing url: URL) throws {
        var volume = statfs()
        guard statfs(url.path, &volume) == 0 else {
            throw InstallError.invalid("无法检查安装磁盘状态。")
        }
        guard (volume.f_flags & UInt32(MNT_RDONLY)) == 0 else {
            throw InstallError.invalid("应用位于只读磁盘，请先将其复制到「应用程序」文件夹。")
        }
        guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            throw InstallError.invalid("没有权限替换当前应用。")
        }
    }

    private static func waitUntilParentExits(_ pid: Int32, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) == -1, errno == ESRCH { return }
            usleep(100_000)
        }
        throw InstallError.parentTimeout
    }

    private static func launchAcknowledgementArguments(_ arguments: [String]) -> (URL, String)? {
        let ackFlags = arguments.indices.filter { arguments[$0] == "--cpus2-update-ack" }
        let tokenFlags = arguments.indices.filter { arguments[$0] == "--cpus2-update-token" }
        guard ackFlags.count == 1, tokenFlags.count == 1,
              let ackIndex = ackFlags.first, ackIndex + 3 < arguments.count,
              arguments[ackIndex + 2] == "--cpus2-update-token",
              tokenFlags[0] == ackIndex + 2 else { return nil }
        let token = arguments[ackIndex + 3].lowercased()
        guard let uuid = UUID(uuidString: token), uuid.uuidString.lowercased() == token else { return nil }
        return (URL(fileURLWithPath: arguments[ackIndex + 1], isDirectory: false), token)
    }

    private static func validateAcknowledgementDirectory(_ ackURL: URL, targetURL: URL,
                                                         token: String) throws {
        let target = try applicationDirectory(targetURL, purpose: "当前安装")
        let ack = ackURL.standardizedFileURL
        let stage = ack.deletingLastPathComponent()
        let stageName = stage.lastPathComponent
        let prefix = ".cpus2-update-"
        guard target.lastPathComponent == "CPU-S2.app",
              ack.isFileURL, ack.lastPathComponent == "ack.json",
              stageName.hasPrefix(prefix), stageName.hasSuffix(".stage") else {
            throw InstallError.invalid("启动确认路径无效。")
        }
        let identifier = String(stageName.dropFirst(prefix.count).dropLast(".stage".count)).lowercased()
        guard let stageUUID = UUID(uuidString: identifier), stageUUID.uuidString.lowercased() == token.lowercased(),
              let tokenUUID = UUID(uuidString: token), tokenUUID.uuidString.lowercased() == token.lowercased(),
              canonical(stage.deletingLastPathComponent()).path == canonical(target.deletingLastPathComponent()).path else {
            throw InstallError.invalid("启动确认不属于当前应用的更新事务。")
        }

        var directoryInfo = stat()
        guard lstat(stage.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == getuid(), (directoryInfo.st_mode & 0o777) == 0o700 else {
            throw InstallError.invalid("启动确认目录不是当前用户的私有目录。")
        }

        var fileInfo = stat()
        if lstat(ack.path, &fileInfo) == 0 {
            guard (fileInfo.st_mode & S_IFMT) == S_IFREG,
                  fileInfo.st_uid == getuid(), (fileInfo.st_mode & 0o777) == 0o600,
                  fileInfo.st_nlink == 1 else {
                throw InstallError.invalid("启动确认文件不是安全的普通文件。")
            }
        } else if errno != ENOENT {
            throw InstallError.invalid("无法检查启动确认文件。")
        }
    }

    private static func writeAcknowledgement(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw InstallError.invalid("无法创建启动确认文件。") }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw InstallError.invalid("无法保护启动确认文件。")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else {
            throw InstallError.invalid("启动确认文件状态无效。")
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw InstallError.invalid("启动确认为空。") }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw InstallError.invalid("无法写入启动确认文件。")
                }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw InstallError.invalid("无法保存启动确认文件。") }
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func waitForLaunchAcknowledgement(at ackURL: URL, targetURL: URL,
                                                     expectedVersion: String, token: String,
                                                     timeout: TimeInterval = 20) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            let acknowledgement: LaunchAcknowledgement
            do {
                acknowledgement = try readLaunchAcknowledgement(at: ackURL, targetURL: targetURL,
                                                                expectedVersion: expectedVersion, token: token)
            } catch {
                lastError = error
                usleep(100_000)
                continue
            }
            try validateAcknowledgedProcess(acknowledgement, targetURL: targetURL)
            usleep(750_000)
            try validateAcknowledgedProcess(acknowledgement, targetURL: targetURL)
            return
        }
        let reason = lastError?.localizedDescription ?? "没有收到启动确认。"
        throw InstallError.relaunch("新版本未能在 20 秒内完成启动确认：\(reason)")
    }

    private static func parentApplicationURL(pid: Int32) -> URL? {
        guard let executable = processExecutableURL(pid: pid) else { return nil }
        return executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func processExecutableURL(pid: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return canonical(URL(fileURLWithPath: String(cString: buffer)))
    }

    private static func processIDs() -> Set<Int32> {
        var capacity = 4096
        while capacity <= 65_536 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                         Int32(capacity * MemoryLayout<pid_t>.stride))
            guard byteCount >= 0 else { return [] }
            let count = min(capacity, Int(byteCount) / MemoryLayout<pid_t>.stride)
            if count < capacity { return Set(pids.prefix(count).filter { $0 > 1 }) }
            capacity *= 2
        }
        return []
    }

    private static func stopUnacknowledgedLaunches(of targetURL: URL, launchedAfter previousPIDs: Set<Int32>) {
        let expected = canonical(targetURL).appendingPathComponent("Contents/MacOS/CPU-S2").path
        for pid in processIDs().subtracting(previousPIDs) where pid > 1 && pid != getpid() {
            guard processExecutableURL(pid: pid)?.path == expected else { continue }
            _ = kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline, processExecutableURL(pid: pid)?.path == expected { usleep(50_000) }
            if processExecutableURL(pid: pid)?.path == expected { _ = kill(pid, SIGKILL) }
        }
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(url.path, mode_t(0o700)) == 0 else {
            try? removeOwnedDirectory(url)
            throw InstallError.invalid("无法设置更新临时目录权限。")
        }
    }

    private static func removeOwnedDirectory(_ url: URL) throws {
        let root = url.standardizedFileURL
        let name = root.lastPathComponent
        guard root.deletingLastPathComponent().path == root.deletingLastPathComponent().standardizedFileURL.path,
              name.hasPrefix(".cpus2-update-"), FileManager.default.fileExists(atPath: root.path) else { return }
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else { return }
        try FileManager.default.removeItem(at: root)
    }

    private static func fileExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Remove only the manager's direct NSTemporaryDirectory cache shape:
    /// cpus2-update-<UUID>/expanded/CPU-S2.app. Never follows a symlink root.
    static func cleanupCandidateCache(for candidate: URL) {
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        let expanded = candidate.standardizedFileURL.deletingLastPathComponent()
        let root = expanded.deletingLastPathComponent()
        let rootName = root.lastPathComponent
        let canonicalParent = root.deletingLastPathComponent().standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        guard candidate.lastPathComponent == "CPU-S2.app",
              expanded.lastPathComponent == "expanded",
              canonicalParent == tempRoot,
              rootName.hasPrefix("cpus2-update-"),
              UUID(uuidString: String(rootName.dropFirst("cpus2-update-".count))) != nil else { return }

        for directory in [root, expanded] {
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { return }
        }
        var appInfo = stat()
        guard lstat(candidate.path, &appInfo) == 0,
              (appInfo.st_mode & S_IFMT) == S_IFDIR,
              appInfo.st_uid == getuid() else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private static func launch(_ url: URL, acknowledgementURL: URL? = nil,
                               token: String? = nil, expectedVersion: String? = nil,
                               acknowledgementTimeout: TimeInterval = 20) throws {
        let requiresAcknowledgement = acknowledgementURL != nil || token != nil || expectedVersion != nil
        guard !requiresAcknowledgement || (acknowledgementURL != nil && token != nil && expectedVersion != nil) else {
            throw InstallError.invalid("启动确认参数不完整。")
        }
        let previousPIDs = requiresAcknowledgement ? processIDs() : []
        var arguments = ["-n", "-a", url.path]
        if let acknowledgementURL, let token, expectedVersion != nil {
            arguments += ["--args", "--cpus2-update-ack", acknowledgementURL.path,
                          "--cpus2-update-token", token]
        }
        do {
            _ = try command("/usr/bin/open", arguments, timeout: 20)
            if let acknowledgementURL, let token, let expectedVersion {
                try waitForLaunchAcknowledgement(at: acknowledgementURL, targetURL: url,
                                                 expectedVersion: expectedVersion, token: token,
                                                 timeout: acknowledgementTimeout)
            }
        } catch {
            if requiresAcknowledgement { stopUnacknowledgedLaunches(of: url, launchedAfter: previousPIDs) }
            throw error
        }
    }

    struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func runCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        try process.run()

        let drainGroup = DispatchGroup()
        let lock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        func drain(_ handle: FileHandle, save: @escaping (Data) -> Void) {
            drainGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                var captured = Data()
                while true {
                    let chunk = handle.readData(ofLength: 4096)
                    if chunk.isEmpty { break }
                    if captured.count < 65_536 {
                        captured.append(chunk.prefix(65_536 - captured.count))
                    }
                }
                lock.lock()
                save(captured)
                lock.unlock()
                drainGroup.leave()
            }
        }
        drain(output.fileHandleForReading) { stdoutData = $0 }
        drain(errors.fileHandleForReading) { stderrData = $0 }

        if termination.wait(timeout: .now() + timeout) != .success {
            if process.isRunning { process.terminate() }
            if termination.wait(timeout: .now() + 2) != .success, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 2)
            }
            _ = drainGroup.wait(timeout: .now() + 2)
            throw InstallError.commandTimeout(URL(fileURLWithPath: executable).lastPathComponent)
        }
        guard drainGroup.wait(timeout: .now() + 3) == .success else {
            throw InstallError.commandTimeout(URL(fileURLWithPath: executable).lastPathComponent)
        }
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    @discardableResult
    private static func command(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let result = try runCommand(executable, arguments, timeout: timeout)
        guard result.status == 0 else {
            let text = result.stderr.isEmpty ? result.stdout : result.stderr
            throw InstallError.invalid(text.isEmpty ? "系统拒绝验证或打开更新应用。" : text)
        }
        return result.stdout
    }
}
