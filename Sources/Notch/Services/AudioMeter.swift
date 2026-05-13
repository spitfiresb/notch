import Foundation
import AudioToolbox
import CoreAudio
import Combine
import SwiftUI

/// Six-band system-audio meter that drives `DancingBars`.
///
/// macOS 14.2 introduced `CATapDescription` + `AudioHardwareCreateProcessTap`: a public
/// way to tap the system mixdown without any virtual-device shenanigans. We create a
/// global stereo tap, wrap it in a private aggregate device so we can install an IO
/// proc, and then in the IO proc run six biquad bandpass filters at log-spaced centre
/// frequencies (80 / 200 / 500 / 1200 / 3000 / 7000 Hz). Per buffer we take RMS-per-
/// band, run it through a dB-scaled shaping curve, apply an asymmetric envelope
/// follower, and publish 6 bar heights on main.
///
/// Everything that touches CoreAudio is gated on macOS 14.2 and on the OS granting the
/// audio-capture TCC. If anything fails we just stay in `isRunning = false` mode and
/// `DancingBars` falls back to its synthesized wiggle.
@MainActor
final class AudioMeter: ObservableObject {
    nonisolated static let bandCount = 6

    /// Six values 0…1 — applied as scaleY on bar capsules, low frequencies first.
    @Published private(set) var bars: [CGFloat] = Array(repeating: 0.22, count: AudioMeter.bandCount)
    @Published private(set) var isRunning = false

    private var processTapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    // One biquad bandpass per band. `nonisolated(unsafe)` because only the IO proc
    // thread mutates these after `start()` initializes them.
    private nonisolated(unsafe) var biquads: [Biquad] = Array(repeating: Biquad(), count: AudioMeter.bandCount)
    nonisolated static let centerFrequencies: [Double] = [80, 200, 500, 1200, 3000, 7000]

    // Published-side smoothing (asymmetric: snappy attack, gentle release).
    private var env: [CGFloat] = Array(repeating: 0, count: AudioMeter.bandCount)

    // Atomically-read snapshot of the latest band magnitudes the IO proc has computed.
    private let snapshot = AudioMeterSnapshot()

    // 60 Hz pull from main to read the snapshot and update @Published bars.
    private var pollTimer: Timer?

