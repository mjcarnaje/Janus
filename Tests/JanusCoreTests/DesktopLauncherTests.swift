import AppKit
import Foundation
import XCTest
@testable import JanusCore

/// Icons that are just a description of what would have been drawn, so a test
/// can see which logo went in without AppKit or `iconutil`.
private struct StubIcons: LauncherIconRenderer {
    func normalizedLogo(_ data: Data) -> Data? {
        String(decoding: data, as: UTF8.self).hasPrefix("IMG") ? data : nil
    }

    func icns(logo: Data?, claudeApp: URL, initial: String, tint: Int) throws -> Data {
        Data("icns logo=\(logo.map { String(decoding: $0, as: UTF8.self) } ?? "default") initial=\(initial)".utf8)
    }
}

private final class StubRegistrar: LauncherRegistrar {
    var signed: [String] = []
    var discarded: [String] = []

    func sign(_ bundle: URL) throws { signed.append(bundle.lastPathComponent) }
    func register(_ bundle: URL) throws {}
    func discard(_ bundle: URL) throws {
        discarded.append(bundle.lastPathComponent)
        try FileManager.default.removeItem(at: bundle)
    }
}

final class DesktopLauncherTests: XCTestCase {

    private var home: URL!
    private var registrar: StubRegistrar!
    private var launchers: DesktopLaunchers!
    private var claudeApp: URL!

    private let ramit = Profile(email: "ramit@example.com")
    private let anaya = Profile(email: "anaya@example.com")

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("janus-launcher-tests/\(UUID().uuidString)", isDirectory: true)

        claudeApp = home.appendingPathComponent("Claude.app", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeApp.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try writeClaudeVersion("1.0.0")

        let binary = home.appendingPathComponent("JanusLauncher")
        try Data("launcher binary".utf8).write(to: binary)

        registrar = StubRegistrar()
        launchers = DesktopLaunchers(folder: home.appendingPathComponent("Applications/Claude Accounts"),
                                     root: home.appendingPathComponent("vault"),
                                     claudeApp: claudeApp,
                                     launcherExecutable: binary,
                                     icons: StubIcons(),
                                     registrar: registrar)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeClaudeVersion(_ version: String) throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        try plist.write(to: claudeApp.appendingPathComponent("Contents/Info.plist"))
    }

