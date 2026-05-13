import AppKit
import Combine

struct ClipItem: Identifiable {
    enum Kind { case text(String), image(NSImage) }
    let id = UUID()
    let date = Date()
    let kind: Kind
}

/// Polls the general pasteboard and keeps a short history of recent copies.
@MainActor
final class ClipboardWatcher: ObservableObject {
    @Published private(set) var items: [ClipItem] = []

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let maxItems = 25

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text(let s):  pb.setString(s, forType: .string)
        case .image(let i): pb.writeObjects([i])
        }
        lastChangeCount = pb.changeCount
    }

    func clear() { items.removeAll() }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if let image = NSImage(pasteboard: pb) {
            items.insert(ClipItem(kind: .image(image)), at: 0)
        } else if let str = pb.string(forType: .string),
                  !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if case .text(let last)? = items.first?.kind, last == str { return }
            items.insert(ClipItem(kind: .text(str)), at: 0)
        }
        if items.count > maxItems { items.removeLast(items.count - maxItems) }
    }
}
