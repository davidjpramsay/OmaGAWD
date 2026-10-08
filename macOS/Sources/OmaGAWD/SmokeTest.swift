import Foundation
import AppKit
import OmaCore

// Opt-in, disposable fixture test; never reads or writes account credentials.
@MainActor func smokeTest(model: PlayerModel, controller: PlayerWindow, fixture: String, port: String, report: String) async {
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
        try check(model.spectrum.read().max() ?? 0 > 0, "Real FFT spectrum receives PCM")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        try check(controller.dancingLlama.isDancing == !reduceMotion, "Llama follows playback and Reduce Motion")
        if !reduceMotion {
            let firstPose = llamaSnapshot(); await settle(0.4)
            try check(firstPose != nil && firstPose != llamaSnapshot(), "Llama renders changing dance poses")
            // Exercise the actual UI timer, not just the deterministic clock.
            await settle(8.1)
            try check(controller.dancingLlama.currentDance == .sideShuffle, "Llama changes dance after ten seconds of playback")
        }
        model.pause(); await settle(0.2); let paused = model.position; await settle(0.3)
        try check(abs(model.position - paused) < 0.1, "Pause holds position")
        try check(!controller.dancingLlama.isDancing && controller.timer == nil, "Paused llama rests without an animation timer")
        model.seek(10); await settle(0.4); try check(abs(model.position - 10) < 0.5, "Local seek")
        model.resume(); model.append(songs); await settle(0.3); try check(model.queue.entries.count == 2 && model.position > 10, "Append does not interrupt playback")
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
        try check(model.spectrum.read().max() ?? 0 > 0, "Streaming FFT spectrum receives PCM")
        model.seek(15); await settle(0.8); try check(model.position >= 15 && model.position < 18, "Remote byte-range seek")
        controller.hide(); await settle(0.2); try check(model.spectrum.read().allSatisfy { $0 == 0 }, "Hidden spectrum sleeps")
        try check(!controller.dancingLlama.isDancing && controller.timer == nil, "Hidden llama sleeps without an animation timer")
        model.stop()
        var rejected = false
        do { _ = try await Jellyfin.request(server: account.server, path: "redirect", auth: account.authorization) } catch { rejected = true }
        try check(rejected, "API redirects rejected")
        controller.show(); model.message = "Smoke tests passed"; model.onChange?()
        let text = (["PASS"] + checks).joined(separator: "\n")
        try text.write(toFile: report, atomically: true, encoding: .utf8)
    } catch {
        try? (["FAIL", error.localizedDescription] + checks).joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
    }
    model.stop()
}