    private func info(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func icon(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url.appendingPathComponent("Contents/Resources/AppIcon.icns")),
               as: UTF8.self)
    }

    private func appNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: launchers.folder.path)) ?? []).sorted()
    }

    // MARK: - Creating

    func testSyncMakesOneLauncherPerAccount() throws {
        let report = try launchers.sync(Roster(profiles: [ramit, anaya]))

        XCTAssertEqual(report.created.sorted(), ["Claude – anaya", "Claude – ramit"])
        XCTAssertEqual(appNames(), ["Claude – anaya.app", "Claude – ramit.app"])

        let url = launchers.folder.appendingPathComponent("Claude – ramit.app")
        let plist = try info(url)
        XCTAssertEqual(plist[DesktopLaunchers.Key.profile] as? String, ramit.id.uuidString)
        XCTAssertEqual(plist[DesktopLaunchers.Key.dataDirectory] as? String,
                       launchers.dataDirectory(for: ramit.id).path)
        XCTAssertEqual(plist[DesktopLaunchers.Key.claudeApp] as? String, claudeApp.path)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "JanusLauncher")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertNil(plist["CFBundleIconName"], "An asset-catalog icon name would hide the .icns")

        let executable = url.appendingPathComponent("Contents/MacOS/JanusLauncher")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        XCTAssertEqual(try icon(url), "icns logo=default initial=R")
    }

    func testEveryLauncherHasItsOwnBundleIdentifier() throws {
        try launchers.sync(Roster(profiles: [ramit, anaya]))
        let identifiers = try launchers.installed().map { try info($0.url)["CFBundleIdentifier"] as? String }
        XCTAssertEqual(Set(identifiers).count, 2)
        XCTAssertFalse(identifiers.contains(DesktopLaunchers.claudeBundleID))
    }

    func testDataDirectoryIsKeyedByAccountNotAddress() {
        XCTAssertTrue(launchers.dataDirectory(for: ramit.id).path.hasSuffix(ramit.id.uuidString))
        XCTAssertFalse(launchers.dataDirectory(for: ramit.id).path.contains("ramit@"))
    }

    // MARK: - Updating

    func testASecondSyncWithNothingChangedTouchesNothing() throws {
        try launchers.sync(Roster(profiles: [ramit, anaya]))
        registrar.signed = []

        let report = try launchers.sync(Roster(profiles: [ramit, anaya]))

        XCTAssertFalse(report.changed)
        XCTAssertEqual(report.unchanged, 2)
        XCTAssertEqual(registrar.signed, [])
    }

    func testChoosingALogoRebuildsOnlyThatLauncher() throws {
        try launchers.sync(Roster(profiles: [ramit, anaya]))

        let source = home.appendingPathComponent("logo.png")
        try Data("IMG-ramit".utf8).write(to: source)
        try launchers.setLogo(from: source, for: ramit.id)

        let report = try launchers.sync(Roster(profiles: [ramit, anaya]))
        XCTAssertEqual(report.updated, ["Claude – ramit"])
        XCTAssertEqual(report.unchanged, 1)

        let url = try XCTUnwrap(launchers.launcher(for: ramit.id))
        XCTAssertEqual(try icon(url), "icns logo=IMG-ramit initial=R")

        launchers.removeLogo(for: ramit.id)
        XCTAssertEqual(try launchers.sync(Roster(profiles: [ramit, anaya])).updated, ["Claude – ramit"])
        XCTAssertEqual(try icon(url), "icns logo=default initial=R")
    }

    func testAFileThatIsNotAnImageIsRefusedAsALogo() throws {
        let source = home.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: source)
        XCTAssertThrowsError(try launchers.setLogo(from: source, for: ramit.id)) {
            XCTAssertEqual($0 as? DesktopLauncherError, .unreadableLogo("notes.txt"))
        }
        XCTAssertFalse(launchers.hasCustomLogo(ramit.id))
    }

    func testAClaudeUpdateRedrawsTheDefaultIcons() throws {
        try launchers.sync(Roster(profiles: [ramit]))
        try writeClaudeVersion("2.0.0")
        XCTAssertEqual(try launchers.sync(Roster(profiles: [ramit])).updated, ["Claude – ramit"])
    }

    func testAnAddressChangeRenamesTheLauncherAndKeepsItsData() throws {
        try launchers.sync(Roster(profiles: [ramit]))
        var renamed = ramit
        renamed.email = "ramit.v@example.com"

        let report = try launchers.sync(Roster(profiles: [renamed]))

        XCTAssertEqual(report.updated, ["Claude – ramit.v"])
        XCTAssertEqual(appNames(), ["Claude – ramit.v.app"])
        XCTAssertEqual(try info(try XCTUnwrap(launchers.launcher(for: ramit.id)))[DesktopLaunchers.Key.dataDirectory] as? String,
                       launchers.dataDirectory(for: ramit.id).path)
    }

    // MARK: - Removing

    func testRemovingAnAccountRemovesItsLauncherButNotItsData() throws {
        try launchers.sync(Roster(profiles: [ramit, anaya]))
        let data = launchers.dataDirectory(for: anaya.id)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

        let report = try launchers.sync(Roster(profiles: [ramit]))

        XCTAssertEqual(report.removed, ["Claude – anaya"])
        XCTAssertEqual(registrar.discarded, ["Claude – anaya.app"])
        XCTAssertEqual(appNames(), ["Claude – ramit.app"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path),
                      "The desktop app's chats and sign-in are not Janus's to delete")
    }

    func testAnEmptyRosterRemovesEveryLauncher() throws {
        try launchers.sync(Roster(profiles: [ramit, anaya]))
        let report = try launchers.sync(Roster())
        XCTAssertEqual(report.removed.count, 2)
        XCTAssertEqual(appNames(), [])
    }

    func testAppsJanusDidNotMakeAreLeftAlone() throws {
        try FileManager.default.createDirectory(
            at: launchers.folder.appendingPathComponent("Something Else.app/Contents"),
            withIntermediateDirectories: true)

        try launchers.sync(Roster(profiles: [ramit]))
        try launchers.sync(Roster())

        XCTAssertEqual(appNames(), ["Something Else.app"])
        XCTAssertEqual(registrar.discarded, ["Claude – ramit.app"])
    }

    func testAnUnmarkedAppWhereALauncherShouldGoIsNotOverwritten() throws {
        let squatter = launchers.folder.appendingPathComponent("Claude – ramit.app/Contents")
        try FileManager.default.createDirectory(at: squatter, withIntermediateDirectories: true)

        XCTAssertThrowsError(try launchers.sync(Roster(profiles: [ramit]))) {
            XCTAssertEqual($0 as? DesktopLauncherError, .nameTaken("Claude – ramit.app"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: squatter.path))
    }

    // MARK: - Names

    func testAccountsSharingANameAreToldApartByAddress() {
        let work = Profile(email: "dev@work.com")
        let home = Profile(email: "dev@home.com")
        let names = launchers.launcherNames(for: [work, home, ramit])
        XCTAssertEqual(names[work.id], "Claude – dev@work.com")
        XCTAssertEqual(names[home.id], "Claude – dev@home.com")
        XCTAssertEqual(names[ramit.id], "Claude – ramit")
    }

    func testNamesCannotEscapeTheFolder() {
        XCTAssertEqual(DesktopLaunchers.sanitize("a/b:c"), "a-b-c")
        XCTAssertEqual(DesktopLaunchers.sanitize("   "), "account")
    }

    // MARK: - Preconditions

    func testNoClaudeMeansNoLaunchers() throws {
        try FileManager.default.removeItem(at: claudeApp)
        XCTAssertThrowsError(try launchers.sync(Roster(profiles: [ramit]))) {
            XCTAssertEqual($0 as? DesktopLauncherError, .claudeNotInstalled(claudeApp.path))
        }
        XCTAssertEqual(appNames(), [])
    }

    func testTheDefaultBadgeColourIsStableForAnAccount() {
        XCTAssertEqual(DesktopLaunchers.tint(for: ramit.id), DesktopLaunchers.tint(for: ramit.id))
    }
}

