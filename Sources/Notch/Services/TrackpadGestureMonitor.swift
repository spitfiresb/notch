import Foundation

// MARK: - MultitouchSupport structs
// MultitouchSupport is a private framework, but its Finger / MTReadout / MTPoint
// layout has been stable across every macOS release since 10.5. Indie apps like
// BetterTouchTool / MagicPrefs / OpenMultitouchSupport rely on the same shape.
// We dlopen the framework so a future macOS that moves or removes the symbols
// degrades gracefully (the monitor goes silent; the notch falls back to the
// `activeSpaceDidChange` slide).

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTReadout {
    var pos: MTPoint
    var vel: MTPoint
}

private struct MTFinger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerNumber: Int32
    var handIndex: Int32
    var normalizedVector: MTReadout
    var size: Float
    var unknown1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTReadout
    var unknown2: Int32
    var unknown3: Int32
    var density: Float
}

// Use a raw pointer so the C convention is happy (`@convention(c)` rejects
// Swift structs in the signature even via UnsafePointer). We decode each
// MTFinger out of the buffer by stride below.
private typealias MTContactFrameCallback = @convention(c) (Int32, UnsafeRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterCallbackFn = @convention(c) (UnsafeMutableRawPointer, MTContactFrameCallback) -> Void
private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
private typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer) -> Void

/// Tracks multi-finger trackpad gestures in real time so we can react to
/// three-finger swipes between Spaces while they're happening. macOS doesn't
/// expose this through any public API — the system gesture recognizer consumes
/// the swipe before NSEvent / CGEventTap can see it — so we read raw finger
/// positions out of the private MultitouchSupport framework instead.
final class TrackpadGestureMonitor {
    static let shared = TrackpadGestureMonitor()

    /// Called on the main queue every callback frame while 3+ fingers are on the
    /// trackpad. `dx` / `dy` are displacement from the gesture's start centroid,
    /// each in normalized trackpad units (~[-1, 1]).
    var onUpdate: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?
    /// Called on the main queue when the gesture ends (finger count drops below 3).
    var onEnd: (() -> Void)?

    private var loaded = false
    private var devicesList: CFArray?
    private var fnCreateList: MTDeviceCreateListFn?
    private var fnRegister: MTRegisterCallbackFn?
    private var fnStart: MTDeviceStartFn?
    private var fnStop: MTDeviceStopFn?

    // State accessed only on the main queue.
    private var inGesture = false
    private var startX: CGFloat = 0
    private var startY: CGFloat = 0
    private var lastLoggedCount: Int = -1
    private var frameCount: Int = 0

    private init() {}

    func start() {
        guard !loaded else { return }
        loaded = true
        notchLog("[mt] start() called")
        guard loadFramework() else {
            notchLog("[mt] MultitouchSupport unavailable — trackpad swipe tracking disabled")
            return
        }
        notchLog("[mt] framework loaded, registering devices…")
        registerDevices()
    }

    fileprivate func process(fingerCount: Int, avgX: CGFloat, avgY: CGFloat) {
        frameCount += 1
        if fingerCount != lastLoggedCount {
            notchLog("[mt] count \(lastLoggedCount) -> \(fingerCount) x=\(String(format: "%.3f", Double(avgX))) y=\(String(format: "%.3f", Double(avgY))) totalFrames=\(frameCount)")
            lastLoggedCount = fingerCount
        }
        if fingerCount >= 3 {
            if !inGesture {
                inGesture = true
                startX = avgX
                startY = avgY
            }
            onUpdate?(avgX - startX, avgY - startY)
        } else if inGesture {
            inGesture = false
            onEnd?()
        }
    }

    private func loadFramework() -> Bool {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else { return false }
        guard let pCreate = dlsym(handle, "MTDeviceCreateList"),
              let pReg = dlsym(handle, "MTRegisterContactFrameCallback"),
              let pStart = dlsym(handle, "MTDeviceStart"),
              let pStop = dlsym(handle, "MTDeviceStop") else { return false }
        fnCreateList = unsafeBitCast(pCreate, to: MTDeviceCreateListFn.self)
        fnRegister = unsafeBitCast(pReg, to: MTRegisterCallbackFn.self)
        fnStart = unsafeBitCast(pStart, to: MTDeviceStartFn.self)
        fnStop = unsafeBitCast(pStop, to: MTDeviceStopFn.self)
        return true
    }

    private func registerDevices() {
        guard let create = fnCreateList, let register = fnRegister, let start = fnStart else {
            notchLog("[mt] missing function pointer (create=\(fnCreateList != nil) reg=\(fnRegister != nil) start=\(fnStart != nil))")
            return
        }
        guard let list = create()?.takeRetainedValue() else {
            notchLog("[mt] MTDeviceCreateList returned no devices")
            return
        }
        devicesList = list
        let count = CFArrayGetCount(list)
        notchLog("[mt] devices count=\(count) stride=\(MemoryLayout<MTFinger>.stride)")
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            register(dev, _mtContactCallback)
            start(dev, 0)
            notchLog("[mt] registered+started device #\(i)")
        }
    }
}

// MultitouchSupport invokes the callback on a private background thread at
// roughly trackpad refresh rate (~120 Hz). Keep work cheap and hop to main.
// We read each finger by raw offset (normalizedVector.pos.x lives at offset 32
// in the C struct — verified via `offsetof` on macOS 26.3). Using a fixed offset
// instead of Swift struct loading keeps us robust against any future struct
// growth (Apple sometimes appends fields), since the position fields are early
// in the layout and have never moved.
private let _mtContactCallback: MTContactFrameCallback = { _, fingersPtr, nFingers, _, _ in
    let count = Int(nFingers)
    var sumX: Float = 0
    var sumY: Float = 0
    if count > 0, let base = fingersPtr {
        let stride = MemoryLayout<MTFinger>.stride
        for i in 0..<count {
            let p = base.advanced(by: i * stride)
            sumX += p.load(fromByteOffset: 32, as: Float.self)
            sumY += p.load(fromByteOffset: 36, as: Float.self)
        }
    }
    let avgX = count > 0 ? CGFloat(sumX / Float(count)) : 0
    let avgY = count > 0 ? CGFloat(sumY / Float(count)) : 0
    DispatchQueue.main.async {
        TrackpadGestureMonitor.shared.process(fingerCount: count, avgX: avgX, avgY: avgY)
    }
    return 0
}
