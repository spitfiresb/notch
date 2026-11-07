import XCTest
@testable import Notch

final class ReleaseSafetyTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func defaults() -> UserDefaults {
        let suite = "NotchReleaseTests.\(UUID().uuidString)"
        let value = UserDefaults(suiteName: suite)!
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }

    func testScreenshotRoutingRestoresCustomFolderAcrossInstances() throws {
        let settings = defaults()
        var location: String? = "/Users/test/Work captures"
        func routing() -> ScreenshotRouting {
            ScreenshotRouting(defaults: settings, managedPath: "/managed", read: { location },
                              write: { location = $0 }, prepareDirectory: {})
        }
        try routing().setEnabled(true)
        try routing().setEnabled(true) // Idempotence must not overwrite the backup.
        XCTAssertEqual(location, "/managed")
        try routing().setEnabled(false)
        XCTAssertEqual(location, "/Users/test/Work captures")
    }

    func testScreenshotRoutingPreservesDefaultAndExternalChanges() throws {
        var location: String?
        let routing = ScreenshotRouting(defaults: defaults(), managedPath: "/managed", read: { location },
                                        write: { location = $0 }, prepareDirectory: {})
        try routing.setEnabled(true)
        try routing.setEnabled(false)
        XCTAssertNil(location)
        try routing.setEnabled(true)
        location = "/chosen-outside-notch"
        try routing.setEnabled(false)
        XCTAssertEqual(location, "/chosen-outside-notch")
        try routing.setEnabled(true)
        try routing.setEnabled(false)
        XCTAssertEqual(location, "/chosen-outside-notch")
    }

    func testScreenshotFolderFailureDoesNotChangeSystemPreference() {
        var location: String? = "/previous"
        let routing = ScreenshotRouting(defaults: defaults(), managedPath: "/managed", read: { location },
                                        write: { location = $0 },
                                        prepareDirectory: { throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try routing.setEnabled(true))
        XCTAssertEqual(location, "/previous")
    }

    func testLaunchGuardBlocksDiskImagesAndTranslocatedAppsButAllowsDevelopment() {
        XCTAssertTrue(LaunchSafety.needsInstallation(url: URL(fileURLWithPath: "/Volumes/Notch/Notch.app"), readOnlyVolume: true))
        XCTAssertTrue(LaunchSafety.needsInstallation(url: URL(fileURLWithPath: "/private/var/AppTranslocation/ID/d/Notch.app"), readOnlyVolume: false))
        XCTAssertFalse(LaunchSafety.needsInstallation(url: URL(fileURLWithPath: "/Applications/Notch.app"), readOnlyVolume: false))
        XCTAssertFalse(LaunchSafety.needsInstallation(url: URL(fileURLWithPath: "/tmp/project/build/Notch.app"), readOnlyVolume: false))
    }

    func testLogRotatesWhileRunningAndRestrictsPermissions() throws {
        let url = try temporaryDirectory().appendingPathComponent("notch.log")
        let log = BoundedLog(url: url, limit: 128)
        for _ in 0..<10 { log.append(String(repeating: "a", count: 50)) }
        for file in [url, url.appendingPathExtension("old")] {
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 128)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testLogBoundsLargeRecordsAndRemovesHomePathAndNewlines() throws {
        let url = try temporaryDirectory().appendingPathComponent("notch.log")
        let log = BoundedLog(url: url, limit: 128)
        log.append(FileManager.default.homeDirectoryForCurrentUser.path + "/private\nsecond line")
        let value = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(value.contains("~/private second line"))
        log.append(String(repeating: "x", count: 1000))
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 128)
    }

    func testLogRotatesAfterManySmallAppends() throws {
        let url = try temporaryDirectory().appendingPathComponent("notch.log")
        let log = BoundedLog(url: url, limit: 8192)
        for _ in 0..<1000 { log.append(String(repeating: "x", count: 128)) }
        for file in [url, url.appendingPathExtension("old")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 8192)
        }
    }

    func testLogSerializesConcurrentWriters() throws {
        let url = try temporaryDirectory().appendingPathComponent("notch.log")
        let log = BoundedLog(url: url, limit: 20_000)
        DispatchQueue.concurrentPerform(iterations: 100) { log.append("record \($0)") }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 100)
        for index in 0..<100 { XCTAssertEqual(lines.filter { $0.hasSuffix("record \(index)") }.count, 1) }
    }
}
