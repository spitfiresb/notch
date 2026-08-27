import AppKit

enum Haptics {
    private static var lastTick = Date.distantPast

    /// macOS exposes no intensity knob, so a "strong" tap = two `.levelChange` pulses
    /// stacked close together — that's about as hard as the trackpad will hit.
    static func tick() {
        let now = Date()
        guard now.timeIntervalSince(lastTick) > 0.06 else { return }   // de-machine-gun
        lastTick = now
        let perf = NSHapticFeedbackManager.defaultPerformer
        perf.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.024) {
            perf.perform(.levelChange, performanceTime: .now)
        }
    }
}
