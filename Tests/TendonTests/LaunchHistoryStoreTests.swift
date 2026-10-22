import Foundation
import XCTest
@testable import Tendon

final class LaunchHistoryStoreTests: XCTestCase {
    private var applicationSupportURL: URL!
    private var store: LaunchHistoryStore!

    override func setUpWithError() throws {
        applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TendonTests-\(UUID().uuidString)", isDirectory: true)
        store = LaunchHistoryStore(applicationSupportURL: applicationSupportURL)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: applicationSupportURL.path) {
            try FileManager.default.removeItem(at: applicationSupportURL)
        }
    }

    func testExternalActivationOverridesLauncherHistoryAndStackingOrder() {
        let launched = window("Launched", identifier: 1, sortIndex: 0)
        let external = window("External", identifier: 2, sortIndex: 10)
        store.recordLaunch(of: launched)
        activate(external)

        XCTAssertEqual(store.sort([launched, external]), [external, launched])
    }

    func testSwitchesWithinAndBetweenApplicationsUseActualActivationOrder() {
        let first = window("First", identifier: 1, processIdentifier: 10)
        let second = window("Second", identifier: 2, processIdentifier: 10)
        let otherApp = window("Other app", identifier: 3, processIdentifier: 20)
        activate(first)
        activate(second)
        activate(otherApp)
        activate(first)

        XCTAssertEqual(store.sort([second, first, otherApp]), [first, otherApp, second])
        // The frontmost window is filtered out before sorting launcher candidates.
        XCTAssertEqual(store.sort([second, otherApp]), [otherApp, second])
    }

    func testWindowIdentitySurvivesTitleChanges() {
        let original = window("Original title", identifier: 1, sortIndex: 10)
        let renamed = window("New title", identifier: 1, sortIndex: 10)
        let other = window("Other", identifier: 2, sortIndex: 0)
        activate(other)
        activate(original)

        XCTAssertEqual(store.sort([other, renamed]), [renamed, other])
    }

    func testWindowsWithIdenticalTitlesHaveIndependentActivationOrder() {
        let first = window("Same title", identifier: 1)
        let second = window("Same title", identifier: 2)
        let otherApp = window("Same title", identifier: 1, processIdentifier: 20)
        activate(first)
        activate(otherApp)
        activate(second)

        XCTAssertEqual(store.sort([first, second, otherApp]), [second, otherApp, first])
    }

    func testUnobservedWindowsPreferStackingOrderOverPersistedLaunchHistory() {
        let oldLaunch = window("Old launch", identifier: 1, sortIndex: 10)
        let front = window("Front", identifier: 2, sortIndex: 0)
        store.recordLaunch(of: oldLaunch)
        let reloadedStore = LaunchHistoryStore(applicationSupportURL: applicationSupportURL)

        XCTAssertEqual(reloadedStore.sort([oldLaunch, front]), [front, oldLaunch])
    }

    func testTitleFallbackIsScopedToProcessWhenWindowIdentifierIsUnavailable() {
        let first = window("Same title", identifier: nil, processIdentifier: 10)
        let second = window("Same title", identifier: nil, processIdentifier: 20)
        activate(first)
        activate(second)

        XCTAssertEqual(store.sort([first, second]), [second, first])
    }

    func testTitleOnlyObservationMatchesCoreGraphicsCandidateWithIdentifier() {
        let observed = window("Observed", identifier: nil, sortIndex: 10)
        let candidate = window("Observed", identifier: 1, sortIndex: 10)
        let other = window("Other", identifier: 2, sortIndex: 0)
        activate(observed)

        XCTAssertEqual(store.sort([other, candidate]), [candidate, other])
    }

    func testOtherCandidatesRetainLaunchHistoryRankingAndFollowWindows() {
        let unused = application("Alphabetical first")
        let launched = application("Last by name")
        let unobservedWindow = window("Window", identifier: 1)
        store.recordLaunch(of: launched)

        XCTAssertEqual(store.sort([unused, launched, unobservedWindow]), [unobservedWindow, launched, unused])
    }

    private func activate(_ app: LaunchableApp) {
        store.recordWindowActivation(
            processIdentifier: app.processIdentifier!,
            windowIdentifier: app.windowIdentifier,
            historyKey: app.historyKey
        )
    }

    private func window(
        _ title: String,
        identifier: UInt32?,
        processIdentifier: pid_t = 10,
        sortIndex: Int? = nil
    ) -> LaunchableApp {
        LaunchableApp(
            name: title,
            applicationName: "Test app",
            url: nil,
            bundleIdentifier: "test.app",
            searchText: title,
            identityKey: "\(processIdentifier):\(identifier.map(String.init) ?? title)",
            historyKey: "window-title:test.app:\(title)",
            processIdentifier: processIdentifier,
            isRunning: true,
            targetKind: .window,
            windowTitle: title,
            windowFrame: nil,
            windowIdentifier: identifier,
            windowSortIndex: sortIndex
        )
    }

    private func application(_ name: String) -> LaunchableApp {
        LaunchableApp(
            name: name,
            applicationName: name,
            url: nil,
            bundleIdentifier: nil,
            searchText: name,
            identityKey: name,
            historyKey: name,
            processIdentifier: nil,
            isRunning: false,
            targetKind: .application,
            windowTitle: nil,
            windowFrame: nil,
            windowIdentifier: nil
        )
    }
}
