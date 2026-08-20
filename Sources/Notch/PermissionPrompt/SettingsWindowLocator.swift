import AppKit
import CoreGraphics
import Foundation

struct SettingsWindowSnapshot: Equatable {
    let pid: pid_t
    let frame: CGRect
    let visibleFrame: CGRect
}

/// Finds the frontmost System Settings window on screen so the permission
/// overlay can anchor itself to it. Only reads window bounds / owner / layer,
/// none of which require the Screen Recording permission.
enum SettingsWindowLocator {
    static let bundleIdentifier = "com.apple.systempreferences"

    /// Treat these as "still in the permission flow" so the overlay doesn't
    /// disappear the moment macOS pops a native TCC prompt over Settings.
    /// The TCC prompt is hosted by UserNotificationCenter, and the prompt's
    /// owning app (us) may briefly become frontmost when the prompt appears.
    private static let allowedFrontmostBundleIDs: Set<String> = {
        var s: Set<String> = [
            bundleIdentifier,
            "com.apple.UserNotificationCenter",
            "com.apple.UNCUserNotificationCenter"
        ]
        if let own = Bundle.main.bundleIdentifier { s.insert(own) }
        return s
    }()

    static var isPermissionFlowFrontmost: Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return allowedFrontmostBundleIDs.contains(frontmost)
    }

    static func frontmostWindow() -> SettingsWindowSnapshot? {
        guard isPermissionFlowFrontmost else {
            return nil
        }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .max(by: { ($0.activationPolicy == .prohibited ? 0 : 1) < ($1.activationPolicy == .prohibited ? 0 : 1) }) else {
            return nil
        }

        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], .zero) as? [[String: Any]] else {
            return nil
        }

        let windows = windowInfo.compactMap { info -> SettingsWindowSnapshot? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == app.processIdentifier else {
                return nil
            }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                return nil
            }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                return nil
            }

            let cgFrame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            let converted = appKitGeometry(from: cgFrame)
            let frame = converted.frame
            guard frame.width > 320, frame.height > 240 else {
                return nil
            }
            return SettingsWindowSnapshot(
                pid: ownerPID,
                frame: frame,
                visibleFrame: converted.visibleFrame
            )
        }

        return windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    /// CGWindowList reports top-left-origin global coordinates; AppKit windows
    /// use bottom-left-origin per-screen coordinates. Convert via the screen
    /// whose display bounds overlap the window most.
    private static func appKitGeometry(from cgFrame: CGRect) -> (frame: CGRect, visibleFrame: CGRect) {
        let screens = NSScreen.screens.compactMap { screen -> (frame: CGRect, visibleFrame: CGRect, cgBounds: CGRect)? in
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return (
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                cgBounds: CGDisplayBounds(displayID)
            )
        }

        let matchedScreen = screens
            .filter { $0.cgBounds.intersects(cgFrame) }
            .max { lhs, rhs in
                lhs.cgBounds.intersection(cgFrame).width * lhs.cgBounds.intersection(cgFrame).height
                    < rhs.cgBounds.intersection(cgFrame).width * rhs.cgBounds.intersection(cgFrame).height
            }

        guard let matchedScreen else {
            let mainVisibleFrame = NSScreen.main?.visibleFrame ?? CGRect(origin: .zero, size: cgFrame.size)
            return (
                frame: cgFrame,
                visibleFrame: mainVisibleFrame
            )
        }

        let localX = cgFrame.minX - matchedScreen.cgBounds.minX
        let localY = cgFrame.minY - matchedScreen.cgBounds.minY
        let frame = CGRect(
            x: matchedScreen.frame.minX + localX,
            y: matchedScreen.frame.maxY - localY - cgFrame.height,
            width: cgFrame.width,
            height: cgFrame.height
        )

        return (frame: frame, visibleFrame: matchedScreen.visibleFrame)
    }
}
