import AppKit

final class SettingsToggle: NSButton {
    private let change: (Bool) -> Void
    init(_ title: String, value: Bool, change: @escaping (Bool) -> Void) {
        self.change = change; super.init(frame: .zero)
        setButtonType(.switch); self.title = title; state = value ? .on : .off
        target = self; action = #selector(toggled)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func toggled() { change(state == .on) }
}

@MainActor final class PlayerSettings: NSWindowController {
    private let model: PlayerModel
    private weak var player: PlayerWindow?
    private let tabs = NSSegmentedControl(labels: ["Playback", "Sources", "Updates", "Shortcuts"], trackingMode: .selectOne, target: nil, action: nil)
    private let body = NSView()
    init(model: PlayerModel, player: PlayerWindow) {
        self.model = model; self.player = player
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 470), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "OmaGAWD Settings"; panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 480, height: 420)
        super.init(window: panel)
        tabs.target = self; tabs.action = #selector(changeTab); tabs.selectedSegment = 0
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 310).isActive = true
        let root = column([tabs, body], spacing: 20); root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18), root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18)])
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(section: Int = 0) { tabs.selectedSegment = section; render(); window?.center(); showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
    func refresh() { if tabs.selectedSegment == 1 { render() } }
    @objc private func changeTab() { render() }
    private func note(_ text: String) -> NSTextField {
        let field = label(text, size: 11, color: .secondaryLabelColor); field.maximumNumberOfLines = 0; field.lineBreakMode = .byWordWrapping
        field.preferredMaxLayoutWidth = 520; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func render() {
        body.subviews.forEach { $0.removeFromSuperview() }
        var views: [NSView] = []
        switch tabs.selectedSegment {
        case 0:
            views = [SettingsToggle("Gapless albums", value: model.gapless) { [weak model] in model?.gapless = $0 }, note("Preload the next music track for continuous playback. Network buffering and format changes may still cause a pause."),
                     SettingsToggle("Volume normalization", value: model.normalization) { [weak model] in model?.normalization = $0 }, note("Balance volume live. Audio files and tags stay unchanged." + { if #available(macOS 27.0, *) { return "" }; return " Live radio normalization requires macOS 27 or later." }()),
                     SettingsToggle("Reduce motion", value: model.reduceMotion) { [weak model] in model?.reduceMotion = $0 }, note("Keep the llama still. The system Reduce Motion setting also applies."),
                     SettingsToggle("Remember recently played", value: model.keepRecent) { [weak model] in model?.keepRecent = $0 },
                     row([ActionButton("Clear recently played") { [weak model] in Task { await model?.clearRecent() } }, spacer()])]
        case 1:
            let jellyfin = model.account.map { "\($0.username) · \($0.server.absoluteString)" } ?? "Connect your music server."
            views = [label("JELLYFIN", size: 13), note(jellyfin), row([ActionButton(model.account == nil ? "Connect…" : "Account…") { [weak self] in self?.player?.showAccount() }, spacer()]), label("LOCAL MUSIC", size: 13),
                     row([ActionButton("+ Files") { [weak self] in self?.choose(folder: false) }, ActionButton("+ Folder") { [weak self] in self?.choose(folder: true) }, spacer()]), note("Removing a source keeps its files and the current queue.")]
            let paths: [NSView] = model.sources.map { url in
                let text = note(url.path); text.toolTip = url.path; text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return row([text, spacer(), ActionButton("Remove") { [weak self] in
                    guard let self, let index = self.model.sources.firstIndex(of: url) else { return }
                    self.model.removeSource(index); self.render()
                }])
            }
            let list = SourceStack(views: paths.isEmpty ? [note("No local sources yet. Add music files or folders.")] : paths)
            list.orientation = .vertical; list.alignment = .leading; list.spacing = 10
            for item in list.arrangedSubviews { item.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = list; list.translatesAutoresizingMaskIntoConstraints = false
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true; views.append(scroll)
        case 2:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
            views = [label("OmaGAWD \(version)", size: 16), note("Check for signed Mac app updates from GitHub. Your queue and playback position are kept; playback restores paused."),
                     row([ActionButton("Check for Updates…") { [weak self] in self?.player?.updates?.controller.checkForUpdates(nil) }, spacer()]), note("Updates are checked when you ask. Background checking and unattended installation are off.")]
        default:
            views = [label("KEYBOARD", size: 13), note("⌘⌥O   Show / hide from any app\nP / L   Playlist / library\n⌘F / Control-F   Clear filters and search\nTab / Shift-Tab   Cycle lists\nArrows / Home / End   Browse\nReturn / double-click   Play selection\nOption-click / Option-Return   Append\n⌘A   Select all songs or queue entries\nDelete   Remove selected queue entries\nOption-↑ / ↓   Reorder queue\nEscape   Hide player\n\nDrop music files or folders onto the player to add them to the library and queue.\n\nMedia keys and Control Centre work with the player hidden."), note(player?.hotKeyWarning ?? "")]
        }
        let stack = column(views, spacing: 12); stack.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: body.leadingAnchor), stack.trailingAnchor.constraint(equalTo: body.trailingAnchor), stack.topAnchor.constraint(equalTo: body.topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor)])
    }
    private func choose(folder: Bool) {
        guard let window else { return }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = folder; chooser.canChooseFiles = !folder; chooser.allowsMultipleSelection = true; chooser.prompt = "Add music"
        if !folder { chooser.allowedContentTypes = MediaPolicy.contentTypes }
        chooser.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK else { return }; self.model.addSources(chooser.urls); self.render()
        }
    }
}

final class MusicDropView: NSView {
    var importMusic: (([URL]) -> Void)?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { sender.draggingPasteboard.types?.contains(.fileURL) == true ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.pasteboardItems?.count ?? 0 <= 1000,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty, urls.count <= 1000 else { return false }
        importMusic?(urls); return true
    }
}
