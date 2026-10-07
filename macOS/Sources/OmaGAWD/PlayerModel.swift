import AppKit
import AVFoundation
import MediaPlayer
import OmaCore

@MainActor final class PlayerModel {
    var onChange: (() -> Void)?
    var onTick: (() -> Void)?
    var queue = PlayQueue()
    var songs: [Song] = []
    var folders: [MusicFolder] = []
    var selectedFolder = "local"
    var sources: [URL] = (UserDefaults.standard.stringArray(forKey: "sources") ?? []).map { URL(fileURLWithPath: $0) }
    var account: Account?
    var busy = false
    var message = "Add a music folder or connect to Jellyfin."
    var error = false
    let player = AVPlayer()
    let spectrum = Spectrum()
    let local = LocalLibrary()
    var position: Double { let t = player.currentTime().seconds; return t.isFinite ? t : 0 }
    var duration: Double { let t = player.currentItem?.duration.seconds ?? 0; return t.isFinite && t > 0 ? t : queue.song?.duration ?? 0 }
    var playing: Bool { player.rate != 0 }
    var bitRate: Float = 0
    var stopped = true
    var visible = false { didSet { spectrum.setEnabled(visible && playing) } }
    var volume: Float { get { player.volume } set { player.volume = min(1, max(0, newValue)); UserDefaults.standard.set(player.volume, forKey: "volume") } }
    private var loader: AudioResourceLoader?
    private var scanTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var wantsPlayback = false
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var periodic: Any?
    private var generation = 0
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    init() {
        player.volume = UserDefaults.standard.object(forKey: "volume") == nil ? 0.7 : UserDefaults.standard.float(forKey: "volume")
        queue.shuffle = UserDefaults.standard.bool(forKey: "shuffle")
        queue.repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "repeat") ?? "off") ?? .off
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in Task { @MainActor in
            guard let self else { return }; self.spectrum.setEnabled(self.visible && self.playing); self.updateNowPlaying(); self.onTick?()
        } }
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; if self.visible { self.onTick?() } }
        }
        configureRemoteCommands()
    }
    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, action: @escaping @MainActor (PlayerModel) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in action(self) }
                return .success
            }
            remoteTargets.append((command, target))
        }
        register(commands.playCommand) { $0.resume() }
        register(commands.pauseCommand) { $0.pause() }
        register(commands.togglePlayPauseCommand) { $0.toggle() }
        register(commands.stopCommand) { $0.stop() }
        register(commands.nextTrackCommand) { $0.next() }
        register(commands.previousTrackCommand) { $0.previous() }
        commands.changePlaybackPositionCommand.isEnabled = true
        let seekTarget = commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self.seek(position) }
            return .success
        }
        remoteTargets.append((commands.changePlaybackPositionCommand, seekTarget))
    }

    func start() {
        account = Keychain.load()
        if !sources.isEmpty { loadLocal() }
        if let account { Task { do { let restored = try await Jellyfin(account).folders(); guard self.account?.token == account.token else { return }; folders = restored; if sources.isEmpty, let first = folders.first { selectFolder(first.id) }; onChange?() } catch { report(error) } } }
    }
    func report(_ error: Error) { if error is CancellationError { return }; self.error = true; message = error.localizedDescription; onChange?() }
    func selectFolder(_ id: String) {
        selectedFolder = id
        if id == "local" { loadLocal(); return }
        guard let account else { return }
        work { (try await Jellyfin(account).songs(folder: id), []) }
    }
    func loadLocal() { let paths = sources; work { let songs = try await self.local.scan(paths); return (songs, await self.local.warnings) } }
    private func work(_ operation: @escaping () async throws -> ([Song], [String])) {
        scanTask?.cancel(); generation += 1; let current = generation
        busy = true; error = false; message = "Reading library…"; onChange?()
        scanTask = Task {
            do {
                let result = try await operation(); try Task.checkCancellation()
                guard generation == current else { return }; songs = result.0; message = (["\(songs.count) songs"] + result.1).joined(separator: " · "); error = !result.1.isEmpty
            } catch { if generation == current { report(error) } }
            if generation == current { busy = false; onChange?() }
        }
    }
    func addSources(_ urls: [URL]) {
        sources = Array(Set(sources + urls)).sorted { $0.path < $1.path }; saveSources(); selectedFolder = "local"; loadLocal()
    }
    func removeSource(_ index: Int) { guard sources.indices.contains(index) else { return }; sources.remove(at: index); saveSources(); selectedFolder = "local"; loadLocal() }
    private func saveSources() { UserDefaults.standard.set(sources.map(\.path), forKey: "sources") }
    func connect(server: String, username: String, password: String) async throws {
        let signedIn = try await Jellyfin.login(server: server, username: username, password: password)
        let libraries = try await Jellyfin(signedIn).folders()
        try Keychain.save(signedIn)
        stop(); queue.clear(); account = signedIn; folders = libraries
        if let first = folders.first { selectFolder(first.id) } else { message = "Connected. No music libraries found."; onChange?() }
    }
    func disconnect() {
        do { try Keychain.remove() } catch { report(error); return }
        if let old = account { Task { await Jellyfin(old).logout() } }
        account = nil; folders = []; stop(); queue.clear(); selectedFolder = "local"; loadLocal()
    }
    func append(_ songs: [Song]) { queue.append(songs); onChange?() }
    func replace(_ songs: [Song]) { guard !songs.isEmpty else { return }; queue.replace(songs); play(0) }
    func play(_ index: Int) {
        guard queue.entries.indices.contains(index) else { return }
        playbackTask?.cancel(); player.pause(); statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }; failureObserver = nil
        player.replaceCurrentItem(with: nil); loader?.cancel(); loader = nil
        queue.current = queue.entries[index].id; let identity = queue.current; let song = queue.entries[index].song
        wantsPlayback = true; stopped = false; bitRate = 0; error = false; message = "Loading \(song.title)…"; onChange?()
        let asset: AVURLAsset
        if let file = song.file { asset = AVURLAsset(url: file) }
        else if let account {
            let resource = AudioResourceLoader(account: account, songID: song.id); loader = resource
            asset = AVURLAsset(url: URL(string: "omagawd://audio/\(UUID().uuidString)")!)
            asset.resourceLoader.setDelegate(resource, queue: .main)
        } else { report(MusicError.message("Connect to Jellyfin to play this track.")); stopped = true; return }
        playbackTask = Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                try Task.checkCancellation(); guard queue.current == identity else { return }
                let item = AVPlayerItem(asset: asset)
                if let track = tracks.first {
                    bitRate = (try? await track.load(.estimatedDataRate)) ?? 0
                    try Task.checkCancellation()
                    item.audioMix = spectrum.mix(for: track)
                }
                statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.player.currentItem === item else { return }
                        if item.status == .failed { self.stopped = true; self.report(item.error ?? MusicError.message("The audio format could not be played.")) }
                        else if item.status == .readyToPlay { self.message = "\(self.songs.count) songs"; self.error = false; self.onChange?(); self.updateNowPlaying() }
                    }
                }
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in self?.next(automatic: true) } }
                failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
                    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    Task { @MainActor in self?.report(error ?? MusicError.message("Playback was interrupted.")) }
                }
                player.replaceCurrentItem(with: item); if wantsPlayback { player.play() }; updateNowPlaying(); onChange?()
            } catch { if !(error is CancellationError), queue.current == identity { stopped = true; report(error) } }
        }
    }
    func toggle() { wantsPlayback && !stopped ? pause() : resume() }
    func resume() { wantsPlayback = true; if stopped { play(queue.index ?? 0) } else if player.currentItem != nil { player.play() } }
    func pause() { wantsPlayback = false; player.pause(); updateNowPlaying(); onTick?() }
    func stop() { wantsPlayback = false; playbackTask?.cancel(); player.pause(); player.replaceCurrentItem(with: nil); loader?.cancel(); loader = nil; stopped = true; spectrum.setEnabled(false); updateNowPlaying(); onTick?() }
    func next(automatic: Bool = false) { if let next = queue.next(automatic: automatic) { play(next) } else { stop() } }
    func previous() { play(max(0, (queue.index ?? 0) - 1)) }
    func seek(_ seconds: Double) { guard seconds.isFinite else { return }; player.seek(to: CMTime(seconds: min(duration, max(0, seconds)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); updateNowPlaying() }
    func remove(_ ids: Set<UUID>) { if queue.remove(ids) { stop() }; onChange?() }
    func clear() { stop(); queue.clear(); updateNowPlaying(); onChange?() }
    func move(_ id: UUID, by delta: Int) { if queue.move(id, by: delta) { onChange?() } }
    func toggleShuffle() { queue.shuffle.toggle(); UserDefaults.standard.set(queue.shuffle, forKey: "shuffle"); onTick?() }
    func cycleRepeat() { queue.repeatMode = queue.repeatMode == .off ? .all : queue.repeatMode == .all ? .one : .off; UserDefaults.standard.set(queue.repeatMode.rawValue, forKey: "repeat"); onTick?() }
    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let song = queue.song else {
            center.playbackState = .stopped
            center.nowPlayingInfo = nil
            return
        }
        center.nowPlayingInfo = [MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue, MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0, MPMediaItemPropertyTitle: song.title, MPMediaItemPropertyArtist: song.artist, MPMediaItemPropertyAlbumTitle: song.album, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1 : 0]
        center.playbackState = stopped ? .stopped : (playing ? .playing : .paused)
    }
    func shutdown() {
        scanTask?.cancel(); stop()
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if let periodic { player.removeTimeObserver(periodic); self.periodic = nil }
    }
}
