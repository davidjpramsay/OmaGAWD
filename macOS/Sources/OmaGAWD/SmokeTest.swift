import Foundation
import AppKit
import OmaCore

// Opt-in, disposable fixture test; never reads or writes account credentials.
@MainActor func smokeTest(model: PlayerModel, controller: PlayerWindow, fixture: String, port: String, report: String, defaultsDomain: String? = nil) async {
    defer { if let defaultsDomain { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) } }
    var checks: [String] = []
    func check(_ condition: Bool, _ name: String) throws { guard condition else { throw MusicError.message("FAIL: \(name); player: \(model.message)") }; checks.append(name) }
    func settle(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    func llamaSnapshot() -> Data? {
        let view = controller.dancingLlama
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
    do {
        model.player.volume = 0
        let fixtureURL = URL(fileURLWithPath: fixture)
        let library = LocalLibrary(cacheDirectory: fixtureURL.deletingLastPathComponent().appendingPathComponent("cache"))
        let songs = try await library.scan([fixtureURL])
        try check(songs.count == 1 && songs[0].duration >= 29, "Local metadata and duration")
        model.songs = songs; model.visible = true; model.queue.repeatMode = .off; model.queue.shuffle = false
        model.replace(songs); await settle(2)
        try check(model.playing && model.position > 0, "Local AVFoundation playback")
        controller.show()
        for _ in 0..<40 {
            if !model.visible { controller.show() }
            if model.spectrum.read().max() ?? 0 > 0 { break }
            await settle(0.05)
        }
        try check(model.spectrum.read().max() ?? 0 > 0, "Real FFT spectrum receives PCM")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        try check(controller.dancingLlama.isDancing == !reduceMotion, "Llama follows playback and Reduce Motion")
        if !reduceMotion {
            let firstPose = llamaSnapshot(); await settle(0.4)
            try check(firstPose != nil && firstPose != llamaSnapshot(), "Llama renders changing dance poses")
            // Exercise the actual UI timer, not just the deterministic clock.
            await settle(8.1)
            // The user can work in other apps while this disposable panel runs.
            // Reveal it again so normal outside-click hiding cannot stall a UI check.
            controller.show()
            for _ in 0..<60 {
                if !model.visible { controller.show() }
                if controller.dancingLlama.currentDance == .sideShuffle { break }
                await settle(0.05)
            }
            try check(controller.dancingLlama.currentDance == .sideShuffle, "Llama changes dance after ten seconds of playback")
            await settle(10); controller.show()
            for _ in 0..<60 {
                if !model.visible { controller.show() }
                if controller.dancingLlama.currentDance == .headBang { break }
                await settle(0.05)
            }
            try check(controller.dancingLlama.currentDance == .headBang, "Head banging joins the third ten-second dance slot")
            let firstHeadPose = llamaSnapshot(); await settle(0.18)
            let secondHeadPose = llamaSnapshot()
            try check(firstHeadPose != nil && secondHeadPose != nil && firstHeadPose != secondHeadPose, "Head banging renders moving neck poses")
            let output = URL(fileURLWithPath: report).deletingLastPathComponent()
            try firstHeadPose?.write(to: output.appendingPathComponent("head-bang-runtime-1.png"))
            try secondHeadPose?.write(to: output.appendingPathComponent("head-bang-runtime-2.png"))
            await settle(10); controller.show()
            for _ in 0..<60 {
                if !model.visible { controller.show() }
                if controller.dancingLlama.currentDance == .twerk { break }
                await settle(0.05)
            }
            try check(controller.dancingLlama.currentDance == .twerk, "Twerk joins the fourth ten-second dance slot")
            let firstTwerkPose = llamaSnapshot(); await settle(0.18)
            let secondTwerkPose = llamaSnapshot()
            try check(firstTwerkPose != nil && secondTwerkPose != nil && firstTwerkPose != secondTwerkPose, "Twerk renders moving hindquarters")
            try firstTwerkPose?.write(to: output.appendingPathComponent("twerk-runtime-1.png"))
            try secondTwerkPose?.write(to: output.appendingPathComponent("twerk-runtime-2.png"))
        }
        model.pause(); await settle(0.2); let paused = model.position; await settle(0.3)
        try check(abs(model.position - paused) < 0.1, "Pause holds position")
        try check(!controller.dancingLlama.isDancing && controller.timer == nil, "Paused llama rests without an animation timer")
        model.seek(10); await settle(0.4); try check(abs(model.position - 10) < 0.5, "Local seek")
        model.resume(); model.append(songs)
        for _ in 0..<40 { if model.position > 10 { break }; await settle(0.05) }
        try check(model.queue.entries.count == 2 && model.position > 10 && model.playing, "Append does not interrupt playback")
        try check(controller.dancingLlama.isDancing == (model.visible && !reduceMotion),
                  "Llama resumes with visible playback (visible: \(model.visible), stopped: \(model.stopped), dancing: \(controller.dancingLlama.isDancing))")
        controller.show()
        try check(controller.dancingLlama.isDancing == !reduceMotion, "Revealed llama resumes with playback")
        let current = model.queue.current!; model.move(current, by: 1); try check(model.queue.index == 1 && model.playing, "Queue reorder preserves playback")
        model.remove([current]); try check(model.stopped && !model.playing, "Removing current track stops playback")
        try check(!controller.dancingLlama.isDancing, "Stopped llama returns to its standing pose")
        let server = "http://127.0.0.1:\(port)/jellyfin"
        let account = try await Jellyfin.login(server: server, username: "fixture", password: "fixture")
        let api = Jellyfin(account)
        let folders = try await api.folders(); try check(folders.count == 1, "Jellyfin authentication and base path")
        let remote = try await api.songs(folder: folders[0].id); try check(remote.count == 1, "Jellyfin library parsing")
        model.account = account; model.songs = remote; model.replace(remote); await settle(3)
        try check(model.playing && model.position > 0 && !model.error, "Authenticated remote byte-range playback")
        // Outside clicks and occlusion intentionally stop spectrum work. Reveal
        // the fixture before checking PCM and allow the next audio buffer to arrive.
        controller.show()
        for _ in 0..<40 {
            if !model.visible { controller.show() }
            if model.spectrum.read().max() ?? 0 > 0 { break }
            await settle(0.05)
        }
        try check(model.spectrum.read().max() ?? 0 > 0, "Streaming FFT spectrum receives PCM")
        model.seek(15); await settle(0.8); try check(model.position >= 15 && model.position < 18, "Remote byte-range seek")
        let hostedAPI = JellyfinPlaylists(account)
        let hosted = try await hostedAPI.catalog()
        try check(hosted.count == 1 && hosted[0].canDelete, "HTTP Jellyfin playlist catalogue")
        let hostedSongs = try await hostedAPI.songs(hosted[0].id)
        try check(hostedSongs.count == 2 && hostedSongs[0].id == hostedSongs[1].id, "Hosted playlist duplicate positions")
        let queueBefore = model.queue.entries.map(\.id)
        let created = try await hostedAPI.create("Native Mac fixture", songs: hostedSongs)
        let afterCreate = try await hostedAPI.catalog()
        try check(afterCreate.contains { $0.id == created.id }, "Private Jellyfin playlist creation over HTTP")
        try await hostedAPI.delete(created.id)
        let afterDelete = try await hostedAPI.catalog()
        try check(!afterDelete.contains { $0.id == created.id } && model.queue.entries.map(\.id) == queueBefore, "Confirmed playlist deletion keeps songs and queue")
        await model.savePlaylist("Fixture on device")
        try check(model.collections.playlists.count == 1, "Save named playlist on device")
        if let saved = model.collections.playlists.first {
            await model.renamePlaylist(saved.id, name: "Renamed fixture")
            try check(model.collections.playlists.first?.name == "Renamed fixture", "Rename saved playlist")
            model.loadCollection(saved, autoplay: false); await settle(0.4)
            try check(!model.playing && !model.stopped && model.queue.entries.count == saved.snapshot.entries.count, "Load saved playlist paused")
            await model.forgetPlaylist(saved.id)
            try check(model.collections.playlists.isEmpty && !model.queue.entries.isEmpty, "Forget saved playlist keeps queue")
            model.resume(); await settle(0.2)
        }
        model.replace(hostedSongs)
        for _ in 0..<40 { if model.player.items().count == 2 && model.playing { break }; await settle(0.05) }
        try check(model.player.items().count == 2, "Authenticated music preloads next item")
        let preparedNext = model.player.items()[1]
        model.seek(44.5)
        for _ in 0..<80 { if model.queue.index == 1 { break }; await settle(0.05) }
        try check(model.queue.index == 1 && model.player.currentItem === preparedNext, "Remote gapless transition uses prepared item")
        model.normalization = true
        try check(model.spectrum.normalizationEnabled && model.player.currentItem === preparedNext, "Normalization switches live without replacing playback")
        model.normalization = false
        controller.hide(); await settle(0.2); try check(model.spectrum.read().allSatisfy { $0 == 0 }, "Hidden spectrum sleeps")
        try check(!controller.dancingLlama.isDancing && controller.timer == nil, "Hidden llama sleeps without an animation timer")
        model.stop()
        var rejected = false
        do { _ = try await Jellyfin.request(server: account.server, path: "redirect", auth: account.authorization) } catch { rejected = true }
        try check(rejected, "API redirects rejected")
        model.selectFolder("radio"); model.radio.start()
        for _ in 0..<100 where model.radio.busy { await settle(0.02) }
        let station = try RadioStation(name: "Fixture Radio", stream: "http://127.0.0.1:\(port)/radio/live")
        await model.radio.save(station)
        try check(model.radio.saved.count == 15, "Radio catalog and custom station saving")
        // Mute output separately from gain: the mixed-output tap follows gain.
        model.player.isMuted = true; model.player.volume = 1
        controller.show(); model.replace([station.song])
        for _ in 0..<100 {
            if !model.visible { controller.show() }
            if model.playing && !model.radioTitle.isEmpty && model.spectrum.processedFrames > 0 { break }
            await settle(0.1)
        }
        try check(model.playing && !model.error, "Anonymous live MP3 radio playback")
        try check(model.radioTitle == "Fixture Artist - Live Track", "ICY live song titles")
        if #available(macOS 27.0, *) { try check(model.spectrum.processedFrames > 0, "Radio FFT processes live decoded PCM while output is muted") }
        try check(!model.canSeek && !controller.seek.isEnabled && controller.elapsed.stringValue == "LIVE", "Live radio display disables seeking")
        try check(controller.dancingLlama.isDancing == !reduceMotion, "Llama dances to live radio")
        let entries = model.queue.entries
        await model.radio.forget(station.id)
        try check(model.queue.entries.map(\.id) == entries.map(\.id) && model.queue.entries.map(\.song) == entries.map(\.song) && model.playing, "Forgetting a station preserves current playback")
        try check(!FileManager.default.fileExists(atPath: fixtureURL.deletingLastPathComponent().appendingPathComponent("radio-auth-failure").path), "Jellyfin authorization never reaches radio")
        model.pause(); await settle(0.2)
        try check(!model.stopped && !model.playing && model.player.currentItem == nil && !controller.dancingLlama.isDancing, "Pausing live radio releases its connection")
        model.resume()
        for _ in 0..<100 {
            if model.player.timeControlStatus == .playing && !model.radioTitle.isEmpty { break }
            await settle(0.1)
        }
        try check(model.player.timeControlStatus == .playing && model.radioTitle == "Fixture Artist - Live Track", "Resuming radio reconnects to the live broadcast")
        model.stop(); await settle(0.2)
        try check(model.player.currentItem == nil && !controller.dancingLlama.isDancing && controller.timer == nil, "Stopping radio releases the stream and animation timer")
        controller.show(); model.message = "Smoke tests passed"; model.onChange?()
        let text = (["PASS"] + checks).joined(separator: "\n")
        try text.write(toFile: report, atomically: true, encoding: .utf8)
    } catch {
        try? (["FAIL", error.localizedDescription] + checks).joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
    }
    model.stop(); NSApp.terminate(nil)
}
