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

@MainActor final class PlayerSettings: NSView {
    private let model: PlayerModel
    private weak var player: PlayerWindow?
    private let tabs = NSSegmentedControl(labels: ["Playback", "Sources", "Updates", "Shortcuts"], trackingMode: .selectOne, target: nil, action: nil)
    private let body = SourceStack()
    private let scroll = NSScrollView()
    private var editingAccount = false
    private var accountPane: JellyfinAccountPane?
    private var pickingFiles = false
    init(model: PlayerModel, player: PlayerWindow) {
        self.model = model; self.player = player
        super.init(frame: .zero)
        setAccessibilityLabel("Settings")
        tabs.target = self; tabs.action = #selector(changeTab); tabs.selectedSegment = 0
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 14
        body.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 16, right: 12)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.documentView = body; body.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let heading = row([label("SETTINGS", size: 13), spacer(), ActionButton("DONE", help: "Return to music") { [weak player] in player?.closeSettings() }])
        let root = column([heading, tabs, scroll], spacing: 14); root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor), root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor)])
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(section: Int = 0) { tabs.selectedSegment = min(3, max(0, section)); render(resetScroll: true); window?.makeFirstResponder(tabs) }
    func refresh() { if !isHidden && tabs.selectedSegment == 1 && !editingAccount && !pickingFiles { render() } }
    @objc private func changeTab() { render(resetScroll: true) }
    private func note(_ text: String) -> NSTextField {
        let field = label(text, size: 11, color: .secondaryLabelColor); field.maximumNumberOfLines = 0; field.lineBreakMode = .byWordWrapping
        field.preferredMaxLayoutWidth = 520; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func render(resetScroll: Bool = false) {
        let offset = scroll.contentView.bounds.origin
        body.arrangedSubviews.forEach { body.removeArrangedSubview($0); $0.removeFromSuperview() }
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
            views = [label("JELLYFIN", size: 13), note(jellyfin), row([ActionButton(model.account == nil ? "Connect…" : "Account…") { [weak self] in self?.showAccount() }, spacer()]), label("LOCAL MUSIC", size: 13),
                     row([ActionButton("+ Files") { [weak self] in self?.choose(folder: false) }, ActionButton("+ Folder") { [weak self] in self?.choose(folder: true) }, spacer()]), note("Removing a source keeps its files and the current queue.")]
            let paths: [NSView] = model.sources.map { url in
                let text = note(url.path); text.toolTip = url.path; text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return row([text, spacer(), ActionButton("Remove") { [weak self] in
                    guard let self, let index = self.model.sources.firstIndex(of: url) else { return }
                    self.model.removeSource(index); self.render()
                }])
            }
            if editingAccount {
                views.insert(contentsOf: [accountPane!], at: 3)
                views.remove(at: 2)
            }
            views += paths.isEmpty ? [note("No local sources yet. Add music files or folders.")] : paths
        case 2:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
            views = [label("OmaGAWD \(version)", size: 16), note("Check for signed Mac app updates from GitHub. Your queue and playback position are kept; playback restores paused."),
                     row([ActionButton("Check for Updates…") { [weak self] in self?.player?.updates?.controller.checkForUpdates(nil) }, spacer()]), note("Updates are checked when you ask. Background checking and unattended installation are off.")]
        default:
            views = [label("KEYBOARD", size: 13), note("⌘⌥O   Show / hide from any app\nP / L   Playlist / library\n⌘F / Control-F   Clear filters and search\nTab / Shift-Tab   Cycle lists\nArrows / Home / End   Browse\nReturn / double-click   Play selection\nOption-click / Option-Return   Append\n⌘A   Select all songs or queue entries\nDelete   Remove selected queue entries\nOption-↑ / ↓   Reorder queue\nEscape   Hide player\n\nDrop music files or folders onto the player to add them to the library and queue.\n\nMedia keys and Control Centre work with the player hidden."), note(player?.hotKeyWarning ?? "")]
        }
        for view in views {
            body.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -12).isActive = true
        }
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: resetScroll ? .zero : offset); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func showAccount() {
        tabs.selectedSegment = 1
        if accountPane == nil {
            accountPane = JellyfinAccountPane(model: model) { [weak self] in
                guard let self else { return }; self.editingAccount = false; self.accountPane = nil
                if self.tabs.selectedSegment == 1 { self.render() }
            }
        }
        editingAccount = true; render(resetScroll: true); accountPane?.focus()
    }
    private func choose(folder: Bool) {
        guard let window, !pickingFiles, window.attachedSheet == nil else { return }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = folder; chooser.canChooseFiles = !folder; chooser.allowsMultipleSelection = true; chooser.prompt = "Add music"
        if !folder { chooser.allowedContentTypes = MediaPolicy.contentTypes }
        pickingFiles = true
        chooser.beginSheetModal(for: window) { [weak self] result in
            guard let self else { return }; self.pickingFiles = false
            if result == .OK { self.model.addSources(chooser.urls) }
            self.render(); self.player?.refitAfterPicker()
        }
    }
}

@MainActor final class JellyfinAccountPane: NSView {
    private let server: NSTextField
    private let username: NSTextField
    private let password = NSSecureTextField()
    init(model: PlayerModel, finished: @escaping () -> Void) {
        server = NSTextField(string: model.account?.server.absoluteString ?? "")
        username = NSTextField(string: model.account?.username ?? "")
        super.init(frame: .zero)
        server.placeholderString = "https://music.example.com"; server.setAccessibilityLabel("Jellyfin server")
        username.placeholderString = "Username"; username.setAccessibilityLabel("Username")
        password.placeholderString = "Password"; password.setAccessibilityLabel("Password")
        for field in [server, username, password] { styleSquareInput(field) }
        let status = label(model.account.map { "Connected as \($0.username). Sign-in saved in Keychain." } ?? "Your server. Your records.", size: 11, color: .secondaryLabelColor)
        status.maximumNumberOfLines = 0; status.lineBreakMode = .byWordWrapping; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = ActionButton("Back", action: finished)
        let connect = ActionButton(model.account == nil ? "Connect" : "Sign out") {}
        connect.perform = { [weak self, weak connect, weak cancel] in
            guard let self else { return }
            connect?.isEnabled = false; cancel?.isEnabled = false
            let signingOut = model.account != nil
            status.stringValue = signingOut ? "Signing out…" : "Connecting…"
            let address = self.server.stringValue, name = self.username.stringValue, secret = self.password.stringValue
            self.password.stringValue = ""
            Task {
                do {
                    if signingOut { try await model.disconnect() }
                    else { try await model.connect(server: address, username: name, password: secret) }
                    finished()
                } catch { status.stringValue = error.localizedDescription; status.textColor = .systemOrange; connect?.isEnabled = true; cancel?.isEnabled = true }
            }
        }
        if model.account != nil { server.isEditable = false; username.isEditable = false; password.isHidden = true }
        let root = column([server, username, password, status, row([connect, cancel, spacer()])], spacing: 10)
        root.translatesAutoresizingMaskIntoConstraints = false; addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor), root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func focus() { window?.makeFirstResponder(server) }
}

final class MusicDropView: NSView {
    var importMusic: (([URL]) -> Void)?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        outline.fill(); NSColor.separatorColor.setStroke(); outline.lineWidth = 1; outline.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { sender.draggingPasteboard.types?.contains(.fileURL) == true ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.pasteboardItems?.count ?? 0 <= 1000,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty, urls.count <= 1000 else { return false }
        importMusic?(urls); return true
    }
}
