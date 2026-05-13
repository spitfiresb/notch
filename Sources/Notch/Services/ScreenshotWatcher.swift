import AppKit
import Combine

/// Watches for new screenshots and keeps a list of recent ones.
/// Uses a Spotlight (`NSMetadataQuery`) query for files flagged `kMDItemIsScreenCapture`,
/// scoped to the folder macOS is configured to save screenshots into.
@MainActor
final class ScreenshotWatcher: ObservableObject {
    @Published private(set) var shots: [URL] = []

    /// Called when a screenshot appears *after* the app launched.
    var onNewScreenshot: ((URL) -> Void)?

    private let query = NSMetadataQuery()
    private let launchDate = Date()
    private var seen = Set<URL>()

    func start() {
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [Self.screenshotDirectory.path]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleResults),
                           name: .NSMetadataQueryDidFinishGathering, object: query)
        center.addObserver(self, selector: #selector(handleResults),
                           name: .NSMetadataQueryDidUpdate, object: query)
        query.start()
    }

    nonisolated static var screenshotDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let raw = CFPreferencesCopyAppValue("location" as CFString,
                                               "com.apple.screencapture" as CFString) as? String,
           !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Desktop")
    }

    @objc private func handleResults(_ note: Notification) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var urls: [URL] = []
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
        }

        let isUpdate = note.name == .NSMetadataQueryDidUpdate
        let fresh = urls.filter { url in
            guard !seen.contains(url) else { return false }
            guard let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return false }
            return mod > launchDate
        }
        seen.formUnion(urls)
        shots = Array(urls.prefix(40))

        if isUpdate, let newest = fresh.first {
            onNewScreenshot?(newest)
        }
    }
}
