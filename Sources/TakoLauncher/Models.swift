import CoreAudio
import Darwin
import Foundation

enum AppPreferences {
    private static let includeChromeBookmarksKey = "includeChromeBookmarks"
    private static let didApplyLaunchAtLoginDefaultKey = "didApplyLaunchAtLoginDefault"

    static var includeChromeBookmarks: Bool {
        get {
            guard UserDefaults.standard.object(forKey: includeChromeBookmarksKey) != nil else {
                return true
            }

            return UserDefaults.standard.bool(forKey: includeChromeBookmarksKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: includeChromeBookmarksKey)
        }
    }

    static var didApplyLaunchAtLoginDefault: Bool {
        get {
            UserDefaults.standard.bool(forKey: didApplyLaunchAtLoginDefaultKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: didApplyLaunchAtLoginDefaultKey)
        }
    }
}

enum LaunchTargetKind: Hashable {
    case application
    case window
    case bookmark
    case audioInput
    case audioOutput
    case webSearch
    case bluetoothConnect
    case bluetoothDisconnect

    var logValue: String {
        switch self {
        case .application:
            return "application"
        case .window:
            return "window"
        case .bookmark:
            return "bookmark"
        case .audioInput:
            return "audio_input"
        case .audioOutput:
            return "audio_output"
        case .webSearch:
            return "web_search"
        case .bluetoothConnect:
            return "bluetooth_connect"
        case .bluetoothDisconnect:
            return "bluetooth_disconnect"
        }
    }
}

struct WindowFrame: Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct LaunchableApp: Hashable {
    let name: String
    let applicationName: String?
    let url: URL?
    let bundleIdentifier: String?
    let searchText: String
    let identityKey: String
    let historyKey: String
    let processIdentifier: pid_t?
    let isRunning: Bool
    let targetKind: LaunchTargetKind
    let windowTitle: String?
    let windowFrame: WindowFrame?
    let windowIdentifier: UInt32?
    let audioDeviceIdentifier: AudioDeviceID?
    let audioDeviceUID: String?
    let bluetoothDeviceAddress: String?

    init(
        name: String,
        applicationName: String?,
        url: URL?,
        bundleIdentifier: String?,
        searchText: String,
        identityKey: String,
        historyKey: String,
        processIdentifier: pid_t?,
        isRunning: Bool,
        targetKind: LaunchTargetKind,
        windowTitle: String?,
        windowFrame: WindowFrame?,
        windowIdentifier: UInt32?,
        audioDeviceIdentifier: AudioDeviceID? = nil,
        audioDeviceUID: String? = nil,
        bluetoothDeviceAddress: String? = nil
    ) {
        self.name = name
        self.applicationName = applicationName
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.searchText = searchText
        self.identityKey = identityKey
        self.historyKey = historyKey
        self.processIdentifier = processIdentifier
        self.isRunning = isRunning
        self.targetKind = targetKind
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
        self.windowIdentifier = windowIdentifier
        self.audioDeviceIdentifier = audioDeviceIdentifier
        self.audioDeviceUID = audioDeviceUID
        self.bluetoothDeviceAddress = bluetoothDeviceAddress
    }

    var subtitle: String {
        switch targetKind {
        case .application:
            let detail = bundleIdentifier ?? url?.path ?? processIdentifier.map { "pid \($0)" } ?? "Unknown source"
            return isRunning ? "Running - \(detail)" : detail
        case .window:
            let owner = applicationName ?? bundleIdentifier ?? processIdentifier.map { "pid \($0)" } ?? "Unknown app"
            return "Window - \(owner)"
        case .bookmark:
            let detail = url?.absoluteString ?? "Unknown URL"
            if let applicationName, !applicationName.isEmpty {
                return "Bookmark - \(applicationName) - \(detail)"
            }

            return "Bookmark - \(detail)"
        case .audioInput:
            let suffix = applicationName.map { " - \($0)" } ?? ""
            return "Sound Input\(suffix)"
        case .audioOutput:
            let suffix = applicationName.map { " - \($0)" } ?? ""
            return "Sound Output\(suffix)"
        case .webSearch:
            return url?.absoluteString ?? "Google Search"
        case .bluetoothConnect:
            return "Bluetooth - Not Connected"
        case .bluetoothDisconnect:
            return "Bluetooth - Connected"
        }
    }

    var resolvedPath: String? {
        guard url?.isFileURL == true else {
            return nil
        }

        return url?.resolvingSymlinksInPath().path
    }

    func matches(_ query: String) -> Bool {
        let tokens = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            switch targetKind {
            case .application, .window:
                return true
            case .bookmark, .audioInput, .audioOutput, .webSearch, .bluetoothConnect, .bluetoothDisconnect:
                return false
            }
        }

        return tokens.allSatisfy { token in
            searchText.range(
                of: token,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    func markedRunning(processIdentifier: pid_t?) -> LaunchableApp {
        let runningSearchText = [searchText, "running"]
            .joined(separator: " ")

        return LaunchableApp(
            name: name,
            applicationName: applicationName,
            url: url,
            bundleIdentifier: bundleIdentifier,
            searchText: runningSearchText,
            identityKey: identityKey,
            historyKey: historyKey,
            processIdentifier: processIdentifier,
            isRunning: true,
            targetKind: targetKind,
            windowTitle: windowTitle,
            windowFrame: windowFrame,
            windowIdentifier: windowIdentifier,
            audioDeviceIdentifier: audioDeviceIdentifier,
            audioDeviceUID: audioDeviceUID,
            bluetoothDeviceAddress: bluetoothDeviceAddress
        )
    }
}