/// The real drawing, `iconutil` and `codesign`, in a scratch folder. Skipped
/// where there is no Claude to draw the default icon from or no built launcher.
final class DesktopLauncherIntegrationTests: XCTestCase {

    func testRealLaunchersAreSignedAndCarryAnIcon() throws {
        let claude = DesktopLaunchers.defaultClaudeApp
        try XCTSkipUnless(FileManager.default.fileExists(atPath: claude.path), "Claude is not installed")

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ["debug", "release"]
            .map { repository.appendingPathComponent(".build/\($0)/JanusLauncher") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        let launcher = try XCTUnwrap(binary, "Build the package first")

        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("janus-launcher-integration/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        /// Signs for real but never registers with LaunchServices, so the
        /// scratch launcher does not show up in Spotlight.
        struct SignOnly: LauncherRegistrar {
            func sign(_ bundle: URL) throws { try SystemRegistrar().sign(bundle) }
            func register(_ bundle: URL) throws {}
            func discard(_ bundle: URL) throws { try FileManager.default.removeItem(at: bundle) }
        }

        let launchers = DesktopLaunchers(folder: home.appendingPathComponent("Apps"),
                                         root: home.appendingPathComponent("vault"),
                                         claudeApp: claude,
                                         launcherExecutable: launcher,
                                         registrar: SignOnly())
        let profile = Profile(email: "integration@example.com")

        // A logo that is a real PNG, drawn and then read back.
        let logo = try XCTUnwrap(SystemIconRenderer().normalizedLogo(
            try XCTUnwrap(NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
                NSColor.systemPurple.setFill(); rect.fill(); return true
            }.tiffRepresentation)))
        let source = home.appendingPathComponent("logo.png")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try logo.write(to: source)

        for withLogo in [false, true] {
            if withLogo { try launchers.setLogo(from: source, for: profile.id) }
            try launchers.sync(Roster(profiles: [profile]))

            let app = try XCTUnwrap(launchers.launcher(for: profile.id))
            let verify = try Command.run("/usr/bin/codesign", ["--verify", "--strict", app.path])
            XCTAssertTrue(verify.succeeded, "codesign rejected the launcher")

            let icns = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
            let image = try XCTUnwrap(NSImage(contentsOf: icns))
            XCTAssertEqual(image.size.width, 512, accuracy: 1)
        }
    }

    /// macOS 26 shrinks an icon onto a grey tile when its outline is not the
    /// standard rounded square, and a badge sticking out of a corner was enough.
    func testIconsStayInsideTheRoundedSquare() throws {
        let claude = DesktopLaunchers.defaultClaudeApp
        try XCTSkipUnless(FileManager.default.fileExists(atPath: claude.path), "Claude is not installed")

        let renderer = SystemIconRenderer()
        let banner = try XCTUnwrap(renderer.normalizedLogo(
            try XCTUnwrap(NSImage(size: NSSize(width: 400, height: 100), flipped: false) { rect in
                NSColor.systemPurple.setFill(); rect.fill(); return true
            }.tiffRepresentation)))

        // Without a logo the badge sits on Claude's icon, so it must not reach
        // past the edge of Claude's own.
        let plain = try renderer.icns(logo: nil, claudeApp: claude, initial: "R", tint: 0)
        assertBounds(try opaqueBounds(of: try XCTUnwrap(NSImage(data: plain))),
                     equal: try opaqueBounds(of: NSWorkspace.shared.icon(forFile: claude.path)))

        let withLogo = try renderer.icns(logo: banner, claudeApp: claude, initial: "R", tint: 0)
        assertBounds(try opaqueBounds(of: try XCTUnwrap(NSImage(data: withLogo))),
                     equal: SystemIconRenderer.plate(in: NSRect(x: 0, y: 0, width: 1024, height: 1024)))
    }

    /// The rectangle round every pixel that is at least half opaque, with the
    /// image drawn at 1024 pixels.
    private func opaqueBounds(of image: NSImage) throws -> NSRect {
        let side = 1024
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                    pixelsWide: side, pixelsHigh: side,
                                                    bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        let pixels = try XCTUnwrap(bitmap.bitmapData)
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where pixels[y * bitmap.bytesPerRow + x * 4 + 3] >= 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Equal to within a couple of pixels, which is what antialiasing moves an edge.
    private func assertBounds(_ actual: NSRect, equal expected: NSRect,
                              file: StaticString = #filePath, line: UInt = #line) {
        for (edge, expectedEdge) in [(actual.minX, expected.minX), (actual.minY, expected.minY),
                                     (actual.maxX, expected.maxX), (actual.maxY, expected.maxY)] {
            XCTAssertEqual(edge, expectedEdge, accuracy: 2,
                           "Drawn over \(actual), expected \(expected)", file: file, line: line)
        }
    }
}

final class ProcessArgumentsTests: XCTestCase {

    private func procargs(argc: Int32, _ strings: [String], padding: Int = 3) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array("/Applications/Claude.app/Contents/MacOS/Claude".utf8)
        bytes += [UInt8](repeating: 0, count: padding)
        for string in strings { bytes += Array(string.utf8) + [0] }
        return bytes
    }

    func testReadsArgumentsAndStopsBeforeTheEnvironment() {
        let bytes = procargs(argc: 2, ["/Applications/Claude.app/Contents/MacOS/Claude",
                                       "--user-data-dir=/tmp/a b",
                                       "HOME=/Users/someone"])
        XCTAssertEqual(ProcessArguments.parse(bytes),
                       ["/Applications/Claude.app/Contents/MacOS/Claude", "--user-data-dir=/tmp/a b"])
    }

    func testToleratesATruncatedBuffer() {
        XCTAssertEqual(ProcessArguments.parse([1, 0]), [])
        XCTAssertEqual(ProcessArguments.parse(procargs(argc: 5, ["only"])), ["only"])
    }

    func testReadsThisProcess() {
        XCTAssertFalse(ProcessArguments.of(getpid()).isEmpty)
    }
}
