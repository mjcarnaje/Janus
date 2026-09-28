import AppKit
import CryptoKit
import Foundation

/// One small app per saved account that opens the Claude desktop app signed in
/// as that account, with the account's own logo in the Dock and in Spotlight.
///
/// The desktop app keeps its sign-in, chats and MCP settings in one data
/// directory, and Electron lets a second copy be started against another one
/// with `--user-data-dir`. So Claude.app itself is never copied or modified,
/// and keeps its signature, its updater and its passkeys. A launcher is a few
/// hundred kilobytes that knows which directory is its account's, and either
/// brings that copy of Claude forward or starts it.
///
/// `CLAUDE_CONFIG_DIR` is deliberately left alone. Claude Code files its
/// keychain entry under a name derived from that path, so changing it would
/// sign the command line tool out, and fight the switching the Claude tab does.
public final class DesktopLaunchers: @unchecked Sendable {

    /// The desktop app every launcher starts.
    public static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Info.plist keys a launcher carries. The marker is the only thing that
    /// makes a bundle one Janus is allowed to replace or delete.
    public enum Key {
        public static let profile = "JanusManagedProfile"
        public static let dataDirectory = "JanusUserDataDir"
        public static let claudeApp = "JanusClaudeApp"
        public static let email = "JanusAccountEmail"
        public static let fingerprint = "JanusFingerprint"
    }

