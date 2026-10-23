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
    private var windowActivationOrder: [String: UInt64] = [:]
    private var latestWindowActivation: UInt64 = 0

    init(fileManager: FileManager = .default, applicationSupportURL: URL? = nil) {
        self.fileManager = fileManager

        let applicationSupportURL = applicationSupportURL ?? fileManager
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
        if app.targetKind == .window, let processIdentifier = app.processIdentifier {
            recordWindowActivation(
                processIdentifier: processIdentifier,
                windowIdentifier: app.windowIdentifier,
                historyKey: app.historyKey
            )
        }
        recordUse(historyKey: app.historyKey)
    }

    func recordWindowActivation(
        processIdentifier: pid_t,
        windowIdentifier: UInt32?,
        historyKey: String?
    ) {
        guard let key = windowActivationKey(
            processIdentifier: processIdentifier,
            windowIdentifier: windowIdentifier,
            historyKey: historyKey
        ) else {
            return
        }

        latestWindowActivation += 1
        windowActivationOrder[key] = latestWindowActivation
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

            if lhs.targetKind == .window, rhs.targetKind == .window {
                let lhsActivation = activationOrder(for: lhs)
                let rhsActivation = activationOrder(for: rhs)
                if lhsActivation != rhsActivation {
                    return lhsActivation > rhsActivation
                }

                // For windows not observed yet, use the current stacking order before
                // persisted launcher history, which misses switches outside Tendon.
                if lhs.windowSortIndex != rhs.windowSortIndex {
                    switch (lhs.windowSortIndex, rhs.windowSortIndex) {
                    case let (lhsIndex?, rhsIndex?):
                        return lhsIndex < rhsIndex
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        break
                    }
                }
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

    private func activationOrder(for app: LaunchableApp) -> UInt64 {
        guard
            let processIdentifier = app.processIdentifier,
            let key = windowActivationKey(
                processIdentifier: processIdentifier,
                windowIdentifier: app.windowIdentifier,
                historyKey: app.historyKey
            )
        else {
            return 0
        }

        if let order = windowActivationOrder[key] {
            return order
        }

        // Accessibility may expose a title without a window ID even when the
        // matching Core Graphics candidate has an ID.
        guard let titleKey = windowActivationKey(
            processIdentifier: processIdentifier,
            windowIdentifier: nil,
            historyKey: app.historyKey
        ) else {
            return 0
        }
        return windowActivationOrder[titleKey] ?? 0
    }

    private func windowActivationKey(
        processIdentifier: pid_t,
        windowIdentifier: UInt32?,
        historyKey: String?
    ) -> String? {
        if let windowIdentifier {
            return "\(processIdentifier):id:\(windowIdentifier)"
        }

        return historyKey.map { "\(processIdentifier):title:\($0)" }
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
             .webURL,
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
