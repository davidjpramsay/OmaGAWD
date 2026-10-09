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
    var selectedFolder = "local" {
        didSet { defaults.set(selectedFolder, forKey: "selectedFolder"); saveSession() }
    }
    var sources: [URL]
    var account: Account?
    var busy = false
    var message = "Add a music folder or connect to Jellyfin."
    var error = false
    let player = AVPlayer()
    let spectrum = Spectrum()
    let local = LocalLibrary()
    var position: Double { if let pendingPosition { return pendingPosition }; let t = player.currentTime().seconds; return t.isFinite ? t : 0 }
    var duration: Double { let t = player.currentItem?.duration.seconds ?? 0; return t.isFinite && t > 0 ? t : queue.song?.duration ?? 0 }
    var playing: Bool { player.rate != 0 }
    var bitRate: Float = 0
    var stopped = true
    var visible = false { didSet { spectrum.setEnabled(visible && playing) } }
    var volume: Float { get { player.volume } set { player.volume = min(1, max(0, newValue)); defaults.set(player.volume, forKey: "volume") } }
    private let defaults: UserDefaults
    private let sessionStore: PlayerSessionStore?
    private let loadAccount: () async throws -> Account?
    private let loadFolders: (Account) async throws -> [MusicFolder]
    private let loadSongs: (Account, String) async throws -> [Song]
    private var startupTask: Task<Void, Never>?
    private var folderTask: Task<Void, Never>?
    private var accountGeneration = 0
    private var queueRevision = 0
    private var selectionRevision = 0
    private var sessionLoaded = false
    private var shuttingDown = false
    private var retrySignIn = false
    private var preferRemoteOnDiscovery = false
    private var queueLibrary: LibraryIdentity?
    private var pendingPosition: Double?
    private var seekGeneration = 0
    private var lastCheckpoint: TimeInterval = 0
    private(set) var accountLoading = false
    private(set) var refreshingFolders = false
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
    init(defaults: UserDefaults = .standard, sessionStore: PlayerSessionStore? = PlayerSessionStore(),
         loadAccount: @escaping () async throws -> Account? = { try await Keychain.load() },
         loadFolders: @escaping (Account) async throws -> [MusicFolder] = { try await Jellyfin($0).folders() },
         loadSongs: @escaping (Account, String) async throws -> [Song] = { try await Jellyfin($0).songs(folder: $1) }) {
        self.defaults = defaults; self.sessionStore = sessionStore
        self.loadAccount = loadAccount; self.loadFolders = loadFolders; self.loadSongs = loadSongs
        sources = (defaults.stringArray(forKey: "sources") ?? []).map { URL(fileURLWithPath: $0) }
        selectedFolder = defaults.string(forKey: "selectedFolder") ?? "local"
        preferRemoteOnDiscovery = defaults.string(forKey: "selectedFolder") == nil && sources.isEmpty
        player.volume = defaults.object(forKey: "volume") == nil ? 0.7 : defaults.float(forKey: "volume")
        queue.shuffle = defaults.bool(forKey: "shuffle")
        queue.repeatMode = RepeatMode(rawValue: defaults.string(forKey: "repeat") ?? "off") ?? .off
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in Task { @MainActor in
            guard let self else { return }; self.spectrum.setEnabled(self.visible && self.playing); self.updateNowPlaying(); self.onTick?()
        } }
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.visible { self.onTick?() }
                let now = ProcessInfo.processInfo.systemUptime
                if self.playing && now - self.lastCheckpoint >= 5 { self.saveSession(); self.lastCheckpoint = now }
            }
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
        startupTask?.cancel()
        accountLoading = true; let revision = accountGeneration; let edits = queueRevision; let selection = selectionRevision
        if sources.isEmpty && queue.entries.isEmpty { message = "Loading saved sign-in…" }
        if selectedFolder == "local", !sources.isEmpty { loadLocal() }
        onChange?()
        startupTask = Task {
            if !sessionLoaded {
                let saved = await sessionStore?.load()
                guard !Task.isCancelled, accountGeneration == revision else { return }
                if queueRevision == edits, let saved {
                    queue.restore(saved.entries, current: saved.current); queueLibrary = saved.library
                    pendingPosition = saved.position.isFinite ? max(0, saved.position) : 0
                    stopped = saved.stopped
                    if selectionRevision == selection { selectedFolder = saved.selectedFolder; preferRemoteOnDiscovery = false }
                }
                sessionLoaded = true; restorePlaybackIfPossible(); onChange?()
            }
            do {
                let restored = try await loadAccount()
                guard !Task.isCancelled, accountGeneration == revision else { return }
                account = restored; accountLoading = false; retrySignIn = false
                restorePlaybackIfPossible(); saveSession(); onChange?()
                if restored != nil { discoverLibraries(reloadSongs: selectedFolder != "local" || preferRemoteOnDiscovery) }
                else if selectedFolder != "local" {
                    report(MusicError.message("Saved Jellyfin sign-in is unavailable. Connect to Jellyfin to restore this library."))
                }
                else if queue.entries.isEmpty && songs.isEmpty && !busy { message = "Add a music folder or connect to Jellyfin."; onChange?() }
            } catch {
                guard !Task.isCancelled, accountGeneration == revision else { return }
                accountLoading = false; retrySignIn = true; report(error)
            }
        }
    }
    func refreshLibrary() {
        if accountLoading { if selectedFolder == "local" { loadLocal() }; return }
        if account != nil {
            if selectedFolder == "local" && !preferRemoteOnDiscovery { loadLocal() }
            discoverLibraries(reloadSongs: selectedFolder != "local" || preferRemoteOnDiscovery)
        }
        else if retrySignIn { start() }
        else { loadLocal() }
    }
    private func discoverLibraries(reloadSongs: Bool) {
        guard let account else { return }
        folderTask?.cancel(); let revision = accountGeneration
        refreshingFolders = true; onChange?()
        folderTask = Task {
            do {
                let restored = try await loadFolders(account)
                try Task.checkCancellation()
                guard accountGeneration == revision, self.account?.token == account.token else { return }
                folders = restored; refreshingFolders = false
                var next = selectedFolder
                if selectedFolder != "local", !folders.contains(where: { $0.id == selectedFolder }) { next = folders.first?.id ?? "local" }
                else if preferRemoteOnDiscovery, let first = folders.first { next = first.id }
                preferRemoteOnDiscovery = false
                if next != selectedFolder || reloadSongs { selectFolder(next) }
                onChange?()
            } catch {
                guard !Task.isCancelled, accountGeneration == revision else { return }
                refreshingFolders = false
                report(MusicError.message("Could not refresh Jellyfin libraries: \(error.localizedDescription) Use Refresh to retry."))
            }
        }
    }
    private func restorePlaybackIfPossible() {
        guard !stopped, let index = queue.index, player.currentItem == nil, playbackTask == nil else { return }
        let song = queue.entries[index].song
        guard song.file != nil || account.map({ queueLibrary == LibraryIdentity($0) }) == true else { return }
        prepare(index, autoplay: wantsPlayback, position: position)
    }
    func report(_ error: Error) { if error is CancellationError { return }; self.error = true; message = error.localizedDescription; onChange?() }
    func selectFolder(_ id: String) {
        selectionRevision += 1
        preferRemoteOnDiscovery = false
        if selectedFolder != id { songs = [] }
        selectedFolder = id
        if id == "local" { loadLocal(); return }
        guard let account else { return }
        work { (try await self.loadSongs(account, id), []) }
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
        sources = Array(Set(sources + urls)).sorted { $0.path < $1.path }; saveSources(); selectFolder("local")
    }
    func removeSource(_ index: Int) { guard sources.indices.contains(index) else { return }; sources.remove(at: index); saveSources(); selectFolder("local") }
    private func saveSources() { defaults.set(sources.map(\.path), forKey: "sources") }
    func connect(server: String, username: String, password: String) async throws {
        accountGeneration += 1; let revision = accountGeneration
        startupTask?.cancel(); folderTask?.cancel(); accountLoading = false; refreshingFolders = false
        let signedIn = try await Jellyfin.login(server: server, username: username, password: password)
        let libraries = try await loadFolders(signedIn)
        guard accountGeneration == revision else { throw CancellationError() }
        try await Keychain.save(signedIn)
        guard accountGeneration == revision else { throw CancellationError() }
        sessionLoaded = true; clear(); account = signedIn; folders = libraries; retrySignIn = false
        if let first = folders.first { selectFolder(first.id) }
        else { selectFolder("local"); message = "Connected. No music libraries found."; onChange?() }
    }
    func disconnect() async throws {
        accountGeneration += 1; let revision = accountGeneration
        startupTask?.cancel(); folderTask?.cancel(); accountLoading = false; refreshingFolders = false
        try await Keychain.remove()
        guard accountGeneration == revision else { throw CancellationError() }
        if let old = account { Task { await Jellyfin(old).logout() } }
        sessionLoaded = true; account = nil; folders = []; clear(); selectFolder("local")
    }
    func append(_ songs: [Song]) { queueRevision += 1; rememberLibrary(for: songs); queue.append(songs); saveSession(); onChange?() }
    func replace(_ songs: [Song]) { guard !songs.isEmpty else { return }; queueRevision += 1; queueLibrary = nil; rememberLibrary(for: songs); queue.replace(songs); play(0) }
    private func rememberLibrary(for songs: [Song]) { if songs.contains(where: { $0.file == nil }), let account { queueLibrary = LibraryIdentity(account) } }
    func play(_ index: Int) { prepare(index, autoplay: true, position: 0) }
    private func prepare(_ index: Int, autoplay: Bool, position: Double) {
        guard queue.entries.indices.contains(index) else { return }
        queueRevision += 1
        seekGeneration += 1
        playbackTask?.cancel(); player.pause(); statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }; failureObserver = nil
        player.replaceCurrentItem(with: nil); loader?.cancel(); loader = nil
        queue.current = queue.entries[index].id; let identity = queue.current; let song = queue.entries[index].song
        wantsPlayback = autoplay; pendingPosition = position > 0 ? position : nil
        stopped = false; bitRate = 0; error = false; message = "Loading \(song.title)…"; saveSession(); onChange?()
        let asset: AVURLAsset
        if let file = song.file { asset = AVURLAsset(url: file) }
        else if let account, queueLibrary == nil || queueLibrary == LibraryIdentity(account) {
            let resource = AudioResourceLoader(account: account, songID: song.id); loader = resource
            asset = AVURLAsset(url: URL(string: "omagawd://audio/\(UUID().uuidString)")!)
            asset.resourceLoader.setDelegate(resource, queue: .main)
        } else {
            if accountLoading { message = "Waiting for saved Jellyfin sign-in…"; onChange?() }
            else { stopped = true; report(MusicError.message("Connect to the saved Jellyfin server and account to play this track.")) }
            return
        }
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
                        else if item.status == .readyToPlay {
                            self.message = "\(self.songs.count) songs"; self.error = false
                            if let position = self.pendingPosition { self.seek(position) }
                            self.onChange?(); self.updateNowPlaying()
                        }
                    }
                }
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in self?.next(automatic: true) } }
                failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
                    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    Task { @MainActor in self?.report(error ?? MusicError.message("Playback was interrupted.")) }
                }
                player.replaceCurrentItem(with: item); if wantsPlayback && pendingPosition == nil { player.play() }; updateNowPlaying(); onChange?()
            } catch { if !(error is CancellationError), queue.current == identity { stopped = true; report(error) } }
        }
    }
    func toggle() { wantsPlayback && !stopped ? pause() : resume() }
    func resume() {
        wantsPlayback = true
        if stopped || (player.currentItem == nil && playbackTask == nil) { prepare(queue.index ?? 0, autoplay: true, position: position) }
        else if player.currentItem != nil && pendingPosition == nil { player.play() }
    }
    func pause() { wantsPlayback = false; player.pause(); saveSession(); updateNowPlaying(); onTick?() }
    func stop() { queueRevision += 1; seekGeneration += 1; wantsPlayback = false; playbackTask?.cancel(); playbackTask = nil; player.pause(); player.replaceCurrentItem(with: nil); loader?.cancel(); loader = nil; pendingPosition = nil; stopped = true; spectrum.setEnabled(false); saveSession(); updateNowPlaying(); onTick?() }
    func next(automatic: Bool = false) { if let next = queue.next(automatic: automatic) { play(next) } else { stop() } }
    func previous() { play(max(0, (queue.index ?? 0) - 1)) }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        seekGeneration += 1; let revision = seekGeneration
        pendingPosition = min(duration, max(0, seconds)); saveSession(); onTick?()
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        player.seek(to: CMTime(seconds: pendingPosition!, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, self.player.currentItem === item, self.seekGeneration == revision else { return }
                self.pendingPosition = nil
                if self.wantsPlayback { self.player.play() }
                self.saveSession(); self.updateNowPlaying(); self.onTick?()
            }
        }
    }
    func remove(_ ids: Set<UUID>) { queueRevision += 1; if queue.remove(ids) { stop() }; saveSession(); onChange?() }
    func clear() { stop(); queue.clear(); queueLibrary = nil; saveSession(); updateNowPlaying(); onChange?() }
    func move(_ id: UUID, by delta: Int) { if queue.move(id, by: delta) { queueRevision += 1; saveSession(); onChange?() } }
    func toggleShuffle() { queue.shuffle.toggle(); defaults.set(queue.shuffle, forKey: "shuffle"); onTick?() }
    func cycleRepeat() { queue.repeatMode = queue.repeatMode == .off ? .all : queue.repeatMode == .all ? .one : .off; defaults.set(queue.repeatMode.rawValue, forKey: "repeat"); onTick?() }
    private func sessionSnapshot() -> PlayerSession {
        PlayerSession(entries: queue.entries, current: queue.current, position: position, selectedFolder: selectedFolder,
                      stopped: stopped, library: queue.entries.contains(where: { $0.song.file == nil }) ? queueLibrary : nil)
    }
    private func saveSession() { if sessionLoaded && !shuttingDown { sessionStore?.save(sessionSnapshot()) } }
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
        guard !shuttingDown else { return }
        shuttingDown = true; accountGeneration += 1; startupTask?.cancel(); folderTask?.cancel()
        if sessionLoaded { try? sessionStore?.flush(sessionSnapshot()) }
        scanTask?.cancel(); stop()
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if let periodic { player.removeTimeObserver(periodic); self.periodic = nil }
    }
}
