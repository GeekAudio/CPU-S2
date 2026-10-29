import Foundation
import Darwin

/// Starts the app-bundled installer and returns only after it has validated the replacement app.
enum UpdateInstaller {
    enum LaunchError: LocalizedError {
        case helperMissing
        case helperInvalid
        case helperFailed(String)
        case noReadySignal

        var errorDescription: String? {
            switch self {
            case .helperMissing: return "应用内缺少自动更新组件。请重新安装 CPU-S2 后重试。"
            case .helperInvalid: return "自动更新组件验证失败。请重新安装 CPU-S2 后重试。"
            case .helperFailed(let reason): return reason
            case .noReadySignal: return "自动更新组件没有完成安全检查，当前应用保持打开。"
            }
        }
    }

    /// Call on a background queue after the downloaded ZIP and its SHA-256 have been verified.
    /// On return, the caller can terminate the old app without racing the installer startup.
    static func launchVerified(appURL: URL, expectedVersion: String,
                               currentAppURL: URL = Bundle.main.bundleURL) throws {
        let current = try UpdateInstallerCore.applicationDirectory(currentAppURL, purpose: "当前安装")
        let helper = current.appendingPathComponent("Contents/Helpers/CPU-S2UpdaterHelper")
        var attributes = stat()
        guard lstat(helper.path, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw LaunchError.helperMissing
        }
        let verify = try UpdateInstallerCore.runCommand("/usr/bin/codesign",
                                                        ["--verify", "--strict", helper.path], timeout: 15)
        guard verify.status == 0 else { throw LaunchError.helperInvalid }

        let process = Process()
        let output = Pipe()
        let terminated = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: helper.path)
        process.arguments = ["install", appURL.standardizedFileURL.path, current.path,
                             expectedVersion, String(getpid())]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()

        // Read asynchronously so a stalled helper cannot hang the app's main thread.
        var line = Data()
        let input = output.fileHandleForReading
        let receivedLine = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while line.count < 4096 {
                let byte = input.readData(ofLength: 1)
                if byte.isEmpty || byte.first == 10 { break }
                line.append(byte)
            }
            receivedLine.signal()
        }
        guard receivedLine.wait(timeout: .now() + 60) == .success else {
            stop(process, terminated: terminated)
            throw LaunchError.noReadySignal
        }
        guard let message = String(data: line, encoding: .utf8) else {
            stop(process, terminated: terminated)
            throw LaunchError.noReadySignal
        }
        if message == "READY" { return }
        stop(process, terminated: terminated)
        if message.hasPrefix("ERROR:") { throw LaunchError.helperFailed(String(message.dropFirst(6))) }
        throw LaunchError.noReadySignal
    }

    private static func stop(_ process: Process, terminated: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if terminated.wait(timeout: .now() + 2) != .success, process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + 2)
        }
    }
}
