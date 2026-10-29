import Foundation

@main
enum UpdateInstallerTests {
    static func main() throws {
        guard CommandLine.arguments.count == 5 else {
            fatalError("usage: installer-tests FIXTURE_EXECUTABLE FOREIGN_ARCH_EXECUTABLE ACK_APP_EXECUTABLE TEST_ROOT")
        }
        let fixtureExecutable = URL(fileURLWithPath: CommandLine.arguments[1])
        let foreignArchitectureExecutable = URL(fileURLWithPath: CommandLine.arguments[2])
        let acknowledgingAppExecutable = URL(fileURLWithPath: CommandLine.arguments[3])
        let root = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        try rejectsMalformedVersion()
        try rejectsSymlinkBundle(fixtureExecutable, root: root)
        try rejectsDowngrade(fixtureExecutable, root: root)
        try rejectsForeignArchitecture(fixtureExecutable, foreign: foreignArchitectureExecutable, root: root)
        try rejectsForeignHelperArchitecture(fixtureExecutable, foreign: foreignArchitectureExecutable, root: root)
        try installsAtomicallyAndKeepsBackup(fixtureExecutable, root: root)
        try restoresOldAppAfterInjectedFailure(fixtureExecutable, root: root)
        try validatesLaunchAcknowledgement(fixtureExecutable, root: root)
        try installsOnlyAfterAppLaunchAcknowledgement(fixtureExecutable, appExecutable: acknowledgingAppExecutable, root: root)
        try rollsBackWhenNewAppDoesNotAcknowledge(fixtureExecutable, root: root)
        try cleansOnlyOwnedTemporaryCache(fixtureExecutable, root: root)
        print("UpdateInstallerTests: 11 passed")
    }

    private static func rejectsMalformedVersion() throws {
        do {
            try UpdateInstallerCore.validateVersion("2.4")
            throw Failure.assertion("two-component version was accepted")
        } catch is UpdateInstallerCore.InstallError {
            // Expected.
        }
        do {
            try UpdateInstallerCore.validateVersion("2.4.4-beta")
            throw Failure.assertion("suffixed version was accepted")
        } catch is UpdateInstallerCore.InstallError {
            // Expected.
        }
    }

