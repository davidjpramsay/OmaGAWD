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
    let player = AVQueuePlayer()
    let spectrum = Spectrum()
    let local = LocalLibrary()
    let radio: RadioLibrary
    private(set) var radioTitle = ""
    private var radioMetadata: RadioMetadataSink?
    var position: Double { if queue.song?.isRadio == true { return 0 }; if let pendingPosition { return pendingPosition }; let t = player.currentTime().seconds; return t.isFinite ? t : 0 }
    var duration: Double { if queue.song?.isRadio == true { return 0 }; let t = player.currentItem?.duration.seconds ?? 0; return t.isFinite && t > 0 ? t : queue.song?.duration ?? 0 }
    var canSeek: Bool { !stopped && queue.song?.isRadio != true }
    var playing: Bool { player.rate != 0 }
    var bitRate: Float = 0
    var stopped = true
    var visible = false { didSet { spectrum.setEnabled(visible && playing) } }
    var volume: Float { get { player.volume } set { player.volume = min(1, max(0, newValue)); defaults.set(player.volume, forKey: "volume") } }
    var gapless: Bool { didSet { defaults.set(gapless, forKey: "gapless"); refreshPreload(); onTick?() } }
    var normalization: Bool { didSet { defaults.set(normalization, forKey: "normalization"); spectrum.normalizationEnabled = normalization; onTick?() } }
    var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: "reduceMotion"); onTick?() } }
    var keepRecent: Bool { didSet { defaults.set(keepRecent, forKey: "keepRecent") } }
    private(set) var collections = CollectionData()
    private let collectionStore: CollectionStore
    private var recentEntry: UUID?
    private var lastRemoteFolder: String?
    private struct Preloaded {
        let id: UUID
        let item: AVPlayerItem
        let loader: AudioResourceLoader?
        let bitRate: Float
    }
    private var preloaded: Preloaded?
    private var preloadTask: Task<Void, Never>?
    private var preloadRevision = 0
    private var itemObservation: NSKeyValueObservation?
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
    init(defaults: UserDefaults = .standard, sessionStore: PlayerSessionStore? = PlayerSessionStore(), radio: RadioLibrary? = nil,
         collectionStore: CollectionStore? = nil,
         loadAccount: @escaping () async throws -> Account? = { try await Keychain.load() },
         loadFolders: @escaping (Account) async throws -> [MusicFolder] = { try await Jellyfin($0).folders() },
         loadSongs: @escaping (Account, String) async throws -> [Song] = { try await Jellyfin($0).songs(folder: $1) }) {
        self.defaults = defaults; self.sessionStore = sessionStore
        self.collectionStore = collectionStore ?? CollectionStore(url: sessionStore == nil ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.davidjpramsay.OmaGAWD/collections.json"))
        gapless = defaults.object(forKey: "gapless") as? Bool ?? true
        normalization = defaults.bool(forKey: "normalization")
        reduceMotion = defaults.bool(forKey: "reduceMotion")
        keepRecent = defaults.object(forKey: "keepRecent") as? Bool ?? true
        lastRemoteFolder = defaults.string(forKey: "lastRemoteFolder")
        self.radio = radio ?? RadioLibrary(store: sessionStore == nil ? RadioStationStore(url: nil) : RadioStationStore())
        self.loadAccount = loadAccount; self.loadFolders = loadFolders; self.loadSongs = loadSongs
        sources = (defaults.stringArray(forKey: "sources") ?? []).map { URL(fileURLWithPath: $0) }
        selectedFolder = defaults.string(forKey: "selectedFolder") ?? "local"
        preferRemoteOnDiscovery = defaults.string(forKey: "selectedFolder") == nil && sources.isEmpty
        player.volume = defaults.object(forKey: "volume") == nil ? 0.7 : defaults.float(forKey: "volume")
        queue.shuffle = defaults.bool(forKey: "shuffle")
        queue.repeatMode = RepeatMode(rawValue: defaults.string(forKey: "repeat") ?? "off") ?? .off
        spectrum.normalizationEnabled = normalization
        player.actionAtItemEnd = .advance
        sessionStore?.onFailure = { [weak self] error in Task { @MainActor in self?.report(MusicError.message("Could not save playback. " + error.localizedDescription)) } }
        itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor in
                guard let self, self.player.currentItem === item, let next = self.preloaded, next.item === item else { return }
                self.preloaded = nil; self.loader?.cancel(); self.loader = next.loader
                self.queue.current = next.id; self.queueRevision += 1; self.pendingPosition = nil; self.bitRate = next.bitRate
                self.stopped = false; self.error = false; self.radioTitle = ""
                self.observeItem(next.item, song: self.queue.song!)
                self.saveSession(); self.recordRecent(); self.updateNowPlaying(); self.onChange?(); self.refreshPreload()
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in Task { @MainActor in
            guard let self else { return }; self.spectrum.setEnabled(self.visible && self.playing); self.recordRecent(); self.updateNowPlaying(); self.onTick?()
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
        self.radio.onChange = { [weak self] in
            guard let self, self.selectedFolder == "radio" else { return }
            self.songs = self.radio.saved.map(\.song); self.message = self.radio.message; self.error = self.radio.error; self.onChange?()
        }
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
        Task { await refreshCollections() }
        radio.start()
        startupTask?.cancel()
        accountLoading = true; let revision = accountGeneration; let edits = queueRevision; let selection = selectionRevision
        if sources.isEmpty && queue.entries.isEmpty { message = "Loading saved sign-in…" }
        if selectedFolder == "local", !sources.isEmpty { loadLocal() }
        if selectedFolder == "radio" { songs = radio.saved.map(\.song); message = radio.message; error = radio.error }
        onChange?()
        startupTask = Task {
            if !sessionLoaded {
                let saved = await sessionStore?.load()
                guard !Task.isCancelled, accountGeneration == revision else { return }
                if queueRevision == edits, let saved {
                    queue.restore(saved.entries, current: saved.current); queueLibrary = saved.library
                    pendingPosition = saved.position.isFinite ? max(0, saved.position) : 0
                    stopped = saved.stopped
                    if selectionRevision == selection {
                        if selectedFolder != saved.selectedFolder { selectFolder(saved.selectedFolder) }
                        preferRemoteOnDiscovery = false
                    }
                }
                if selectedFolder == "radio" { songs = self.radio.saved.map(\.song); message = self.radio.message; error = self.radio.error }
                sessionLoaded = true; restorePlaybackIfPossible(); onChange?()
            }
            do {
                let restored = try await loadAccount()
                guard !Task.isCancelled, accountGeneration == revision else { return }
                account = restored; accountLoading = false; retrySignIn = false
                restorePlaybackIfPossible(); saveSession(); onChange?()
                if restored != nil { discoverLibraries(reloadSongs: (selectedFolder != "local" && selectedFolder != "radio") || preferRemoteOnDiscovery) }
                else if selectedFolder != "local" && selectedFolder != "radio" {
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
        if selectedFolder == "radio" { if radio.mode == .discover { radio.search() } else { message = radio.message; error = radio.error; onChange?() }; return }
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
                if selectedFolder != "local", selectedFolder != "radio", !folders.contains(where: { $0.id == selectedFolder }) { next = folders.first?.id ?? "local" }
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
        guard song.file != nil || song.isRadio || account.map({ queueLibrary == LibraryIdentity($0) }) == true else { return }
        if song.isRadio && !wantsPlayback { updateNowPlaying(); return }
        prepare(index, autoplay: wantsPlayback, position: position)
    }
    func report(_ error: Error) { if error is CancellationError { return }; self.error = true; message = error.localizedDescription; onChange?() }
    func selectFolder(_ id: String) {
        selectionRevision += 1
        preferRemoteOnDiscovery = false
        if selectedFolder != id { songs = [] }
        selectedFolder = id
        if id != "local" && id != "radio" { lastRemoteFolder = id; defaults.set(id, forKey: "lastRemoteFolder") }
        if id == "radio" {
            scanTask?.cancel(); generation += 1; busy = false; radio.start()
            songs = radio.saved.map(\.song); message = radio.message; error = radio.error; onChange?(); return
        }
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
        do { let chosen = try MediaPolicy.sources(urls); let combined = Array(Set(sources + chosen)).sorted { $0.path < $1.path }
            guard combined.count <= 1000, combined.reduce(0, { $0 + $1.path.utf8.count }) <= 1024 * 1024 else { throw MusicError.message("Too many local sources (maximum 1,000 / 1 MiB).") }
            sources = combined; saveSources(); selectFolder("local")
        } catch { report(error) }
    }
    func selectJellyfin() {
        if let id = lastRemoteFolder, folders.contains(where: { $0.id == id }) { selectFolder(id) }
        else if let folder = folders.first { selectFolder(folder.id) }
    }
    func dropMusic(_ urls: [URL], append: Bool) {
        Task {
            do {
                let chosen = try MediaPolicy.sources(urls)
                let songs = try await local.scan(chosen)
                guard !songs.isEmpty else { throw MusicError.message("No playable music found in that drop.") }
                addSources(chosen)
                if append { self.append(songs) } else { self.replace(songs) }
            } catch { report(error) }
        }
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
        if queue.song?.requiresAccount == true, queueLibrary != LibraryIdentity(signedIn) {
            let savedPosition = position; stop(); pendingPosition = savedPosition; stopped = false
        }
        discardPreload()
        sessionLoaded = true; account = signedIn; folders = libraries; retrySignIn = false
        if let first = folders.first { selectFolder(first.id) }
        else { selectFolder("local"); message = "Connected. No music libraries found."; onChange?() }
    }
    func disconnect() async throws {
        accountGeneration += 1; let revision = accountGeneration
        startupTask?.cancel(); folderTask?.cancel(); accountLoading = false; refreshingFolders = false
        try await Keychain.remove()
        guard accountGeneration == revision else { throw CancellationError() }
        if let old = account { Task { await Jellyfin(old).logout() } }
        sessionLoaded = true; discardPreload(); if queue.song?.requiresAccount == true { let savedPosition = position; stop(); pendingPosition = savedPosition; stopped = false }; account = nil; folders = []; selectFolder("local")
    }
    func append(_ songs: [Song]) {
        guard !songs.isEmpty, queue.entries.count + songs.count <= 100_000 else { if !songs.isEmpty { report(MusicError.message("Queue exceeds 100,000 tracks.")) }; return }
        if songs.contains(where: \.requiresAccount), queue.entries.contains(where: \.song.requiresAccount), let account, let queueLibrary, queueLibrary != LibraryIdentity(account) { report(MusicError.message("Load or clear the queue before adding songs from a different Jellyfin account.")); return }
        queueRevision += 1; rememberLibrary(for: songs); queue.append(songs); saveSession(); refreshPreload(); onChange?() }
    func replace(_ songs: [Song]) { guard !songs.isEmpty, songs.count <= 100_000 else { return }; queueRevision += 1; queueLibrary = nil; rememberLibrary(for: songs); queue.replace(songs); play(0) }
    private func rememberLibrary(for songs: [Song]) { if songs.contains(where: \.requiresAccount), let account { queueLibrary = LibraryIdentity(account) } }
    func play(_ index: Int) { prepare(index, autoplay: true, position: 0) }
    private func prepare(_ index: Int, autoplay: Bool, position: Double) {
        guard queue.entries.indices.contains(index) else { return }
        queueRevision += 1
        seekGeneration += 1
        discardPreload(); playbackTask?.cancel(); player.pause(); statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }; failureObserver = nil
        player.replaceCurrentItem(with: nil); loader?.cancel(); loader = nil; radioMetadata = nil; radioTitle = ""
        queue.current = queue.entries[index].id; let identity = queue.current; let song = queue.entries[index].song
        wantsPlayback = autoplay; pendingPosition = !song.isRadio && position > 0 ? position : nil
        stopped = false; bitRate = 0; error = false; message = "Loading \(song.title)…"; saveSession(); onChange?()
        let asset: AVURLAsset
        if let file = song.file {
            do { asset = AVURLAsset(url: try MediaPolicy.localFile(file)) }
            catch { stopped = true; report(error); return }
        }
        else if let url = song.radioURL {
            guard let stream = try? RadioStream.address(url.absoluteString) else {
                stopped = true; report(MusicError.message("The saved radio stream link is invalid. Choose or save the station again.")); return
            }
            asset = AVURLAsset(url: stream, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false, AVURLAssetHTTPUserAgentKey: "OmaGAWD/macOS"])
        }
        else if let account, queueLibrary == LibraryIdentity(account) {
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
                if song.isRadio {
                    let metadata = AVPlayerItemMetadataOutput(identifiers: nil)
                    let sink = RadioMetadataSink { [weak self, weak item] title in
                        guard let self, let item, self.player.currentItem === item, self.radioTitle != title else { return }
                        self.radioTitle = title; self.updateNowPlaying(); self.onTick?()
                    }
                    radioMetadata = sink; metadata.setDelegate(sink, queue: .main); item.add(metadata)
                    // ICY/HLS assets may not expose an AVAssetTrack before play.
                    // The mixed-output tap is independent of that track list.
                    if #available(macOS 27.0, *) { item.audioMix = spectrum.mix() }
                }
                if let track = tracks.first {
                    bitRate = (try? await track.load(.estimatedDataRate)) ?? 0
                    try Task.checkCancellation()
                    if item.audioMix == nil { item.audioMix = spectrum.mix(for: track) }
                }
                observeItem(item, song: song)
                player.replaceCurrentItem(with: item); refreshPreload(); if wantsPlayback && pendingPosition == nil { player.play() }; updateNowPlaying(); onChange?()
            } catch { if !Task.isCancelled, !(error is CancellationError), queue.current == identity { stopped = true; report(error) } }
        }
    }
    private func observeItem(_ item: AVPlayerItem, song: Song) {
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }; failureObserver = nil
        let observedID = queue.current
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed {
                    if song.isRadio { self.stop() } else { self.stopped = true }
                    self.report(item.error ?? MusicError.message("The audio format could not be played."))
                }
                else if item.status == .readyToPlay {
                    self.message = self.selectedFolder == "radio" ? self.radio.message : "\(self.songs.count) songs"; self.error = false
                    if let position = self.pendingPosition { self.seek(position) }
                    self.onChange?(); self.updateNowPlaying()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in
            guard let self, self.player.currentItem === item || (self.player.currentItem == nil && self.queue.current == observedID && !self.stopped) else { return }
            if !song.isRadio, let next = self.preloaded, self.player.items().contains(where: { $0 === next.item }) { return }
            if song.isRadio { self.stop(); self.report(MusicError.message("Radio station is unavailable. Press Play to reconnect or choose another station.")) }
            else { self.next(automatic: true) }
        } }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if song.isRadio { self.stop(); self.report(MusicError.message("Radio station is unavailable. Press Play to reconnect or choose another station.")) }
                else { self.report(error ?? MusicError.message("Playback was interrupted.")) }
            }
        }
    }
    private func discardPreload() {
        preloadRevision += 1; preloadTask?.cancel(); preloadTask = nil
        if let preloaded { player.remove(preloaded.item); preloaded.loader?.cancel() }
        preloaded = nil
    }
    func refreshPreload() {
        guard gapless, !stopped, queue.song?.isRadio == false, let current = player.currentItem,
              let index = queue.next(automatic: true), !queue.entries[index].song.isRadio else { discardPreload(); return }
        let entry = queue.entries[index]
        if preloaded?.id == entry.id { return }
        discardPreload(); let revision = preloadRevision
        let account = self.account, library = queueLibrary
        preloadTask = Task {
            var resource: AudioResourceLoader?
            do {
                let asset: AVURLAsset
                if let file = entry.song.file { asset = AVURLAsset(url: try MediaPolicy.localFile(file)) }
                else {
                    guard let account, library == LibraryIdentity(account) else { return }
                    let loader = AudioResourceLoader(account: account, songID: entry.song.id); resource = loader
                    asset = AVURLAsset(url: URL(string: "omagawd://audio/\(UUID().uuidString)")!)
                    asset.resourceLoader.setDelegate(loader, queue: .main)
                }
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                let rate = (try? await tracks.first?.load(.estimatedDataRate)) ?? 0
                try Task.checkCancellation()
                guard preloadRevision == revision, player.currentItem === current, queue.entries.contains(where: { $0.id == entry.id }) else { resource?.cancel(); return }
                let item = AVPlayerItem(asset: asset)
                if let track = tracks.first { item.audioMix = spectrum.mix(for: track) }
                guard player.canInsert(item, after: current) else { resource?.cancel(); return }
                preloaded = Preloaded(id: entry.id, item: item, loader: resource, bitRate: rate)
                player.insert(item, after: current)
            } catch { resource?.cancel() } // Current playback continues; normal Next can report a bad source.
        }
    }
    func toggle() { wantsPlayback && !stopped ? pause() : resume() }
    func resume() {
        wantsPlayback = true
        if stopped || (player.currentItem == nil && playbackTask == nil) { prepare(queue.index ?? 0, autoplay: true, position: position) }
        else if player.currentItem != nil && pendingPosition == nil { player.play() }
    }
    func pause() {
        if queue.song?.isRadio == true && !stopped {
            // A live broadcast has no resumable position. Release its connection
            // while paused and reconnect to the current broadcast on Play.
            stop(); stopped = false
        } else { wantsPlayback = false; player.pause() }
        saveSession(); updateNowPlaying(); onTick?()
    }
    func stop() {
        discardPreload(); queueRevision += 1; seekGeneration += 1; wantsPlayback = false; playbackTask?.cancel(); playbackTask = nil
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }; failureObserver = nil
        player.pause(); player.replaceCurrentItem(with: nil); loader?.cancel(); loader = nil
        radioMetadata = nil; radioTitle = ""; pendingPosition = nil; stopped = true; spectrum.setEnabled(false)
        saveSession(); updateNowPlaying(); onTick?()
    }
    func next(automatic: Bool = false) { if let next = queue.next(automatic: automatic) { play(next) } else { stop() } }
    func previous() { play(max(0, (queue.index ?? 0) - 1)) }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, queue.song?.isRadio != true else { return }
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
    func remove(_ ids: Set<UUID>) { queueRevision += 1; if queue.remove(ids) { stop() }; saveSession(); refreshPreload(); onChange?() }
    func clear() { stop(); queue.clear(); queueLibrary = nil; saveSession(); updateNowPlaying(); onChange?() }
    func move(_ id: UUID, by delta: Int) { if queue.move(id, by: delta) { queueRevision += 1; saveSession(); refreshPreload(); onChange?() } }
    func toggleShuffle() { queue.shuffle.toggle(); defaults.set(queue.shuffle, forKey: "shuffle"); refreshPreload(); onTick?() }
    func cycleRepeat() { queue.repeatMode = queue.repeatMode == .off ? .all : queue.repeatMode == .all ? .one : .off; defaults.set(queue.repeatMode.rawValue, forKey: "repeat"); refreshPreload(); onTick?() }
    func sessionSnapshot() -> PlayerSession {
        PlayerSession(entries: queue.entries, current: queue.current, position: position, selectedFolder: selectedFolder,
                      stopped: stopped, library: queue.entries.contains(where: \.song.requiresAccount) ? queueLibrary : nil)
    }
    private func saveSession() { if sessionLoaded && !shuttingDown { sessionStore?.save(sessionSnapshot()) } }
    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let song = queue.song else {
            center.playbackState = .stopped
            center.nowPlayingInfo = nil
            return
        }
        center.nowPlayingInfo = [MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue, MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0, MPMediaItemPropertyTitle: song.isRadio && !radioTitle.isEmpty ? radioTitle : song.title, MPMediaItemPropertyArtist: song.isRadio ? song.title : song.artist, MPMediaItemPropertyAlbumTitle: song.album, MPNowPlayingInfoPropertyIsLiveStream: song.isRadio, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1 : 0]
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = !song.isRadio
        center.playbackState = stopped ? .stopped : (playing ? .playing : .paused)
    }
    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true; accountGeneration += 1; startupTask?.cancel(); folderTask?.cancel()
        if sessionLoaded { do { try sessionStore?.flush(sessionSnapshot()) } catch { report(MusicError.message("Could not save playback before quitting. " + error.localizedDescription)) } }
        scanTask?.cancel(); radio.cancel(); stop()
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if let periodic { player.removeTimeObserver(periodic); self.periodic = nil }
    }
    func refreshCollections() async {
        do { collections = try await collectionStore.load(); onChange?() } catch { report(error) }
    }
    func savePlaylist(_ name: String) async {
        do { collections = try await collectionStore.add(name, snapshot: sessionSnapshot()); onChange?() } catch { report(error) }
    }
    func renamePlaylist(_ id: String, name: String) async {
        do { collections = try await collectionStore.rename(id, title: name); onChange?() } catch { report(error) }
    }
    func forgetPlaylist(_ id: String) async {
        do { collections = try await collectionStore.remove(id); onChange?() } catch { report(error) }
    }
    func clearRecent() async {
        do { collections = try await collectionStore.clearRecent(); recentEntry = queue.current; onChange?() } catch { report(error) }
    }
    func appendCollection(_ item: SavedCollection, selectedIndex: Int? = nil) {
        if item.snapshot.entries.contains(where: \.song.requiresAccount) {
            guard let account, item.snapshot.library == LibraryIdentity(account) else { report(MusicError.message("Connect to the original Jellyfin server and account to append this playlist.")); return }
        }
        if let index = selectedIndex, item.snapshot.entries.indices.contains(index) { append([item.snapshot.entries[index].song]) }
        else { append(item.snapshot.entries.map(\.song)) }
    }
    func loadCollection(_ item: SavedCollection, autoplay: Bool, startIndex: Int = 0) {
        if item.snapshot.entries.contains(where: \.song.requiresAccount) {
            guard let account, item.snapshot.library == LibraryIdentity(account) else { report(MusicError.message("Connect to the original Jellyfin server and account to open this playlist.")); return }
        }
        stop(); queueRevision += 1; queue.restore(item.snapshot.entries.map { QueueEntry($0.song) }, current: nil)
        queueLibrary = item.snapshot.library
        if !queue.entries.isEmpty { prepare(min(max(0, startIndex), queue.entries.count - 1), autoplay: autoplay, position: 0) }
        saveSession(); onChange?()
    }
    private func recordRecent() {
        guard keepRecent, playing, !stopped, recentEntry != queue.current, let song = queue.song else { return }
        recentEntry = queue.current
        let groupSongs: [Song]
        if song.isRadio { groupSongs = [song] }
        else {
            let pool = songs.contains(where: { $0.id == song.id }) ? songs : queue.entries.map(\.song)
            var seen = Set<String>()
            groupSongs = pool.filter { $0.albumID == song.albumID && $0.artist == song.artist && $0.requiresAccount == song.requiresAccount && !$0.isRadio && seen.insert($0.id).inserted }
        }
        guard !groupSongs.isEmpty else { return }
        let entries = groupSongs.map(QueueEntry.init)
        let snapshot = PlayerSession(entries: entries, current: entries.first?.id, position: 0, selectedFolder: selectedFolder, stopped: true, library: song.requiresAccount ? queueLibrary : nil)
        let origin = song.requiresAccount ? "\(queueLibrary?.server.absoluteString ?? "")/\(queueLibrary?.user ?? "")" : song.isRadio ? "radio" : "local"
        let group = "\(origin)/\(song.isRadio ? song.id : song.artist + "/" + song.albumID)"
        Task {
            do { collections = try await collectionStore.recent(group: group, title: song.isRadio ? song.title : "\(song.artist) — \(song.album)", snapshot: snapshot); onChange?() }
            catch { report(error) }
        }
    }

}
