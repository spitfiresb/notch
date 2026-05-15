import AppKit
import CoreGraphics

// Private CGS / SkyLight APIs. These are how every Mac tiling WM / overlay app
// (yabai, hammerspoon, Stats, etc.) pins a window across all Spaces — including
// full-screen Spaces, which the public `.fullScreenAuxiliary` behavior won't do
// without WindowServer occluding the window during transitions.
//
// The functions have been stable since at least 10.11. They live in
// SkyLight.framework (auto-loaded by AppKit), so no dlopen is needed.

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpaces")
private func CGSCopySpaces(_ cid: Int32, _ mask: Int32) -> Unmanaged<CFArray>?

@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: Int32, _ wids: CFArray, _ spaces: CFArray)

enum SpaceAttacher {
    /// Pin `window` to every Space the user has — Desktop, full-screen,
    /// system, anything. Call once after `window.show()`, and again on
    /// `activeSpaceDidChange` so newly created Spaces also include it.
    static func attachToAllSpaces(_ window: NSWindow) {
        let cid = CGSMainConnectionID()
        let wid = NSNumber(value: window.windowNumber)
        let wids = [wid] as CFArray
        // mask 0x7 = all current space types (user, system, fullscreen).
        guard let spaces = CGSCopySpaces(cid, 0x7)?.takeRetainedValue() else { return }
        CGSAddWindowsToSpaces(cid, wids, spaces)
    }
}