    private static func rejectsSymlinkBundle(_ binary: URL, root: URL) throws {
        let folder = root.appendingPathComponent("symlink", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let actual = try makeApp(at: folder.appendingPathComponent("actual/CPU-S2.app"),
                                 version: "2.4.4", executable: binary)
        let link = folder.appendingPathComponent("CPU-S2.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        let candidate = try makeApp(at: folder.appendingPathComponent("download/CPU-S2.app"),
                                    version: "2.5.0", executable: binary)
        try expectRejected(UpdateInstallerCore.Request(candidate: candidate, target: link,
                                                       expectedVersion: "2.5.0", parentPID: 1),
                           message: "symlink install target")
    }

    private static func rejectsDowngrade(_ binary: URL, root: URL) throws {
        let folder = root.appendingPathComponent("downgrade", isDirectory: true)
        let target = try makeApp(at: folder.appendingPathComponent("current/CPU-S2.app"),
                                 version: "2.4.4", executable: binary)
        let candidate = try makeApp(at: folder.appendingPathComponent("candidate/CPU-S2.app"),
                                    version: "2.4.3", executable: binary)
        try expectRejected(UpdateInstallerCore.Request(candidate: candidate, target: target,
                                                       expectedVersion: "2.4.3", parentPID: 1),
                           message: "downgrade")
    }

    private static func rejectsForeignArchitecture(_ binary: URL, foreign: URL, root: URL) throws {
        let folder = root.appendingPathComponent("architecture", isDirectory: true)
        let target = try makeApp(at: folder.appendingPathComponent("current/CPU-S2.app"),
                                 version: "2.4.4", executable: binary)
        let candidate = try makeApp(at: folder.appendingPathComponent("candidate/CPU-S2.app"),
                                    version: "2.5.0", executable: foreign)
        try expectRejected(UpdateInstallerCore.Request(candidate: candidate, target: target,
                                                       expectedVersion: "2.5.0", parentPID: 1),
                           message: "foreign architecture")
    }

    private static func rejectsForeignHelperArchitecture(_ binary: URL, foreign: URL, root: URL) throws {
        let folder = root.appendingPathComponent("helper-architecture", isDirectory: true)
        let target = try makeApp(at: folder.appendingPathComponent("current/CPU-S2.app"),
                                 version: "2.4.4", executable: binary)
        let candidate = try makeApp(at: folder.appendingPathComponent("candidate/CPU-S2.app"),
                                    version: "2.5.0", executable: binary, updaterHelper: foreign)
        try expectRejected(UpdateInstallerCore.Request(candidate: candidate, target: target,
                                                       expectedVersion: "2.5.0", parentPID: 1),
                           message: "foreign updater helper architecture")
    }

    private static func installsAtomicallyAndKeepsBackup(_ binary: URL, root: URL) throws {
        let folder = root.appendingPathComponent("success", isDirectory: true)
        let target = try makeApp(at: folder.appendingPathComponent("CPU-S2.app"),
                                 version: "2.4.4", executable: binary)
        let candidate = try makeApp(at: folder.appendingPathComponent("download/CPU-S2.app"),
                                    version: "2.5.0", executable: binary)
        let request = UpdateInstallerCore.Request(candidate: candidate, target: target,
                                                  expectedVersion: "2.5.0", parentPID: 1)
        try UpdateInstallerCore.perform(request, waitForParent: false, relaunch: false)
        try assertVersion("2.5.0", at: target, message: "installed version")
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".cpus2-update-") && $0.lastPathComponent.hasSuffix(".backup") }
        guard backups.count == 1 else { throw Failure.assertion("successful install did not retain one rollback backup") }
        try assertVersion("2.4.4", at: backups[0].appendingPathComponent("CPU-S2.app"), message: "backup version")
    }

    private static func restoresOldAppAfterInjectedFailure(_ binary: URL, root: URL) throws {
        let folder = root.appendingPathComponent("rollback", isDirectory: true)
        let target = try makeApp(at: folder.appendingPathComponent("CPU-S2.app"),
                                 version: "2.4.4", executable: binary)
        let candidate = try makeApp(at: folder.appendingPathComponent("download/CPU-S2.app"),
                                    version: "2.5.0", executable: binary)
        let request = UpdateInstallerCore.Request(candidate: candidate, target: target,
                                                  expectedVersion: "2.5.0", parentPID: 1)
        do {
            try UpdateInstallerCore.perform(request, waitForParent: false, relaunch: false,
                                            afterInstall: { throw Failure.injected })
            throw Failure.assertion("injected failure did not fail the installation")
        } catch Failure.injected {
            // The installer must restore the old app before returning the injected error.
        }
        try assertVersion("2.4.4", at: target, message: "rollback version")
        let failed = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".cpus2-update-") && $0.lastPathComponent.hasSuffix(".failed") }
        guard failed.count == 1 else { throw Failure.assertion("failed candidate was not preserved for diagnosis") }
    }

    private static func cleansOnlyOwnedTemporaryCache(_ binary: URL, root: URL) throws {
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpus2-update-\(UUID().uuidString)", isDirectory: true)
        let expanded = owned.appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let candidate = try makeApp(at: owned.appendingPathComponent("expanded/CPU-S2.app"),
                                    version: "2.5.0", executable: binary)
        UpdateInstallerCore.cleanupCandidateCache(for: candidate)
        guard !FileManager.default.fileExists(atPath: owned.path) else {
            throw Failure.assertion("owned temporary cache was not cleaned")
        }

        let outside = try makeApp(at: root.appendingPathComponent("outside-cache/expanded/CPU-S2.app"),
                                  version: "2.5.0", executable: binary)
        let outsideRoot = outside.deletingLastPathComponent().deletingLastPathComponent()
        UpdateInstallerCore.cleanupCandidateCache(for: outside)
        guard FileManager.default.fileExists(atPath: outsideRoot.path) else {
            throw Failure.assertion("installer removed a cache outside NSTemporaryDirectory")
        }

        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpus2-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideRoot)
        let linkedCandidate = link.appendingPathComponent("expanded/CPU-S2.app", isDirectory: true)
        UpdateInstallerCore.cleanupCandidateCache(for: linkedCandidate)
        guard FileManager.default.fileExists(atPath: outsideRoot.path) else {
            throw Failure.assertion("installer followed and removed a symlink cache root")
        }
        try FileManager.default.removeItem(at: link)
    }

    private static func validatesLaunchAcknowledgement(_ binary: URL, root: URL) throws {
        let folder = root.appendingPathComponent("acknowledgement", isDirectory: true)
        let target = try makeApp(at: folder.appendingPathComponent("CPU-S2.app"),
                                 version: "2.5.0", executable: binary)
        let token = UUID().uuidString.lowercased()
        let stage = folder.appendingPathComponent(".cpus2-update-\(token).stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
        let ackURL = stage.appendingPathComponent("ack.json")

        let process = Process()
        process.executableURL = target.appendingPathComponent("Contents/MacOS/CPU-S2")
        process.arguments = ["--hold"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let values: [String: Any] = [
            "pid": Int(process.processIdentifier),
            "token": token,
            "version": "2.5.0",
            "bundlePath": target.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        ]
        try JSONSerialization.data(withJSONObject: values).write(to: ackURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ackURL.path)

        let acknowledgement = try UpdateInstallerCore.readLaunchAcknowledgement(
            at: ackURL, targetURL: target, expectedVersion: "2.5.0", token: token)
        try UpdateInstallerCore.validateAcknowledgedProcess(acknowledgement, targetURL: target)
        do {
            _ = try UpdateInstallerCore.readLaunchAcknowledgement(
                at: ackURL, targetURL: target, expectedVersion: "2.5.1", token: token)
            throw Failure.assertion("acknowledgement for another version was accepted")
        } catch is UpdateInstallerCore.InstallError {
            // Expected.
        }

        let forged = UpdateInstallerCore.LaunchAcknowledgement(pid: Int32(getpid()), token: token,
                                                              version: "2.5.0", bundlePath: target.path)
        do {
            try UpdateInstallerCore.validateAcknowledgedProcess(forged, targetURL: target)
            throw Failure.assertion("acknowledgement from another executable was accepted")
        } catch is UpdateInstallerCore.InstallError {
            // Expected.
        }

        let args = ["CPU-S2", "--cpus2-update-ack", ackURL.path,
                    "--cpus2-update-token", token]
        guard !UpdateInstallerCore.acknowledgeLaunch(arguments: args, currentAppURL: target) else {
            throw Failure.assertion("foreign process wrote an app launch acknowledgement")
        }
    }

    private static func installsOnlyAfterAppLaunchAcknowledgement(_ binary: URL, appExecutable: URL,
                                                                   root: URL) throws {
        let folder = root.appendingPathComponent("acknowledged-install", isDirectory: true)
        let target = try makeApp(at: folder.appendingPathComponent("CPU-S2.app"),
                                 version: "2.4.4", executable: binary)
        let candidate = try makeApp(at: folder.appendingPathComponent("download/CPU-S2.app"),
                                    version: "2.5.0", executable: appExecutable)
        let request = UpdateInstallerCore.Request(candidate: candidate, target: target,
                                                  expectedVersion: "2.5.0", parentPID: 1)
        try UpdateInstallerCore.perform(request, waitForParent: false, relaunch: true)
        try assertVersion("2.5.0", at: target, message: "acknowledged installation")
        // The fixture stays alive briefly after acknowledging; let it exit before test cleanup.
        Thread.sleep(forTimeInterval: 2)
    }

    private static func rollsBackWhenNewAppDoesNotAcknowledge(_ binary: URL, root: URL) throws {
        let folder = root.appendingPathComponent("missing-ack", isDirectory: true)
        let target = try makeApp(at: folder.appendingPathComponent("CPU-S2.app"),
                                 version: "2.4.4", executable: binary)
        let candidate = try makeApp(at: folder.appendingPathComponent("download/CPU-S2.app"),
                                    version: "2.5.0", executable: binary)
        let request = UpdateInstallerCore.Request(candidate: candidate, target: target,
                                                  expectedVersion: "2.5.0", parentPID: 1)
        do {
            try UpdateInstallerCore.perform(request, waitForParent: false, relaunch: true,
                                            acknowledgementTimeout: 0.25)
            throw Failure.assertion("new app without an acknowledgement was accepted")
        } catch is UpdateInstallerCore.InstallError {
            // The old bundle must be back at its original path before the failure returns.
        }
        try assertVersion("2.4.4", at: target, message: "missing-ack rollback")
        let failed = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".cpus2-update-") && $0.lastPathComponent.hasSuffix(".failed") }
        guard failed.count == 1 else { throw Failure.assertion("unacknowledged app was not retained as a failed candidate") }
    }

    private static func makeApp(at url: URL, version: String, executable: URL,
                                updaterHelper: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.cpus2.CPU-S2",
            "CFBundleExecutable": "CPU-S2",
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "APPL",
            "CFBundleName": "CPU-S2"
        ]
        let info = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let program = macOS.appendingPathComponent("CPU-S2")
        try fm.copyItem(at: executable, to: program)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let helperDirectory = contents.appendingPathComponent("Helpers", isDirectory: true)
        try fm.createDirectory(at: helperDirectory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o755])
        let helper = helperDirectory.appendingPathComponent("CPU-S2UpdaterHelper")
        try fm.copyItem(at: updaterHelper ?? executable, to: helper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", "--timestamp=none", url.path])
        return url
    }

    private static func expectRejected(_ request: UpdateInstallerCore.Request, message: String) throws {
        do {
            try UpdateInstallerCore.validate(request)
            throw Failure.assertion("installer accepted \(message)")
        } catch is UpdateInstallerCore.InstallError {
            // Expected.
        }
    }

    private static func assertVersion(_ expected: String, at app: URL, message: String) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              values["CFBundleShortVersionString"] as? String == expected else {
            throw Failure.assertion("unexpected \(message)")
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let detail = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: detail, encoding: .utf8) ?? ""
            throw Failure.assertion("command failed: \(text)")
        }
    }

    enum Failure: Error, LocalizedError {
        case assertion(String)
        case injected

        var errorDescription: String? {
            switch self {
            case .assertion(let reason): return reason
            case .injected: return "injected post-install failure"
            }
        }
    }
}
