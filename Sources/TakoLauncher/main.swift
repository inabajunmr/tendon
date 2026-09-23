import AppKit
import ApplicationServices
import Carbon
import CoreAudio
import Darwin
import IOBluetooth
import IOKit
import ServiceManagement
import UniformTypeIdentifiers

private struct CoreGraphicsWindowInfo {
    let identifier: UInt32?
    let ownerProcessIdentifier: pid_t
    let ownerName: String?
    let title: String?
    let frame: WindowFrame?

    var hasTitle: Bool {
        title?.isEmpty == false
    }

    var isLargeEnoughForCandidate: Bool {
        guard let frame else {
            return true
        }

        return frame.width >= 80 && frame.height >= 40
    }
}

private enum CoreGraphicsWindowReader {
    static func layerZeroWindows() -> [CoreGraphicsWindowInfo] {
        guard
            let windowInfoList = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return []
        }

        return windowInfoList.compactMap { info in
            guard
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0,
                let ownerProcessIdentifier = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            else {
                return nil
            }

            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let frame = windowFrame(from: bounds)
            let identifier = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value

            return CoreGraphicsWindowInfo(
                identifier: identifier,
                ownerProcessIdentifier: ownerProcessIdentifier,
                ownerName: trimmedString(info[kCGWindowOwnerName as String]),
                title: trimmedString(info[kCGWindowName as String]),
                frame: frame
            )
        }
    }

    static func candidateWindows() -> [CoreGraphicsWindowInfo] {
        layerZeroWindows().filter(\.isLargeEnoughForCandidate)
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func windowFrame(from bounds: [String: Any]?) -> WindowFrame? {
        guard
            let x = (bounds?["X"] as? NSNumber)?.doubleValue,
            let y = (bounds?["Y"] as? NSNumber)?.doubleValue,
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue,
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue
        else {
            return nil
        }

        return WindowFrame(x: x, y: y, width: width, height: height)
    }
}

private enum WindowHistoryKey {
    static func make(appHistoryKey: String, title: String, applicationName: String?) -> String {
        let normalizedTitle = normalizedWindowTitle(title, applicationName: applicationName)
        return "window-title:\(appHistoryKey):\(normalizedTitle)"
    }

