import AppKit
import AVFoundation
import MediaToolbox
import Accelerate
import UniformTypeIdentifiers
import Darwin
import OmaCore

final class RadioMetadataSink: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let receive: @MainActor (String) -> Void
    init(receive: @escaping @MainActor (String) -> Void) { self.receive = receive }
    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        Task { [weak self] in
            for group in groups.suffix(8) {
                for item in group.items.prefix(16) where item.identifier == .icyMetadataStreamTitle || item.commonKey == .commonKeyTitle {
                    if let value = try? await item.load(.stringValue) {
                        let title = RadioStream.text(value, limit: 512)
                        if let self { await receive(title) }
                    }
                }
            }
        }
    }
}

// Feed AVFoundation authenticated byte ranges without placing credentials in URLs
// or allowing a redirect to forward them to a different endpoint.
final class AudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    let account: Account
    let songID: String
    private var requests: [Int: AVAssetResourceLoadingRequest] = [:]
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    init(account: Account, songID: String) { self.account = account; self.songID = songID }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        var c = URLComponents(url: account.server.appendingPathComponent("Audio").appendingPathComponent(songID).appendingPathComponent("stream"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "static", value: "true")]
        var r = URLRequest(url: c.url!); r.timeoutInterval = 45
        r.setValue(account.authorization, forHTTPHeaderField: "Authorization")
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let data = request.dataRequest {
            let start = max(data.requestedOffset, data.currentOffset)
            let end = data.requestedOffset + Int64(data.requestedLength) - 1
            r.setValue(data.requestsAllDataToEndOfResource ? "bytes=\(start)-" : "bytes=\(start)-\(max(start,end))", forHTTPHeaderField: "Range")
        } else { r.setValue("bytes=0-1", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: r)
        requests[task.taskIdentifier] = request; tasks[ObjectIdentifier(request)] = task; task.resume(); return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        if let task = tasks.removeValue(forKey: ObjectIdentifier(request)) { requests.removeValue(forKey: task.taskIdentifier); task.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let request = requests[dataTask.taskIdentifier], let response = response as? HTTPURLResponse, [200,206].contains(response.statusCode) else { completionHandler(.cancel); return }
        let offset = request.dataRequest.map { max($0.currentOffset, $0.requestedOffset) } ?? 0
        if response.statusCode == 200 && offset > 0 { request.finishLoading(with: MusicError.message("This server does not support seeking by byte range.")); completionHandler(.cancel); return }
        var length = response.expectedContentLength
        if let range = response.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last, let value = Int64(total) { length = value }
        let info = request.contentInformationRequest
        info?.contentLength = max(0, length)
        info?.isByteRangeAccessSupported = response.statusCode == 206 || response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes"
        info?.contentType = UTType(mimeType: response.mimeType ?? "audio/mpeg")?.identifier ?? UTType.mp3.identifier
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { requests[dataTask.taskIdentifier]?.dataRequest?.respond(with: data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = requests.removeValue(forKey: task.taskIdentifier) else { return }
        tasks.removeValue(forKey: ObjectIdentifier(request))
        guard !request.isFinished, !request.isCancelled else { return }
        if let error { request.finishLoading(with: error) } else { request.finishLoading() }
    }
    func cancel() { session.invalidateAndCancel(); requests.removeAll(); tasks.removeAll() }
}

final class Spectrum {
    let lock = NSLock()
    private var enabled = false
    private var levels = [Float](repeating: 0, count: 16)
    private var samples = [Float](repeating: 0, count: 1024)
    private var window = [Float](repeating: 0, count: 1024)
    private var real = [Float](repeating: 0, count: 512)
    private var imag = [Float](repeating: 0, count: 512)
    private var power = [Float](repeating: 0, count: 512)
    private var count = 0
    private var skipped = 0
    private var format = AudioStreamBasicDescription()
    private var framesProcessed = 0
    var processedFrames: Int { lock.lock(); defer { lock.unlock() }; return framesProcessed }
    let fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    init() { vDSP_hann_window(&window, 1024, Int32(vDSP_HANN_NORM)) }
    deinit { vDSP_destroy_fftsetup(fft) }
    func setEnabled(_ value: Bool) { lock.lock(); enabled = value; if !value { levels = Array(repeating: 0, count: 16); framesProcessed = 0 }; lock.unlock() }
    func read() -> [Float] { lock.lock(); defer { lock.unlock() }; return levels }
    private func setFormat(_ value: AudioStreamBasicDescription) {
        lock.lock(); defer { lock.unlock() }
        format = value; count = 0; skipped = 0; framesProcessed = 0; levels = Array(repeating: 0, count: 16)
    }
    func consume(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard lock.try() else { return }; defer { lock.unlock() }
        guard enabled, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        guard let first = list.first, let pointer = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        framesProcessed += frames
        let stride = max(1, Int(first.mNumberChannels))
        for i in 0..<frames {
            if skipped > 0 { skipped -= 1; continue }
            samples[count] = pointer[i * stride]; count += 1
            if count == 1024 {
                vDSP_vmul(samples, 1, window, 1, &samples, 1, 1024)
                real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    samples.withUnsafeBytes { bytes in vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, 512) }
                    vDSP_fft_zrip(fft, &split, 1, 10, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, 512)
                } }
                for band in 0..<16 {
                    let low = 40 * pow(500.0, Double(band) / 16)
                    let high = 40 * pow(500.0, Double(band + 1) / 16)
                    let a = max(1, min(511, Int(low * 1024 / max(1, format.mSampleRate))))
                    let b = max(a, min(511, Int(high * 1024 / max(1, format.mSampleRate))))
                    var peak: Float = 0
                    for bin in a...b { peak = max(peak, power[bin]) }
                    let db = 10 * log10(max(1e-12, peak / (1024 * 1024)))
                    levels[band] = max(0, min(1, (db + 65) / 60))
                }
                count = 0; skipped = 2048
            }
        }
    }
    func mix(for track: AVAssetTrack? = nil) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: Unmanaged.passRetained(self).toOpaque(), init: { _, info, storage in storage.pointee = info }, finalize: { tap in
            Unmanaged<Spectrum>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
        }, prepare: { tap, _, format in
            Unmanaged<Spectrum>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().setFormat(format.pointee)
        }, unprepare: { _ in }, process: { tap, frames, flags, buffers, framesOut, flagsOut in
            let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
            if status == noErr { Unmanaged<Spectrum>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().consume(buffers, frames: Int(framesOut.pointee)) }
        })
        var tap: MTAudioProcessingTap?
        let status: OSStatus
        if track == nil, #available(macOS 27.0, *),
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "MTAudioProcessingTapCreateWithPreferredFormat") {
            // Public macOS 27 API, resolved at runtime so builds with an older
            // SDK still support macOS 14. A mixed-output tap accepts live audio.
            typealias Create = @convention(c) (CFAllocator?, UnsafePointer<MTAudioProcessingTapCallbacks>, UInt32,
                CMFormatDescription?, UnsafeMutablePointer<Unmanaged<MTAudioProcessingTap>?>) -> OSStatus
            let create = unsafeBitCast(symbol, to: Create.self)
            var format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            var description: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
            var result: Unmanaged<MTAudioProcessingTap>?
            status = create(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, description, &result)
            tap = result?.takeRetainedValue()
        } else {
            status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        }
        guard status == noErr, let tap else {
            Unmanaged<Spectrum>.fromOpaque(callbacks.clientInfo!).release(); return nil
        }
        // The parameterless initializer targets the mixed output on macOS 27+.
        // The prepare callback observes the negotiated PCM format, including its
        // sample rate, interleaving and numeric type; no new SDK is required.
        let parameters = track.map { AVMutableAudioMixInputParameters(track: $0) } ?? AVMutableAudioMixInputParameters()
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]; return mix
    }
}
