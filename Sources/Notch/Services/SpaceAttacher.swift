import AppKit
import CoreGraphics

// Private CGS / SkyLight APIs. These are how every Mac tiling WM / overlay app
// (yabai, hammerspoon, Stats, etc.) manipulates Spaces. The functions have been
// stable since at least 10.11. They live in SkyLight.framework (auto-loaded by
// AppKit), so no dlopen is needed.

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpaces")
private func CGSCopySpaces(_ cid: Int32, _ mask: Int32) -> Unmanaged<CFArray>?

@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: Int32, _ wids: CFArray, _ spaces: CFArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
private func CGSRemoveWindowsFromSpaces(_ cid: Int32, _ wids: CFArray, _ spaces: CFArray)

@_silgen_name("CGSSpaceCreate")
private func CGSSpaceCreate(_ cid: Int32, _ unknown: Int32, _ options: CFDictionary?) -> UInt64

@_silgen_name("CGSSpaceDestroy")
private func CGSSpaceDestroy(_ cid: Int32, _ space: UInt64)

@_silgen_name("CGSSpaceSetAbsoluteLevel")
private func CGSSpaceSetAbsoluteLevel(_ cid: Int32, _ space: UInt64, _ level: Int32)

@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ cid: Int32, _ spaces: CFArray)

enum SpaceAttacher {
    /// Our private overlay space. Spaces created with `CGSSpaceCreate` and given
    /// an absolute level live in the same layer system overlays (Mission Control
    /// chrome, the Dock's spring-loaded UI) do: they are composited above the
    /// managed-Space stack and are NOT part of the slide animation when the user
    /// 3-finger-swipes between Spaces. A window that lives *only* here therefore
    /// stays perfectly still during transitions — the "physical notch" behavior
    /// that pinning-to-all-managed-Spaces (tested 2026-07-22) could not deliver:
    /// pinned windows ride the outgoing Space and pop back in on the new one.
    private static var overlaySpace: UInt64 = 0

    /// Move `window` into the overlay space and take it out of every managed
    /// Space. Call once after `window.show()`; calling again (e.g. on
    /// `activeSpaceDidChange`) is harmless and re-asserts membership.
    static func attachToAllSpaces(_ window: NSWindow) {
        let cid = CGSMainConnectionID()
        let wids = [NSNumber(value: window.windowNumber)] as CFArray

        if overlaySpace == 0 {
            let space = CGSSpaceCreate(cid, 1, nil)
            guard space != 0 else {
                // Couldn't create the overlay space — fall back to the old
                // pin-to-every-managed-Space behavior so the notch still shows up.
                if let spaces = CGSCopySpaces(cid, 0x7)?.takeRetainedValue() {
                    CGSAddWindowsToSpaces(cid, wids, spaces)
                }
                return
            }
            // Composited above all user Spaces. Level 0 already achieves that,
            // but at 0 WindowServer still blanks the window while the Mission
            // Control / hot-corner transition builds in (~250ms occlusion at MC
            // start, logged 2026-07-22). A higher absolute level puts our space
            // above the transition layer so the panel stays visible and its
            // retract animation can actually be seen. The window's own NSWindow
            // level still applies within the space.
            CGSSpaceSetAbsoluteLevel(cid, space, 400)
            CGSShowSpaces(cid, [NSNumber(value: space)] as CFArray)
            overlaySpace = space
        }

        CGSAddWindowsToSpaces(cid, wids, [NSNumber(value: overlaySpace)] as CFArray)

        // Take it out of the managed Spaces — if it stays in them, WindowServer
        // keeps including it in the swipe slide and we're back to square one.
        // mask 0x7 = all current space types (user, system, fullscreen).
        if let managed = CGSCopySpaces(cid, 0x7)?.takeRetainedValue() {
            CGSRemoveWindowsFromSpaces(cid, wids, managed)
        }
    }

    /// Tear down the overlay space (the WindowServer also cleans it up when our
    /// connection dies, so this is belt-and-braces for orderly quits).
    static func detach() {
        guard overlaySpace != 0 else { return }
        CGSSpaceDestroy(CGSMainConnectionID(), overlaySpace)
        overlaySpace = 0
    }
}
