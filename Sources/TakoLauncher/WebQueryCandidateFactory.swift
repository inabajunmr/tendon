import Foundation

enum WebQueryCandidateFactory {
    static func candidate(for query: String) -> LaunchableApp? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return nil
        }

        if let url = webURL(for: trimmedQuery) {
            return makeCandidate(
                name: "URL を開く: \(trimmedQuery)",
                applicationName: nil,
                url: url,
                searchText: trimmedQuery,
                identityKey: "web-url:\(url.absoluteString)",
                targetKind: .webURL
            )
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmedQuery)]
        guard let url = components?.url else {
            return nil
        }

        return makeCandidate(
            name: "Google 検索: \(trimmedQuery)",
            applicationName: "Google",
            url: url,
            searchText: [trimmedQuery, "google", "search", "web"].joined(separator: " "),
            identityKey: "web-search:google:\(trimmedQuery)",
            targetKind: .webSearch
        )
    }

    private static func webURL(for query: String) -> URL? {
        guard query.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }

        let lowercasedQuery = query.lowercased()
        let hasScheme = lowercasedQuery.hasPrefix("https://") || lowercasedQuery.hasPrefix("http://")
        let urlString = hasScheme ? query : "https://\(query)"
        guard
            let components = URLComponents(string: urlString),
            let host = components.host,
            !host.isEmpty,
            let url = components.url
        else {
            return nil
        }

        if !hasScheme {
            guard components.user == nil, components.password == nil, isImplicitWebHost(host) else {
                return nil
            }
        }

        return url
    }

    private static func isImplicitWebHost(_ host: String) -> Bool {
        if host.lowercased() == "localhost" || (host.hasPrefix("[") && host.hasSuffix("]")) {
            return true
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-") &&
                label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else {
            return false
        }

        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
        }

        return labels.last?.contains(where: \.isLetter) == true
    }

    private static func makeCandidate(
        name: String,
        applicationName: String?,
        url: URL,
        searchText: String,
        identityKey: String,
        targetKind: LaunchTargetKind
    ) -> LaunchableApp {
        LaunchableApp(
            name: name,
            applicationName: applicationName,
            url: url,
            bundleIdentifier: nil,
            searchText: searchText,
            identityKey: identityKey,
            historyKey: identityKey,
            processIdentifier: nil,
            isRunning: false,
            targetKind: targetKind,
            windowTitle: nil,
            windowFrame: nil,
            windowIdentifier: nil
        )
    }
}
