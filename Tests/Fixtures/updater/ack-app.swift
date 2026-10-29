import Foundation

@main
enum AcknowledgingFixtureApp {
    static func main() {
        guard UpdateInstallerCore.acknowledgeLaunch() else { exit(23) }
        Thread.sleep(forTimeInterval: 1.5)
    }
}
