import AppKit
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published var accounts: [AccountSnapshot] = []
    @Published var currentID: String?
    @Published var isRefreshing = false
    @Published var error: String?

    private let client = CodexUsageClient()
    private let storageURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storageURL = support.appendingPathComponent("CodexLimitBar/accounts.json")
        accounts = (try? JSONDecoder().decode([AccountSnapshot].self, from: Data(contentsOf: storageURL))) ?? []
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
            accounts.removeAll { $0.id == snapshot.id }
            accounts.append(snapshot)
            accounts.sort { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
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
                .frame(width: 390)
                .task { await store.refresh() }
        } label: {
            Label(store.menuTitle, systemImage: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
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
                        ForEach(store.accounts) { account in
                            AccountRow(account: account, isCurrent: account.id == store.currentID)
                                .contextMenu {
                                    if account.id != store.currentID {
                                        Button("Forget account", role: .destructive) { store.forget(account) }
                                    }
                                }
                        }
                    }
                }.frame(maxHeight: 390)
            }

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Text("Switch Codex accounts, then refresh once to remember each one.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
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

struct AccountRow: View {
    let account: AccountSnapshot
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(account.email).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1)
                if isCurrent { Text("CURRENT").font(.system(size: 9, weight: .bold)).foregroundStyle(.blue) }
                Spacer()
                Text(account.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            LimitRow(title: "5 hour", window: account.session)
            LimitRow(title: "Weekly", window: account.weekly)
        }
        .padding(12)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
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
