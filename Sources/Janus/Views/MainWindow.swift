import SwiftUI
import JanusCore

/// Which section the window shows. Held outside the view so a tile in the widget
/// can open the window at the section it is about.
@MainActor
final class ManageRouter: ObservableObject {
    @Published var section: MainWindow.Section = .claude
}

/// The window behind the widget's Manage tile. One tab for each tool whose
/// accounts it switches, and one for the caches.
struct MainWindow: View {

    @ObservedObject var accounts: AccountsModel
    @ObservedObject var codex: CodexModel
    @ObservedObject var caches: CachesModel
    @ObservedObject var router: ManageRouter

    enum Section: String, CaseIterable, Identifiable {
        case claude = "Claude"
        case codex = "Codex"
        case storage = "Storage"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch router.section {
            case .claude:  AccountsView(model: accounts)
            case .codex:   CodexView(model: codex)
            case .storage: StorageView(model: caches)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            accounts.reload()
            codex.reload()
            caches.scan()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $router.section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Spacer()

            Text(Build.displayVersion)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
