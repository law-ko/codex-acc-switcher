import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    static let accountLimit = 100
    @Published var accounts: [AccountSnapshot] = []
    @Published var currentID: String?
    @Published var isRefreshing = false
    @Published var error: String?

    private let client = CodexUsageClient()
    private let storageURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storageURL = support.appendingPathComponent("CodexLimitBar/accounts.json")
        let saved = (try? JSONDecoder().decode([AccountSnapshot].self, from: Data(contentsOf: storageURL))) ?? []
        accounts = Array(saved.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.accountLimit))
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }

    var menuTitle: String {
        guard let current = accounts.first(where: { $0.id == currentID }), let score = current.score(at: Date()) else {
            return "Codex"
        }
        return "Codex \(Int(score.rounded()))%"
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await client.fetch()
            currentID = snapshot.id
            accounts.removeAll {
                $0.id == snapshot.id || (!$0.id.contains("|") && $0.email.caseInsensitiveCompare(snapshot.email) == .orderedSame)
            }
            accounts.append(snapshot)
            accounts = Array(accounts.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.accountLimit))
            accounts = AccountChooser.ordered(accounts: accounts, currentID: currentID, now: Date())
            try save()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func forget(_ account: AccountSnapshot) {
        guard account.id != currentID else { return }
        accounts.removeAll { $0.id == account.id }
        try? save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(accounts).write(to: storageURL, options: .atomic)
    }
}

@main
struct CodexLimitBarApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
                .frame(width: 430)
        } label: {
            Label(store.menuTitle, systemImage: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let orderedAccounts = AccountChooser.ordered(accounts: store.accounts, currentID: store.currentID, now: Date())
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex limits").font(.headline)
                    Text("Current CLI login updates every 5 minutes")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless).disabled(store.isRefreshing).help("Refresh now")
            }

            recommendation

            if store.accounts.isEmpty && store.error == nil {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark").font(.largeTitle)
                    Text("No accounts yet").font(.headline)
                    Text("Sign in with the Codex CLI, then refresh.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 170)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(orderedAccounts.enumerated()), id: \.element.id) { index, account in
                            AccountRow(
                                account: account,
                                rank: index + 1,
                                isCurrent: account.id == store.currentID,
                                isNext: account.id != store.currentID && index == (store.currentID == nil ? 0 : 1)
                            )
                                .contextMenu {
                                    if account.id != store.currentID {
                                        Button("Forget account", role: .destructive) { store.forget(account) }
                                    }
                                }
                        }
                    }
                }.frame(height: min(560, max(320, CGFloat(store.accounts.count) * 200 + 20)))
            }

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Text("\(store.accounts.count)/\(UsageStore.accountLimit) accounts · Switch login, then refresh once.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if #available(macOS 14, *) {
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Preferences")
                } else {
                    Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: {
                        Image(systemName: "gearshape")
                    }.buttonStyle(.plain).help("Preferences")
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var recommendation: some View {
        let result = AccountChooser.next(accounts: store.accounts, excluding: store.currentID, now: Date())
        switch result {
        case .switchNow(let account):
            Label {
                Text("Switch next: **\(account.email)**")
            } icon: { Image(systemName: "arrow.triangle.swap") }
            .foregroundStyle(.green)
        case .wait(let account, let date):
            Label("Next available: \(account.email) · \(date.formatted(date: .abbreviated, time: .shortened))",
                  systemImage: "clock")
                .foregroundStyle(.orange)
        case .none:
            Label("No other account recorded", systemImage: "person.2")
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class LaunchAtLoginSetting: ObservableObject {
    @Published var isEnabled = false
    @Published var requiresApproval = false
    @Published var error: String?

    init() { reload() }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        reload()
    }

    private func reload() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }
}

struct PreferencesView: View {
    @StateObject private var launchAtLogin = LaunchAtLoginSetting()

    var body: some View {
        Form {
            Toggle("Start Codex Limit Bar at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            if launchAtLogin.requiresApproval {
                Text("Approval is required in System Settings → General → Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error = launchAtLogin.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440, height: 190)
    }
}

struct AccountRow: View {
    let account: AccountSnapshot
    let rank: Int
    let isCurrent: Bool
    let isNext: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(rank)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: Circle())
                Text(account.email).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1)
                if isCurrent { Text("CURRENT").font(.system(size: 9, weight: .bold)).foregroundStyle(.blue) }
                else if isNext { Text("NEXT").font(.system(size: 9, weight: .bold)).foregroundStyle(.green) }
                Spacer()
                Text(account.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            LimitRow(title: "5 hour", window: account.session)
            LimitRow(title: "Weekly", window: account.weekly)
            ResetCreditsRow(credits: account.resetCredits)
        }
        .padding(12)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct ResetCreditsRow: View {
    let credits: ResetCredits?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("Resets", systemImage: "arrow.counterclockwise.circle")
                Spacer()
                Text(credits.map { "\($0.available) available" } ?? "Not checked")
            }
            .font(.caption)
            if let credits, credits.available > 0 {
                Text(expiryText(credits))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func expiryText(_ credits: ResetCredits) -> String {
        guard !credits.expiries.isEmpty else { return "Expiry dates unavailable" }
        let dates = credits.expiries.map { $0.formatted(date: .abbreviated, time: .shortened) }.joined(separator: ", ")
        let missing = max(0, credits.available - credits.expiries.count)
        return "Expires: \(dates)" + (missing > 0 ? " · \(missing) without expiry" : "")
    }
}

struct LimitRow: View {
    let title: String
    let window: LimitWindow?

    var body: some View {
        let remaining = window?.effectiveRemaining(at: Date())
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 48, alignment: .leading)
            ProgressView(value: remaining ?? 0, total: 100).tint(color(for: remaining ?? 0))
            Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
            Text(resetText).font(.caption2).foregroundStyle(.secondary).frame(width: 94, alignment: .trailing)
        }
    }

    private var resetText: String {
        guard let reset = window?.resetsAt else { return "No reset time" }
        if reset <= Date() { return "Reset available" }
        return "↻ " + reset.formatted(date: reset.timeIntervalSinceNow > 86_400 ? .abbreviated : .omitted, time: .shortened)
    }

    private func color(for value: Double) -> Color {
        value > 40 ? .green : value > 15 ? .orange : .red
    }
}
