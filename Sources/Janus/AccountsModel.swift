import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import JanusCore

/// One account's figures and where they came from, which is what decides how the
/// row is allowed to describe itself.
struct Reading: Equatable {
    let usage: Usage
    let source: UsageSource
}

/// Everything the interface knows about accounts, and the only place it asks for
/// anything to change.
///
/// Reading off the disk is cheap and happens often: it touches files and asks the
/// keychain whether entries exist, but never asks for a secret, so the window
/// redrawing itself can never raise a permission prompt. Only a switch, or a
/// fetch, does that.
@MainActor
final class AccountsModel: ObservableObject {

    /// How often the window re-reads the disk and moves its clocks on.
    ///
    /// Half a minute is chosen against what is on screen rather than against what
    /// it costs: the finest thing shown is a countdown in whole minutes, so this
    /// is the longest interval that can never show a minute that has passed.
    static let tick: TimeInterval = 30

    @Published private(set) var roster = Roster()
    @Published private(set) var readings: [UUID: Reading] = [:]
    @Published private(set) var restorable: Set<UUID> = []
    @Published private(set) var signedInEmail: String?
    @Published private(set) var isWorking = false
    @Published private(set) var outcome: Outcome?
    @Published private(set) var failure: String?

    /// The Claude desktop launcher each account has, and what it looks like.
    @Published private(set) var desktopApps: [UUID: DesktopApp] = [:]

    /// What the last launcher sync did, or why it could not.
    @Published private(set) var desktopStatus: String?
    @Published private(set) var desktopStatusIsError = false
    @Published private(set) var isSyncingDesktop = false

    /// The moment every countdown and every "has this window reset yet" is
    /// measured against.
    ///
    /// Published, and therefore the reason the window changes on its own. Reading
    /// the clock inside a view instead would be read once, at the moment the row
    /// was drawn, and a row drawn at nine o'clock would still be saying "resets in
    /// 2h 22m" at midnight.
    @Published private(set) var now = Date()

    /// Figures fetched from Anthropic, kept apart from what the disk says so that
    /// re-reading the disk cannot quietly undo them.
    private var fetched: [UUID: Usage] = [:]

    /// Why the last fetch for each account failed, cleared by the next one that
    /// succeeds. Kept per account so the row can say it, rather than go on
    /// advising a Refresh that has already been tried.
    @Published private(set) var fetchFailures: [UUID: String] = [:]

    private let switcher: Switcher
    let launchers: DesktopLaunchers
    private var ticker: Timer?

    init(switcher: Switcher = Switcher(), launchers: DesktopLaunchers = DesktopLaunchers()) {
        self.switcher = switcher
        self.launchers = launchers
        reload()
        startTicking()
    }

    deinit { ticker?.invalidate() }

    // MARK: - Derived state

    var profiles: [Profile] { roster.profiles }

    /// The account signed in right now. The settings file wins over the roster's
    /// record of it, so signing in outside the app still shows up correctly.
    var active: Profile? { roster.active(signedInAs: signedInEmail) }

    var next: Profile? { roster.successor(to: active) }

    /// True when the signed-in account is one Janus already knows about.
    var currentAccountIsManaged: Bool {
        guard let signedInEmail else { return false }
        return roster.profile(withEmail: signedInEmail) != nil
    }

    /// An account can only be switched to if its saved session is still intact.
    func canRestore(_ profile: Profile) -> Bool {
        restorable.contains(profile.id)
    }

    func isActive(_ profile: Profile) -> Bool {
        profile.id == active?.id
    }

    func reading(for profile: Profile) -> Reading? {
        readings[profile.id]
    }

    func fetchFailure(for profile: Profile) -> String? {
        fetchFailures[profile.id]
    }

    // MARK: - The clock

