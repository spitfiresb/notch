import XCTest
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import Notch

final class ScreenshotPipelineTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NotchScreenshots-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let canonical = realpath(url.path, nil)!
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }
    private func png() -> Data {
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
    @discardableResult private func shot(_ dir: URL, _ name: String, data: Data? = nil) throws -> URL {
        let url = dir.appendingPathComponent("Screenshot-\(name).png")
        try (data ?? png()).write(to: url)
        return url
    }
    @MainActor private func eventually(timeout: Double = 4, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate(), "Condition did not complete within \(timeout)s")
    }

    func testHistorySilentTopSevenAndCacheInvalidation() throws {
        let dir = try directory()
        for i in 0..<10 { try shot(dir, "\(i)") }
        try png().write(to: dir.appendingPathComponent("holiday.png"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Screenshot-folder.png"), withIntermediateDirectories: true)
        let scanner = ScreenshotScanner()
        let first = scanner.scan(dir)
        XCTAssertNil(first.capture); XCTAssertEqual(first.records.count, 7)
        let initialCalls = scanner.classifications
        XCTAssertEqual(initialCalls, 11)
        XCTAssertNil(scanner.scan(dir).capture)
        XCTAssertEqual(scanner.classifications, initialCalls, "Unchanged images should not repeat Spotlight work")
        try shot(dir, "9", data: png() + Data([0]))
        _ = scanner.scan(dir)
        XCTAssertEqual(scanner.classifications, initialCalls + 1)
    }

    func testEqualTimestampBurstRenameAndReplacement() throws {
        let dir = try directory(), scanner = ScreenshotScanner()
        let existing = try shot(dir, "old")
        let date = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: existing.path)
        _ = scanner.scan(dir)
        let a = try shot(dir, "a"), b = try shot(dir, "b")
        for url in [a, b] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        let burst = scanner.scan(dir)
        XCTAssertEqual(burst.capture, b); XCTAssertEqual(burst.records.count, 3)
        XCTAssertNil(scanner.scan(dir).capture)
        let renamed = dir.appendingPathComponent("Screenshot-renamed.png")
        try FileManager.default.moveItem(at: b, to: renamed)
        XCTAssertNil(scanner.scan(dir).capture, "Renaming the same inode is not a new capture")
        try png().write(to: renamed, options: .atomic)
        XCTAssertEqual(scanner.scan(dir).capture, renamed)
        try FileManager.default.removeItem(at: renamed)
        XCTAssertEqual(scanner.scan(dir).records.count, 2)
    }

    func testPartialCaptureRetriesAreBoundedAndResumeAfterWrite() throws {
        let dir = try directory()
        var readinessCalls = 0
        let scanner = ScreenshotScanner(ready: { readinessCalls += 1; return ScreenshotScanner.isReady($0) })
        _ = scanner.scan(dir)
        let file = try shot(dir, "partial", data: Data([0]))
        for _ in 0..<12 {
            let result = scanner.scan(dir)
            XCTAssertNil(result.capture); XCTAssertTrue(result.records.isEmpty)
        }
        XCTAssertEqual(readinessCalls, 6, "Corrupt files must not retry forever")
        try png().write(to: file)
        XCTAssertEqual(scanner.scan(dir).capture, file)
        XCTAssertNil(scanner.scan(dir).capture)
    }

    func testNewerCaptureSupersedesPendingPartialAndSymlinksAreIgnored() throws {
        let dir = try directory(), scanner = ScreenshotScanner()
        _ = scanner.scan(dir)
        let partial = try shot(dir, "partial", data: Data())
        XCTAssertTrue(scanner.scan(dir).retry)
        let latest = try shot(dir, "latest")
        XCTAssertEqual(scanner.scan(dir).capture, latest)
        try png().write(to: partial)
        XCTAssertNil(scanner.scan(dir).capture, "Completing the older file must not recopy it")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("Screenshot-link.png"), withDestinationURL: latest)
        XCTAssertEqual(scanner.scan(dir).records.count, 2)
    }

    func testCancelledScanDoesNotPublishAndMissingFolderRecovers() throws {
        let parent = try directory(), dir = parent.appendingPathComponent("missing")
        let scanner = ScreenshotScanner()
        XCTAssertNotNil(scanner.scan(dir).error)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try shot(dir, "history")
        let token = ScreenshotScanCancellation(); token.cancel()
        XCTAssertTrue(scanner.scan(dir, cancellation: token).records.isEmpty)
        let recovered = scanner.scan(dir)
        XCTAssertNil(recovered.error); XCTAssertNil(recovered.capture); XCTAssertEqual(recovered.records.count, 1)
    }

    @MainActor func testSlowScannerKeepsMainActorResponsiveAndCoalescesStorm() async throws {
        let dir = try directory()
        try shot(dir, "history")
        let started = expectation(description: "background scan started")
        let gate = DispatchSemaphore(value: 0)
        let watcher = ScreenshotWatcher(directory: dir, scannerFactory: {
            ScreenshotScanner(classify: { url in
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill(); _ = gate.wait(timeout: .now() + 3)
                return ScreenshotScanner.isScreenshot(url)
            })
        })
        defer { watcher.stop(); gate.signal() }
        watcher.start()
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<100 { watcher.refresh() }
        // This actor continues to execute even while the worker is deliberately blocked.
        var heartbeat = 0
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 2_000_000); heartbeat += 1 }
        XCTAssertEqual(heartbeat, 10); XCTAssertEqual(watcher.completedScans, 0)
        gate.signal()
        await eventually { watcher.completedScans >= 2 && !watcher.isRefreshing }
        XCTAssertEqual(watcher.completedScans, 2, "A hundred refresh requests need only one follow-up")
        XCTAssertEqual(watcher.shots.count, 1)
    }

    @MainActor func testFolderSwitchRejectsInFlightResultsAndStopIsSilent() async throws {
        let old = try directory(), new = try directory()
        let oldFile = try shot(old, "old"), newFile = try shot(new, "new")
        var current = old
        let started = expectation(description: "old scan started"), gate = DispatchSemaphore(value: 0)
        let watcher = ScreenshotWatcher(directoryProvider: { current }, scannerFactory: {
            ScreenshotScanner(classify: { url in
                if url == oldFile { started.fulfill(); _ = gate.wait(timeout: .now() + 3) }
                return true
            })
        })
        var captures: [URL] = []; watcher.onNewScreenshot = { captures.append($0) }
        watcher.start(); await fulfillment(of: [started], timeout: 2)
        current = new; watcher.rebindToCurrentDirectory(); gate.signal()
        await eventually { watcher.shots == [newFile] }
        XCTAssertTrue(captures.isEmpty)
        watcher.stop()
        try shot(new, "after-stop")
        watcher.refresh()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(watcher.shots, [newFile]); XCTAssertTrue(captures.isEmpty)
    }

    @MainActor func testNativeEventsPartialWritesFolderReplacementAndRestart() async throws {
        let parent = try directory(), dir = parent.appendingPathComponent("captures")
        let watcher = ScreenshotWatcher(directory: dir)
        var delivered: [URL] = []; watcher.onNewScreenshot = { delivered.append($0) }
        defer { watcher.stop() }
        watcher.start(); await eventually { watcher.issue != nil }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        watcher.refresh(); await eventually { watcher.issue == nil && !watcher.isRefreshing }
        let partial = try shot(dir, "partial", data: Data([0]))
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(delivered.isEmpty)
        try png().write(to: partial)
        await eventually { delivered == [partial] }
        let renamed = parent.appendingPathComponent("old")
        try FileManager.default.moveItem(at: dir, to: renamed)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await eventually { watcher.shots.isEmpty }
        let next = try shot(dir, "replacement")
        await eventually { delivered.last == next }
        let count = delivered.count
        for _ in 0..<5 { watcher.stop(); watcher.start(); await watcher.waitUntilIdle() }
        XCTAssertEqual(delivered.count, count, "Restart history must remain silent")
        let last = try shot(dir, "restart")
        await eventually { delivered.last == last }
    }

    @MainActor func testClipboardSuccessFailureAndUserClipboardChange() async throws {
        let dir = try directory(), file = try shot(dir, "valid")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let clipboard = ScreenshotClipboard()
        let success = await clipboard.copy(file, pasteboard: board)
        XCTAssertEqual(success, .copied)
        XCTAssertEqual(board.data(forType: .png), try Data(contentsOf: file))
        XCTAssertNotNil(board.data(forType: .tiff))
        board.clearContents(); board.setString("keep me", forType: .string)
        let invalid = try shot(dir, "corrupt", data: Data([0]))
        let failed = await clipboard.copy(invalid, pasteboard: board)
        XCTAssertEqual(failed, .failed); XCTAssertEqual(board.string(forType: .string), "keep me")
        let gate = DispatchSemaphore(value: 0), started = expectation(description: "copy started")
        let slow = ScreenshotClipboard(prepare: { url in
            XCTAssertFalse(Thread.isMainThread); started.fulfill(); _ = gate.wait(timeout: .now() + 3)
            return ScreenshotClipboard.prepareImage(url)
        })
        var result: ScreenshotClipboard.Outcome?
        slow.copy(file, pasteboard: board, completion: { result = $0 })
        await fulfillment(of: [started], timeout: 2)
        board.clearContents(); board.setString("new user content", forType: .string); gate.signal()
        await eventually { result != nil }
        XCTAssertEqual(result, .clipboardChanged); XCTAssertEqual(board.string(forType: .string), "new user content")
    }

    @MainActor func testClipboardLatestWinsCancellationAndTruthfulToast() async throws {
        let dir = try directory(), first = try shot(dir, "first"), second = try shot(dir, "second"), latest = try shot(dir, "latest")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let gate = DispatchSemaphore(value: 0), started = expectation(description: "first conversion")
        let clipboard = ScreenshotClipboard(prepare: { url in
            if url == first { started.fulfill(); _ = gate.wait(timeout: .now() + 3) }
            return ScreenshotClipboard.Payload(png: nil, tiff: Data(url.lastPathComponent.utf8))
        })
        var outcomes: [URL: ScreenshotClipboard.Outcome] = [:]
        clipboard.copy(first, pasteboard: board, completion: { outcomes[first] = $0 })
        await fulfillment(of: [started], timeout: 2)
        clipboard.copy(second, pasteboard: board, completion: { outcomes[second] = $0 })
        clipboard.copy(latest, pasteboard: board, completion: { outcomes[latest] = $0 })
        gate.signal(); await eventually { outcomes.count == 3 }
        XCTAssertEqual(outcomes[first], .superseded); XCTAssertEqual(outcomes[second], .superseded)
        XCTAssertEqual(outcomes[latest], .copied)
        XCTAssertEqual(board.data(forType: .tiff), Data(latest.lastPathComponent.utf8))
        var cancelled: ScreenshotClipboard.Outcome?
        clipboard.copy(second, pasteboard: board, canCommit: { false }) { cancelled = $0 }
        await eventually { cancelled != nil }; XCTAssertEqual(cancelled, .superseded)
        clipboard.copy(second, pasteboard: board, completion: { cancelled = $0 })
        clipboard.cancel(); cancelled = nil
        await eventually { cancelled != nil }; XCTAssertEqual(cancelled, .superseded)
        let suite = "NotchScreenshotTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let notch = NotchState(defaults: defaults)
        notch.presentScreenshotToast(url: first)
        guard case .screenshot(let captured) = notch.toast else { return XCTFail("Capture toast missing") }
        XCTAssertEqual(captured.message, "Screenshot captured")
        notch.presentScreenshotToast(url: latest); notch.markScreenshotCopied(url: first)
        guard case .screenshot(let unchanged) = notch.toast else { return XCTFail("Toast missing") }
        XCTAssertEqual(unchanged.url, latest); XCTAssertEqual(unchanged.message, "Screenshot captured")
        notch.markScreenshotCopied(url: latest)
        guard case .screenshot(let copied) = notch.toast else { return XCTFail("Toast missing") }
        XCTAssertEqual(copied.message, "Screenshot copied to clipboard")
        notch.dismissToast()
    }

    func testCleanupOnlyTouchesConfirmedUnchangedScreenshots() async throws {
        let dir = try directory()
        let old = try shot(dir, "old"), replace = try shot(dir, "replace")
        try png().write(to: dir.appendingPathComponent("holiday.png"))
        let confirmed = try await ScreenshotCleanup.candidates(in: dir)
        XCTAssertEqual(confirmed.count, 2)
        try shot(dir, "after-confirmation")
        try png().write(to: replace, options: .atomic)
        let moved = await ScreenshotCleanup.trash(confirmed) { url in
            XCTAssertFalse(Thread.isMainThread); XCTAssertEqual(url, old)
            try FileManager.default.removeItem(at: url) // Only temporary fixtures; never use the user's Trash in tests.
        }
        XCTAssertEqual(moved, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replace.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 3)
    }
    @MainActor func testPermissionRecoveryPreservesExistingStrip() async throws {
        let dir = try directory(), file = try shot(dir, "existing")
        let watcher = ScreenshotWatcher(directory: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); watcher.stop() }
        watcher.start(); await watcher.waitUntilIdle()
        XCTAssertEqual(watcher.shots, [file])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        watcher.refresh(); await watcher.waitUntilIdle()
        XCTAssertNotNil(watcher.issue); XCTAssertEqual(watcher.shots, [file])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        watcher.refresh(); await watcher.waitUntilIdle()
        XCTAssertNil(watcher.issue); XCTAssertEqual(watcher.shots, [file])
    }

    @MainActor func testAutomaticMissingFolderRecoveryAndWakePreferenceChange() async throws {
        let parent = try directory(), missing = parent.appendingPathComponent("later")
        let other = try directory(), file = try shot(other, "other")
        var current = missing
        let watcher = ScreenshotWatcher(directoryProvider: { current })
        defer { watcher.stop() }
        watcher.start(); await eventually { watcher.issue != nil }
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        await eventually { watcher.issue == nil && !watcher.isRefreshing }
        current = other
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await eventually { watcher.shots == [file] }
    }

    @MainActor func testRepeatedStartStopReleasesDirectoryDescriptors() async throws {
        let dir = try directory()
        let count = { () -> Int in
            let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
            var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16)
            let actual = entries.withUnsafeMutableBytes { proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            return Int(actual) / MemoryLayout<proc_fdinfo>.stride
        }
        let watcher = ScreenshotWatcher(directory: dir)
        watcher.start(); await watcher.waitUntilIdle(); watcher.stop()
        try await Task.sleep(nanoseconds: 30_000_000)
        let before = count()
        for _ in 0..<25 { watcher.start(); await watcher.waitUntilIdle(); watcher.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertLessThanOrEqual(count(), before + 1)
    }

    func testJPEGAndTIFFClipboardPreparationAndSizeLimit() throws {
        let dir = try directory(), source = CGImageSourceCreateWithData(png() as CFData, nil)!
        let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        for type in [UTType.jpeg, UTType.tiff] {
            let url = dir.appendingPathComponent("Screenshot-format.\(type.preferredFilenameExtension!)")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, cg, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
            XCTAssertTrue(ScreenshotScanner.isReady(url))
            let payload = ScreenshotClipboard.prepareImage(url)
            XCTAssertNotNil(payload?.tiff); XCTAssertNil(payload?.png)
        }
        let huge = try shot(dir, "oversize", data: Data())
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 129 * 1024 * 1024); try handle.close()
        XCTAssertNil(ScreenshotClipboard.prepareImage(huge))
    }

    func testPDFReadinessThumbnailAndClipboard() async throws {
        let dir = try directory(), url = dir.appendingPathComponent("Screenshot-page.pdf")
        var rect = CGRect(x: 0, y: 0, width: 800, height: 600)
        let ctx = CGContext(url as CFURL, mediaBox: &rect, nil)!
        ctx.beginPDFPage(nil); ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(rect)
        ctx.endPDFPage(); ctx.closePDF()
        XCTAssertTrue(ScreenshotScanner.isReady(url))
        let thumb = await ScreenshotImage.thumbnail(for: url)
        XCTAssertNotNil(thumb); XCTAssertLessThanOrEqual(max(thumb!.size.width, thumb!.size.height), 400)
        XCTAssertNotNil(ScreenshotClipboard.prepareImage(url)?.tiff)
    }

    func testBurstValidatesStripAndOldTimestampCaptureOutsideStrip() throws {
        let dir = try directory(), scanner = ScreenshotScanner()
        for i in 0..<10 { try shot(dir, "history-\(i)") }
        _ = scanner.scan(dir)
        let oldTimestamp = try shot(dir, "new-with-old-date")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: oldTimestamp.path)
        let result = scanner.scan(dir)
        XCTAssertEqual(result.capture, oldTimestamp); XCTAssertEqual(result.records.count, 7)
        XCTAssertFalse(result.records.contains { $0.url == oldTimestamp })
        let partial = try shot(dir, "burst-partial", data: Data([0]))
        let latest = try shot(dir, "burst-valid")
        let burst = scanner.scan(dir)
        XCTAssertEqual(burst.capture, latest)
        XCTAssertFalse(burst.records.contains { $0.url == partial })
        try png().write(to: partial)
        let completed = scanner.scan(dir)
        XCTAssertNil(completed.capture)
        XCTAssertTrue(completed.records.contains { $0.url == partial })
    }

    @MainActor func testCancelledThumbnailReturnsNoObsoleteImage() async throws {
        let dir = try directory(), file = try shot(dir, "cancelled-thumbnail")
        let task = Task { @MainActor in await ScreenshotImage.thumbnail(for: file) }
        task.cancel()
        let image = await task.value
        XCTAssertNil(image)
    }

    func testScreenshotDirectoryMayBeSymlinkButIndividualFilesAreNotFollowed() throws {
        let parent = try directory(), real = try directory(), file = try shot(real, "real")
        let link = parent.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let result = ScreenshotScanner().scan(link)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.stamp.identity, ScreenshotFileStamp.read(file)?.identity)
    }

    @MainActor func testScreenshotStripActuallyLoadsThumbnail() async throws {
        let dir = try directory(), url = dir.appendingPathComponent("Screenshot-red.png")
        let ctx = CGContext(data: nil, width: 100, height: 60, bitsPerComponent: 8, bytesPerRow: 400,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let watcher = ScreenshotWatcher(directory: dir)
        watcher.start(); await watcher.waitUntilIdle()
        let host = NSHostingView(rootView: ScreenshotTabView().environmentObject(watcher).environmentObject(CursorTracker())
            .frame(width: 380, height: 100).background(Color.black))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 380, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close(); watcher.stop() }
        var redPixels = 0
        let deadline = Date().addingTimeInterval(3)
        while redPixels < 500 && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = URL(fileURLWithPath: ".build/renders/screenshot-loaded-test.png")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output)
            redPixels = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.6, color.redComponent > color.greenComponent * 2,
                       color.redComponent > color.blueComponent * 2 { redPixels += 1 }
                }
            }
        }
        XCTAssertGreaterThan(redPixels, 500, "The strip must replace its placeholder with the decoded screenshot")
    }

}
