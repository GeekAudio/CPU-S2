import Foundation
import Darwin

@main
enum CPUUpdaterHelper {
    static func main() {
        var readySent = false
        var candidateForCleanup: URL?
        do {
            guard CommandLine.arguments.count == 6, CommandLine.arguments[1] == "install",
                  let pidValue = Int32(CommandLine.arguments[5]), pidValue > 1 else {
                throw UpdateInstallerCore.InstallError.invalid("自动更新器参数无效。")
            }
            let candidate = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            candidateForCleanup = candidate
            let request = UpdateInstallerCore.Request(
                candidate: candidate,
                target: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true),
                expectedVersion: CommandLine.arguments[4], parentPID: pidValue)
            // Preflight before asking the app to quit. A failed download or path check leaves it open.
            try UpdateInstallerCore.validateParent(request)
            try UpdateInstallerCore.validate(request)
            print("READY", terminator: "\n")
            fflush(stdout)
            readySent = true
            _ = close(STDOUT_FILENO)
            try UpdateInstallerCore.perform(request, parentWasValidated: true)
            UpdateInstallerCore.cleanupCandidateCache(for: candidate)
            exit(0)
        } catch {
            let message = error.localizedDescription
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            UpdateInstallerCore.recordFailure(message)
            if let candidate = candidateForCleanup {
                UpdateInstallerCore.cleanupCandidateCache(for: candidate)
            }
            if !readySent {
                print("ERROR:" + message, terminator: "\n")
                fflush(stdout)
            }
            exit(1)
        }
    }
}