    /// Starts the timer that keeps the window honest while nobody is touching it.
    ///
    /// Scheduled in `.common` mode rather than the default, or it would stop for
    /// as long as a menu is open or a window is being dragged — which is to say,
    /// during exactly the moments somebody is looking at it.
    private func startTicking() {
        let ticker = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        ticker.tolerance = Self.tick / 4
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func tick() {
        let previous = now
        now = Date()

        // Re-read, because figures on disk move while the window sits open: Claude
        // Code writes new ones as a session runs. Three file reads, which is cheap
        // enough to spend every half minute.
        reload()

        // A window turning over is the one moment worth spending a request on
        // without being asked. The number on screen has just become the spend of a
        // window that has ended, and there is no honest way to guess its
        // replacement — but there is a way to go and get it.
        if crossedAReset(between: previous, and: now) { fetch(because: .aWindowReset) }
    }

    private func crossedAReset(between previous: Date, and now: Date) -> Bool {
        readings.values.contains { reading in
            [reading.usage.fiveHour, reading.usage.sevenDay]
                .compactMap { $0?.resetsAt }
                .contains { $0 > previous && $0 <= now }
        }
    }

    // MARK: - Reading

    func reload() {
        // Claude Code writes fresh figures into the live settings file as it
        // goes. Folding them into the signed-in account's saved copy here is what
        // stops those figures being lost the moment it is switched away from.
        switcher.captureLiveUsage()

        roster = (try? switcher.roster()) ?? Roster()
        signedInEmail = switcher.liveSettings()?.email

        var restorable: Set<UUID> = []
        var readings: [UUID: Reading] = [:]

        for profile in roster.profiles {
            if switcher.hasSavedSession(profile) { restorable.insert(profile.id) }

            let live = isActive(profile)
            let reading = best(onDisk: switcher.usage(for: profile, isActive: live),
                               from: live ? .liveSettings : .savedSettings,
                               fetched: fetched[profile.id])
            let desktop = launchers.recordedUsage(for: profile.id)
            if let reading = newer(desktop, than: reading) { readings[profile.id] = reading }
        }

        self.restorable = restorable
        self.readings = readings
        reloadDesktopApps()

        // An account that has been removed keeps nothing behind it.
        let known = Set(roster.profiles.map(\.id))
        fetched = fetched.filter { known.contains($0.key) }
        fetchFailures = fetchFailures.filter { known.contains($0.key) }
    }

    /// Which of the two sets of figures for an account to believe.
    ///
    /// Whichever was measured later, and the disk is allowed to win: the
    /// signed-in account's file is written by Claude Code as it works, so a
    /// fetch from five minutes ago is genuinely the older answer by then.
    ///
    /// "Later" means later by a second, not by any amount at all. A fetched
    /// reading is written to the saved file as well, as milliseconds since 1970
    /// and back, and a round trip through that costs a fraction of a fraction of
    /// a second — enough for a figure to come back from the disk looking newer
    /// than the fetch it came from, and be labelled as a memory of it.
    private func best(onDisk: Usage?, from source: UsageSource, fetched: Usage?) -> Reading? {
        guard let fetched else {
            return onDisk.map { Reading(usage: $0, source: source) }
        }
        if let onDisk, let written = onDisk.measuredAt, let asked = fetched.measuredAt,
           written > asked.addingTimeInterval(1) {
            return Reading(usage: onDisk, source: source)
        }
        return Reading(usage: fetched, source: .fetched)
    }

    /// The desktop app's figures in place of `reading`, when they are newer by
    /// more than a second.
    ///
    /// They carry no reset times of their own, so they borrow the ones `reading`
    /// knows for any window still running when the app took its sample. That
    /// keeps "resets in …" on screen, and keeps the tick able to see a reset
    /// coming.
    private func newer(_ desktop: Usage?, than reading: Reading?) -> Reading? {
        guard let desktop, let logged = desktop.measuredAt else { return reading }
        if let reading, let measured = reading.usage.measuredAt,
           logged <= measured.addingTimeInterval(1) {
            return reading
        }
        return Reading(usage: desktop.carryingResets(from: reading?.usage), source: .desktopApp)
    }

    // MARK: - Asking Anthropic

    private enum Prompting {
        case theRefreshButton
        case aWindowReset
    }

    /// The Refresh button: re-read the disk, bring the desktop launchers in line
    /// with the roster, then go and ask for the real numbers.
    func refresh() {
        guard !isWorking else { return }
        reload()

        // Before the empty-roster check below, so removing the last account
        // still removes its launcher.
        syncDesktopApps()

        // With nothing saved there is nobody to ask on behalf of, and a button
        // that does nothing at all reads as a button that is broken.
        guard !profiles.isEmpty else {
            failure = nil
            outcome = Outcome("Nothing to refresh yet.",
                              notes: ["Save an account and its figures appear here."])
            return
        }

        fetch(because: .theRefreshButton)
    }

    /// Fetches every account's current figures, including the ones not signed in.
    ///
    /// Sequential rather than all at once. There are two or three accounts, each
    /// request takes a moment, and doing them in turn keeps the keychain reads in
    /// a predictable order instead of racing each other for the same tool.
    private func fetch(because prompting: Prompting) {
        guard !isWorking, !profiles.isEmpty else { return }
        isWorking = true
        failure = nil

        // A fetch nobody asked for leaves whatever was on screen where it is.
        if prompting == .theRefreshButton {
            outcome = Outcome("Refreshing…",
                              notes: ["Asking Anthropic for each account's current figures."])
        }

        let targets = profiles.map { ($0, isActive($0)) }
        let switcher = switcher
        let moment = Date()

        Task {
            defer { isWorking = false }

            var measured: [UUID: Usage] = [:]
            var refused: [UUID: String] = [:]

            for (profile, live) in targets {
                do {
                    measured[profile.id] = try await switcher.fetchUsage(for: profile,
                                                                         isActive: live,
                                                                         now: moment)
                } catch {
                    refused[profile.id] = error.localizedDescription
                }
            }

            for (id, usage) in measured {
                fetched[id] = usage
                fetchFailures[id] = nil
            }
            for (id, reason) in refused { fetchFailures[id] = reason }
            now = Date()
            reload()

            // A fetch nobody asked for says nothing when it fails. The figures it
            // was going to replace are still on screen and still labelled with
            // when they were taken, and an error appearing by itself in a window
            // nobody touched is worse than the silence.
            if prompting == .theRefreshButton || refused.isEmpty {
                outcome = summary(measured: measured, refused: refused, prompting: prompting)
            }
        }
    }

    private func summary(measured: [UUID: Usage],
                         refused: [UUID: String],
                         prompting: Prompting) -> Outcome {
        var notes: [String] = []

        if !measured.isEmpty {
            let names = profiles.filter { measured[$0.id] != nil }.map(\.email)
            notes.append("\(Self.list(names)) measured just now, straight from Anthropic.")
        }

        for profile in profiles {
            if let reason = refused[profile.id] { notes.append("\(profile.email): \(reason)") }
        }

        // Said once, at the bottom, for whoever is looking at a figure that did
        // not move: what is on screen is still true of the moment it was taken.
        if !refused.isEmpty {
            notes.append("""
                         Accounts that could not be fetched keep the last figures Claude Code \
                         measured for them, which is what the line under each bar is dated by.
                         """)
        }

        // Not "could not reach Anthropic": reaching it and being turned away is a
        // different thing, and each account's own line above says which it was.
        if measured.isEmpty {
            return Outcome("Could not fetch the current figures.", notes: notes)
        }
        if prompting == .aWindowReset {
            return Outcome("A limit started over, so the figures were fetched again.", notes: notes)
        }
        return Outcome("Refreshed.", notes: notes)
    }

    /// "a@b.com and c@d.com", rather than a comma-separated list of two.
    private static func list(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - Acting

    func addCurrentAccount() {
        perform(thenSyncDesktop: true) { try $0.adoptCurrentAccount() }
    }

    func switchTo(_ profile: Profile) {
        perform { try $0.activate(profile.id) }
    }

    func switchToNext() {
        perform { try $0.switchToNext() }
    }

    func remove(_ profile: Profile) {
        perform(thenSyncDesktop: true) { try $0.remove(profile.id) }
    }

    func tidy() {
        perform { try $0.tidy() }
    }

    func move(_ profile: Profile, by offset: Int) {
        perform {
            try $0.reorder(profile.id, by: offset)
            return nil
        }
    }

    func dismissMessage() {
        outcome = nil
        failure = nil
    }

    /// Runs one operation away from the main thread.
    ///
    /// Switching can stop to ask macOS for keychain permission, and that wait
    /// belongs anywhere except the thread drawing the window.
    private func perform(thenSyncDesktop: Bool = false,
                         _ work: @escaping @Sendable (Switcher) throws -> Outcome?) {
        guard !isWorking else { return }
        isWorking = true
        outcome = nil
        failure = nil
        // A switch or a save is how a refused sign-in gets mended, so what the
        // last fetch said stops being true here. The next fetch says it again
        // if it still is.
        fetchFailures = [:]

        // macOS draws a keychain prompt in front of the app that asked for it, so
        // an app still in the background gets one nobody can see, and every button
        // stays disabled behind it. Coming forward first is what keeps a switch
        // waiting on a prompt from looking like a switch that has hung.
        NSApp.activate(ignoringOtherApps: true)

        let switcher = switcher
        Task {
            // The flag disables the whole interface, so it has to come back down
            // on every path out of here, cancellation included.
            defer {
                isWorking = false
                reload()
                if thenSyncDesktop { syncDesktopApps() }
            }

            let result = await Task.detached { () -> Result<Outcome?, Error> in
                do { return .success(try work(switcher)) } catch { return .failure(error) }
            }.value

            switch result {
            case .success(let value): outcome = value
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
}

// MARK: - The Claude desktop app

/// One account's launcher, as the row needs it.
struct DesktopApp: Equatable {
    let url: URL
    let icon: NSImage?
    let isRunning: Bool
    let hasCustomLogo: Bool
}

extension AccountsModel {

    func desktopApp(for profile: Profile) -> DesktopApp? {
        desktopApps[profile.id]
    }

    var isClaudeDesktopInstalled: Bool { launchers.isClaudeInstalled }

    /// Reads what is in the launcher folder. Touches files and the process
    /// list only, so it is cheap enough for every tick.
    func reloadDesktopApps() {
        var apps: [UUID: DesktopApp] = [:]
        for launcher in launchers.installed() {
            let iconURL = launcher.url.appendingPathComponent("Contents/Resources/AppIcon.icns")
            apps[launcher.id] = DesktopApp(url: launcher.url,
                                           icon: NSImage(contentsOf: iconURL),
                                           isRunning: launchers.isRunning(launcher.id),
                                           hasCustomLogo: launchers.hasCustomLogo(launcher.id))
        }
        desktopApps = apps
    }

    /// Creates, updates and deletes launchers until there is exactly one, current,
    /// for every saved account. Off the main thread: a changed launcher is drawn,
    /// packed by `iconutil` and signed by `codesign`.
    func syncDesktopApps() {
        guard !isSyncingDesktop else { return }
        guard launchers.isClaudeInstalled else {
            desktopStatus = nil
            return
        }
        isSyncingDesktop = true
        let launchers = launchers
        let roster = roster

        Task {
            let result = await Task.detached { () -> Result<DesktopLaunchers.Report, Error> in
                Result { try launchers.sync(roster) }
            }.value

            isSyncingDesktop = false
            switch result {
            case .success(let report):
                desktopStatus = report.summary
                desktopStatusIsError = false
            case .failure(let error):
                desktopStatus = error.localizedDescription
                desktopStatusIsError = true
            }
            reloadDesktopApps()
        }
    }

    /// Opens Claude as this account, making its launcher first if need be.
    func openDesktop(_ profile: Profile) {
        if let app = desktopApps[profile.id] {
            NSWorkspace.shared.open(app.url)
            return
        }
        let launchers = launchers
        let roster = roster
        Task {
            let result = await Task.detached { Result { try launchers.sync(roster) } }.value
            reloadDesktopApps()
            if case .failure(let error) = result {
                desktopStatus = error.localizedDescription
                desktopStatusIsError = true
            } else if let app = desktopApps[profile.id] {
                NSWorkspace.shared.open(app.url)
            }
        }
    }

    func revealDesktop(_ profile: Profile) {
        guard let app = desktopApps[profile.id] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    /// Asks for an image and makes it the account's launcher icon.
    func chooseLogo(for profile: Profile) {
        let panel = NSOpenPanel()
        panel.title = "Choose a logo for \(profile.email)"
        panel.prompt = "Use as Logo"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try launchers.setLogo(from: url, for: profile.id)
            syncDesktopApps()
        } catch {
            desktopStatus = error.localizedDescription
            desktopStatusIsError = true
        }
    }

    func useDefaultLogo(for profile: Profile) {
        launchers.removeLogo(for: profile.id)
        syncDesktopApps()
    }
}