    /// Where launchers go: a folder of their own under `~/Applications`, which
    /// Spotlight and Launchpad index, and which holds nothing Janus did not put
    /// there.
    public static var defaultFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Applications/Claude Accounts", isDirectory: true)
    }

    public static var defaultClaudeApp: URL {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID)
            ?? URL(fileURLWithPath: "/Applications/Claude.app")
    }

    public let folder: URL
    public let root: URL
    public let claudeApp: URL
    private let launcherExecutable: URL?
    private let icons: LauncherIconRenderer
    private let registrar: LauncherRegistrar

    /// - Parameters:
    ///   - root: Janus's own storage; data directories and logos live under it.
    ///   - launcherExecutable: the binary copied into every launcher. `nil`
    ///     when Janus is running outside its bundle and has none to copy.
    public init(folder: URL = DesktopLaunchers.defaultFolder,
                root: URL = Vault.defaultRoot,
                claudeApp: URL = DesktopLaunchers.defaultClaudeApp,
                launcherExecutable: URL? = DesktopLaunchers.bundledExecutable,
                icons: LauncherIconRenderer = SystemIconRenderer(),
                registrar: LauncherRegistrar = SystemRegistrar()) {
        self.folder = folder
        self.root = root
        self.claudeApp = claudeApp
        self.launcherExecutable = launcherExecutable
        self.icons = icons
        self.registrar = registrar
    }

    /// The launcher binary `build.sh` puts beside Janus's own executable.
    public static var bundledExecutable: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "JanusLauncher")
            ?? Bundle.main.executableURL.map {
                // `swift run` has no bundle, but builds both products side by side.
                $0.deletingLastPathComponent().appendingPathComponent("JanusLauncher")
            }.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    private var fileManager: FileManager { .default }
    private var desktopRoot: URL { root.appendingPathComponent("Desktop", isDirectory: true) }
    private var logosDirectory: URL { desktopRoot.appendingPathComponent("logos", isDirectory: true) }

    public var isClaudeInstalled: Bool {
        fileManager.fileExists(atPath: claudeApp.path)
    }

    // MARK: - Where things live

    /// The account's own copy of everything the desktop app keeps. Keyed by the
    /// account's id rather than its address, because this path is the identity
    /// of the sign-in: moving it would sign the account out.
    public func dataDirectory(for id: UUID) -> URL {
        desktopRoot.appendingPathComponent("profiles/\(id.uuidString)", isDirectory: true)
    }

    public func logoURL(for id: UUID) -> URL {
        logosDirectory.appendingPathComponent("\(id.uuidString).png")
    }

    public func hasCustomLogo(_ id: UUID) -> Bool {
        fileManager.fileExists(atPath: logoURL(for: id).path)
    }

    /// Launcher names, one per account.
    ///
    /// "Claude – ramit" reads well in the Dock, and every launcher sorts next to
    /// Claude itself in Spotlight. Two accounts sharing the part before the "@"
    /// fall back to their whole addresses so neither name hides the other.
    public func launcherNames(for profiles: [Profile]) -> [UUID: String] {
        var counts: [String: Int] = [:]
        for profile in profiles { counts[profile.shortName.lowercased(), default: 0] += 1 }

        var names: [UUID: String] = [:]
        var taken: Set<String> = []
        for profile in profiles {
            let label = counts[profile.shortName.lowercased(), default: 0] > 1
                ? profile.email : profile.shortName
            var name = "Claude – " + Self.sanitize(label)
            // Two profiles with the same address can only come from a hand-edited
            // roster, but a name used twice would make one launcher overwrite the other.
            if taken.contains(name.lowercased()) { name += " " + profile.id.uuidString.prefix(4) }
            taken.insert(name.lowercased())
            names[profile.id] = name
        }
        return names
    }

    /// Characters a file name cannot hold, or that Finder shows oddly.
    static func sanitize(_ label: String) -> String {
        let cleaned = label.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "account" : trimmed
    }

    public func launcherURL(for profile: Profile, in profiles: [Profile]) -> URL {
        let name = launcherNames(for: profiles)[profile.id] ?? "Claude – \(profile.shortName)"
        return folder.appendingPathComponent(name + ".app", isDirectory: true)
    }

    // MARK: - Logos

    /// Keeps a copy of an image as the account's logo. Converted to PNG on the
    /// way in, so an unreadable file is refused here rather than at the next sync.
    public func setLogo(from source: URL, for id: UUID) throws {
        guard let data = try? Data(contentsOf: source), let png = icons.normalizedLogo(data) else {
            throw DesktopLauncherError.unreadableLogo(source.lastPathComponent)
        }
        try fileManager.createDirectory(at: logosDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try png.write(to: logoURL(for: id), options: .atomic)
    }

    public func removeLogo(for id: UUID) {
        try? fileManager.removeItem(at: logoURL(for: id))
    }

    // MARK: - What is installed

    public struct Installed: Equatable {
        public let id: UUID
        public let url: URL
        public let fingerprint: String?
    }

    /// Every launcher in the folder that carries Janus's marker. Anything else,
    /// such as an app somebody dragged in by hand, is invisible to sync.
    public func installed() -> [Installed] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".app") else { return nil }
            let url = folder.appendingPathComponent(name, isDirectory: true)
            let plist = url.appendingPathComponent("Contents/Info.plist")
            guard let data = fileManager.contents(atPath: plist.path),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                      as? [String: Any],
                  let marker = info[Key.profile] as? String,
                  let id = UUID(uuidString: marker)
            else { return nil }
            return Installed(id: id, url: url, fingerprint: info[Key.fingerprint] as? String)
        }
    }

    public func launcher(for id: UUID) -> URL? {
        installed().first { $0.id == id }?.url
    }

    // MARK: - Sync

    public struct Report: Equatable {
        public var created: [String] = []
        public var updated: [String] = []
        public var removed: [String] = []
        public var unchanged = 0

        public var changed: Bool { !(created.isEmpty && updated.isEmpty && removed.isEmpty) }

        /// One line for the message under the Refresh button.
        public var summary: String {
            var parts: [String] = []
            if !created.isEmpty { parts.append("\(created.count) created") }
            if !updated.isEmpty { parts.append("\(updated.count) updated") }
            if !removed.isEmpty { parts.append("\(removed.count) removed") }
            if unchanged > 0 { parts.append("\(unchanged) already up to date") }
            return "Desktop apps: " + (parts.isEmpty ? "none to make yet" : parts.joined(separator: ", ")) + "."
        }
    }

    /// Makes the folder match the roster: one launcher per account, each current,
    /// and none for an account that is gone.
    ///
    /// A launcher is only rewritten when something that goes into it changed,
    /// which is what its fingerprint records. Rewriting all of them on every
    /// Refresh would make LaunchServices re-read each one and the Dock redraw it.
    ///
    /// Removing an account removes its launcher but leaves its data directory:
    /// that is where the desktop app's chats and sign-in are, and saving the
    /// account again brings the same launcher, still signed in, back.
    @discardableResult
    public func sync(_ roster: Roster) throws -> Report {
        guard isClaudeInstalled else { throw DesktopLauncherError.claudeNotInstalled(claudeApp.path) }
        guard let launcherExecutable else { throw DesktopLauncherError.noLauncherBinary }

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        var report = Report()
        var existing = Dictionary(grouping: installed(), by: \.id)
        let names = launcherNames(for: roster.profiles)
        let executable = try Data(contentsOf: launcherExecutable)
        let claudeVersion = installedClaudeVersion()

        for profile in roster.profiles {
            let name = names[profile.id] ?? "Claude – \(profile.shortName)"
            let destination = folder.appendingPathComponent(name + ".app", isDirectory: true)
            let logo = fileManager.contents(atPath: logoURL(for: profile.id).path)

            var info = infoDictionary(for: profile, name: name)
            let fingerprint = Self.fingerprint(info: info, executable: executable,
                                               logo: logo, claudeVersion: claudeVersion)
            info[Key.fingerprint] = fingerprint

            let current = existing.removeValue(forKey: profile.id) ?? []
            if current.count == 1, let only = current.first,
               only.url.standardizedFileURL == destination.standardizedFileURL,
               only.fingerprint == fingerprint {
                report.unchanged += 1
                continue
            }

            // Replaced, not patched: a launcher holds nothing but what is built here.
            for stale in current { try fileManager.removeItem(at: stale.url) }
            // Anything still at that path is not Janus's to replace.
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw DesktopLauncherError.nameTaken(destination.lastPathComponent)
            }
            try build(at: destination, info: info, executable: executable,
                      icon: try icons.icns(logo: logo, claudeApp: claudeApp,
                                           initial: Self.initial(of: profile),
                                           tint: Self.tint(for: profile.id)))
            if current.isEmpty { report.created.append(name) } else { report.updated.append(name) }
        }

        // Whatever is left belongs to accounts no longer on the roster.
        for leftovers in existing.values {
            for launcher in leftovers {
                try registrar.discard(launcher.url)
                report.removed.append(launcher.url.deletingPathExtension().lastPathComponent)
            }
        }
        return report
    }

    /// Read from the file each time rather than through `Bundle`, which caches
    /// what it read first and would miss Claude updating while Janus runs.
    func installedClaudeVersion() -> String {
        let plist = claudeApp.appendingPathComponent("Contents/Info.plist")
        guard let data = fileManager.contents(atPath: plist.path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any]
        else { return "" }
        return info["CFBundleShortVersionString"] as? String ?? ""
    }

    func infoDictionary(for profile: Profile, name: String) -> [String: Any] {
        [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": "com.ramitvishwakarma.janus.claude." + profile.id.uuidString.lowercased(),
            "CFBundleExecutable": "JanusLauncher",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": Build.version,
            "CFBundleVersion": Build.version,
            "LSMinimumSystemVersion": "13.0",
            // Starts Claude and quits, so it has no business bouncing in the Dock.
            "LSUIElement": true,
            "NSHumanReadableCopyright": "Made by Janus for \(profile.email)",
            Key.profile: profile.id.uuidString,
            Key.dataDirectory: dataDirectory(for: profile.id).path,
            Key.claudeApp: claudeApp.path,
            Key.email: profile.email
        ]
    }

    /// Everything that ends up in a launcher, hashed. The Claude version is part
    /// of it because the default icon is drawn from Claude's own.
    static func fingerprint(info: [String: Any], executable: Data,
                            logo: Data?, claudeVersion: String) -> String {
        var hasher = SHA256()
        if let plist = try? PropertyListSerialization.data(fromPropertyList: info,
                                                           format: .xml, options: 0) {
            hasher.update(data: plist)
        }
        hasher.update(data: executable)
        hasher.update(data: logo ?? Data("default-icon-v1".utf8))
        hasher.update(data: Data(claudeVersion.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func build(at destination: URL, info: [String: Any],
                       executable: Data, icon: Data) throws {
        // Assembled beside its final place and moved in whole, so a failure
        // halfway never leaves a launcher that half works.
        let staging = folder.appendingPathComponent(".staging-\(UUID().uuidString).app",
                                                    isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        let contents = staging.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        let binary = macOS.appendingPathComponent("JanusLauncher")
        try executable.write(to: binary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try icon.write(to: resources.appendingPathComponent("AppIcon.icns"))
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        try registrar.sign(staging)
        try fileManager.moveItem(at: staging, to: destination)
        try? registrar.register(destination)
    }

    // MARK: - The default icon

    static func initial(of profile: Profile) -> String {
        profile.shortName.first.map { String($0).uppercased() } ?? "?"
    }

    /// A colour per account that stays the same from one run to the next, which
    /// `hashValue` would not.
    static func tint(for id: UUID) -> Int {
        let digest = SHA256.hash(data: Data(id.uuidString.utf8))
        return Int(Array(digest)[0]) % LauncherPalette.count
    }

    // MARK: - Running copies

    /// The copy of Claude started against this data directory, if one is running.
    public static func runningInstance(dataDirectory: String) -> NSRunningApplication? {
        let flag = "--user-data-dir=" + dataDirectory
        return NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID)
            .first { ProcessArguments.of($0.processIdentifier).contains(flag) }
    }

    public func isRunning(_ id: UUID) -> Bool {
        Self.runningInstance(dataDirectory: dataDirectory(for: id).path) != nil
    }
}

public enum DesktopLauncherError: LocalizedError, Equatable {
    case claudeNotInstalled(String)
    case noLauncherBinary
    case unreadableLogo(String)
    case signingFailed(String)
    case nameTaken(String)

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name):
            return "\(name) already exists and was not made by Janus, so it was left alone. Rename or move it, then refresh."
        case .claudeNotInstalled(let path):
            return "The Claude desktop app is not at \(path), so there is nothing to make launchers for."
        case .noLauncherBinary:
            return "This build of Janus has no launcher to copy. Build it with ./build.sh."
        case .unreadableLogo(let name):
            return "\(name) is not an image Janus can read."
        case .signingFailed(let name):
            return "Could not sign the launcher \(name)."
        }
    }
}

