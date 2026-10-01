import AppKit
import SwiftUI
import JanusCore

/// What the status item opens: who is signed in to each tool, and a grid of tiles
/// for everything worth doing without opening a window.
///
/// Anything that needs room — reordering, removing, logos, choosing which caches
/// go — stays in the window, one tile away.
struct WidgetView: View {

    @ObservedObject var accounts: AccountsModel
    @ObservedObject var codex: CodexModel
    @ObservedObject var caches: CachesModel

    /// Opens the window at one of its sections.
    let manage: (MainWindow.Section) -> Void

    static let width: CGFloat = 340

    var body: some View {
        VStack(spacing: 10) {
            claudeSection
            Separator()
            codexSection
            Separator()

            HStack(spacing: 8) {
                Tile("Caches", symbol: "internaldrive",
                     trailing: caches.clearableBytes > 0
                        ? .text(DiskUsage.describe(caches.clearableBytes)) : .none,
                     isBusy: caches.isScanning) {
                    caches.scan()
                    manage(.storage)
                }
                Tile("Refresh", symbol: "arrow.clockwise", trailing: .shortcut("r"),
                     isBusy: isRefreshing) { refresh() }
                    .disabled(isRefreshing)
            }

            Separator()

            HStack(spacing: 8) {
                Tile("Manage", symbol: "gearshape", trailing: .shortcut(",")) { manage(.claude) }
                Tile("Quit", symbol: "power", trailing: .shortcut("q")) {
                    NSApplication.shared.terminate(nil)
                }
            }

            Button { AboutPanel.show() } label: {
                Text("Version \(Build.version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("About Janus")
        }
        .padding(14)
        .frame(width: Self.width)
    }

    // MARK: - Claude

    private var claudeSection: some View {
        VStack(spacing: 8) {
            AccountCard(product: "Claude Code",
                        symbol: "sparkle",
                        name: accounts.active?.email ?? accounts.signedInEmail,
                        isSaved: accounts.currentAccountIsManaged,
                        usage: accounts.active.flatMap { accounts.reading(for: $0)?.usage },
                        now: accounts.now)

            HStack(spacing: 8) {
                claudeSwitch
                MenuTile(symbol: "person.2") { claudeEntries }
                    .help("All accounts")
            }

            Message(outcome: accounts.outcome, failure: accounts.failure)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The one-click action: the next account round, or saving the one that is
    /// signed in when Janus does not know it yet. ⌘S, as it has always been.
    @ViewBuilder
    private var claudeSwitch: some View {
        if accounts.isWorking {
            Tile("Working…", symbol: "arrow.triangle.2.circlepath", isBusy: true) {}
                .disabled(true)
        } else if let next = accounts.next, accounts.canRestore(next) {
            Tile("Switch to \(next.shortName)", symbol: "arrow.triangle.2.circlepath",
                 trailing: .shortcut("s")) { accounts.switchToNext() }
                .help("Switch Claude Code to \(next.email)")
        } else if accounts.signedInEmail != nil, !accounts.currentAccountIsManaged {
            Tile("Save Account", symbol: "plus.circle", trailing: .shortcut("s")) {
                accounts.addCurrentAccount()
            }
        } else {
            Tile("Switch", symbol: "arrow.triangle.2.circlepath") {}
                .disabled(true)
                .help("Save a second account to switch between them")
        }
    }

    private var claudeEntries: [MenuTile.Entry] {
        var entries: [MenuTile.Entry] = accounts.profiles.map { profile in
            .item(profile.email,
                  isChecked: accounts.isActive(profile),
                  isEnabled: !accounts.isWorking && !accounts.isActive(profile)
                             && accounts.canRestore(profile),
                  action: { accounts.switchTo(profile) })
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.item("Save Current Account",
                             isEnabled: !accounts.isWorking && accounts.signedInEmail != nil
                                        && !accounts.currentAccountIsManaged,
                             action: { accounts.addCurrentAccount() }))
        entries.append(.item("Manage Accounts…", action: { manage(.claude) }))
        return entries
    }

    // MARK: - Codex

    private var codexSection: some View {
        VStack(spacing: 8) {
            AccountCard(product: "Codex",
                        symbol: "terminal",
                        name: codex.active?.email ?? codex.signedInName,
                        detail: codex.active?.plan?.capitalized,
                        isSaved: codex.currentAccountIsManaged,
                        usage: codex.active.flatMap { codex.reading(for: $0)?.usage },
                        now: codex.now)

            HStack(spacing: 8) {
                codexSwitch
                MenuTile(symbol: "person.2") { codexEntries }
                    .help("All accounts")
            }

            Message(outcome: codex.outcome, failure: codex.failure)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The same for Codex, without a shortcut, so that ⌘S keeps meaning Claude.
    @ViewBuilder
    private var codexSwitch: some View {
        if codex.isWorking {
            Tile("Working…", symbol: "arrow.triangle.2.circlepath", isBusy: true) {}
                .disabled(true)
        } else if let next = codex.next, next.id != codex.active?.id, codex.canRestore(next) {
            Tile("Switch to \(next.shortName)", symbol: "arrow.triangle.2.circlepath") {
                codex.switchToNext()
            }
            .help("Switch Codex to \(next.email). Quit Codex first.")
        } else if codex.signedInName != nil, !codex.currentAccountIsManaged {
            Tile("Save Account", symbol: "plus.circle") { codex.addCurrentAccount() }
        } else {
            Tile("Switch", symbol: "arrow.triangle.2.circlepath") {}
                .disabled(true)
                .help("Save a second Codex account to switch between them")
        }
    }

    private var codexEntries: [MenuTile.Entry] {
        var entries: [MenuTile.Entry] = codex.profiles.map { profile in
            let plan = profile.plan.map { " (\($0.capitalized))" } ?? ""
            return .item(profile.email + plan,
                         isChecked: codex.isActive(profile),
                         isEnabled: !codex.isWorking && !codex.isActive(profile)
                                    && codex.canRestore(profile),
                         action: { codex.switchTo(profile) })
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.item("Save Current Account",
                             isEnabled: !codex.isWorking && codex.signedInName != nil
                                        && !codex.currentAccountIsManaged,
                             action: { codex.addCurrentAccount() }))
        entries.append(.item("Manage Accounts…", action: { manage(.codex) }))
        return entries
    }

    // MARK: - Both

    private var isRefreshing: Bool {
        accounts.isWorking || accounts.isSyncingDesktop || codex.isWorking
    }

    private func refresh() {
        accounts.refresh()
        if !codex.profiles.isEmpty { codex.refresh() }
        caches.scan()
    }
}

/// Who is signed in to one tool, and how much of their limits they have spent.
private struct AccountCard: View {
    let product: String
    let symbol: String
    let name: String?
    var detail: String?
    let isSaved: Bool
    let usage: Usage?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(product)
                Spacer()
                if let detail { Text(detail) }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text(name ?? "Not signed in")
                    .font(.system(size: 13.5, weight: name == nil ? .regular : .semibold))
                    .foregroundStyle(name == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if name != nil, !isSaved {
                    Text("Not saved")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                }
            }

            if let usage {
                VStack(alignment: .leading, spacing: 3) {
                    if let window = usage.fiveHour {
                        LimitBar(caption: "5-hour", window: window, now: now)
                    }
                    if let window = usage.sevenDay {
                        LimitBar(caption: "7-day", window: window, now: now)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The hairline between groups of tiles, inset like the tiles themselves.
private struct Separator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 4)
    }
}
