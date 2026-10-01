import AppKit
import SwiftUI
import JanusCore

/// A row of coloured advice with one thing to do about it.
struct Notice: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(12)
        .background(tint.opacity(0.09))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// What just happened, shown where the button that caused it was.
struct Message: View {
    let outcome: Outcome?
    let failure: String?

    var body: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let outcome {
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.headline).font(.callout)
                ForEach(outcome.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One limit, drawn as a bar. The colour is the warning, not decoration.
///
/// A window whose reset has gone by is drawn empty with a dash in place of the
/// percentage. The last figure is not the current one and there is no honest way
/// to guess what replaced it, so the bar says nothing rather than saying the old
/// number again.
///
/// `now` is handed in rather than read here, so that the moment the whole window
/// is drawn against is one moment, and so that it moving is something the model
/// can cause. A bar that read the clock itself would read it once, when it was
/// first drawn, and go on believing that answer all evening.
struct LimitBar: View {
    let caption: String
    let window: Usage.Window
    let now: Date

    private var hasReset: Bool { window.hasReset(by: now) }

    private var tint: Color {
        switch window.percentUsed {
        case ..<50: return .green
        case ..<80: return .yellow
        default:    return .orange
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    // Nothing spent draws nothing. The floor below is there to
                    // keep 1% visible rather than to give 0% something to show,
                    // and a window that has just started over is exactly where a
                    // sliver of colour would be read as a sliver of spend.
                    if !hasReset, window.percentUsed > 0 {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(2, geometry.size.width
                                                 * Double(min(window.percentUsed, 100)) / 100))
                    }
                }
            }
            .frame(width: 88, height: 5)

            Text(hasReset ? "—" : "\(window.percentUsed)%")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(hasReset ? .tertiary : .secondary)
                .frame(width: 34, alignment: .leading)

            if let resets = Elapsed.until(window.resetsAt, now: now) {
                Text(resets)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Both limits plus a line saying how current the figures are, which matters
/// because only one of the three ways they can arrive is current by definition.
struct UsagePanel: View {
    let usage: Usage
    let source: UsageSource
    let now: Date
    var provider = "Anthropic"

    /// Why the last fetch for this account failed. Said in place of the advice to
    /// press Refresh, which has just been shown not to help.
    var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let window = usage.fiveHour {
                LimitBar(caption: "5-hour", window: window, now: now)
            }
            if let window = usage.sevenDay {
                LimitBar(caption: "7-day", window: window, now: now)
            }

            HStack(spacing: 5) {
                Text(freshness)
                if !usage.breakdown.isEmpty {
                    Text("·")
                    Text(usage.breakdown.map { "\($0.label) \($0.percent)%" }
                        .joined(separator: ", "))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if let failure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let advice {
                Text(advice)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var freshness: String {
        let measured = Elapsed.since(usage.measuredAt, now: now)

        switch source {
        case .fetched:
            guard let measured else { return "asked \(provider)" }
            return "asked \(provider) \(measured)"

        case .liveSettings:
            // "current" stops being true the moment a window turns over: the file
            // is still the latest one Claude Code wrote, and that is now old news.
            guard !usage.resetWindows(by: now).isEmpty, let measured else { return "current" }
            return "measured \(measured)"

        case .savedSettings:
            guard let measured else { return "from the last saved session" }
            return "measured \(measured), when last signed in"

        case .desktopApp:
            guard let measured else { return "from the Claude app" }
            return "measured \(measured) in the Claude app"
        }
    }

    /// What to do about a figure that has stopped moving.
    ///
    /// The same answer whichever account it is now, which it was not before: a
    /// window that has turned over can be measured again without signing anybody
    /// in, so the remedy no longer depends on which account is which.
    private var advice: String? {
        guard !usage.resetWindows(by: now).isEmpty else { return nil }
        return "That window has started over. Press Refresh to fetch the new figure."
    }
}

// MARK: - The widget's tiles

/// One square-cornered button in the widget's grid: a symbol, a title, and on the
/// right whatever helps decide whether to press it — the shortcut, a size, or a
/// chevron for a tile that opens a menu.
struct Tile: View {

    enum Trailing {
        case none
        case shortcut(Character)
        case text(String)
        case chevron
    }

    let title: String
    let symbol: String
    var trailing: Trailing = .none
    var isBusy = false
    let action: () -> Void

    init(_ title: String, symbol: String, trailing: Trailing = .none,
         isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                    }
                }
                .font(.system(size: 15))
                .frame(width: 20)

                Text(title)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 4)

                trailingView
            }
        }
        .buttonStyle(TileStyle())
        .modifier(Shortcut(trailing: trailing))
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .shortcut(let key):
            Text("⌘\(String(key).uppercased())")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        case .text(let text):
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        case .chevron:
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// The shortcut shown is the shortcut bound, so the two can never disagree.
    private struct Shortcut: ViewModifier {
        let trailing: Trailing

        func body(content: Content) -> some View {
            if case .shortcut(let key) = trailing {
                content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
            } else {
                content
            }
        }
    }
}

/// A tile that opens a menu where it was clicked.
///
/// The menu is AppKit's rather than SwiftUI's `Menu`, because on macOS a `Menu`
/// draws its label as a pop-up button and ignores any background given to it, so
/// it could not be made to look like the tiles around it.
struct MenuTile: View {

    enum Entry {
        case item(String, isChecked: Bool = false, isEnabled: Bool = true, action: () -> Void)
        case separator
    }

    /// Without a title the tile shrinks to its symbol and chevron, leaving the
    /// rest of the row to the tile beside it.
    var title: String?
    let symbol: String
    let entries: () -> [Entry]

    var body: some View {
        if let title {
            Tile(title, symbol: symbol, trailing: .chevron) { popUp() }
        } else {
            Button { popUp() } label: {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 15))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(TileStyle())
            .frame(width: 62)
        }
    }

    @MainActor private static var showing: NSMenu?

    private func popUp() {
        guard let event = NSApp.currentEvent,
              let view = event.window?.contentView else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries() {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .item(title, isChecked, isEnabled, action):
                let item = ClosureMenuItem(title, handler: action)
                item.state = isChecked ? .on : .off
                item.isEnabled = isEnabled
                menu.addItem(item)
            }
        }

        // Held until the next menu replaces it, so the items, which are their own
        // targets, outlive the call however late AppKit sends the action.
        Self.showing = menu

        // The hosting view is flipped, so the point is converted rather than read
        // straight off the event.
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// The tile's look: a soft rounded square that brightens under the pointer.
struct TileStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        private var fill: Double {
            if configuration.isPressed { return 0.15 }
            return isHovered && isEnabled ? 0.10 : 0.06
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            configuration.label
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(shape.fill(Color.primary.opacity(fill)))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}