    func start() {
        guard #available(macOS 14.2, *) else {
            NSLog("[AudioMeter] requires macOS 14.2+, skipping")
            return
        }
        guard !isRunning else { return }
        do {
            try setupTapAndAggregate()
            try startIOProc()
            startPolling()
            isRunning = true
            NSLog("[AudioMeter] running (tap=\(processTapID) aggregate=\(aggregateDeviceID))")
        } catch {
            tearDown()
            NSLog("[AudioMeter] failed to start: \(error)")
        }
    }

    func stop() {
        tearDown()
        isRunning = false
        bars = Array(repeating: 0.22, count: Self.bandCount)
    }

    // MARK: - Setup

    @available(macOS 14.2, *)
    private func setupTapAndAggregate() throws {
        // Global stereo mixdown of every process; passing `[]` for the exclude list means
        // "tap everything that comes out of the default output device".
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true

        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            throw AudioMeterError.tapCreate(tapStatus)
        }
        self.processTapID = tapID

        // Find the current default output device's UID; we use it as the aggregate's
        // main sub-device so the aggregate inherits its sample rate / clock.
        let outputUID = try defaultOutputDeviceUID()
        let tapUID = try string(of: tapID, selector: kAudioTapPropertyUID)

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey       as String: "Notch Audio Meter",
            kAudioAggregateDeviceUIDKey        as String: "com.spitfiresb.notch.audio-meter",
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey  as String: true,
            kAudioAggregateDeviceIsStackedKey  as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey    as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]

        var aggregateID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard aggStatus == noErr, aggregateID != kAudioObjectUnknown else {
            throw AudioMeterError.aggregateCreate(aggStatus)
        }
        self.aggregateDeviceID = aggregateID
    }

    private func startIOProc() throws {
        // Filter coefficients depend on the device's actual sample rate — tune for it
        // before the IO proc starts firing.
        let sampleRate = (try? deviceSampleRate(aggregateDeviceID)) ?? 48_000
        for (i, fc) in Self.centerFrequencies.enumerated() {
            biquads[i] = Biquad.bandpass(centerHz: fc, q: 1.4, sampleRate: sampleRate)
        }

        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            nil
        ) { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            self.process(inputData)
        }
        guard status == noErr, let ioProcID else {
            throw AudioMeterError.ioProcCreate(status)
        }
        self.ioProcID = ioProcID
        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else {
            throw AudioMeterError.ioProcStart(startStatus)
        }
    }

    private func deviceSampleRate(_ device: AudioObjectID) throws -> Double {
        var sr: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &sr)
        guard status == noErr, sr > 0 else { throw AudioMeterError.stringProperty(status) }
        return sr
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func tearDown() {
        pollTimer?.invalidate(); pollTimer = nil
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if processTapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(processTapID)
            }
            processTapID = kAudioObjectUnknown
        }
    }

    // MARK: - Real-time processing
    // Runs on the CoreAudio IO thread. Keep allocations / locks out.

    private nonisolated func process(_ buffers: UnsafePointer<AudioBufferList>) {
        // The flexible array of buffers lives past the head of the struct; walk it via
        // the pointer, not via a by-value copy. We only read the first buffer — that's
        // either interleaved stereo (handled below) or the L channel of a planar pair,
        // both of which are fine for level metering.
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffers))
        guard let first = list.first, let raw = first.mData else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let totalSamples = Int(first.mDataByteSize) / MemoryLayout<Float32>.size
        let frames = totalSamples / channels
        let samples = raw.bindMemory(to: Float32.self, capacity: totalSamples)

        // Local copies of biquad state — kept in registers across the hot loop, written
        // back once at the end. Each biquad is a 5-tap direct-form-I bandpass.
        var bq0 = biquads[0], bq1 = biquads[1], bq2 = biquads[2]
        var bq3 = biquads[3], bq4 = biquads[4], bq5 = biquads[5]
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, s5 = 0.0
        let invChans = 1.0 / Double(channels)

        for f in 0..<frames {
            // Mono-sum interleaved channels so we feed each biquad at the device's
            // actual sample rate, not 2× it.
            var x: Double = 0
            let base = f * channels
            for c in 0..<channels { x += Double(samples[base + c]) }
            x *= invChans

            let y0 = bq0.step(x); s0 += y0 * y0
            let y1 = bq1.step(x); s1 += y1 * y1
            let y2 = bq2.step(x); s2 += y2 * y2
            let y3 = bq3.step(x); s3 += y3 * y3
            let y4 = bq4.step(x); s4 += y4 * y4
            let y5 = bq5.step(x); s5 += y5 * y5
        }
        biquads[0] = bq0; biquads[1] = bq1; biquads[2] = bq2
        biquads[3] = bq3; biquads[4] = bq4; biquads[5] = bq5

        if frames > 0 {
            let inv = 1.0 / Double(frames)
            snapshot.store([
                sqrt(s0 * inv), sqrt(s1 * inv), sqrt(s2 * inv),
                sqrt(s3 * inv), sqrt(s4 * inv), sqrt(s5 * inv),
            ])
        }
    }

    // MARK: - Main-thread publish

    private func tick() {
        let rms = snapshot.load()
        var out = bars
        for i in 0..<Self.bandCount {
            env[i] = follow(env: env[i], target: shape(rms[i]))
            out[i] = env[i]
        }
        bars = out
    }

    /// dB-scaled mapping: per-band RMS is converted to dBFS, then a window
    /// [floor, ceil] is linearly mapped onto [0, 1]. Spreads music's actual dynamic
    /// range across the full bar height instead of compressing the loud half together.
    private func shape(_ rms: Double) -> CGFloat {
        let floorDb = -58.0     // anything quieter than this lies at the rest line
        let ceilDb  = -10.0     // anything louder pins to the top
        let safe = max(rms, 1e-7)
        let db = 20 * log10(safe)
        let v = (db - floorDb) / (ceilDb - floorDb)
        let clamped = min(1.0, max(0.0, v))
        return 0.22 + CGFloat(clamped) * 0.78
    }

    private func follow(env: CGFloat, target: CGFloat) -> CGFloat {
        // Asymmetric: very snappy attack so transients punch, faster release than before
        // so the bars settle between hits instead of looking glued open.
        let attack: CGFloat  = 0.7
        let release: CGFloat = 0.32
        let a = target > env ? attack : release
        return env + (target - env) * a
    }

    // MARK: - Helpers

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioMeterError.defaultOutput(status)
        }
        return try string(of: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private func string(of object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &cf)
        guard status == noErr, let cf else { throw AudioMeterError.stringProperty(status) }
        return cf.takeRetainedValue() as String
    }
}

/// Direct-Form-I biquad bandpass with constant 0 dB peak gain at the centre frequency
/// (RBJ audio EQ cookbook). Each `step(_:)` is 5 multiplies + 4 adds + 4 state writes —
/// cheap enough to run six per sample at 48 kHz without breaking a sweat.
private struct Biquad: Sendable {
    var b0: Double = 0, b1: Double = 0, b2: Double = 0
    var a1: Double = 0, a2: Double = 0
    var x1: Double = 0, x2: Double = 0
    var y1: Double = 0, y2: Double = 0

    static func bandpass(centerHz: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * .pi * centerHz / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: alpha / a0,
            b1: 0,
            b2: -alpha / a0,
            a1: -2 * cosw / a0,
            a2: (1 - alpha) / a0)
    }

    mutating func step(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

private enum AudioMeterError: Error {
    case tapCreate(OSStatus)
    case aggregateCreate(OSStatus)
    case ioProcCreate(OSStatus)
    case ioProcStart(OSStatus)
    case defaultOutput(OSStatus)
    case stringProperty(OSStatus)
}

/// Thread-safe snapshot of the latest per-band magnitudes the IO proc computed.
/// The IO proc writes; the main-thread poll reads. Sub-microsecond lock cost is plenty
/// for a 60 Hz UI poll.
private final class AudioMeterSnapshot: @unchecked Sendable {
    private var values: [Double] = Array(repeating: 0, count: AudioMeter.bandCount)
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    init() { lock.initialize(to: os_unfair_lock()) }
    deinit { lock.deinitialize(count: 1); lock.deallocate() }

    func store(_ v: [Double]) {
        os_unfair_lock_lock(lock)
        values = v
        os_unfair_lock_unlock(lock)
    }
    func load() -> [Double] {
        os_unfair_lock_lock(lock)
        let r = values
        os_unfair_lock_unlock(lock)
        return r
    }
}
