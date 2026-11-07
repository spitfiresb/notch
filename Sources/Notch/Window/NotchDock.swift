import Foundation

/// Which screen edge the notch lives on. Top is the classic spot; left and right
/// hug the vertical edges for people who'd rather keep the top of the screen
/// clear. Changed by click-hold-dragging the blob (NotchDragController) and
/// persisted across launches.
enum NotchDock: String, CaseIterable {
    case top, left, right

    private static let key = "notch.dock"

    static var stored: NotchDock {
        load(from: .standard)
    }

    static func load(from defaults: UserDefaults) -> NotchDock {
        NotchDock(rawValue: defaults.string(forKey: key) ?? "") ?? .top
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.key)
    }
}
