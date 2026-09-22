import Darwin
import Foundation

private struct LaunchHistoryEntry: Codable {
    var count: Int
    var lastLaunchedAt: Date
}

final class LaunchHistoryStore {
    private let fileManager: FileManager
    private let fileURL: URL
    private let legacyFileURL: URL
    private var entries: [String: LaunchHistoryEntry] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let applicationSupportURL = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ??
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        self.fileURL = applicationSupportURL
            .appendingPathComponent("Tendon", isDirectory: true)
            .appendingPathComponent("launch-history.json")
        self.legacyFileURL = applicationSupportURL
            .appendingPathComponent("TakoLauncher", isDirectory: true)
            .appendingPathComponent("launch-history.json")

        load()
    }

    func recordLaunch(of app: LaunchableApp) {
        recordUse(historyKey: app.historyKey)
    }

    func recordUse(historyKey: String) {
        var entry = entries[historyKey] ?? LaunchHistoryEntry(
            count: 0,
            lastLaunchedAt: .distantPast
        )

        entry.count += 1
        entry.lastLaunchedAt = Date()
        entries[historyKey] = entry
        save()
    }

    func sort(_ apps: [LaunchableApp]) -> [LaunchableApp] {
        apps.sorted { lhs, rhs in
            let lhsPriority = sortPriority(for: lhs)
            let rhsPriority = sortPriority(for: rhs)

            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            let lhsEntry = entries[lhs.historyKey]
            let rhsEntry = entries[rhs.historyKey]
            let lhsLastLaunchedAt = lhsEntry?.lastLaunchedAt ?? .distantPast
            let rhsLastLaunchedAt = rhsEntry?.lastLaunchedAt ?? .distantPast

            if lhsLastLaunchedAt != rhsLastLaunchedAt {
                return lhsLastLaunchedAt > rhsLastLaunchedAt
            }

            let lhsCount = lhsEntry?.count ?? 0
            let rhsCount = rhsEntry?.count ?? 0

            if lhsCount != rhsCount {
                return lhsCount > rhsCount
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func sortPriority(for app: LaunchableApp) -> Int {
        switch app.targetKind {
        case .window:
            return 0
        case .application,
             .bookmark,
             .audioInput,
             .audioOutput,
             .webSearch,
             .bluetoothConnect,
             .bluetoothDisconnect:
            return 1
        }
    }

    private func load() {
        if let decodedEntries = entries(from: fileURL) {
            entries = decodedEntries
            return
        }

        if let decodedEntries = entries(from: legacyFileURL) {
            entries = decodedEntries
            save()
            return
        }

        entries = [:]
    }

    private func entries(from fileURL: URL) -> [String: LaunchHistoryEntry]? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let decodedEntries = try? JSONDecoder().decode([String: LaunchHistoryEntry].self, from: data)
        else {
            return nil
        }

        return decodedEntries
    }

    private func save() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            fputs("Failed to save launch history: \(error.localizedDescription)\n", stderr)
        }
    }
}