// MARK: - Seams

/// Draws a launcher's icon. Separate so tests need neither AppKit drawing nor
/// `iconutil`.
public protocol LauncherIconRenderer {
    /// The image as PNG, or `nil` when it is not an image.
    func normalizedLogo(_ data: Data) -> Data?
    /// An `.icns`: the account's logo when it has one, otherwise Claude's own
    /// icon with a coloured initial on it.
    func icns(logo: Data?, claudeApp: URL, initial: String, tint: Int) throws -> Data
}

/// Signs and registers a finished launcher. Separate for the same reason.
public protocol LauncherRegistrar {
    func sign(_ bundle: URL) throws
    func register(_ bundle: URL) throws
    /// Takes away a launcher whose account is gone.
    func discard(_ bundle: URL) throws
}

public struct SystemRegistrar: LauncherRegistrar {
    public init() {}

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
        + "LaunchServices.framework/Support/lsregister"

    /// Ad hoc, like Janus itself. Required rather than cosmetic: Apple silicon
    /// will not run an unsigned binary, and the signature seals the Info.plist
    /// that says which account the launcher is for.
    public func sign(_ bundle: URL) throws {
        let result = try Command.run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        guard result.succeeded else {
            throw DesktopLauncherError.signingFailed(bundle.lastPathComponent)
        }
    }

    /// Tells LaunchServices the bundle changed, so Spotlight and the Dock show
    /// the new icon without waiting to notice by themselves.
    public func register(_ bundle: URL) throws {
        try Command.run(Self.lsregister, ["-f", bundle.path])
    }

    /// To the Trash rather than deleted, like everything else Janus takes away.
    public func discard(_ bundle: URL) throws {
        _ = try? Command.run(Self.lsregister, ["-u", bundle.path])
        try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
    }
}
