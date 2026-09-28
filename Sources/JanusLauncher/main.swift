import AppKit
import JanusCore

// The program inside every "Claude – <account>.app" that Janus makes.
//
// It reads which data directory is its account's from its own Info.plist, then
// either brings the copy of Claude already running against that directory to
// the front, or starts one. Checking first matters: Claude does not stop a
// second copy on the same directory, and two copies would fight over its files.

let info = Bundle.main.infoDictionary ?? [:]

guard let dataDirectory = info[DesktopLaunchers.Key.dataDirectory] as? String else {
    FileHandle.standardError.write(Data("JanusLauncher: no data directory in Info.plist\n".utf8))
    exit(1)
}

if let running = DesktopLaunchers.runningInstance(dataDirectory: dataDirectory) {
    running.activate(options: [.activateAllWindows])
    exit(0)
}

let claudeApp = URL(fileURLWithPath: info[DesktopLaunchers.Key.claudeApp] as? String
    ?? DesktopLaunchers.defaultClaudeApp.path)

try? FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])

let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.arguments = ["--user-data-dir=" + dataDirectory]
configuration.activates = true

NSWorkspace.shared.openApplication(at: claudeApp, configuration: configuration) { _, error in
    if let error {
        FileHandle.standardError.write(Data("JanusLauncher: \(error.localizedDescription)\n".utf8))
    }
    exit(error == nil ? 0 : 1)
}

// Kept alive only until the open above calls back.
RunLoop.main.run()
