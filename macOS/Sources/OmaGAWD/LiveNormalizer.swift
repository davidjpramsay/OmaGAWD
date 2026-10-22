import Foundation
import AudioToolbox

// Native, bounded live loudness control: BS.1770 K weighting, 400 ms energy,
// silence gating, gentle gain changes and a -1.5 dBFS sample-peak ceiling.
// This is a streaming leveler, not an offline integrated R128 mastering pass.
final class LiveNormalizer {
    private struct Biquad {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func sample(_ x: Double) -> Double {
            let y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y
        }
    }
    private var shelf: [Biquad] = [], highpass: [Biquad] = []
    private var sampleRate = 44100.0, channels = 0
    private var energy = 0.0, gain = 1.0
    private(set) var processedFrames = 0
    func prepare(rate: Double, channels: Int) {
        sampleRate = max(8000, rate); self.channels = channels; energy = 0; gain = 1; processedFrames = 0
        let k = tan(.pi * 1681.974450955533 / sampleRate), q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416), a = 1 + k / q + k * k
        let first = Biquad(b0: (vh + vb * k / q + k * k) / a, b1: 2 * (k * k - vh) / a, b2: (vh - vb * k / q + k * k) / a, a1: 2 * (k * k - 1) / a, a2: (1 - k / q + k * k) / a)
        let h = tan(.pi * 38.13547087602444 / sampleRate), r = 0.5003270373238773, b = 1 + h / r + h * h
        let second = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (h * h - 1) / b, a2: (1 - h / r + h * h) / b)
        shelf = Array(repeating: first, count: channels); highpass = Array(repeating: second, count: channels)
    }
    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int, format: AudioStreamBasicDescription) {
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32, frames > 0 else { return }
        let count = Int(format.mChannelsPerFrame)
        guard (1...8).contains(count) else { return }
        if channels != count || sampleRate != format.mSampleRate { prepare(rate: format.mSampleRate, channels: count) }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        var sum = 0.0, peak = 0.0, channel = 0
        for buffer in list {
            guard let pointer = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let stride = max(1, Int(buffer.mNumberChannels))
            guard Int(buffer.mDataByteSize) >= frames * stride * MemoryLayout<Float>.size else { return }
            for c in 0..<stride {
                guard channel < count else { return }
                for frame in 0..<frames {
                    let value = Double(pointer[frame * stride + c]); peak = max(peak, abs(value))
                    let filtered = highpass[channel].sample(shelf[channel].sample(value))
                    sum += filtered * filtered
                }
                channel += 1
            }
        }
        let blend = 1 - exp(-Double(frames) / (sampleRate * 0.4))
        energy += blend * (sum / Double(frames) - energy)
        let loudness = -0.691 + 10 * log10(max(1e-12, energy))
        let target = loudness > -60 ? pow(10, min(12, max(-24, -18 - loudness)) / 20) : min(1, gain)
        let smoothing = 1 - exp(-Double(frames) / (sampleRate * (target < gain ? 0.08 : 1.5)))
        let desired = gain + smoothing * (target - gain)
        let ceiling = pow(10, -1.5 / 20)
        let safe = peak > 0 ? ceiling / peak : 1
        let from = min(gain, safe), to = min(desired, safe)
        for buffer in list {
            guard let pointer = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = max(1, Int(buffer.mNumberChannels))
            for frame in 0..<frames {
                let level = Float(from + (to - from) * Double(frame + 1) / Double(frames))
                for c in 0..<stride { let i = frame * stride + c; pointer[i] = min(Float(ceiling), max(-Float(ceiling), pointer[i] * level)) }
            }
        }
        gain = to; processedFrames += frames
    }
}

private final class AudioTapState {
    let spectrum: Spectrum
    let normalizer = LiveNormalizer()
    var format = AudioStreamBasicDescription()
    init(_ spectrum: Spectrum) { self.spectrum = spectrum }
    func prepare(_ value: AudioStreamBasicDescription) {
        format = value; normalizer.prepare(rate: value.mSampleRate, channels: Int(value.mChannelsPerFrame))
    }
    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        if spectrum.normalizationEnabled { normalizer.process(buffers, frames: frames, format: format) }
        spectrum.consume(buffers, frames: frames, format: format)
    }
    static func callbacks(for spectrum: Spectrum) -> MTAudioProcessingTapCallbacks {
        MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: Unmanaged.passRetained(AudioTapState(spectrum)).toOpaque(), init: { _, info, storage in storage.pointee = info }, finalize: { tap in
            Unmanaged<AudioTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
        }, prepare: { tap, _, format in
            Unmanaged<AudioTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
        }, unprepare: { _ in }, process: { tap, frames, _, buffers, framesOut, flagsOut in
            if MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr {
                Unmanaged<AudioTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().process(buffers, frames: Int(framesOut.pointee))
            }
        })
    }
    static func release(_ pointer: UnsafeMutableRawPointer) { Unmanaged<AudioTapState>.fromOpaque(pointer).release() }
}

import MediaToolbox
extension Spectrum {
    static func tapCallbacks(for spectrum: Spectrum) -> MTAudioProcessingTapCallbacks { AudioTapState.callbacks(for: spectrum) }
    static func releaseTapInfo(_ pointer: UnsafeMutableRawPointer) { AudioTapState.release(pointer) }
}