    private static func normalizedWindowTitle(_ title: String, applicationName: String?) -> String {
        let collapsedTitle = collapseWhitespace(title)
        let strippedTitle = titleByStrippingApplicationSuffix(
            from: collapsedTitle,
            applicationName: applicationName
        )

        return collapseWhitespace(strippedTitle)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func titleByStrippingApplicationSuffix(
        from title: String,
        applicationName: String?
    ) -> String {
        for applicationName in applicationNameAliases(for: applicationName) {
            for separator in [" - ", " — "] {
                guard
                    let range = title.range(
                        of: "\(separator)\(applicationName)",
                        options: [.caseInsensitive, .diacriticInsensitive]
                    )
                else {
                    continue
                }

                let prefix = String(title[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    return prefix
                }
            }
        }

        return title
    }

    private static func applicationNameAliases(for applicationName: String?) -> [String] {
        guard let applicationName = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !applicationName.isEmpty else {
            return []
        }

        var aliases = [applicationName]
        if applicationName.hasPrefix("Google ") {
            aliases.append(String(applicationName.dropFirst("Google ".count)))
        }

        return aliases
    }

    private static func collapseWhitespace(_ string: String) -> String {
        string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private enum AccessibilityWindowGeometry {
    static func frame(of window: AXUIElement) -> WindowFrame? {
        guard
            let origin = pointAttribute(kAXPositionAttribute as CFString, of: window),
            let size = sizeAttribute(kAXSizeAttribute as CFString, of: window)
        else {
            return nil
        }

        return WindowFrame(
            x: origin.x,
            y: origin.y,
            width: size.width,
            height: size.height
        )
    }

    private static func pointAttribute(_ attribute: CFString, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard error == .success, let value else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue((value as! AXValue), .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private static func sizeAttribute(_ attribute: CFString, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard error == .success, let value else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue((value as! AXValue), .cgSize, &size) else {
            return nil
        }

        return size
    }
}

private struct AccessibilityWindowIdentifierLookup {
    let identifier: UInt32?
    let error: AXError?
    let symbolName: String?
}

private enum AccessibilityWindowIdentity {
    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let resolvedFunction: (name: String, function: GetWindowFunction)? = {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            return nil
        }

        for symbolName in ["_AXUIElementGetWindow", "AXUIElementGetWindow"] {
            guard let symbol = dlsym(handle, symbolName) else {
                continue
            }

            let function = unsafeBitCast(symbol, to: GetWindowFunction.self)
            return (symbolName, function)
        }

        return nil
    }()

    static var availabilityDescription: String {
        resolvedFunction.map { "\($0.name) available" } ?? "unavailable"
    }

    static func identifier(of window: AXUIElement) -> UInt32? {
        lookup(of: window).identifier
    }

    static func lookup(of window: AXUIElement) -> AccessibilityWindowIdentifierLookup {
        guard let resolvedFunction else {
            return AccessibilityWindowIdentifierLookup(
                identifier: nil,
                error: nil,
                symbolName: nil
            )
        }

        var identifier = CGWindowID(0)
        let error = resolvedFunction.function(window, &identifier)

        guard error == .success, identifier != 0 else {
            return AccessibilityWindowIdentifierLookup(
                identifier: nil,
                error: error,
                symbolName: resolvedFunction.name
            )
        }

        return AccessibilityWindowIdentifierLookup(
            identifier: identifier,
            error: error,
            symbolName: resolvedFunction.name
        )
    }
}

enum AppDiscovery {
    static func loadInstalledApplications() -> [LaunchableApp] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        var seenPaths = Set<String>()
        var apps: [LaunchableApp] = []

        for root in roots where fileManager.fileExists(atPath: root.path) {
            apps.append(contentsOf: applications(in: root, seenPaths: &seenPaths))
        }

        return apps.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func includeRunningApplications(in installedApps: [LaunchableApp]) -> [LaunchableApp] {
        var appsByHistoryKey: [String: LaunchableApp] = [:]
        var historyKeyByPath: [String: String] = [:]

        func store(_ app: LaunchableApp) {
            appsByHistoryKey[app.historyKey] = app

            if let resolvedPath = app.resolvedPath {
                historyKeyByPath[resolvedPath] = app.historyKey
            }
        }

        for app in installedApps {
            store(app)
        }

        for runningApp in runningApplications() {
            let existingKey = runningApp.resolvedPath.flatMap { historyKeyByPath[$0] } ?? runningApp.historyKey

            if let existingApp = appsByHistoryKey[existingKey] {
                store(existingApp.markedRunning(processIdentifier: runningApp.processIdentifier))
            } else {
                store(runningApp)
            }
        }

        let windowCandidates = windowCandidates(for: Array(appsByHistoryKey.values))
        let windowCandidateProcessIdentifiers = Set(windowCandidates.compactMap(\.processIdentifier))
        let applicationCandidates = appsByHistoryKey.values.filter { app in
            guard
                app.isRunning,
                app.targetKind == .application,
                let processIdentifier = app.processIdentifier
            else {
                return true
            }

            return !windowCandidateProcessIdentifiers.contains(processIdentifier)
        }

        var candidatesByIdentityKey = Dictionary(
            uniqueKeysWithValues: applicationCandidates.map { ($0.identityKey, $0) }
        )

        for windowCandidate in windowCandidates {
            candidatesByIdentityKey[windowCandidate.identityKey] = windowCandidate
        }

        return candidatesByIdentityKey.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func applications(in root: URL, seenPaths: inout Set<String>) -> [LaunchableApp] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        var apps: [LaunchableApp] = []

        for case let url as URL in enumerator where url.pathExtension == "app" {
            let resolvedPath = url.resolvingSymlinksInPath().path
            guard !seenPaths.contains(resolvedPath) else {
                continue
            }

            seenPaths.insert(resolvedPath)
            apps.append(makeApp(from: url))
        }

        return apps
    }

    private static func makeApp(from url: URL) -> LaunchableApp {
        let bundle = Bundle(url: url)
        let localizedInfo = bundle?.localizedInfoDictionary
        let info = bundle?.infoDictionary

        let displayName =
            localizedInfo?["CFBundleDisplayName"] as? String ??
            localizedInfo?["CFBundleName"] as? String ??
            info?["CFBundleDisplayName"] as? String ??
            info?["CFBundleName"] as? String ??
            resourceName(for: url) ??
            url.deletingPathExtension().lastPathComponent

        let bundleIdentifier = bundle?.bundleIdentifier
        let historyKey = bundleIdentifier.map { "bundle:\($0)" } ??
            "path:\(url.resolvingSymlinksInPath().path)"
        let searchText = [
            displayName,
            bundleIdentifier,
            url.lastPathComponent,
            url.path
        ]
            .compactMap { $0 }
            .joined(separator: " ")

        return LaunchableApp(
            name: displayName,
            applicationName: displayName,
            url: url,
            bundleIdentifier: bundleIdentifier,
            searchText: searchText,
            identityKey: historyKey,
            historyKey: historyKey,
            processIdentifier: nil,
            isRunning: false,
            targetKind: .application,
            windowTitle: nil,
            windowFrame: nil,
            windowIdentifier: nil
        )
    }

    private static func runningApplications() -> [LaunchableApp] {
        var appsByProcessIdentifier: [pid_t: LaunchableApp] = [:]
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier

        for runningApplication in NSWorkspace.shared.runningApplications {
            guard runningApplication.processIdentifier != currentProcessIdentifier else {
                continue
            }

            guard runningApplication.activationPolicy == .regular else {
                continue
            }

            if let app = makeApp(from: runningApplication) {
                appsByProcessIdentifier[runningApplication.processIdentifier] = app
            }
        }

        for app in coreGraphicsRunningApplications() {
            guard let processIdentifier = app.processIdentifier else {
                continue
            }

            guard processIdentifier != currentProcessIdentifier else {
                continue
            }

            appsByProcessIdentifier[processIdentifier] = appsByProcessIdentifier[processIdentifier] ?? app
        }

        return appsByProcessIdentifier.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func makeApp(
        from runningApplication: NSRunningApplication,
        fallbackName: String? = nil
    ) -> LaunchableApp? {
        let url = runningApplication.bundleURL
        let bundle = url.flatMap { Bundle(url: $0) }
        let localizedInfo = bundle?.localizedInfoDictionary
        let info = bundle?.infoDictionary

        let displayNameCandidates: [String?] = [
            runningApplication.localizedName,
            localizedInfo?["CFBundleDisplayName"] as? String,
            localizedInfo?["CFBundleName"] as? String,
            info?["CFBundleDisplayName"] as? String,
            info?["CFBundleName"] as? String,
            fallbackName,
            url.flatMap { resourceName(for: $0) },
            url?.deletingPathExtension().lastPathComponent
        ]
        let displayName = displayNameCandidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let displayName else {
            return nil
        }

        let bundleIdentifier = runningApplication.bundleIdentifier ?? bundle?.bundleIdentifier
        return makeRunningApp(
            name: displayName,
            processIdentifier: runningApplication.processIdentifier,
            url: url,
            bundleIdentifier: bundleIdentifier
        )
    }

    private static func makeRunningApp(
        name: String,
        processIdentifier: pid_t,
        url: URL?,
        bundleIdentifier: String?
    ) -> LaunchableApp {
        let resolvedPath = url?.resolvingSymlinksInPath().path
        let historyKey = bundleIdentifier.map { "bundle:\($0)" } ??
            resolvedPath.map { "path:\($0)" } ??
            "pid:\(processIdentifier)"
        let searchText = [
            name,
            bundleIdentifier,
            url?.lastPathComponent,
            url?.path,
            "running"
        ]
            .compactMap { $0 }
            .joined(separator: " ")

        return LaunchableApp(
            name: name,
            applicationName: name,
            url: url,
            bundleIdentifier: bundleIdentifier,
            searchText: searchText,
            identityKey: historyKey,
            historyKey: historyKey,
            processIdentifier: processIdentifier,
            isRunning: true,
            targetKind: .application,
            windowTitle: nil,
            windowFrame: nil,
            windowIdentifier: nil
        )
    }

    private static func coreGraphicsRunningApplications() -> [LaunchableApp] {
        var appsByProcessIdentifier: [pid_t: LaunchableApp] = [:]
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier

        for windowInfo in CoreGraphicsWindowReader.candidateWindows() {
            guard
                windowInfo.ownerProcessIdentifier != currentProcessIdentifier,
                appsByProcessIdentifier[windowInfo.ownerProcessIdentifier] == nil
            else {
                continue
            }

            let processIdentifier = windowInfo.ownerProcessIdentifier
            let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)

            if let runningApplication, let app = makeApp(from: runningApplication, fallbackName: windowInfo.ownerName) {
                appsByProcessIdentifier[processIdentifier] = app
                continue
            }

            guard let ownerName = windowInfo.ownerName else {
                continue
            }

            appsByProcessIdentifier[processIdentifier] = makeRunningApp(
                name: ownerName,
                processIdentifier: processIdentifier,
                url: runningApplication?.bundleURL,
                bundleIdentifier: runningApplication?.bundleIdentifier
            )
        }

        return appsByProcessIdentifier.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func windowCandidates(for apps: [LaunchableApp]) -> [LaunchableApp] {
        var candidates: [LaunchableApp] = []
        var seenWindowKeys = Set<String>()

        func append(_ candidate: LaunchableApp) {
            guard let processIdentifier = candidate.processIdentifier else {
                return
            }

            let title = candidate.windowTitle ?? candidate.name
            let windowKey = candidate.windowIdentifier.map {
                "\(processIdentifier):id:\($0)"
            } ?? "\(processIdentifier):title:\(title)"

            guard !seenWindowKeys.contains(windowKey) else {
                return
            }

            seenWindowKeys.insert(windowKey)
            candidates.append(candidate)
        }

        accessibilityWindowCandidates(for: apps).forEach(append)
        coreGraphicsWindowCandidates(for: apps).forEach(append)

        return candidates
    }

    private static func accessibilityWindowCandidates(for apps: [LaunchableApp]) -> [LaunchableApp] {
        guard AXIsProcessTrusted() else {
            return []
        }

        return apps.flatMap { app in
            guard let processIdentifier = app.processIdentifier else {
                return [LaunchableApp]()
            }

            let applicationElement = AXUIElementCreateApplication(processIdentifier)
            let windows = accessibilityWindows(in: applicationElement)

            return windows.enumerated().compactMap { index, window in
                guard let title = accessibilityTitle(of: window), !title.isEmpty else {
                    return nil
                }

                let windowIdentifier = AccessibilityWindowIdentity.identifier(of: window)
                let identityKey = windowIdentifier.map {
                    "window:\(processIdentifier):ax-window-id:\($0)"
                } ?? "window:\(processIdentifier):ax:\(index):\(title)"

                return makeWindowCandidate(
                    baseApp: app,
                    title: title,
                    identityKey: identityKey,
                    frame: AccessibilityWindowGeometry.frame(of: window),
                    windowIdentifier: windowIdentifier
                )
            }
        }
    }

    private static func coreGraphicsWindowCandidates(for apps: [LaunchableApp]) -> [LaunchableApp] {
        let appsByPID = Dictionary(
            uniqueKeysWithValues: apps.compactMap { app -> (pid_t, LaunchableApp)? in
                guard let processIdentifier = app.processIdentifier else {
                    return nil
                }

                return (processIdentifier, app)
            }
        )

        return CoreGraphicsWindowReader.candidateWindows().compactMap { windowInfo in
            guard
                let baseApp = appsByPID[windowInfo.ownerProcessIdentifier],
                let title = windowInfo.title,
                let identifier = windowInfo.identifier
            else {
                return nil
            }

            let identityKey = "window:\(windowInfo.ownerProcessIdentifier):\(identifier)"
            return makeWindowCandidate(
                baseApp: baseApp,
                title: title,
                identityKey: identityKey,
                frame: windowInfo.frame,
                windowIdentifier: identifier
            )
        }
    }

    private static func makeWindowCandidate(
        baseApp: LaunchableApp,
        title: String,
        identityKey: String,
        frame: WindowFrame?,
        windowIdentifier: UInt32?
    ) -> LaunchableApp {
        let applicationName = baseApp.applicationName ?? baseApp.name
        let historyKey = WindowHistoryKey.make(
            appHistoryKey: baseApp.historyKey,
            title: title,
            applicationName: applicationName
        )
        let searchText = [
            title,
            baseApp.name,
            baseApp.applicationName,
            baseApp.bundleIdentifier,
            baseApp.url?.lastPathComponent,
            baseApp.url?.path,
            "window",
            "running"
        ]
            .compactMap { $0 }
            .joined(separator: " ")

        return LaunchableApp(
            name: title,
            applicationName: applicationName,
            url: baseApp.url,
            bundleIdentifier: baseApp.bundleIdentifier,
            searchText: searchText,
            identityKey: identityKey,
            historyKey: historyKey,
            processIdentifier: baseApp.processIdentifier,
            isRunning: true,
            targetKind: .window,
            windowTitle: title,
            windowFrame: frame,
            windowIdentifier: windowIdentifier
        )
    }

    private static func accessibilityWindows(in applicationElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &value
        )

        guard error == .success, let windows = value as? [AXUIElement] else {
            return []
        }

        return windows
    }

    private static func accessibilityTitle(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &value
        )

        guard error == .success else {
            return nil
        }

        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resourceName(for url: URL) -> String? {
        try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName
    }
}

private enum ChromeBookmarkDiscovery {
    private struct BookmarkFile: Decodable {
        let roots: [String: BookmarkNode]
    }

    private struct BookmarkNode: Decodable {
        let type: String?
        let name: String?
        let url: String?
        let children: [BookmarkNode]?
    }

    static func loadBookmarks(fileManager: FileManager = .default) -> [LaunchableApp] {
        var seenURLs = Set<String>()
        var bookmarks: [LaunchableApp] = []

        for bookmarksFileURL in bookmarkFileURLs(fileManager: fileManager) {
            guard
                let data = try? Data(contentsOf: bookmarksFileURL),
                let bookmarkFile = try? JSONDecoder().decode(BookmarkFile.self, from: data)
            else {
                continue
            }

            let profileName = bookmarksFileURL.deletingLastPathComponent().lastPathComponent

            for root in bookmarkFile.roots.values {
                appendBookmarks(
                    from: root,
                    folderPath: [],
                    profileName: profileName,
                    seenURLs: &seenURLs,
                    bookmarks: &bookmarks
                )
            }
        }

        return bookmarks.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func bookmarkFileURLs(fileManager: FileManager) -> [URL] {
        let chromeDirectoryURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)

        var fileURLs: [URL] = []

        let topLevelBookmarksURL = chromeDirectoryURL.appendingPathComponent("Bookmarks")
        if fileManager.fileExists(atPath: topLevelBookmarksURL.path) {
            fileURLs.append(topLevelBookmarksURL)
        }

        guard
            let profileDirectoryURLs = try? fileManager.contentsOfDirectory(
                at: chromeDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return fileURLs
        }

        for profileDirectoryURL in profileDirectoryURLs {
            guard
                (try? profileDirectoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else {
                continue
            }

            let bookmarksURL = profileDirectoryURL.appendingPathComponent("Bookmarks")
            if fileManager.fileExists(atPath: bookmarksURL.path) {
                fileURLs.append(bookmarksURL)
            }
        }

        return fileURLs.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func appendBookmarks(
        from node: BookmarkNode,
        folderPath: [String],
        profileName: String,
        seenURLs: inout Set<String>,
        bookmarks: inout [LaunchableApp]
    ) {
        switch node.type {
        case "url":
            guard
                let urlString = trimmed(node.url),
                let url = URL(string: urlString),
                isWebURL(url)
            else {
                return
            }

            let normalizedURL = url.absoluteString
            guard !seenURLs.contains(normalizedURL) else {
                return
            }

            seenURLs.insert(normalizedURL)

            let title = trimmed(node.name) ?? url.host ?? normalizedURL
            let folderDescription = bookmarkFolderDescription(profileName: profileName, folderPath: folderPath)
            let historyKey = "bookmark:\(normalizedURL)"
            let searchText = [
                title,
                normalizedURL,
                url.host,
                folderDescription,
                "bookmark"
            ]
                .compactMap { $0 }
                .joined(separator: " ")

            bookmarks.append(LaunchableApp(
                name: title,
                applicationName: folderDescription,
                url: url,
                bundleIdentifier: nil,
                searchText: searchText,
                identityKey: historyKey,
                historyKey: historyKey,
                processIdentifier: nil,
                isRunning: false,
                targetKind: .bookmark,
                windowTitle: nil,
                windowFrame: nil,
                windowIdentifier: nil
            ))
        default:
            let nextFolderPath: [String]
            if let folderName = trimmed(node.name) {
                nextFolderPath = folderPath + [folderName]
            } else {
                nextFolderPath = folderPath
            }

            for child in node.children ?? [] {
                appendBookmarks(
                    from: child,
                    folderPath: nextFolderPath,
                    profileName: profileName,
                    seenURLs: &seenURLs,
                    bookmarks: &bookmarks
                )
            }
        }
    }

    private static func bookmarkFolderDescription(profileName: String, folderPath: [String]) -> String {
        ([profileName] + folderPath)
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return scheme == "http" || scheme == "https"
    }

    private static func trimmed(_ string: String?) -> String? {
        guard let string else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum AudioDeviceDiscovery {
    private struct DeviceInfo {
        let identifier: AudioDeviceID
        let uid: String
        let name: String
        let transportType: UInt32?
    }

    private static let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

    static func loadDevices() -> [LaunchableApp] {
        let defaultInputDevice = defaultDevice(
            selector: kAudioHardwarePropertyDefaultInputDevice
        )
        let defaultOutputDevice = defaultDevice(
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )

        let devices = deviceIdentifiers().compactMap(deviceInfo)
        var candidates: [LaunchableApp] = []

        for device in devices where hasStreams(
            deviceID: device.identifier,
            scope: kAudioObjectPropertyScopeInput
        ) {
            candidates.append(
                makeCandidate(
                    device: device,
                    kind: .audioInput,
                    isCurrent: device.identifier == defaultInputDevice
                )
            )
        }

        for device in devices where hasStreams(
            deviceID: device.identifier,
            scope: kAudioObjectPropertyScopeOutput
        ) {
            candidates.append(
                makeCandidate(
                    device: device,
                    kind: .audioOutput,
                    isCurrent: device.identifier == defaultOutputDevice
                )
            )
        }

        return candidates.sorted {
            if $0.targetKind != $1.targetKind {
                return sortRank(for: $0.targetKind) < sortRank(for: $1.targetKind)
            }

            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func setDefaultDevice(for app: LaunchableApp) -> Bool {
        guard let deviceID = app.audioDeviceIdentifier else {
            AppLog.write("audio_device_switch_failed", [
                "name": app.name,
                "target_kind": app.targetKind.logValue,
                "reason": "missing_audio_device_id"
            ])
            return false
        }

        switch app.targetKind {
        case .audioInput:
            let inputStatus = setDefaultDevice(
                deviceID,
                selector: kAudioHardwarePropertyDefaultInputDevice
            )
            AppLog.write("audio_device_switch", [
                "name": app.name,
                "target_kind": app.targetKind.logValue,
                "device_id": Int(deviceID),
                "device_uid": app.audioDeviceUID ?? "nil",
                "default_input_status": Int(inputStatus)
            ])
            return inputStatus == noErr
        case .audioOutput:
            let outputStatus = setDefaultDevice(
                deviceID,
                selector: kAudioHardwarePropertyDefaultOutputDevice
            )
            let systemOutputStatus = setDefaultDevice(
                deviceID,
                selector: kAudioHardwarePropertyDefaultSystemOutputDevice
            )
            AppLog.write("audio_device_switch", [
                "name": app.name,
                "target_kind": app.targetKind.logValue,
                "device_id": Int(deviceID),
                "device_uid": app.audioDeviceUID ?? "nil",
                "default_output_status": Int(outputStatus),
                "default_system_output_status": Int(systemOutputStatus)
            ])
            return outputStatus == noErr
        case .application, .window, .bookmark, .webSearch, .bluetoothConnect, .bluetoothDisconnect:
            return false
        }
    }

    static func connectedBluetoothDeviceNames() -> [String] {
        deviceIdentifiers()
            .compactMap(deviceInfo)
            .filter { device in
                device.transportType == kAudioDeviceTransportTypeBluetooth ||
                    device.transportType == kAudioDeviceTransportTypeBluetoothLE
            }
            .map(\.name)
    }

    private static func makeCandidate(
        device: DeviceInfo,
        kind: LaunchTargetKind,
        isCurrent: Bool
    ) -> LaunchableApp {
        let searchAliases: [String]
        let historyPrefix: String

        switch kind {
        case .audioInput:
            searchAliases = ["sound input", "audio input", "microphone", "mic", "input"]
            historyPrefix = "audio-input"
        case .audioOutput:
            searchAliases = ["sound output", "audio output", "speaker", "headphones", "output"]
            historyPrefix = "audio-output"
        case .application, .window, .bookmark, .webSearch, .bluetoothConnect, .bluetoothDisconnect:
            searchAliases = []
            historyPrefix = "audio"
        }

        let historyKey = "\(historyPrefix):\(device.uid)"
        var searchTextParts: [String?] = [device.name, device.uid]
        searchTextParts.append(contentsOf: searchAliases.map(Optional.some))
        searchTextParts.append(isCurrent ? "current default selected active" : nil)
        let searchText = searchTextParts
            .compactMap { $0 }
            .joined(separator: " ")

        return LaunchableApp(
            name: device.name,
            applicationName: isCurrent ? "Current" : nil,
            url: nil,
            bundleIdentifier: nil,
            searchText: searchText,
            identityKey: historyKey,
            historyKey: historyKey,
            processIdentifier: nil,
            isRunning: false,
            targetKind: kind,
            windowTitle: nil,
            windowFrame: nil,
            windowIdentifier: nil,
            audioDeviceIdentifier: device.identifier,
            audioDeviceUID: device.uid
        )
    }

    private static func deviceIdentifiers() -> [AudioDeviceID] {
        var address = propertyAddress(selector: kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            systemObjectID,
            &address,
            0,
            nil,
            &dataSize
        )

        guard
            sizeStatus == noErr,
            dataSize >= UInt32(MemoryLayout<AudioDeviceID>.size)
        else {
            AppLog.write("audio_device_scan_failed", [
                "step": "devices_size",
                "status": Int(sizeStatus),
                "data_size": Int(dataSize)
            ])
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: deviceCount
        )

        let dataStatus = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                systemObjectID,
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }

        guard dataStatus == noErr else {
            AppLog.write("audio_device_scan_failed", [
                "step": "devices",
                "status": Int(dataStatus)
            ])
            return []
        }

        return deviceIDs.filter { $0 != AudioDeviceID(kAudioObjectUnknown) }
    }

    private static func deviceInfo(for deviceID: AudioDeviceID) -> DeviceInfo? {
        let uid = stringProperty(
            kAudioDevicePropertyDeviceUID,
            of: AudioObjectID(deviceID)
        ) ?? "device-\(deviceID)"
        let name = stringProperty(
            kAudioObjectPropertyName,
            of: AudioObjectID(deviceID)
        ) ?? uid

        return DeviceInfo(
            identifier: deviceID,
            uid: uid,
            name: name,
            transportType: uint32Property(
                kAudioDevicePropertyTransportType,
                of: AudioObjectID(deviceID)
            )
        )
    }

    private static func hasStreams(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = propertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: scope
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(deviceID),
            &address,
            0,
            nil,
            &dataSize
        )

        return status == noErr && dataSize >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func defaultDevice(
        selector: AudioObjectPropertySelector
    ) -> AudioDeviceID? {
        var address = propertyAddress(selector: selector)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            systemObjectID,
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }

        return deviceID
    }

    private static func setDefaultDevice(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> OSStatus {
        var address = propertyAddress(selector: selector)
        var mutableDeviceID = deviceID
        return AudioObjectSetPropertyData(
            systemObjectID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of objectID: AudioObjectID
    ) -> String? {
        var address = propertyAddress(selector: selector)
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr, let value else {
            return nil
        }

        let string = (value.takeRetainedValue() as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector,
        of objectID: AudioObjectID
    ) -> UInt32? {
        var address = propertyAddress(selector: selector)
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            return nil
        }

        return value
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func sortRank(for kind: LaunchTargetKind) -> Int {
        switch kind {
        case .audioInput:
            return 0
        case .audioOutput:
            return 1
        case .application, .window, .bookmark, .webSearch, .bluetoothConnect, .bluetoothDisconnect:
            return 2
        }
    }
}

private enum WebSearchCandidateFactory {
    static func candidate(for query: String) -> LaunchableApp? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return nil
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmedQuery)
        ]

        guard let url = components?.url else {
            return nil
        }

        let identityKey = "web-search:google:\(trimmedQuery)"
        let searchText = [
            trimmedQuery,
            "google",
            "search",
            "web"
        ].joined(separator: " ")

        return LaunchableApp(
            name: "Google 検索: \(trimmedQuery)",
            applicationName: "Google",
            url: url,
            bundleIdentifier: nil,
            searchText: searchText,
            identityKey: identityKey,
            historyKey: identityKey,
            processIdentifier: nil,
            isRunning: false,
            targetKind: .webSearch,
            windowTitle: nil,
            windowFrame: nil,
            windowIdentifier: nil
        )
    }
}

private enum BluetoothDeviceDiscovery {
    private struct BluetoothDeviceInfo {
        let address: String
        let name: String
        let isConnected: Bool
    }

    private struct ConnectedDeviceSnapshot {
        let ioregistryAddresses: Set<String>
        let audioDeviceNames: Set<String>

        func contains(device: IOBluetoothDevice, address: String, name: String) -> Bool {
            device.isConnected() ||
                ioregistryAddresses.contains(address) ||
                audioDeviceNames.contains(normalizedName(name))
        }
    }

    struct ConnectionResult {
        let success: Bool
        let status: IOReturn
        let wasConnected: Bool
        let isConnected: Bool

        var logPayload: [String: Any] {
            [
                "success": success,
                "status": Int(status),
                "was_connected": wasConnected,
                "is_connected": isConnected
            ]
        }
    }

    static func loadDevices() -> [LaunchableApp] {
        bluetoothDevices()
            .map(makeCandidate)
            .sorted {
                if $0.targetKind != $1.targetKind {
                    return sortRank(for: $0.targetKind) < sortRank(for: $1.targetKind)
                }

                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    static func setConnection(for app: LaunchableApp) -> ConnectionResult? {
        guard
            let address = app.bluetoothDeviceAddress,
            let device = IOBluetoothDevice(addressString: address)
        else {
            AppLog.write("bluetooth_device_switch_failed", [
                "name": app.name,
                "target_kind": app.targetKind.logValue,
                "reason": "missing_bluetooth_device"
            ])
            return nil
        }

        let deviceName = trimmed(device.nameOrAddress) ?? app.name
        let wasConnected = connectedDeviceSnapshot().contains(
            device: device,
            address: address,
            name: deviceName
        )
        let status: IOReturn

        switch app.targetKind {
        case .bluetoothConnect:
            status = wasConnected ? kIOReturnSuccess : device.openConnection()
        case .bluetoothDisconnect:
            status = wasConnected ? device.closeConnection() : kIOReturnSuccess
        case .application, .window, .bookmark, .audioInput, .audioOutput, .webSearch:
            return nil
        }

        let isConnected = waitForConnectionState(
            device: device,
            address: address,
            name: deviceName,
            connected: app.targetKind == .bluetoothConnect
        )
        let success: Bool

        switch app.targetKind {
        case .bluetoothConnect:
            success = status == kIOReturnSuccess || isConnected
        case .bluetoothDisconnect:
            success = status == kIOReturnSuccess || !isConnected
        case .application, .window, .bookmark, .audioInput, .audioOutput, .webSearch:
            success = false
        }

        let result = ConnectionResult(
            success: success,
            status: status,
            wasConnected: wasConnected,
            isConnected: isConnected
        )

        AppLog.write("bluetooth_device_switch", [
            "name": app.name,
            "target_kind": app.targetKind.logValue,
            "device_address": address,
            "result": result.logPayload
        ])

        return result
    }

    private static func bluetoothDevices() -> [BluetoothDeviceInfo] {
        let connectedSnapshot = connectedDeviceSnapshot()
        let deviceLists = [
            IOBluetoothDevice.pairedDevices(),
            IOBluetoothDevice.recentDevices(24)
        ]

        var devicesByAddress: [String: IOBluetoothDevice] = [:]

        for deviceList in deviceLists {
            guard let devices = deviceList as? [IOBluetoothDevice] else {
                continue
            }

            for device in devices {
                let address = normalizedAddress(device.addressString)
                guard !address.isEmpty else {
                    continue
                }

                devicesByAddress[address] = devicesByAddress[address] ?? device
            }
        }

        return devicesByAddress.values.compactMap { device in
            let address = normalizedAddress(device.addressString)
            guard !address.isEmpty else {
                return nil
            }

            let name = trimmed(device.nameOrAddress) ?? address
            return BluetoothDeviceInfo(
                address: address,
                name: name,
                isConnected: connectedSnapshot.contains(
                    device: device,
                    address: address,
                    name: name
                )
            )
        }
    }

    private static func makeCandidate(from device: BluetoothDeviceInfo) -> LaunchableApp {
        let targetKind: LaunchTargetKind = device.isConnected ? .bluetoothDisconnect : .bluetoothConnect
        let stateText = device.isConnected ? "connected disconnect" : "disconnected connect"
        let identityKey = "bluetooth:\(device.address)"
        let searchText = [
            device.name,
            device.address,
            "ble",
            "bluetooth",
            stateText
        ].joined(separator: " ")

        return LaunchableApp(
            name: device.name,
            applicationName: device.isConnected ? "Connected" : "Not Connected",
            url: nil,
            bundleIdentifier: nil,
            searchText: searchText,
            identityKey: identityKey,
            historyKey: identityKey,
            processIdentifier: nil,
            isRunning: false,
            targetKind: targetKind,
            windowTitle: nil,
            windowFrame: nil,
            windowIdentifier: nil,
            bluetoothDeviceAddress: device.address
        )
    }

    private static func sortRank(for kind: LaunchTargetKind) -> Int {
        switch kind {
        case .bluetoothDisconnect:
            return 0
        case .bluetoothConnect:
            return 1
        case .application, .window, .bookmark, .audioInput, .audioOutput, .webSearch:
            return 2
        }
    }

    private static func normalizedAddress(_ address: String?) -> String {
        (address ?? "")
            .replacingOccurrences(of: "-", with: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private static func trimmed(_ string: String?) -> String? {
        guard let string else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func waitForConnectionState(
        device: IOBluetoothDevice,
        address: String,
        name: String,
        connected desiredState: Bool
    ) -> Bool {
        var latest = connectedDeviceSnapshot().contains(
            device: device,
            address: address,
            name: name
        )
        let deadline = Date().addingTimeInterval(2.0)

        while latest != desiredState && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            latest = connectedDeviceSnapshot().contains(
                device: device,
                address: address,
                name: name
            )
        }

        return latest
    }

    private static func connectedDeviceSnapshot() -> ConnectedDeviceSnapshot {
        ConnectedDeviceSnapshot(
            ioregistryAddresses: connectedBluetoothAddressesFromIORegistry(),
            audioDeviceNames: Set(AudioDeviceDiscovery.connectedBluetoothDeviceNames().map(normalizedName))
        )
    }

    private static func connectedBluetoothAddressesFromIORegistry() -> Set<String> {
        var addresses = Set<String>()
        let classes = [
            "AppleDeviceManagementHIDEventService",
            "IOBluetoothDevice"
        ]

        for className in classes {
            var iterator: io_iterator_t = 0
            let status = IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching(className),
                &iterator
            )

            guard status == KERN_SUCCESS else {
                continue
            }

            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 {
                    break
                }

                defer {
                    IOObjectRelease(service)
                }

                guard let properties = registryProperties(for: service) else {
                    continue
                }

                if className == "IOBluetoothDevice" {
                    guard connectionHandle(from: properties) != 4095 else {
                        continue
                    }
                } else if (properties["BluetoothDevice"] as? Bool) != true {
                    continue
                }

                if let address = bluetoothAddress(from: properties) {
                    addresses.insert(address)
                }
            }

            IOObjectRelease(iterator)
        }

        return addresses
    }

    private static func registryProperties(for service: io_object_t) -> [String: Any]? {
        var rawProperties: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(
            service,
            &rawProperties,
            kCFAllocatorDefault,
            0
        )

        guard
            status == KERN_SUCCESS,
            let properties = rawProperties?.takeRetainedValue() as? [String: Any]
        else {
            return nil
        }

        return properties
    }

    private static func connectionHandle(from properties: [String: Any]) -> Int? {
        if let value = properties["ConnectionHandle"] as? Int {
            return value
        }

        if let value = properties["ConnectionHandle"] as? NSNumber {
            return value.intValue
        }

        return nil
    }

    private static func bluetoothAddress(from properties: [String: Any]) -> String? {
        let keys = [
            "DeviceAddress",
            "BD_ADDR",
            "BTAddress"
        ]

        for key in keys {
            guard let value = properties[key] else {
                continue
            }

            if let string = value as? String {
                let address = normalizedAddress(string)
                if !address.isEmpty {
                    return address
                }
            } else if let data = value as? Data {
                let address = normalizedAddress(
                    data.map { String(format: "%02X", $0) }.joined(separator: ":")
                )
                if !address.isEmpty {
                    return address
                }
            }
        }

        return nil
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

enum WindowActivator {
    private struct AXWindowsLookup {
        let windows: [AXUIElement]
        let error: AXError
        let valueDescription: String
        let source: String
        let manualAccessibilityError: AXError?
        let childrenError: AXError?
        let childrenValueDescription: String?
        let childrenVisitedCount: Int?
    }

    private struct AXElementArrayLookup {
        let elements: [AXUIElement]
        let error: AXError
        let valueDescription: String
    }

    private struct AXChildrenWindowLookup {
        let windows: [AXUIElement]
        let error: AXError
        let valueDescription: String
        let visitedCount: Int
    }

    private struct AXElementLookup {
        let element: AXUIElement?
        let error: AXError
        let valueDescription: String
    }

    private struct AXMenuItemSearchResult {
        let item: AXUIElement?
        let visitedCount: Int
        let visibleTitles: [String]
    }

    private struct WindowMenuSelectionObservation {
        let frontmostProcessIdentifier: pid_t?
        let title: String?
    }

    private enum WindowMenuFallbackActivationMode {
        case direct
        case activateFirst

        var logLabel: String {
            switch self {
            case .direct:
                return "direct"
            case .activateFirst:
                return "activated"
            }
        }
    }

    static func activate(
        _ app: LaunchableApp,
        previousFrontmostProcessIdentifier: pid_t?,
        previousFrontmostWindowTitle: String?
    ) -> Bool {
        switch app.targetKind {
        case .application:
            return activateApplication(
                for: app,
                previousFrontmostProcessIdentifier: previousFrontmostProcessIdentifier,
                previousFrontmostWindowTitle: previousFrontmostWindowTitle
            )
        case .window:
            return activateWindow(for: app)
        case .bookmark:
            return false
        case .audioInput, .audioOutput:
            return false
        case .webSearch:
            return false
        case .bluetoothConnect, .bluetoothDisconnect:
            return false
        }
    }

    static func frontmostWindowTitle(for processIdentifier: pid_t) -> String? {
        accessibilityFocusedWindowTitle(for: processIdentifier) ?? CoreGraphicsWindowReader.candidateWindows().first {
            $0.ownerProcessIdentifier == processIdentifier && $0.hasTitle
        }?.title
    }

    private static func activateApplication(
        for app: LaunchableApp,
        previousFrontmostProcessIdentifier: pid_t?,
        previousFrontmostWindowTitle: String?
    ) -> Bool {
        var lines = [
            "context: application candidate",
            "candidate: \(app.name)",
            "previous pid: \(previousFrontmostProcessIdentifier.map(String.init) ?? "nil")",
            "previous title: \(previousFrontmostWindowTitle ?? "nil")"
        ]

        guard
            app.isRunning,
            let processIdentifier = app.processIdentifier
        else {
            lines.append("result: skipped, candidate is not a running app with pid")
            recordActivation(lines)
            return false
        }

        lines.append("target pid: \(processIdentifier)")

        guard let runningApplication = NSRunningApplication(processIdentifier: processIdentifier) else {
            lines.append("result: skipped, NSRunningApplication not found")
            recordActivation(lines)
            return false
        }

        runningApplication.unhide()

        guard AXIsProcessTrusted() else {
            WindowPermissionManager.requestAccessibilityPermission()
            let activated = runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            lines.append("result: accessibility not trusted, fallback activate \(activated ? "true" : "false")")
            recordActivation(lines)
            return activated
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let windowsLookup = windowsResult(in: applicationElement, enableManualAccessibility: true)
        let windows = windowsLookup.windows
        let targetWindows = candidateApplicationWindows(in: windows)
        let shouldCycleWindow = previousFrontmostProcessIdentifier == processIdentifier
        let coreGraphicsTitles = coreGraphicsWindowTitles(for: processIdentifier)

        lines.append("same app as previous: \(shouldCycleWindow ? "true" : "false")")
        lines.append("AXManualAccessibility set: \(formatOptionalError(windowsLookup.manualAccessibilityError))")
        lines.append("AX windows copy error: \(describe(windowsLookup.error))")
        lines.append("AX windows value: \(windowsLookup.valueDescription)")
        lines.append("AX windows source: \(windowsLookup.source)")
        lines.append("AX children copy error: \(formatOptionalError(windowsLookup.childrenError))")
        lines.append("AX children value: \(windowsLookup.childrenValueDescription ?? "not attempted")")
        lines.append("AX children visited: \(windowsLookup.childrenVisitedCount.map(String.init) ?? "not attempted")")
        lines.append("AX windows: \(windows.count)")
        lines.append("AX titled windows: \(targetWindows.count)")
        lines.append("CG titles: \(formatTitles(coreGraphicsTitles))")

        let targetWindow = targetApplicationWindow(
            in: targetWindows,
            processIdentifier: processIdentifier,
            applicationElement: applicationElement,
            shouldCycleWindow: shouldCycleWindow,
            previousFrontmostWindowTitle: previousFrontmostWindowTitle
        )

        guard let targetWindow else {
            let activated = runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            lines.append("result: no target AX window, fallback activate \(activated ? "true" : "false")")
            recordActivation(lines)
            return activated
        }

        raise(
            targetWindow,
            in: applicationElement,
            runningApplication: runningApplication,
            context: "application candidate",
            processIdentifier: processIdentifier,
            prefixLines: lines
        )
        return true
    }

    private static func activateWindow(for app: LaunchableApp) -> Bool {
        var lines = [
            "context: window candidate",
            "candidate: \(app.name)",
            "candidate window title: \(app.windowTitle ?? "nil")",
            "candidate window id: \(formatIdentifier(app.windowIdentifier))",
            "candidate frame: \(formatFrame(app.windowFrame))"
        ]

        guard
            app.targetKind == .window,
            let processIdentifier = app.processIdentifier
        else {
            lines.append("result: skipped, candidate is not a window with pid")
            recordActivation(lines)
            return false
        }

        lines.append("target pid: \(processIdentifier)")

        guard let runningApplication = NSRunningApplication(processIdentifier: processIdentifier) else {
            lines.append("result: skipped, NSRunningApplication not found")
            recordActivation(lines)
            return false
        }

        runningApplication.unhide()

        guard AXIsProcessTrusted() else {
            WindowPermissionManager.requestAccessibilityPermission()
            let activated = runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            lines.append("result: accessibility not trusted, fallback activate \(activated ? "true" : "false")")
            recordActivation(lines)
            return false
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let windowsLookup = windowsResult(in: applicationElement, enableManualAccessibility: true)
        let axWindows = windowsLookup.windows
        lines.append("AX window id symbol: \(AccessibilityWindowIdentity.availabilityDescription)")
        lines.append("AXManualAccessibility set: \(formatOptionalError(windowsLookup.manualAccessibilityError))")
        lines.append("AX windows copy error: \(describe(windowsLookup.error))")
        lines.append("AX windows value: \(windowsLookup.valueDescription)")
        lines.append("AX windows source: \(windowsLookup.source)")
        lines.append("AX children copy error: \(formatOptionalError(windowsLookup.childrenError))")
        lines.append("AX children value: \(windowsLookup.childrenValueDescription ?? "not attempted")")
        lines.append("AX children visited: \(windowsLookup.childrenVisitedCount.map(String.init) ?? "not attempted")")
        lines.append("AX windows: \(axWindows.count)")
        lines.append("AX frames: \(formatAXWindows(axWindows))")

        var targetWindow = findWindow(
            in: axWindows,
            matching: app.windowTitle,
            identifier: app.windowIdentifier,
            frame: app.windowFrame
        )

        if targetWindow == nil, windowsLookup.source != "AXChildren" {
            let childrenLookup = childWindows(in: applicationElement)
            lines.append("secondary AX children copy error: \(describe(childrenLookup.error))")
            lines.append("secondary AX children value: \(childrenLookup.valueDescription)")
            lines.append("secondary AX children visited: \(childrenLookup.visitedCount)")
            lines.append("secondary AX children windows: \(childrenLookup.windows.count)")
            lines.append("secondary AX children frames: \(formatAXWindows(childrenLookup.windows))")
            targetWindow = findWindow(
                in: childrenLookup.windows,
                matching: app.windowTitle,
                identifier: app.windowIdentifier,
                frame: app.windowFrame
            )
        }

        if targetWindow == nil {
            targetWindow = hitTestWindow(for: app, processIdentifier: processIdentifier, lines: &lines)
        }

        if targetWindow == nil,
            pressWindowMenuItem(
                for: app,
                in: applicationElement,
                runningApplication: runningApplication,
                lines: &lines
            ) {
            recordActivation(lines)
            return true
        }

        guard let targetWindow else {
            lines.append("result: target AX window not found")
            recordActivation(lines)
            return false
        }

        raise(
            targetWindow,
            in: applicationElement,
            runningApplication: runningApplication,
            context: "window candidate",
            processIdentifier: processIdentifier,
            prefixLines: lines
        )

        return true
    }

    private static func targetApplicationWindow(
        in windows: [AXUIElement],
        processIdentifier: pid_t,
        applicationElement: AXUIElement,
        shouldCycleWindow: Bool,
        previousFrontmostWindowTitle: String?
    ) -> AXUIElement? {
        guard !windows.isEmpty else {
            return nil
        }

        guard shouldCycleWindow, windows.count > 1 else {
            return focusedWindow(in: applicationElement) ?? windows.first
        }

        if
            let previousFrontmostWindowTitle,
            let nextWindowTitle = nextWindowTitle(
                after: previousFrontmostWindowTitle,
                for: processIdentifier
            ),
            let nextWindow = findWindow(in: windows, matching: nextWindowTitle) {
            return nextWindow
        }

        if
            let previousFrontmostWindowTitle,
            let previousIndex = firstWindowIndex(in: windows, matching: previousFrontmostWindowTitle) {
            return windows[(previousIndex + 1) % windows.count]
        }

        guard
            let focusedWindow = focusedWindow(in: applicationElement),
            let focusedIndex = windows.firstIndex(where: { CFEqual($0, focusedWindow) })
        else {
            return windows.dropFirst().first ?? windows.first
        }

        return windows[(focusedIndex + 1) % windows.count]
    }

    private static func nextWindowTitle(after currentTitle: String, for processIdentifier: pid_t) -> String? {
        let orderedTitles = deduplicate(
            CoreGraphicsWindowReader.candidateWindows()
                .filter { $0.ownerProcessIdentifier == processIdentifier && $0.hasTitle }
                .compactMap(\.title)
        )

        guard orderedTitles.count > 1 else {
            return nil
        }

        guard let currentIndex = orderedTitles.firstIndex(where: { titlesMatch($0, currentTitle) }) else {
            return orderedTitles.first
        }

        return orderedTitles[(currentIndex + 1) % orderedTitles.count]
    }

    private static func deduplicate(_ titles: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for title in titles {
            let key = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !seen.contains(key) else {
                continue
            }

            seen.insert(key)
            result.append(title)
        }

        return result
    }

    private static func firstWindowIndex(in windows: [AXUIElement], matching targetTitle: String) -> Int? {
        if let exactMatch = windows.firstIndex(where: { title(of: $0) == targetTitle }) {
            return exactMatch
        }

        return windows.firstIndex { window in
            guard let windowTitle = title(of: window) else {
                return false
            }

            return titlesMatch(windowTitle, targetTitle)
        }
    }

    private static func candidateApplicationWindows(in windows: [AXUIElement]) -> [AXUIElement] {
        let titledWindows = windows.filter { window in
            title(of: window)?.isEmpty == false
        }

        return titledWindows.isEmpty ? windows : titledWindows
    }

    private static func raise(
        _ targetWindow: AXUIElement,
        in applicationElement: AXUIElement,
        runningApplication: NSRunningApplication,
        context: String,
        processIdentifier: pid_t,
        prefixLines: [String] = []
    ) {
        let targetTitle = title(of: targetWindow) ?? "(untitled)"
        var lines = prefixLines + [
            "activation context: \(context)",
            "activation pid: \(processIdentifier)",
            "target title: \(targetTitle)"
        ]

        let unminimizeError = AXUIElementSetAttributeValue(
            targetWindow,
            kAXMinimizedAttribute as CFString,
            kCFBooleanFalse
        )
        lines.append("set AXMinimized=false: \(describe(unminimizeError))")

        let mainError = AXUIElementSetAttributeValue(
            targetWindow,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        lines.append("set window AXMain=true: \(describe(mainError))")

        let focusedError = AXUIElementSetAttributeValue(
            targetWindow,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        lines.append("set window AXFocused=true: \(describe(focusedError))")

        let mainWindowError = AXUIElementSetAttributeValue(
            applicationElement,
            kAXMainWindowAttribute as CFString,
            targetWindow
        )
        lines.append("set app AXMainWindow: \(describe(mainWindowError))")

        let focusedWindowError = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            targetWindow
        )
        lines.append("set app AXFocusedWindow: \(describe(focusedWindowError))")

        let preActivationRaiseError = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        lines.append("perform AXRaise before app activation: \(describe(preActivationRaiseError))")

        let frontmostError = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        lines.append("set app AXFrontmost=true: \(describe(frontmostError))")

        let activated = runningApplication.activate(options: [.activateIgnoringOtherApps])
        lines.append("NSRunningApplication.activate: \(activated ? "true" : "false")")

        let postActivationRaiseError = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        lines.append("perform AXRaise after app activation: \(describe(postActivationRaiseError))")

        recordActivation(lines)
    }

    private static func findWindow(
        in windows: [AXUIElement],
        matching targetTitle: String?,
        identifier targetIdentifier: UInt32? = nil,
        frame targetFrame: WindowFrame? = nil
    ) -> AXUIElement? {
        if
            let targetIdentifier,
            let identifierMatch = windows.first(where: {
                AccessibilityWindowIdentity.identifier(of: $0) == targetIdentifier
            }) {
            return identifierMatch
        }

        let fallbackWindows: [AXUIElement]
        if targetIdentifier == nil {
            fallbackWindows = windows
        } else {
            fallbackWindows = windows.filter {
                AccessibilityWindowIdentity.identifier(of: $0) == nil
            }
        }

        if let targetTitle, let exactMatch = fallbackWindows.first(where: { title(of: $0) == targetTitle }) {
            return exactMatch
        }

        if let targetTitle {
            return fallbackWindows.first { window in
                guard let windowTitle = title(of: window) else {
                    return false
                }

                return titlesAreCompatible(windowTitle, targetTitle)
            }
        }

        if
            targetIdentifier == nil,
            let frameMatch = findWindow(in: fallbackWindows, matching: targetFrame) {
            return frameMatch
        }

        if targetIdentifier == nil {
            return fallbackWindows.first
        }

        return nil
    }

    private static func findWindow(in windows: [AXUIElement], matching targetFrame: WindowFrame?) -> AXUIElement? {
        guard let targetFrame else {
            return nil
        }

        return windows
            .compactMap { window -> (AXUIElement, Double)? in
                guard let frame = AccessibilityWindowGeometry.frame(of: window) else {
                    return nil
                }

                return (window, frameDistance(frame, targetFrame))
            }
            .filter { _, distance in distance <= 96 }
            .min { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    private static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(
            rhs,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    private static func titlesAreCompatible(_ lhs: String, _ rhs: String) -> Bool {
        titlesMatch(lhs, rhs) ||
            lhs.localizedCaseInsensitiveContains(rhs) ||
            rhs.localizedCaseInsensitiveContains(lhs)
    }

    private static func hitTestWindow(
        for app: LaunchableApp,
        processIdentifier: pid_t,
        lines: inout [String]
    ) -> AXUIElement? {
        guard let frame = app.windowFrame else {
            lines.append("AX hit test: skipped, no candidate frame")
            return nil
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        let points = hitTestPoints(in: frame)

        for (index, point) in points.enumerated() {
            var element: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(
                systemWideElement,
                Float(point.x),
                Float(point.y),
                &element
            )
            lines.append("AX hit test \(index) at x:\(Int(point.x)) y:\(Int(point.y)): \(describe(error))")

            guard error == .success, let element else {
                continue
            }

            let elementPID = pid(of: element)
            let elementRole = role(of: element) ?? "nil"
            let elementTitle = title(of: element) ?? "(untitled)"
            lines.append(
                "AX hit test element: pid \(formatPID(elementPID)) role \(elementRole) title \(elementTitle)"
            )

            guard let window = relatedWindow(of: element) else {
                lines.append("AX hit test result: no related AX window")
                continue
            }

            let windowPID = pid(of: window)
            let windowIdentifierLookup = AccessibilityWindowIdentity.lookup(of: window)
            let windowTitle = title(of: window) ?? "(untitled)"
            lines.append(
                "AX hit test window: pid \(formatPID(windowPID)) id \(formatWindowIdentifierLookup(windowIdentifierLookup)) title \(windowTitle) frame \(formatFrame(AccessibilityWindowGeometry.frame(of: window)))"
            )

            guard windowPID == processIdentifier else {
                lines.append("AX hit test rejected: pid mismatch")
                continue
            }

            guard windowMatchesTarget(window, title: app.windowTitle, identifier: app.windowIdentifier) else {
                lines.append("AX hit test rejected: target id/title mismatch")
                continue
            }

            lines.append("AX hit test result: matched target window")
            return window
        }

        lines.append("AX hit test result: no matched window")
        return nil
    }

    private static func pressWindowMenuItem(
        for app: LaunchableApp,
        in applicationElement: AXUIElement,
        runningApplication: NSRunningApplication,
        lines: inout [String]
    ) -> Bool {
        guard let targetTitle = app.windowTitle else {
            lines.append("Window menu fallback: skipped, no target title")
            return false
        }

        if pressWindowMenuItemAttempt(
            targetTitle: targetTitle,
            in: applicationElement,
            runningApplication: runningApplication,
            activationMode: .direct,
            lines: &lines
        ) {
            return true
        }

        lines.append("Window menu fallback: direct attempt failed, retrying after app activation")
        return pressWindowMenuItemAttempt(
            targetTitle: targetTitle,
            in: applicationElement,
            runningApplication: runningApplication,
            activationMode: .activateFirst,
            lines: &lines
        )
    }

    private static func pressWindowMenuItemAttempt(
        targetTitle: String,
        in applicationElement: AXUIElement,
        runningApplication: NSRunningApplication,
        activationMode: WindowMenuFallbackActivationMode,
        lines: inout [String]
    ) -> Bool {
        switch activationMode {
        case .direct:
            lines.append("Window menu fallback direct: skipped explicit app activation")
        case .activateFirst:
            let frontmostError = AXUIElementSetAttributeValue(
                applicationElement,
                kAXFrontmostAttribute as CFString,
                kCFBooleanTrue
            )
            lines.append("Window menu fallback activated set app AXFrontmost=true: \(describe(frontmostError))")

            let activated = runningApplication.activate(options: [.activateIgnoringOtherApps])
            lines.append("Window menu fallback activated activate app: \(activated ? "true" : "false")")
            let observedFrontmostProcessIdentifier = waitForFrontmostProcessIdentifier(
                runningApplication.processIdentifier,
                timeout: 0.12
            )
            lines.append(
                "Window menu fallback activated frontmost after activate: \(formatPID(observedFrontmostProcessIdentifier))"
            )
        }

        let menuBarLookup = elementAttribute(
            kAXMenuBarAttribute as CFString,
            of: applicationElement
        )
        lines.append(
            "Window menu fallback \(activationMode.logLabel) menu bar: \(describe(menuBarLookup.error)) \(menuBarLookup.valueDescription)"
        )

        guard let menuBar = menuBarLookup.element else {
            lines.append("Window menu fallback \(activationMode.logLabel) result: no menu bar")
            return false
        }

        let menuBarItemsLookup = elementArray(
            attribute: kAXChildrenAttribute as CFString,
            of: menuBar
        )
        let menuBarItems = menuBarItemsLookup.elements
        let menuBarTitles = menuBarItems.compactMap { title(of: $0) }
        lines.append("Window menu fallback \(activationMode.logLabel) menu bar items: \(formatTitles(menuBarTitles))")

        let windowMenuItems = menuBarItems.filter {
            title(of: $0).map(isWindowMenuTitle) == true
        }

        guard !windowMenuItems.isEmpty else {
            lines.append("Window menu fallback \(activationMode.logLabel) result: Window menu not found")
            return false
        }

        for windowMenuItem in windowMenuItems {
            let windowMenuTitle = title(of: windowMenuItem) ?? "(untitled)"
            let initialSearch = menuItem(in: windowMenuItem, matching: targetTitle)
            lines.append(
                "Window menu fallback \(activationMode.logLabel) initial search in \(windowMenuTitle): visited \(initialSearch.visitedCount), titles \(formatTitles(initialSearch.visibleTitles))"
            )

            if let item = initialSearch.item {
                return pressMenuItem(
                    item,
                    targetTitle: targetTitle,
                    source: "\(activationMode.logLabel) initial",
                    runningApplication: runningApplication,
                    lines: &lines
                )
            }

            guard activationMode == .activateFirst else {
                lines.append("Window menu fallback direct: target not visible without opening menu")
                continue
            }

            let openError = AXUIElementPerformAction(windowMenuItem, kAXPressAction as CFString)
            lines.append("Window menu fallback activated open \(windowMenuTitle): \(describe(openError))")

            let openedSearch = waitForMenuItem(
                in: windowMenuItem,
                matching: targetTitle,
                timeout: 0.12
            )
            lines.append(
                "Window menu fallback activated opened search in \(windowMenuTitle): visited \(openedSearch.visitedCount), titles \(formatTitles(openedSearch.visibleTitles))"
            )

            if let item = openedSearch.item {
                return pressMenuItem(
                    item,
                    targetTitle: targetTitle,
                    source: "activated opened",
                    runningApplication: runningApplication,
                    lines: &lines
                )
            }
        }

        lines.append("Window menu fallback \(activationMode.logLabel) result: no matching menu item")
        return false
    }

    private static func pressMenuItem(
        _ menuItem: AXUIElement,
        targetTitle: String,
        source: String,
        runningApplication: NSRunningApplication,
        lines: inout [String]
    ) -> Bool {
        let menuItemTitle = title(of: menuItem) ?? "(untitled)"
        let pressError = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
        lines.append(
            "Window menu fallback press \(source): target \(targetTitle), item \(menuItemTitle), \(describe(pressError))"
        )

        guard pressError == .success else {
            lines.append("Window menu fallback result: press failed")
            return false
        }

        var observation = waitForWindowMenuSelection(
            targetTitle: targetTitle,
            processIdentifier: runningApplication.processIdentifier,
            requireFrontmost: false,
            timeout: 0.08
        )
        lines.append(
            "Window menu fallback observed after press: frontmost pid \(formatPID(observation.frontmostProcessIdentifier)), title \(observation.title ?? "nil")"
        )

        if observation.frontmostProcessIdentifier != runningApplication.processIdentifier {
            let activated = runningApplication.activate(options: [.activateIgnoringOtherApps])
            lines.append("Window menu fallback activate after press: \(activated ? "true" : "false")")
            observation = waitForWindowMenuSelection(
                targetTitle: targetTitle,
                processIdentifier: runningApplication.processIdentifier,
                requireFrontmost: true,
                timeout: 0.18
            )
            lines.append(
                "Window menu fallback observed after activate: frontmost pid \(formatPID(observation.frontmostProcessIdentifier)), title \(observation.title ?? "nil")"
            )
        }

        guard
            observation.frontmostProcessIdentifier == runningApplication.processIdentifier,
            let observedTitle = observation.title,
            menuItemTitleMatches(observedTitle, targetTitle)
        else {
            lines.append("Window menu fallback result: press succeeded but target app/title not observed")
            return false
        }

        lines.append("Window menu fallback result: pressed and observed matching Window menu item")
        return true
    }

    private static func menuItem(in root: AXUIElement, matching targetTitle: String) -> AXMenuItemSearchResult {
        var queue = [(root, 0)]
        var visibleTitles: [String] = []
        var visitedCount = 0
        let maxDepth = 8
        let maxVisitedCount = 700

        while !queue.isEmpty, visitedCount < maxVisitedCount {
            let (element, depth) = queue.removeFirst()
            visitedCount += 1

            let elementRole = role(of: element)
            if
                elementRole == (kAXMenuItemRole as String),
                let elementTitle = title(of: element),
                !elementTitle.isEmpty {
                visibleTitles.append(elementTitle)

                if menuItemTitleMatches(elementTitle, targetTitle), isEnabled(element) {
                    return AXMenuItemSearchResult(
                        item: element,
                        visitedCount: visitedCount,
                        visibleTitles: visibleTitles
                    )
                }
            }

            guard depth < maxDepth else {
                continue
            }

            let childrenLookup = elementArray(
                attribute: kAXChildrenAttribute as CFString,
                of: element
            )
            queue.append(contentsOf: childrenLookup.elements.map { ($0, depth + 1) })
        }

        return AXMenuItemSearchResult(
            item: nil,
            visitedCount: visitedCount,
            visibleTitles: visibleTitles
        )
    }

    private static func waitForMenuItem(
        in root: AXUIElement,
        matching targetTitle: String,
        timeout: TimeInterval
    ) -> AXMenuItemSearchResult {
        let deadline = Date().addingTimeInterval(timeout)
        var latestResult = menuItem(in: root, matching: targetTitle)

        while latestResult.item == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            latestResult = menuItem(in: root, matching: targetTitle)
        }

        return latestResult
    }

    private static func waitForWindowMenuSelection(
        targetTitle: String,
        processIdentifier: pid_t,
        requireFrontmost: Bool,
        timeout: TimeInterval
    ) -> WindowMenuSelectionObservation {
        let deadline = Date().addingTimeInterval(timeout)
        var latestObservation = observeWindowMenuSelection(for: processIdentifier)

        while Date() < deadline {
            if windowMenuSelectionMatches(
                latestObservation,
                targetTitle: targetTitle,
                processIdentifier: processIdentifier,
                requireFrontmost: requireFrontmost
            ) {
                break
            }

            Thread.sleep(forTimeInterval: 0.01)
            latestObservation = observeWindowMenuSelection(for: processIdentifier)
        }

        return latestObservation
    }

    private static func waitForFrontmostProcessIdentifier(
        _ processIdentifier: pid_t,
        timeout: TimeInterval
    ) -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        var latestProcessIdentifier = frontmostProcessIdentifier()

        while latestProcessIdentifier != processIdentifier, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            latestProcessIdentifier = frontmostProcessIdentifier()
        }

        return latestProcessIdentifier
    }

    private static func observeWindowMenuSelection(for processIdentifier: pid_t) -> WindowMenuSelectionObservation {
        WindowMenuSelectionObservation(
            frontmostProcessIdentifier: frontmostProcessIdentifier(),
            title: frontmostWindowTitle(for: processIdentifier)
        )
    }

    private static func windowMenuSelectionMatches(
        _ observation: WindowMenuSelectionObservation,
        targetTitle: String,
        processIdentifier: pid_t,
        requireFrontmost: Bool
    ) -> Bool {
        if requireFrontmost, observation.frontmostProcessIdentifier != processIdentifier {
            return false
        }

        guard let observedTitle = observation.title else {
            return false
        }

        return menuItemTitleMatches(observedTitle, targetTitle)
    }

    private static func hitTestPoints(in frame: WindowFrame) -> [CGPoint] {
        let insetX = min(max(frame.width * 0.08, 32), max(frame.width / 2, 1))
        let insetY = min(max(frame.height * 0.08, 32), max(frame.height / 2, 1))

        return [
            CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2),
            CGPoint(x: frame.x + insetX, y: frame.y + insetY),
            CGPoint(x: frame.x + frame.width - insetX, y: frame.y + insetY)
        ]
    }

    private static func relatedWindow(of element: AXUIElement) -> AXUIElement? {
        if role(of: element) == (kAXWindowRole as String) {
            return element
        }

        return axElementAttribute("AXWindow" as CFString, of: element) ??
            axElementAttribute("AXTopLevelUIElement" as CFString, of: element)
    }

    private static func elementAttribute(_ attribute: CFString, of element: AXUIElement) -> AXElementLookup {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard error == .success else {
            return AXElementLookup(
                element: nil,
                error: error,
                valueDescription: describeAXValue(value)
            )
        }

        guard
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return AXElementLookup(
                element: nil,
                error: error,
                valueDescription: describeAXValue(value)
            )
        }

        return AXElementLookup(
            element: (value as! AXUIElement),
            error: error,
            valueDescription: "AXUIElement"
        )
    }

    private static func axElementAttribute(_ attribute: CFString, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard
            error == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func isWindowMenuTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)

        return normalized.compare("Window", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ||
            normalized.compare("Windows", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ||
            normalized == "ウインドウ" ||
            normalized == "ウィンドウ"
    }

    private static func menuItemTitleMatches(_ menuItemTitle: String, _ targetTitle: String) -> Bool {
        let normalizedMenuItemTitle = normalizedWindowMenuTitle(menuItemTitle)
        let normalizedTargetTitle = normalizedWindowMenuTitle(targetTitle)

        guard !normalizedMenuItemTitle.isEmpty, !normalizedTargetTitle.isEmpty else {
            return false
        }

        return normalizedMenuItemTitle == normalizedTargetTitle ||
            normalizedMenuItemTitle.contains(normalizedTargetTitle) ||
            normalizedTargetTitle.contains(normalizedMenuItemTitle)
    }

    private static func normalizedWindowMenuTitle(_ title: String) -> String {
        var normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)

        while let first = normalized.first, "✓✔•".contains(first) {
            normalized.removeFirst()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let shortcutRange = normalized.range(
            of: #"^\d+[\.)]?\s+"#,
            options: .regularExpression
        ) {
            normalized.removeSubrange(shortcutRange)
        }

        return normalized
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func windowMatchesTarget(
        _ window: AXUIElement,
        title targetTitle: String?,
        identifier targetIdentifier: UInt32?
    ) -> Bool {
        if
            let targetIdentifier {
            let lookup = AccessibilityWindowIdentity.lookup(of: window)

            if let identifier = lookup.identifier {
                return identifier == targetIdentifier
            }
        }

        if
            let targetTitle,
            let windowTitle = title(of: window) {
            return titlesAreCompatible(windowTitle, targetTitle)
        }

        return targetTitle == nil && targetIdentifier == nil
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXEnabledAttribute as CFString,
            &value
        )

        guard error == .success else {
            return true
        }

        return (value as? Bool) ?? true
    }

    private static func coreGraphicsWindowTitles(for processIdentifier: pid_t) -> [String] {
        deduplicate(
            CoreGraphicsWindowReader.candidateWindows()
                .filter { $0.ownerProcessIdentifier == processIdentifier && $0.hasTitle }
                .compactMap(\.title)
        )
    }

    private static func formatTitles(_ titles: [String]) -> String {
        guard !titles.isEmpty else {
            return "none"
        }

        return titles.prefix(6).joined(separator: " | ")
    }

    private static func formatAXWindows(_ windows: [AXUIElement]) -> String {
        guard !windows.isEmpty else {
            return "none"
        }

        return windows.prefix(6).map { window in
            let windowTitle = title(of: window) ?? "(untitled)"
            let identifierLookup = AccessibilityWindowIdentity.lookup(of: window)
            return "pid:\(formatPID(pid(of: window))) id:\(formatWindowIdentifierLookup(identifierLookup)) \(windowTitle) \(formatFrame(AccessibilityWindowGeometry.frame(of: window)))"
        }.joined(separator: " | ")
    }

    private static func formatIdentifier(_ identifier: UInt32?) -> String {
        identifier.map(String.init) ?? "nil"
    }

    private static func formatWindowIdentifierLookup(_ lookup: AccessibilityWindowIdentifierLookup) -> String {
        if let identifier = lookup.identifier {
            return "\(identifier) via \(lookup.symbolName ?? "unknown")"
        }

        if let error = lookup.error {
            return "nil via \(lookup.symbolName ?? "unknown") \(describe(error))"
        }

        return "nil (symbol unavailable)"
    }

    private static func formatPID(_ processIdentifier: pid_t?) -> String {
        processIdentifier.map(String.init) ?? "nil"
    }

    private static func formatFrame(_ frame: WindowFrame?) -> String {
        guard let frame else {
            return "nil"
        }

        return "x:\(Int(frame.x)) y:\(Int(frame.y)) w:\(Int(frame.width)) h:\(Int(frame.height))"
    }

    private static func frameDistance(_ lhs: WindowFrame, _ rhs: WindowFrame) -> Double {
        abs(lhs.x - rhs.x) +
            abs(lhs.y - rhs.y) +
            abs(lhs.width - rhs.width) +
            abs(lhs.height - rhs.height)
    }

    private static func describe(_ error: AXError) -> String {
        error == .success ? "success" : "error \(error.rawValue)"
    }

    private static func formatOptionalError(_ error: AXError?) -> String {
        error.map(describe) ?? "not attempted"
    }

    private static func pid(of element: AXUIElement) -> pid_t? {
        var processIdentifier = pid_t(0)
        let error = AXUIElementGetPid(element, &processIdentifier)

        guard error == .success else {
            return nil
        }

        return processIdentifier
    }

    private static func frontmostProcessIdentifier() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static func recordActivation(_ lines: [String]) {
        AppLog.write("window_activation", [
            "lines": lines
        ])
    }

    private static func windowsResult(
        in applicationElement: AXUIElement,
        enableManualAccessibility: Bool = false
    ) -> AXWindowsLookup {
        let manualAccessibilityError: AXError?

        if enableManualAccessibility {
            manualAccessibilityError = AXUIElementSetAttributeValue(
                applicationElement,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
        } else {
            manualAccessibilityError = nil
        }

        var directLookup = elementArray(
            attribute: kAXWindowsAttribute as CFString,
            of: applicationElement
        )

        if
            directLookup.elements.isEmpty,
            directLookup.error == .success,
            manualAccessibilityError == .success {
            directLookup = waitForNonEmptyElementArray(
                attribute: kAXWindowsAttribute as CFString,
                of: applicationElement,
                timeout: 0.06
            )
        }

        if !directLookup.elements.isEmpty {
            return AXWindowsLookup(
                windows: directLookup.elements,
                error: directLookup.error,
                valueDescription: directLookup.valueDescription,
                source: "AXWindows",
                manualAccessibilityError: manualAccessibilityError,
                childrenError: nil,
                childrenValueDescription: nil,
                childrenVisitedCount: nil
            )
        }

        let childrenLookup = childWindows(in: applicationElement)
        if !childrenLookup.windows.isEmpty {
            return AXWindowsLookup(
                windows: childrenLookup.windows,
                error: directLookup.error,
                valueDescription: directLookup.valueDescription,
                source: "AXChildren",
                manualAccessibilityError: manualAccessibilityError,
                childrenError: childrenLookup.error,
                childrenValueDescription: childrenLookup.valueDescription,
                childrenVisitedCount: childrenLookup.visitedCount
            )
        }

        return AXWindowsLookup(
            windows: [],
            error: directLookup.error,
            valueDescription: directLookup.valueDescription,
            source: "none",
            manualAccessibilityError: manualAccessibilityError,
            childrenError: childrenLookup.error,
            childrenValueDescription: childrenLookup.valueDescription,
            childrenVisitedCount: childrenLookup.visitedCount
        )
    }

    private static func waitForNonEmptyElementArray(
        attribute: CFString,
        of element: AXUIElement,
        timeout: TimeInterval
    ) -> AXElementArrayLookup {
        let deadline = Date().addingTimeInterval(timeout)
        var latestLookup = elementArray(attribute: attribute, of: element)

        while latestLookup.elements.isEmpty, latestLookup.error == .success, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            latestLookup = elementArray(attribute: attribute, of: element)
        }

        return latestLookup
    }

    private static func elementArray(attribute: CFString, of element: AXUIElement) -> AXElementArrayLookup {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )

        guard error == .success else {
            return AXElementArrayLookup(
                elements: [],
                error: error,
                valueDescription: describeAXValue(value)
            )
        }

        guard let elements = value as? [AXUIElement] else {
            return AXElementArrayLookup(
                elements: [],
                error: error,
                valueDescription: describeAXValue(value)
            )
        }

        return AXElementArrayLookup(
            elements: elements,
            error: error,
            valueDescription: "AXUIElement array count \(elements.count)"
        )
    }

    private static func childWindows(in applicationElement: AXUIElement) -> AXChildrenWindowLookup {
        let rootChildrenLookup = elementArray(
            attribute: kAXChildrenAttribute as CFString,
            of: applicationElement
        )
        var queue = rootChildrenLookup.elements.map { ($0, 1) }
        var windows: [AXUIElement] = []
        var visitedCount = 0
        let maxDepth = 7
        let maxVisitedCount = 500

        while !queue.isEmpty, visitedCount < maxVisitedCount {
            let (element, depth) = queue.removeFirst()
            visitedCount += 1

            if role(of: element) == (kAXWindowRole as String) {
                windows.append(element)
                continue
            }

            guard depth < maxDepth else {
                continue
            }

            let childrenLookup = elementArray(
                attribute: kAXChildrenAttribute as CFString,
                of: element
            )
            queue.append(contentsOf: childrenLookup.elements.map { ($0, depth + 1) })
        }

        return AXChildrenWindowLookup(
            windows: windows,
            error: rootChildrenLookup.error,
            valueDescription: rootChildrenLookup.valueDescription,
            visitedCount: visitedCount
        )
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        )

        guard error == .success else {
            return nil
        }

        return value as? String
    }

    private static func describeAXValue(_ value: CFTypeRef?) -> String {
        guard let value else {
            return "nil"
        }

        if let array = value as? [Any] {
            return "array count \(array.count)"
        }

        return String(describing: type(of: value))
    }

    private static func accessibilityFocusedWindowTitle(for processIdentifier: pid_t) -> String? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        return focusedWindow(in: applicationElement).flatMap { title(of: $0) }
    }

    private static func focusedWindow(in applicationElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )

        guard error == .success else {
            return nil
        }

        guard let value else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &value
        )

        guard error == .success else {
            return nil
        }

        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

private enum LauncherKey {
    static let a: UInt16 = 0
    static let z: UInt16 = 6
    static let x: UInt16 = 7
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53
    static let n: UInt16 = 45
    static let p: UInt16 = 35
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126

    static func isControlPressed(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.control)
    }

    static func isCommandPressed(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
    }

    static func isShiftPressed(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.shift)
    }
}

final class LauncherSearchField: NSSearchField {
    var onMoveSelection: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard LauncherKey.isCommandPressed(event) else {
            return super.performKeyEquivalent(with: event)
        }

        guard let editor = currentEditor() else {
            if event.keyCode == LauncherKey.a {
                selectText(nil)
                return true
            }

            return super.performKeyEquivalent(with: event)
        }

        switch event.keyCode {
        case LauncherKey.a:
            editor.selectAll(nil)
        case LauncherKey.c:
            editor.copy(nil)
        case LauncherKey.x:
            editor.cut(nil)
        case LauncherKey.v:
            editor.paste(nil)
        case LauncherKey.z:
            if LauncherKey.isShiftPressed(event) {
                editor.undoManager?.redo()
            } else {
                editor.undoManager?.undo()
            }
        default:
            return super.performKeyEquivalent(with: event)
        }

        return true
    }

    override func keyDown(with event: NSEvent) {
        if LauncherKey.isControlPressed(event) {
            switch event.keyCode {
            case LauncherKey.n:
                onMoveSelection?(1)
            case LauncherKey.p:
                onMoveSelection?(-1)
            default:
                super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case LauncherKey.returnKey, LauncherKey.keypadEnter:
            onSubmit?()
        case LauncherKey.escape:
            onCancel?()
        case LauncherKey.downArrow:
            onMoveSelection?(1)
        case LauncherKey.upArrow:
            onMoveSelection?(-1)
        default:
            super.keyDown(with: event)
        }
    }
}

final class LauncherTableView: NSTableView {
    var onMoveSelection: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if LauncherKey.isControlPressed(event) {
            switch event.keyCode {
            case LauncherKey.n:
                onMoveSelection?(1)
            case LauncherKey.p:
                onMoveSelection?(-1)
            default:
                super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case LauncherKey.returnKey, LauncherKey.keypadEnter:
            onSubmit?()
        case LauncherKey.escape:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class LauncherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else {
            return
        }

        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        let selectedRect = bounds.insetBy(dx: 6, dy: 3)
        NSBezierPath(roundedRect: selectedRect, xRadius: 8, yRadius: 8).fill()
    }
}

final class AppCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppCellView")

    private let appIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let hideButton = NSButton()
    private var app: LaunchableApp?
    private var onHide: ((LaunchableApp) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(with app: LaunchableApp, onHide: ((LaunchableApp) -> Void)?) {
        self.app = app
        self.onHide = onHide
        hideButton.isHidden = onHide == nil

        if app.targetKind == .bluetoothConnect || app.targetKind == .bluetoothDisconnect {
            appIconView.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)
        } else if app.targetKind == .webSearch {
            appIconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        } else if let audioIcon = icon(forAudioTargetKind: app.targetKind) {
            appIconView.image = audioIcon
        } else if app.targetKind == .bookmark {
            appIconView.image = NSWorkspace.shared.icon(for: .url)
        } else if let url = app.url {
            appIconView.image = NSWorkspace.shared.icon(forFile: url.path)
        } else if
            let processIdentifier = app.processIdentifier,
            let runningApplication = NSRunningApplication(processIdentifier: processIdentifier),
            let icon = runningApplication.icon {
            appIconView.image = icon
        } else {
            appIconView.image = NSWorkspace.shared.icon(for: .applicationBundle)
        }

        titleLabel.stringValue = app.name
        detailLabel.stringValue = app.subtitle
    }

    @objc private func hideButtonClicked(_ sender: NSButton) {
        guard let app else {
            return
        }

        onHide?(app)
    }

    private func icon(forAudioTargetKind targetKind: LaunchTargetKind) -> NSImage? {
        switch targetKind {
        case .audioInput:
            return NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        case .audioOutput:
            return NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        case .application, .window, .bookmark, .webSearch, .bluetoothConnect, .bluetoothDisconnect:
            return nil
        }
    }

    private func setup() {
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        hideButton.translatesAutoresizingMaskIntoConstraints = false
        hideButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Hide")
        hideButton.imagePosition = .imageOnly
        hideButton.isBordered = false
        hideButton.focusRingType = .none
        hideButton.contentTintColor = .secondaryLabelColor
        hideButton.toolTip = "Hide"
        hideButton.target = self
        hideButton.action = #selector(hideButtonClicked(_:))

        imageView = appIconView
        textField = titleLabel

        addSubview(appIconView)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(hideButton)

        NSLayoutConstraint.activate([
            appIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            appIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 32),
            appIconView.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: hideButton.leadingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            hideButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hideButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            hideButton.widthAnchor.constraint(equalToConstant: 28),
            hideButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }
}

final class PreferencesViewController: NSViewController {
    var onIncludeChromeBookmarksChanged: ((Bool) -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    var onRestoreHiddenCandidate: ((HiddenCandidate) -> Void)?

    private let includeChromeBookmarksButton = NSButton(
        checkboxWithTitle: "Chrome bookmarks",
        target: nil,
        action: nil
    )
    private let launchAtLoginButton = NSButton(
        checkboxWithTitle: "Launch at login",
        target: nil,
        action: nil
    )
    private let hiddenCandidatesLabel = NSTextField(labelWithString: "0 hidden")
    private let hiddenCandidatesMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let restoreHiddenCandidateButton = NSButton(
        title: "Restore",
        target: nil,
        action: nil
    )
    private var hiddenCandidates: [HiddenCandidate] = []

    init(includeChromeBookmarks: Bool, launchAtLogin: Bool, hiddenCandidates: [HiddenCandidate]) {
        super.init(nibName: nil, bundle: nil)
        includeChromeBookmarksButton.state = includeChromeBookmarks ? .on : .off
        launchAtLoginButton.state = launchAtLogin ? .on : .off
        setHiddenCandidates(hiddenCandidates)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 284))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setup()
    }

    func setIncludeChromeBookmarks(_ includeChromeBookmarks: Bool) {
        includeChromeBookmarksButton.state = includeChromeBookmarks ? .on : .off
    }

    func setLaunchAtLogin(_ launchAtLogin: Bool) {
        launchAtLoginButton.state = launchAtLogin ? .on : .off
    }

    func setHiddenCandidates(_ hiddenCandidates: [HiddenCandidate]) {
        self.hiddenCandidates = hiddenCandidates.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        hiddenCandidatesLabel.stringValue = "\(hiddenCandidates.count) hidden"

        hiddenCandidatesMenu.removeAllItems()
        if self.hiddenCandidates.isEmpty {
            hiddenCandidatesMenu.addItem(withTitle: "No hidden items")
        } else {
            for candidate in self.hiddenCandidates {
                hiddenCandidatesMenu.addItem(withTitle: hiddenCandidateTitle(candidate))
                hiddenCandidatesMenu.lastItem?.representedObject = candidate.key
            }
        }

        hiddenCandidatesMenu.isEnabled = !self.hiddenCandidates.isEmpty
        restoreHiddenCandidateButton.isEnabled = !self.hiddenCandidates.isEmpty
    }

    private func setup() {
        let sourcesLabel = sectionLabel("Sources")
        let startupLabel = sectionLabel("Startup")
        let hiddenItemsLabel = sectionLabel("Hidden Items")

        includeChromeBookmarksButton.translatesAutoresizingMaskIntoConstraints = false
        includeChromeBookmarksButton.target = self
        includeChromeBookmarksButton.action = #selector(toggleIncludeChromeBookmarks(_:))

        launchAtLoginButton.translatesAutoresizingMaskIntoConstraints = false
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(toggleLaunchAtLogin(_:))

        hiddenCandidatesLabel.translatesAutoresizingMaskIntoConstraints = false
        hiddenCandidatesLabel.textColor = .secondaryLabelColor

        hiddenCandidatesMenu.translatesAutoresizingMaskIntoConstraints = false

        restoreHiddenCandidateButton.translatesAutoresizingMaskIntoConstraints = false
        restoreHiddenCandidateButton.target = self
        restoreHiddenCandidateButton.action = #selector(restoreHiddenCandidate(_:))

        view.addSubview(sourcesLabel)
        view.addSubview(includeChromeBookmarksButton)
        view.addSubview(startupLabel)
        view.addSubview(launchAtLoginButton)
        view.addSubview(hiddenItemsLabel)
        view.addSubview(hiddenCandidatesLabel)
        view.addSubview(hiddenCandidatesMenu)
        view.addSubview(restoreHiddenCandidateButton)

        NSLayoutConstraint.activate([
            sourcesLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            sourcesLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            sourcesLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),

            includeChromeBookmarksButton.leadingAnchor.constraint(equalTo: sourcesLabel.leadingAnchor),
            includeChromeBookmarksButton.trailingAnchor.constraint(lessThanOrEqualTo: sourcesLabel.trailingAnchor),
            includeChromeBookmarksButton.topAnchor.constraint(equalTo: sourcesLabel.bottomAnchor, constant: 14),

            startupLabel.leadingAnchor.constraint(equalTo: sourcesLabel.leadingAnchor),
            startupLabel.trailingAnchor.constraint(equalTo: sourcesLabel.trailingAnchor),
            startupLabel.topAnchor.constraint(equalTo: includeChromeBookmarksButton.bottomAnchor, constant: 24),

            launchAtLoginButton.leadingAnchor.constraint(equalTo: sourcesLabel.leadingAnchor),
            launchAtLoginButton.trailingAnchor.constraint(lessThanOrEqualTo: sourcesLabel.trailingAnchor),
            launchAtLoginButton.topAnchor.constraint(equalTo: startupLabel.bottomAnchor, constant: 14),

            hiddenItemsLabel.leadingAnchor.constraint(equalTo: sourcesLabel.leadingAnchor),
            hiddenItemsLabel.trailingAnchor.constraint(equalTo: sourcesLabel.trailingAnchor),
            hiddenItemsLabel.topAnchor.constraint(equalTo: launchAtLoginButton.bottomAnchor, constant: 24),

            hiddenCandidatesLabel.leadingAnchor.constraint(equalTo: sourcesLabel.leadingAnchor),
            hiddenCandidatesLabel.trailingAnchor.constraint(equalTo: sourcesLabel.trailingAnchor),
            hiddenCandidatesLabel.topAnchor.constraint(equalTo: hiddenItemsLabel.bottomAnchor, constant: 8),

            hiddenCandidatesMenu.leadingAnchor.constraint(equalTo: sourcesLabel.leadingAnchor),
            hiddenCandidatesMenu.trailingAnchor.constraint(equalTo: restoreHiddenCandidateButton.leadingAnchor, constant: -10),
            hiddenCandidatesMenu.topAnchor.constraint(equalTo: hiddenCandidatesLabel.bottomAnchor, constant: 10),

            restoreHiddenCandidateButton.trailingAnchor.constraint(equalTo: sourcesLabel.trailingAnchor),
            restoreHiddenCandidateButton.centerYAnchor.constraint(equalTo: hiddenCandidatesMenu.centerYAnchor),
            restoreHiddenCandidateButton.widthAnchor.constraint(equalToConstant: 82)
        ])
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    @objc private func toggleIncludeChromeBookmarks(_ sender: NSButton) {
        onIncludeChromeBookmarksChanged?(sender.state == .on)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        onLaunchAtLoginChanged?(sender.state == .on)
    }

    private func hiddenCandidateTitle(_ candidate: HiddenCandidate) -> String {
        let name = candidate.name.isEmpty ? candidate.key : candidate.name
        guard !candidate.kind.isEmpty else {
            return name
        }

        return "\(name) (\(candidate.kind))"
    }

    @objc private func restoreHiddenCandidate(_ sender: NSButton) {
        guard
            let key = hiddenCandidatesMenu.selectedItem?.representedObject as? String,
            let candidate = hiddenCandidates.first(where: { $0.key == key })
        else {
            return
        }

        onRestoreHiddenCandidate?(candidate)
    }
}

final class PreferencesWindowController: NSWindowController {
    private let preferencesViewController: PreferencesViewController

    init(
        includeChromeBookmarks: Bool,
        launchAtLogin: Bool,
        hiddenCandidates: [HiddenCandidate],
        onIncludeChromeBookmarksChanged: @escaping (Bool) -> Void,
        onLaunchAtLoginChanged: @escaping (Bool) -> Void,
        onRestoreHiddenCandidate: @escaping (HiddenCandidate) -> Void
    ) {
        self.preferencesViewController = PreferencesViewController(
            includeChromeBookmarks: includeChromeBookmarks,
            launchAtLogin: launchAtLogin,
            hiddenCandidates: hiddenCandidates
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 284),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.contentViewController = preferencesViewController
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        preferencesViewController.onIncludeChromeBookmarksChanged = onIncludeChromeBookmarksChanged
        preferencesViewController.onLaunchAtLoginChanged = onLaunchAtLoginChanged
        preferencesViewController.onRestoreHiddenCandidate = onRestoreHiddenCandidate
    }

    required init?(coder: NSCoder) {
        nil
    }

    func syncFromPreferences() {
        preferencesViewController.setIncludeChromeBookmarks(AppPreferences.includeChromeBookmarks)
        preferencesViewController.setLaunchAtLogin(LoginItemManager.isEnabled)
        preferencesViewController.setHiddenCandidates(AppPreferences.hiddenCandidates)
    }
}

private enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func enableByDefaultIfNeeded() {
        guard
            !AppPreferences.didApplyLaunchAtLoginDefault,
            Bundle.main.bundleURL.pathExtension == "app"
        else {
            return
        }

        defer {
            AppPreferences.didApplyLaunchAtLoginDefault = true
        }

        do {
            try setEnabled(true)
            AppLog.write("launch_at_login_default_applied", [
                "launch_at_login": isEnabled
            ])
        } catch {
            AppLog.write("launch_at_login_default_failed", [
                "reason": error.localizedDescription
            ])
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard !isEnabled else {
                return
            }

            try SMAppService.mainApp.register()
        } else {
            guard isEnabled else {
                return
            }

            try SMAppService.mainApp.unregister()
        }
    }
}

final class LauncherViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onLaunch: ((LaunchableApp) -> Void)?
    var onClose: (() -> Void)?
    var onHide: ((LaunchableApp) -> Void)?
    var isHidden: ((LaunchableApp) -> Bool)?
    var sortApps: (([LaunchableApp]) -> [LaunchableApp])?

    private let effectView = NSVisualEffectView()
    private let searchField = LauncherSearchField()
    private let scrollView = NSScrollView()
    private let tableView = LauncherTableView()
    private let emptyLabel = NSTextField(labelWithString: "No matching items")

    private var apps: [LaunchableApp] = []
    private var filteredApps: [LaunchableApp] = []

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        setupSearchField()
        setupTableView()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        tableView.tableColumns.first?.width = tableView.bounds.width
    }

    func prepareForPresentation(apps: [LaunchableApp]) {
        self.apps = apps
        searchField.stringValue = ""
        applyFilter()
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    private func setupView() {
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true

        view.addSubview(effectView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: view.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupSearchField() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search"
        searchField.font = .systemFont(ofSize: 18)
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.onMoveSelection = { [weak self] delta in
            self?.moveSelection(by: delta)
        }
        searchField.onSubmit = { [weak self] in
            self?.launchSelectedApp()
        }
        searchField.onCancel = { [weak self] in
            self?.onClose?()
        }

        effectView.addSubview(searchField)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -20),
            searchField.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 18),
            searchField.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    private func setupTableView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 54
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleClick(_:))
        tableView.focusRingType = .none
        tableView.onMoveSelection = { [weak self] delta in
            self?.moveSelection(by: delta)
        }
        tableView.onSubmit = { [weak self] in
            self?.launchSelectedApp()
        }
        tableView.onCancel = { [weak self] in
            self?.onClose?()
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        effectView.addSubview(scrollView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        effectView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else {
            return false
        }

        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(by: 1)
            return true
        }

        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(by: -1)
            return true
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
            commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            launchSelectedApp()
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }

        if commandSelector == #selector(NSResponder.selectAll(_:)) {
            textView.selectAll(nil)
            return true
        }

        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredApps.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LauncherRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(
            withIdentifier: AppCellView.reuseIdentifier,
            owner: self
        ) as? AppCellView ?? AppCellView()

        cell.configure(with: filteredApps[row]) { [weak self] app in
            self?.hide(app)
        }
        return cell
    }

    @objc private func handleClick(_ sender: Any?) {
        let clickedRow = tableView.clickedRow
        guard filteredApps.indices.contains(clickedRow) else {
            return
        }

        onLaunch?(filteredApps[clickedRow])
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingApps = apps.filter { app in
            app.matches(query) && !(isHidden?(app) ?? false)
        }
        filteredApps = sortApps?(matchingApps) ?? matchingApps

        if
            let webSearchCandidate = WebSearchCandidateFactory.candidate(for: query),
            !(isHidden?(webSearchCandidate) ?? false) {
            filteredApps.append(webSearchCandidate)
        }

        tableView.reloadData()
        emptyLabel.isHidden = !filteredApps.isEmpty

        if filteredApps.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filteredApps.isEmpty else {
            return
        }

        let currentRow = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let nextRow = min(max(currentRow + delta, 0), filteredApps.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(nextRow)
    }

    private func launchSelectedApp() {
        let selectedRow = tableView.selectedRow
        guard filteredApps.indices.contains(selectedRow) else {
            return
        }

        onLaunch?(filteredApps[selectedRow])
    }

    private func hide(_ app: LaunchableApp) {
        onHide?(app)
        applyFilter()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launcherViewController = LauncherViewController()
    private let launchHistoryStore = LaunchHistoryStore()
    private var window: LauncherPanel?
    private var preferencesWindowController: PreferencesWindowController?
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var cachedInstalledApps: [LaunchableApp] = []
    private var cachedBookmarks: [LaunchableApp] = []
    private var cachedAudioDevices: [LaunchableApp] = []
    private var cachedBluetoothDevices: [LaunchableApp] = []
    private var cachedApps: [LaunchableApp] = []
    private var lastScanDate = Date.distantPast
    private var previousFrontmostProcessIdentifier: pid_t?
    private var previousFrontmostWindowTitle: String?
    private var isRelaunchingFromReopen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.start()
        terminateOtherRunningInstances()
        NSApp.setActivationPolicy(.accessory)
        setupWindow()
        setupStatusItem()
        registerHotKey()
        LoginItemManager.enableByDefaultIfNeeded()
        refreshApplications(force: true)
        WindowPermissionManager.requestStartupPermissions()
        AppLog.write("application_did_finish_launching", [
            "cached_installed_apps": cachedInstalledApps.count,
            "cached_bookmarks": cachedBookmarks.count,
            "cached_audio_devices": cachedAudioDevices.count,
            "cached_bluetooth_devices": cachedBluetoothDevices.count,
            "cached_apps": cachedApps.count
        ])
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        relaunchCurrentBundleAndTerminate(reason: "reopen")
        return false
    }

    private func relaunchCurrentBundleAndTerminate(reason: String) {
        guard !isRelaunchingFromReopen else {
            return
        }

        isRelaunchingFromReopen = true

        let bundleURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]

        do {
            try process.run()
            AppLog.write("relaunch_current_bundle", [
                "reason": reason,
                "bundle_path": bundleURL.path,
                "result": "started"
            ])
            NSApp.terminate(nil)
        } catch {
            isRelaunchingFromReopen = false
            AppLog.write("relaunch_current_bundle", [
                "reason": reason,
                "bundle_path": bundleURL.path,
                "result": "failed",
                "error": error.localizedDescription
            ])
            showLauncher()
        }
    }

    private func terminateOtherRunningInstances() {
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let knownBundleIdentifiers = [
            currentBundleIdentifier,
            "com.juninaba.TakoLauncher"
        ].compactMap { $0 }

        let otherApplications = NSWorkspace.shared.runningApplications.filter { runningApplication in
            guard runningApplication.processIdentifier != currentProcessIdentifier else {
                return false
            }

            return knownBundleIdentifiers.contains { bundleIdentifier in
                runningApplication.bundleIdentifier == bundleIdentifier
            }
        }

        guard !otherApplications.isEmpty else {
            AppLog.write("terminate_other_instances", [
                "result": "none"
            ])
            return
        }

        let terminationRequests = otherApplications.map { runningApplication -> [String: Any] in
            let requested = runningApplication.terminate()
            return [
                "pid": Int(runningApplication.processIdentifier),
                "bundle_id": runningApplication.bundleIdentifier ?? "nil",
                "bundle_url": runningApplication.bundleURL?.path ?? "nil",
                "terminate_requested": requested
            ]
        }

        waitForTermination(of: otherApplications, timeout: 1.5)

        let forceTerminationRequests = otherApplications
            .filter { !$0.isTerminated }
            .map { runningApplication -> [String: Any] in
                let requested = runningApplication.forceTerminate()
                return [
                    "pid": Int(runningApplication.processIdentifier),
                    "bundle_id": runningApplication.bundleIdentifier ?? "nil",
                    "force_terminate_requested": requested
                ]
            }

        if !forceTerminationRequests.isEmpty {
            waitForTermination(of: otherApplications, timeout: 0.8)
        }

        AppLog.write("terminate_other_instances", [
            "result": "attempted",
            "termination_requests": terminationRequests,
            "force_termination_requests": forceTerminationRequests,
            "remaining_pids": otherApplications
                .filter { !$0.isTerminated }
                .map { Int($0.processIdentifier) }
        ])
    }

    private func waitForTermination(
        of applications: [NSRunningApplication],
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            guard applications.contains(where: { !$0.isTerminated }) else {
                return
            }

            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.05)
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    private func setupWindow() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.contentViewController = launcherViewController
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        launcherViewController.onLaunch = { [weak self] app in
            self?.launch(app)
        }
        launcherViewController.onClose = { [weak self] in
            self?.hideLauncher()
        }
        launcherViewController.onHide = { [weak self] app in
            self?.hideCandidate(app)
        }
        launcherViewController.isHidden = { app in
            AppPreferences.isCandidateHidden(app)
        }
        launcherViewController.sortApps = { [weak self] apps in
            self?.launchHistoryStore.sort(apps) ?? apps
        }

        window = panel
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.toolTip = "Tendon"

            if let icon = statusItemIcon() {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = false
                button.image = icon
                button.imagePosition = .imageOnly
                button.title = ""
            } else {
                button.title = "Tendon"
            }
        }

        let menu = NSMenu()
        let preferencesItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(showPreferencesFromMenu),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    private func statusItemIcon() -> NSImage? {
        if let bundledIconURL = Bundle.main.url(forResource: "tendon", withExtension: "png") {
            return NSImage(contentsOf: bundledIconURL)
        }

        let developmentIconURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent("assets/tendon.png")

        return NSImage(contentsOf: developmentIconURL)
    }

    private func registerHotKey() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return noErr
                }

                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard hotKeyID.id == 1 else {
                    return noErr
                }

                let delegate = Unmanaged<AppDelegate>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                DispatchQueue.main.async {
                    delegate.toggleLauncher()
                }

                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            reportHotKeyFailure(status: installStatus)
            return
        }

        let hotKeyID = EventHotKeyID(signature: fourCharacterCode("TNDN"), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_N),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            reportHotKeyFailure(status: registerStatus)
        }
    }

    private func reportHotKeyFailure(status: OSStatus) {
        fputs("Failed to register Option+N hotkey: \(status)\n", stderr)
        statusItem?.button?.title = "Tendon!"
        statusItem?.button?.toolTip = "Option+N could not be registered"
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func showPreferencesFromMenu() {
        hideLauncher()

        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                includeChromeBookmarks: AppPreferences.includeChromeBookmarks,
                launchAtLogin: LoginItemManager.isEnabled,
                hiddenCandidates: AppPreferences.hiddenCandidates,
                onIncludeChromeBookmarksChanged: { [weak self] includeChromeBookmarks in
                    AppPreferences.includeChromeBookmarks = includeChromeBookmarks
                    self?.refreshApplications(force: true)
                    AppLog.write("preferences_changed", [
                        "include_chrome_bookmarks": includeChromeBookmarks
                    ])
                },
                onLaunchAtLoginChanged: { [weak self] launchAtLogin in
                    AppPreferences.didApplyLaunchAtLoginDefault = true

                    do {
                        try LoginItemManager.setEnabled(launchAtLogin)
                        AppLog.write("preferences_changed", [
                            "launch_at_login": LoginItemManager.isEnabled
                        ])
                    } catch {
                        NSSound.beep()
                        AppLog.write("preferences_change_failed", [
                            "launch_at_login": launchAtLogin,
                            "reason": error.localizedDescription
                        ])
                    }

                    self?.preferencesWindowController?.syncFromPreferences()
                },
                onRestoreHiddenCandidate: { [weak self] candidate in
                    AppPreferences.restoreHiddenCandidate(candidate)
                    self?.refreshApplications(force: true)
                    self?.preferencesWindowController?.syncFromPreferences()
                    AppLog.write("hidden_candidate_restored", [
                        "name": candidate.name,
                        "kind": candidate.kind,
                        "hidden_key": candidate.key,
                        "hidden_candidate_count": AppPreferences.hiddenCandidateCount
                    ])
                }
            )
        }

        preferencesWindowController?.syncFromPreferences()
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func toggleLauncher() {
        guard let window else {
            return
        }

        if window.isVisible {
            hideLauncher()
        } else {
            showLauncher()
        }
    }

    private func showLauncher() {
        capturePreviousFrontmostWindow()
        refreshApplications(force: false)
        let actionableCandidateResult = actionableCandidates(from: cachedApps)
        launcherViewController.prepareForPresentation(apps: actionableCandidateResult.candidates)
        positionWindow()
        AppLog.write("show_launcher", [
            "candidate_count": actionableCandidateResult.candidates.count,
            "raw_candidate_count": cachedApps.count,
            "hidden_noop_candidates": actionableCandidateResult.hiddenCounts,
            "previous_pid": logPID(previousFrontmostProcessIdentifier),
            "previous_title": previousFrontmostWindowTitle ?? "nil"
        ])

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async { [weak self] in
            self?.launcherViewController.focusSearchField()
        }
    }

    private func hideLauncher() {
        window?.orderOut(nil)
    }

    private func capturePreviousFrontmostWindow() {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            previousFrontmostProcessIdentifier = nil
            previousFrontmostWindowTitle = nil
            AppLog.write("capture_previous_frontmost_window", [
                "result": "no_frontmost_application"
            ])
            return
        }

        let processIdentifier = frontmostApplication.processIdentifier
        previousFrontmostProcessIdentifier = processIdentifier
        previousFrontmostWindowTitle = WindowActivator.frontmostWindowTitle(for: processIdentifier)

        if let previousFrontmostWindowTitle {
            let appHistoryKey = historyKey(for: frontmostApplication)
            let windowHistoryKey = WindowHistoryKey.make(
                appHistoryKey: appHistoryKey,
                title: previousFrontmostWindowTitle,
                applicationName: frontmostApplication.localizedName
            )
            launchHistoryStore.recordUse(historyKey: windowHistoryKey)
            AppLog.write("record_frontmost_window_use", [
                "bundle_id": frontmostApplication.bundleIdentifier ?? "nil",
                "localized_name": frontmostApplication.localizedName ?? "nil",
                "pid": Int(processIdentifier),
                "window_title": previousFrontmostWindowTitle,
                "history_key": windowHistoryKey
            ])
        }

        AppLog.write("capture_previous_frontmost_window", [
            "pid": Int(processIdentifier),
            "localized_name": frontmostApplication.localizedName ?? "nil",
            "bundle_id": frontmostApplication.bundleIdentifier ?? "nil",
            "window_title": previousFrontmostWindowTitle ?? "nil"
        ])
    }

    private func positionWindow() {
        guard let window else {
            return
        }

        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let width = min(680, max(360, screenFrame.width - 32))
        let height = min(420, max(300, screenFrame.height - 80))
        let windowSize = NSSize(width: width, height: height)
        window.setContentSize(windowSize)

        let preferredY = screenFrame.midY + screenFrame.height * 0.12
        let minY = screenFrame.minY + 24
        let maxY = max(minY, screenFrame.maxY - windowSize.height - 24)

        let origin = NSPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: min(max(preferredY, minY), maxY)
        )
        window.setFrameOrigin(origin)
    }

    private func refreshApplications(force: Bool) {
        if force || cachedInstalledApps.isEmpty || Date().timeIntervalSince(lastScanDate) > 30 {
            cachedInstalledApps = AppDiscovery.loadInstalledApplications()
            cachedBookmarks = AppPreferences.includeChromeBookmarks ?
                ChromeBookmarkDiscovery.loadBookmarks() :
                []
            lastScanDate = Date()
        }

        cachedAudioDevices = AudioDeviceDiscovery.loadDevices()
        cachedBluetoothDevices = BluetoothDeviceDiscovery.loadDevices()
        rebuildCandidateCache()
        AppLog.write("refresh_applications", [
            "force": force,
            "include_chrome_bookmarks": AppPreferences.includeChromeBookmarks,
            "installed_candidates": cachedInstalledApps.count,
            "bookmark_candidates": cachedBookmarks.count,
            "audio_device_candidates": cachedAudioDevices.count,
            "bluetooth_device_candidates": cachedBluetoothDevices.count,
            "all_candidates": cachedApps.count
        ])
    }

    private func rebuildCandidateCache() {
        cachedApps = AppDiscovery.includeRunningApplications(in: cachedInstalledApps) +
            cachedBookmarks +
            cachedAudioDevices +
            cachedBluetoothDevices
    }

    private func actionableCandidates(
        from candidates: [LaunchableApp]
    ) -> (candidates: [LaunchableApp], hiddenCounts: [String: Int]) {
        var hiddenCounts: [String: Int] = [:]
        var actionableCandidates: [LaunchableApp] = []

        for candidate in candidates {
            if let reason = noopCandidateReason(for: candidate) {
                hiddenCounts[reason, default: 0] += 1
            } else {
                actionableCandidates.append(candidate)
            }
        }

        return (actionableCandidates, hiddenCounts)
    }

    private func noopCandidateReason(for app: LaunchableApp) -> String? {
        if AppPreferences.isCandidateHidden(app) {
            return "hidden_by_user"
        }

        if isCurrentRunningApplication(app) {
            return "frontmost_running_application"
        }

        if isCurrentWindow(app) {
            return "frontmost_window"
        }

        if isCurrentAudioDevice(app) {
            return "current_audio_device"
        }

        return nil
    }

    private func hideCandidate(_ app: LaunchableApp) {
        AppPreferences.hideCandidate(app)
        preferencesWindowController?.syncFromPreferences()
        AppLog.write("candidate_hidden", [
            "name": app.name,
            "application_name": app.applicationName ?? "nil",
            "bundle_id": app.bundleIdentifier ?? "nil",
            "target_kind": app.targetKind.logValue,
            "hidden_key": app.hiddenKey,
            "hidden_candidate_count": AppPreferences.hiddenCandidateCount
        ])
    }

    private func isCurrentRunningApplication(_ app: LaunchableApp) -> Bool {
        app.targetKind == .application &&
            app.isRunning &&
            app.processIdentifier == previousFrontmostProcessIdentifier
    }

    private func isCurrentWindow(_ app: LaunchableApp) -> Bool {
        guard
            app.targetKind == .window,
            app.processIdentifier == previousFrontmostProcessIdentifier,
            let windowTitle = trimmed(app.windowTitle),
            let previousTitle = trimmed(previousFrontmostWindowTitle)
        else {
            return false
        }

        return normalized(windowTitle) == normalized(previousTitle)
    }

    private func isCurrentAudioDevice(_ app: LaunchableApp) -> Bool {
        (app.targetKind == .audioInput || app.targetKind == .audioOutput) &&
            app.applicationName == "Current"
    }

    private func launch(_ app: LaunchableApp) {
        hideLauncher()
        AppLog.write("launch_candidate", [
            "name": app.name,
            "application_name": (app.applicationName ?? "nil") as String,
            "bundle_id": (app.bundleIdentifier ?? "nil") as String,
            "identity_key": app.identityKey,
            "history_key": app.historyKey,
            "pid": logPID(app.processIdentifier),
            "is_running": app.isRunning,
            "target_kind": app.targetKind.logValue,
            "window_title": (app.windowTitle ?? "nil") as String,
            "window_identifier": logWindowIdentifier(app.windowIdentifier),
            "window_frame": logFrame(app.windowFrame),
            "audio_device_id": logAudioDeviceIdentifier(app.audioDeviceIdentifier),
            "audio_device_uid": app.audioDeviceUID ?? "nil",
            "bluetooth_device_address": app.bluetoothDeviceAddress ?? "nil"
        ])

        if app.targetKind == .audioInput || app.targetKind == .audioOutput {
            launchAudioDevice(app)
            return
        }

        if app.targetKind == .bluetoothConnect || app.targetKind == .bluetoothDisconnect {
            launchBluetoothDevice(app)
            return
        }

        if app.targetKind == .webSearch {
            launchWebSearch(app)
            return
        }

        if app.targetKind == .bookmark {
            guard let url = app.url else {
                NSSound.beep()
                AppLog.write("launch_failed", [
                    "name": app.name,
                    "reason": "missing_bookmark_url"
                ])
                return
            }

            if NSWorkspace.shared.open(url) {
                launchHistoryStore.recordLaunch(of: app)
                AppLog.write("launch_completed", [
                    "name": app.name,
                    "url": url.absoluteString
                ])
            } else {
                NSSound.beep()
                AppLog.write("launch_failed", [
                    "name": app.name,
                    "reason": "failed_to_open_bookmark_url"
                ])
            }

            return
        }

        if WindowActivator.activate(
            app,
            previousFrontmostProcessIdentifier: previousFrontmostProcessIdentifier,
            previousFrontmostWindowTitle: previousFrontmostWindowTitle
        ) {
            launchHistoryStore.recordLaunch(of: app)
            return
        }

        if app.targetKind == .window {
            NSSound.beep()
            AppLog.write("launch_failed", [
                "name": app.name,
                "reason": "target_window_not_focusable"
            ])
            return
        }

        if
            app.isRunning,
            let processIdentifier = app.processIdentifier,
            let runningApplication = NSRunningApplication(processIdentifier: processIdentifier) {
            runningApplication.unhide()

            if runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
                AppLog.write("running_app_fallback_activated", [
                    "name": app.name,
                    "pid": Int(processIdentifier)
                ])
                launchHistoryStore.recordLaunch(of: app)
                return
            }
        }

        guard let url = app.url else {
            NSSound.beep()
            fputs("Failed to activate \(app.name): no application URL is available\n", stderr)
            AppLog.write("launch_failed", [
                "name": app.name,
                "reason": "missing_url"
            ])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                NSSound.beep()
                fputs("Failed to launch \(app.name): \(error.localizedDescription)\n", stderr)
                AppLog.write("launch_failed", [
                    "name": app.name,
                    "reason": error.localizedDescription
                ])
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.launchHistoryStore.recordLaunch(of: app)
                AppLog.write("launch_completed", [
                    "name": app.name,
                    "url": url.path
                ])
            }
        }
    }

    private func launchWebSearch(_ app: LaunchableApp) {
        guard let url = app.url else {
            NSSound.beep()
            AppLog.write("launch_failed", [
                "name": app.name,
                "target_kind": app.targetKind.logValue,
                "reason": "missing_web_search_url"
            ])
            return
        }

        if NSWorkspace.shared.open(url) {
            AppLog.write("launch_completed", [
                "name": app.name,
                "target_kind": app.targetKind.logValue,
                "url": url.absoluteString
            ])
        } else {
            NSSound.beep()
            AppLog.write("launch_failed", [
                "name": app.name,
                "target_kind": app.targetKind.logValue,
                "reason": "failed_to_open_web_search_url"
            ])
        }
    }

    private func launchBluetoothDevice(_ app: LaunchableApp) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = BluetoothDeviceDiscovery.setConnection(for: app)

            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                guard result?.success == true else {
                    NSSound.beep()
                    AppLog.write("launch_failed", [
                        "name": app.name,
                        "target_kind": app.targetKind.logValue,
                        "bluetooth_device_address": app.bluetoothDeviceAddress ?? "nil",
                        "reason": "failed_to_switch_bluetooth_device",
                        "result": result?.logPayload ?? [:]
                    ])
                    return
                }

                self.launchHistoryStore.recordLaunch(of: app)
                self.cachedBluetoothDevices = BluetoothDeviceDiscovery.loadDevices()
                self.rebuildCandidateCache()
                AppLog.write("launch_completed", [
                    "name": app.name,
                    "target_kind": app.targetKind.logValue,
                    "bluetooth_device_address": app.bluetoothDeviceAddress ?? "nil",
                    "result": result?.logPayload ?? [:]
                ])
            }
        }
    }

    private func launchAudioDevice(_ app: LaunchableApp) {
        if AudioDeviceDiscovery.setDefaultDevice(for: app) {
            launchHistoryStore.recordLaunch(of: app)
            cachedAudioDevices = AudioDeviceDiscovery.loadDevices()
            rebuildCandidateCache()
            AppLog.write("launch_completed", [
                "name": app.name,
                "target_kind": app.targetKind.logValue,
                "audio_device_id": logAudioDeviceIdentifier(app.audioDeviceIdentifier),
                "audio_device_uid": app.audioDeviceUID ?? "nil"
            ])
        } else {
            NSSound.beep()
            AppLog.write("launch_failed", [
                "name": app.name,
                "target_kind": app.targetKind.logValue,
                "audio_device_id": logAudioDeviceIdentifier(app.audioDeviceIdentifier),
                "audio_device_uid": app.audioDeviceUID ?? "nil",
                "reason": "failed_to_switch_audio_device"
            ])
        }
    }

    private func logFrame(_ frame: WindowFrame?) -> [String: Any] {
        guard let frame else {
            return [:]
        }

        return [
            "x": frame.x,
            "y": frame.y,
            "width": frame.width,
            "height": frame.height
        ]
    }

    private func logPID(_ processIdentifier: pid_t?) -> Any {
        processIdentifier.map { Int($0) } ?? NSNull()
    }

    private func logWindowIdentifier(_ windowIdentifier: UInt32?) -> Any {
        windowIdentifier.map { Int($0) } ?? NSNull()
    }

    private func logAudioDeviceIdentifier(_ audioDeviceIdentifier: AudioDeviceID?) -> Any {
        audioDeviceIdentifier.map { Int($0) } ?? NSNull()
    }

    private func historyKey(for runningApplication: NSRunningApplication) -> String {
        if let bundleIdentifier = runningApplication.bundleIdentifier {
            return "bundle:\(bundleIdentifier)"
        }

        if let bundleURL = runningApplication.bundleURL {
            return "path:\(bundleURL.resolvingSymlinksInPath().path)"
        }

        return "pid:\(runningApplication.processIdentifier)"
    }

    private func trimmed(_ string: String?) -> String? {
        guard let string else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

private func fourCharacterCode(_ code: String) -> OSType {
    code.utf8.reduce(0) { result, character in
        (result << 8) + OSType(character)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
