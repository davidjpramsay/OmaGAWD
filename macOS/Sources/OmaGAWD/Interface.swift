import AppKit
import UniformTypeIdentifiers
import OmaCore

final class PaddedSourceCell: NSPopUpButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle(title, withFrame: frame.insetBy(dx: 5, dy: 0), in: controlView)
    }
}

final class ActionButton: NSButton {
    var perform: () -> Void
    init(_ title: String, help: String? = nil, action: @escaping () -> Void) {
        perform = action; super.init(frame: .zero); self.title = title; target = self; self.action = #selector(run)
        bezelStyle = .smallSquare; font = .monospacedSystemFont(ofSize: 11, weight: .medium); toolTip = help
        setAccessibilityLabel(help ?? title)
    }
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(32, size.width + 12), height: max(24, size.height))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { perform() }
}
func styleSquareInput(_ field: NSTextField) {
    field.bezelStyle = .squareBezel
    field.isBezeled = false
    field.isBordered = true
    field.drawsBackground = true
    field.backgroundColor = .controlBackgroundColor
    field.heightAnchor.constraint(equalToConstant: 24).isActive = true
}

func label(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text); label.font = .monospacedSystemFont(ofSize: size, weight: .regular); label.textColor = color; label.lineBreakMode = .byTruncatingTail; return label
}
func row(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
    let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = spacing; stack.alignment = .centerY; return stack
}
func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views); stack.orientation = .vertical; stack.spacing = spacing; stack.alignment = .leading
    for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }; return stack
}
func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.init(1), for: .horizontal); return v }

final class SourceStack: NSStackView { override var isFlipped: Bool { true } }

final class SpectrumView: NSView {
    var levels = [Float](repeating: 0, count: 16) { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let pitch = bounds.width / 16, height = bounds.height / 12
        for band in 0..<16 { for bar in 0..<12 {
            let color: NSColor = bar > 9 ? .systemOrange : bar > 6 ? .systemYellow : .systemGreen
            color.withAlphaComponent(Float(bar) < levels[band] * 12 ? 0.95 : 0.12).setFill()
            NSRect(x: CGFloat(band) * pitch, y: CGFloat(bar) * height, width: max(1, pitch - 2), height: max(1, height - 1)).fill()
        } }
    }
}
final class MusicTable: NSTableView {
    var activate: ((Bool) -> Void)?
    var removeSelection: (() -> Void)?
    var moveSelection: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: activate?(event.modifierFlags.contains(.option))
        case 51, 117: if let removeSelection { removeSelection() } else { super.keyDown(with: event) }
        case 126,125: if event.modifierFlags.contains(.option), let moveSelection { moveSelection(event.keyCode == 126 ? -1 : 1) } else { super.keyDown(with: event) }
        case 49: if selectedRow < 0 && numberOfRows > 0 { selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        default: super.keyDown(with: event)
        }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            let index = self.row(at: convert(event.locationInWindow, from: nil))
            if index >= 0 { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); activate?(true) }; return
        }
        super.mouseDown(with: event)
    }
}
// Borderless panels must explicitly accept key focus for search and shortcuts.
final class DockedPlayerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class PlayerWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let model: PlayerModel
    let titleLabel = label("Your records. One little receiver.", size: 16, color: .systemBlue)
    let detailLabel = label("Jellyfin + local music", color: .secondaryLabelColor)
    let formatLabel = label("NATIVE AUDIO  /  macOS", size: 10, color: .tertiaryLabelColor)
    let elapsed = label("0:00", size: 28, color: .systemBlue)
    let stateLabel = label("STOPPED", size: 10, color: .secondaryLabelColor)
    let total = label("0:00", size: 10, color: .secondaryLabelColor)
    let spectrum = SpectrumView()
    let seek = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let volume = NSSlider(value: 0.7, minValue: 0, maxValue: 1, target: nil, action: nil)
    let search = NSSearchField()
    private var refreshButton: ActionButton!
    let source = NSPopUpButton()
    let footer = label("", size: 10, color: .secondaryLabelColor)
    let artistTable = MusicTable(), albumTable = MusicTable(), songTable = MusicTable(), queueTable = MusicTable()
    var artists: [String] = [], albums: [(id: String, name: String)] = [], visibleSongs: [Song] = []
    var artist: String?, album: String?
    var refreshing = false
    var libraryPane: NSView!, queuePane: NSView!, desk: NSView!
    private var filterTablesHeight: NSLayoutConstraint!
    private var contentStack: NSStackView!
    var playlist = false
    var compact = false
    var monitor: Any?
    private var outsideClickMonitor: Any?
    var timer: Timer?
    var playButton: ActionButton!, shuffleButton: ActionButton!, repeatButton: ActionButton!, playlistButton: ActionButton!, libraryButton: ActionButton!
    var accountWindow: NSWindow?
    var sourcesWindow: NSWindow?
    var hotKeyWarning: String?
    private weak var anchorButton: NSStatusBarButton?
    private var screenObserver: NSObjectProtocol?
    init(model: PlayerModel) {
        self.model = model
        let panel = DockedPlayerPanel(contentRect: NSRect(x: 0, y: 0, width: 610, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "OmaGAWD"; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovable = false; panel.isMovableByWindowBackground = false
        panel.isRestorable = false; panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(calibratedRed: 0.085, green: 0.09, blue: 0.125, alpha: 1)
        super.init(window: panel); panel.delegate = self
        build()
        model.onChange = { [weak self] in self?.reload() }; model.onTick = { [weak self] in self?.tick() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event) ? nil : event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionAtTopRight() }
        }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func build() {
        guard let content = window?.contentView else { return }
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!, target: self, action: #selector(showSettings(_:)))
        settings.isBordered = false
        settings.imageScaling = .scaleProportionallyDown
        settings.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        settings.contentTintColor = .secondaryLabelColor
        settings.toolTip = "Settings"
        settings.setAccessibilityLabel("Settings")
        settings.widthAnchor.constraint(equalToConstant: 26).isActive = true
        settings.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let branding = row([label("🦙  O M A G A W D", size: 13), spacer(), settings])
        branding.heightAnchor.constraint(equalToConstant: 22).isActive = true
        spectrum.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let left = column([elapsed, stateLabel, spectrum], spacing: 5); left.widthAnchor.constraint(equalToConstant: 122).isActive = true
        let right = column([titleLabel, detailLabel, formatLabel], spacing: 12)
        let display = row([left, right], spacing: 18)
        display.wantsLayer = true; display.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        display.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        // Keep the receiver at its content height; the library absorbs extra height.
        display.heightAnchor.constraint(equalToConstant: display.fittingSize.height).isActive = true
        right.setContentHuggingPriority(.init(1), for: .horizontal)
        seek.target = self; seek.action = #selector(seekChanged); seek.isContinuous = false; seek.setAccessibilityLabel("Playback position")
        volume.target = self; volume.action = #selector(volumeChanged); volume.doubleValue = Double(model.volume); volume.setAccessibilityLabel("Volume")
        volume.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        volume.setContentHuggingPriority(.init(1), for: .horizontal)
        playButton = ActionButton("▶", help: "Play or pause") { [weak model] in model?.toggle() }
        shuffleButton = ActionButton("SHF", help: "Shuffle") { [weak model] in model?.toggleShuffle() }
        repeatButton = ActionButton("RPT", help: "Repeat: off, all, one") { [weak model] in model?.cycleRepeat() }
        let controls = row([ActionButton("◀|", help: "Previous track") { [weak model] in model?.previous() }, playButton, ActionButton("■", help: "Stop") { [weak model] in model?.stop() }, ActionButton("|▶", help: "Next track") { [weak model] in model?.next() }, shuffleButton, repeatButton, label("VOL", size: 10), volume, ActionButton("PL", help: "Show or hide music desk") { [weak self] in self?.toggleCompact() }])
        playlistButton = ActionButton("PLAYLIST", help: "Playlist (P)") { [weak self] in self?.showPlaylist(true) }
        libraryButton = ActionButton("LIBRARY", help: "Library (L)") { [weak self] in self?.showPlaylist(false) }
        source.cell = PaddedSourceCell(textCell: "", pullsDown: false)
        source.bezelStyle = .smallSquare
        source.heightAnchor.constraint(equalToConstant: 28).isActive = true
        source.target = self; source.action = #selector(sourceChanged); source.setAccessibilityLabel("Music source")
        source.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let tabs = row([playlistButton, libraryButton, spacer(), source])
        styleSquareInput(search)
        search.placeholderString = "Search your collection  ⌘F"; search.delegate = self; search.setAccessibilityLabel("Search library")
        refreshButton = ActionButton("", help: "Refresh library — check for added or changed music") { [weak model] in
            guard let model, !model.busy else { return }
            model.selectFolder(model.selectedFolder)
        }
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh library")
        refreshButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        refreshButton.imagePosition = .imageOnly
        refreshButton.imageScaling = .scaleProportionallyDown
        refreshButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let searchRow = row([search, refreshButton])
        search.setContentHuggingPriority(.init(1), for: .horizontal)
        let artistScroll = table(artistTable, title: "ARTIST"), albumScroll = table(albumTable, title: "ALBUM"), songScroll = table(songTable, title: "SONG"), queueScroll = table(queueTable, title: "PLAYLIST")
        let filterTables = row([artistScroll, albumScroll], spacing: 8); filterTables.distribution = .fillEqually
        filterTablesHeight = filterTables.heightAnchor.constraint(equalToConstant: 220)
        filterTablesHeight.isActive = true
        artistScroll.heightAnchor.constraint(equalTo: filterTables.heightAnchor).isActive = true; albumScroll.heightAnchor.constraint(equalTo: filterTables.heightAnchor).isActive = true
        songScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        let add = row([ActionButton("+ ADD", help: "Add selected music to queue") { [weak self] in guard let self else { return }; self.model.append(self.chosenSongs()) }, spacer(), label("⌥ click / Return to add", size: 10, color: .secondaryLabelColor)])
        libraryPane = column([searchRow, filterTables, songScroll, add])
        let queueActions = row([ActionButton("− SELECTED") { [weak self] in self?.removeQueue() }, ActionButton("↑") { [weak self] in self?.moveQueue(-1) }, ActionButton("↓") { [weak self] in self?.moveQueue(1) }, spacer(), ActionButton("CLEAR") { [weak model] in model?.clear() }])
        queuePane = column([queueScroll, queueActions]); queuePane.isHidden = true
        desk = column([tabs, libraryPane, queuePane]); desk.setContentHuggingPriority(.init(1), for: .vertical)
        footer.maximumNumberOfLines = 2; footer.lineBreakMode = .byWordWrapping
        let root = column([branding, display, row([seek,total]), controls, desk, footer], spacing: 10)
        contentStack = root
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), root.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
        for t in [artistTable,albumTable,songTable] { t.activate = { [weak self, weak t] append in self?.activate(t, append: append) } }
        queueTable.activate = { [weak self] _ in guard let self else { return }; self.model.play(self.queueTable.selectedRow) }
        queueTable.removeSelection = { [weak self] in self?.removeQueue() }; queueTable.moveSelection = { [weak self] in self?.moveQueue($0) }
        artistTable.nextKeyView = albumTable; albumTable.nextKeyView = songTable; songTable.nextKeyView = artistTable
    }
    private func table(_ table: MusicTable, title: String) -> NSScrollView {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title)); col.title = title; col.width = 350; col.minWidth = 80; table.addTableColumn(col)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.rowHeight = 25; table.intercellSpacing = NSSize(width: 8, height: 2)
        table.backgroundColor = NSColor.black.withAlphaComponent(0.15); table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = table === songTable || table === queueTable; table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(doubleClick(_:)); table.setAccessibilityLabel(title.capitalized)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .lineBorder
        return scroll
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === artistTable { return artists.count }; if tableView === albumTable { return albums.count }; if tableView === songTable { return visibleSongs.count }; return model.queue.entries.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            let text = label(""); text.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(text); cell.textField = text
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            cell.identifier = id
        }
        var text = ""
        if tableView === artistTable { text = artists[row] }
        else if tableView === albumTable { text = albums[row].name }
        else if tableView === songTable { let s = visibleSongs[row]; text = "\(s.track > 0 ? String(format: "%02d  ", s.track) : "")\(s.title)    \(clockText(s.duration))" }
        else { let e = model.queue.entries[row]; text = "\(e.id == model.queue.current ? "▶" : String(row + 1))  \(e.song.artist) — \(e.song.title)    \(clockText(e.song.duration))" }
        cell.textField?.stringValue = text; cell.toolTip = text
        cell.textField?.textColor = tableView === queueTable && model.queue.entries[row].id == model.queue.current ? .systemBlue : .labelColor
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, let table = notification.object as? NSTableView else { return }
        if table === artistTable { artist = artists.indices.contains(table.selectedRow) ? artists[table.selectedRow] : nil; album = nil; filter(reloadArtists: false) }
        else if table === albumTable { album = albums.indices.contains(table.selectedRow) ? albums[table.selectedRow].id : nil; filter(reloadArtists: false, reloadAlbums: false) }
    }
    func controlTextDidChange(_ obj: Notification) { artist = nil; album = nil; filter() }
    private func filter(reloadArtists: Bool = true, reloadAlbums: Bool = true) {
        refreshing = true; defer { refreshing = false }
        let matches = LibraryFilter.songs(model.songs, query: search.stringValue)
        if reloadArtists { artists = Array(Set(matches.map(\.artist))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }; artistTable.reloadData(); if let artist, let i = artists.firstIndex(of: artist) { artistTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) } }
        let artistSongs = matches.filter { artist == nil || $0.artist == artist }
        if reloadAlbums {
            var seen = Set<String>(); albums = artistSongs.filter { seen.insert($0.albumID).inserted }.map { ($0.albumID, $0.album) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            albumTable.reloadData(); if let album, let i = albums.firstIndex(where: { $0.id == album }) { albumTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }
        }
        visibleSongs = artistSongs.filter { album == nil || $0.albumID == album }; songTable.reloadData()
    }
    func reload() {
        let selected = Set(queueTable.selectedRowIndexes.compactMap { model.queue.entries.indices.contains($0) ? model.queue.entries[$0].id : nil })
        filter(); queueTable.reloadData()
        queueTable.selectRowIndexes(IndexSet(model.queue.entries.indices.filter { selected.contains(model.queue.entries[$0].id) }), byExtendingSelection: false)
        source.removeAllItems(); source.addItem(withTitle: "Local Music"); source.lastItem?.representedObject = "local"
        for folder in model.folders { source.addItem(withTitle: folder.name); source.lastItem?.representedObject = folder.id }
        source.menu?.addItem(.separator()); source.addItem(withTitle: model.account == nil ? "Connect to Jellyfin…" : "Jellyfin account…"); source.lastItem?.representedObject = "account"
        if let item = source.itemArray.first(where: { ($0.representedObject as? String) == model.selectedFolder }) { source.select(item) }
        footer.stringValue = model.message; footer.textColor = model.error ? .systemOrange : .secondaryLabelColor
        playlistButton.title = "PLAYLIST \(model.queue.entries.count)"; source.isEnabled = !model.busy
        refreshButton.isEnabled = !model.busy
        tick()
    }
    func tick() {
        titleLabel.stringValue = model.queue.song?.title ?? "Your records. One little receiver."
        detailLabel.stringValue = model.queue.song.map { "\($0.artist) / \($0.album)" } ?? "Jellyfin + local music"
        formatLabel.stringValue = model.bitRate > 0 ? "\(Int(model.bitRate / 1000)) KBPS  /  ORIGINAL AUDIO" : "NATIVE AUDIO  /  macOS"
        elapsed.stringValue = clockText(model.position); total.stringValue = clockText(model.duration)
        stateLabel.stringValue = model.stopped ? "STOPPED" : model.playing ? (model.queue.song?.file == nil ? "▶ STREAMING" : "▶ PLAYING") : "PAUSED"
        seek.maxValue = max(1, model.duration); seek.doubleValue = model.position; seek.isEnabled = !model.stopped
        playButton.title = model.playing ? "Ⅱ" : "▶"
        shuffleButton.contentTintColor = model.queue.shuffle ? .systemBlue : nil
        repeatButton.title = model.queue.repeatMode == .one ? "RPT 1" : "RPT"
        repeatButton.contentTintColor = model.queue.repeatMode == .off ? nil : .systemBlue
        playlistButton.contentTintColor = playlist ? .systemBlue : nil; libraryButton.contentTintColor = playlist ? nil : .systemBlue
        updateSpectrumTimer()
        if !model.playing { spectrum.levels = Array(repeating: 0, count: 16) }
    }
    @objc private func seekChanged() { model.seek(seek.doubleValue) }
    @objc private func volumeChanged() { model.volume = volume.floatValue }
    @objc private func sourceChanged() {
        guard let id = source.selectedItem?.representedObject as? String else { return }
        if id == "account" { showAccount(); reload() } else { artist = nil; album = nil; model.selectFolder(id) }
    }
    @objc private func doubleClick(_ sender: MusicTable) { if sender === queueTable { model.play(sender.clickedRow) } else { activate(sender, append: NSEvent.modifierFlags.contains(.option)) } }
    private func activate(_ table: MusicTable?, append: Bool) {
        var selected: [Song] = []
        if table === artistTable, artists.indices.contains(artistTable.selectedRow) { let name = artists[artistTable.selectedRow]; selected = model.songs.filter { $0.artist == name } }
        else if table === albumTable, albums.indices.contains(albumTable.selectedRow) { let id = albums[albumTable.selectedRow].id; selected = model.songs.filter { $0.albumID == id } }
        else if table === songTable { selected = songTable.selectedRowIndexes.compactMap { visibleSongs.indices.contains($0) ? visibleSongs[$0] : nil } }
        if append { model.append(selected) } else { model.replace(selected) }
    }
    private func chosenSongs() -> [Song] { let selected = songTable.selectedRowIndexes.compactMap { visibleSongs.indices.contains($0) ? visibleSongs[$0] : nil }; return selected.isEmpty ? visibleSongs : selected }
    private func removeQueue() { model.remove(Set(queueTable.selectedRowIndexes.compactMap { model.queue.entries.indices.contains($0) ? model.queue.entries[$0].id : nil })) }
    private func moveQueue(_ delta: Int) {
        let i = queueTable.selectedRow; guard model.queue.entries.indices.contains(i), model.queue.entries.indices.contains(i + delta) else { return }
        model.move(model.queue.entries[i].id, by: delta); queueTable.selectRowIndexes(IndexSet(integer: i + delta), byExtendingSelection: false); queueTable.scrollRowToVisible(i + delta)
    }
    func showPlaylist(_ value: Bool) {
        if compact { toggleCompact() }; playlist = value; libraryPane.isHidden = value; queuePane.isHidden = !value
        window?.makeFirstResponder(value ? queueTable : artistTable); tick()
    }
    func toggleCompact() {
        compact.toggle(); desk.isHidden = compact
        footer.isHidden = compact
        positionAtTopRight()
    }
    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { hide(); return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "f", flags.contains(.command) || flags.contains(.control) {
            showPlaylist(false); search.stringValue = ""; artist = nil; album = nil; filter(); window?.makeFirstResponder(search); return true
        }
        if !playlist && !compact && event.keyCode == 48 && flags.isDisjoint(with: [.command, .control, .option]) {
            let tables = [artistTable, albumTable, songTable]; let current = tables.firstIndex { $0 === window?.firstResponder }
            let next = current.map { ($0 + (flags.contains(.shift) ? 2 : 1)) % 3 } ?? (flags.contains(.shift) ? 2 : 0)
            let target = tables[next]
            guard window?.makeFirstResponder(target) == true else { return false }
            // Give keyboard focus a visible, actionable row, as the QML list does.
            if target.selectedRow < 0 && target.numberOfRows > 0 {
                target.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            if target.selectedRow >= 0 { target.scrollRowToVisible(target.selectedRow) }
            return true
        }
        if window?.firstResponder is NSTextView { return false }
        if flags.isDisjoint(with: [.command,.control,.option]), let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "p" { if playlist && !compact { toggleCompact() } else { showPlaylist(true) }; return true }
            if key == "l" { if !playlist && !compact { toggleCompact() } else { showPlaylist(false) }; return true }
        }
        return false
    }
    func show(near button: NSStatusBarButton? = nil) {
        guard let window else { return }
        if let button { anchorButton = button }
        positionAtTopRight()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); model.visible = true
        if outsideClickMonitor == nil {
            // Global mouse monitors exclude this app, so menus, sheets and source
            // windows remain interactive and the status button keeps its toggle.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.hide()
            }
        }
        updateSpectrumTimer()
    }
    private func positionAtTopRight() {
        guard let window, let screen = anchorButton?.window?.screen ?? window.screen ?? NSScreen.main else { return }
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        filterTablesHeight.constant = min(300, max(125, available.height * 0.26))
        // Size the receiver to its content instead of stretching rows to 320 points.
        let visibleRows = contentStack.arrangedSubviews.filter { !$0.isHidden }
        let compactHeight = visibleRows.reduce(CGFloat(24)) { $0 + $1.fittingSize.height }
            + CGFloat(max(0, visibleRows.count - 1)) * contentStack.spacing
        let size = NSSize(width: min(610, available.width), height: compact ? min(compactHeight, available.height) : available.height)
        window.setFrame(NSRect(x: available.maxX - size.width, y: available.maxY - size.height, width: size.width, height: size.height), display: true)
    }
    private func updateSpectrumTimer() {
        if !model.visible || !model.playing { timer?.invalidate(); timer = nil; return }
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                guard let self, self.model.playing else { return }
                let levels = self.model.spectrum.read(); self.spectrum.levels = zip(self.spectrum.levels, levels).map { max($1, $0 - 0.07) }
                }
            }; t.tolerance = 0.015; RunLoop.main.add(t, forMode: .common); timer = t
        }
    }
    func hide() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        window?.orderOut(nil); model.visible = false; timer?.invalidate(); timer = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowDidChangeOcclusionState(_ notification: Notification) { model.visible = window?.occlusionState.contains(.visible) == true; updateSpectrumTimer() }
    @objc private func showSettings(_ sender: NSButton) {
        let menu = NSMenu(title: "Settings")
        let shortcuts = menu.addItem(withTitle: "Shortcuts…", action: #selector(showHelp), keyEquivalent: "")
        shortcuts.target = self
        let sources = menu.addItem(withTitle: "Sources…", action: #selector(manageSources), keyEquivalent: "")
        sources.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit OmaGAWD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX - menu.size.width, y: sender.bounds.minY - 4), in: sender)
    }
    @objc private func showHelp() {
        let alert = NSAlert(); alert.messageText = "OmaGAWD shortcuts"
        alert.informativeText = "⌘⌥O — Show / hide from any app\nP / L — Playlist / library\n⌘F or Control-F — Clear filters and search\nTab / Shift-Tab — Artist → Album → Songs\nArrows / Space — Browse / select\nReturn / double-click — Play\nOption-click / Option-Return — Add to queue\nDelete — Remove from queue\nOption-↑ / ↓ — Reorder queue\nEscape — Hide\n\nMedia keys and Control Centre control playback.\(hotKeyWarning.map { "\n\n" + $0 } ?? "")"
        alert.beginSheetModal(for: window!)
    }
    private func choose(folder: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = folder; panel.canChooseFiles = !folder; panel.allowsMultipleSelection = true; panel.prompt = "Add music"
        if !folder { panel.allowedContentTypes = [.audio] }
        panel.beginSheetModal(for: sourcesWindow ?? window!) { [weak self] result in if result == .OK { self?.model.addSources(panel.urls); self?.refreshSources() } }
    }
    @objc func manageSources() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 350), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        panel.title = "Music sources"; panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: .darkAqua); sourcesWindow = panel
        refreshSources(); panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    private func refreshSources() {
        guard let panel = sourcesWindow else { return }
        let items = model.sources.enumerated().map { index, url in row([label(url.path, size: 11), spacer(), ActionButton("Remove") { [weak self] in self?.model.removeSource(index); self?.refreshSources() }]) }
        let list = SourceStack(views: items.isEmpty ? [label("No local sources yet.", color: .secondaryLabelColor)] : items)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 8
        for item in list.arrangedSubviews { item.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = list; list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let root = column([label("LOCAL MUSIC SOURCES", size: 13), label("Removing a source keeps your files and queued tracks.", size: 10, color: .secondaryLabelColor), row([ActionButton("+ Files") { [weak self] in self?.choose(folder: false) }, ActionButton("+ Folder") { [weak self] in self?.choose(folder: true) }, spacer(), ActionButton("Jellyfin…") { [weak self] in self?.showAccount() }]), scroll])
        panel.contentView = NSView(); root.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16),root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -16)])
    }
    func showAccount() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 290), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        panel.title = "Jellyfin"; panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: .darkAqua); accountWindow = panel
        let server = NSTextField(string: model.account?.server.absoluteString ?? ""); server.placeholderString = "https://music.example.com"; server.setAccessibilityLabel("Jellyfin server")
        let username = NSTextField(string: model.account?.username ?? ""); username.placeholderString = "Username"; username.setAccessibilityLabel("Username")
        let password = NSSecureTextField(); password.placeholderString = "Password"; password.setAccessibilityLabel("Password")
        for field in [server, username, password] { styleSquareInput(field) }
        let status = label(model.account.map { "Connected as \($0.username). Sign-in saved in Keychain." } ?? "Your server. Your records.", size: 11, color: .secondaryLabelColor); status.maximumNumberOfLines = 3; status.lineBreakMode = .byWordWrapping
        let connect = ActionButton(model.account == nil ? "Connect" : "Sign out") {}
        connect.perform = { [weak self, weak connect, weak panel] in
            guard let self else { return }
            if self.model.account != nil { self.model.disconnect(); panel?.close(); return }
            connect?.isEnabled = false; status.stringValue = "Connecting…"
            let secret = password.stringValue; password.stringValue = ""
            Task {
                do { try await self.model.connect(server: server.stringValue, username: username.stringValue, password: secret); panel?.close() }
                catch { status.stringValue = error.localizedDescription; status.textColor = .systemOrange; connect?.isEnabled = true }
            }
        }
        connect.keyEquivalent = "\r"
        let root = column([label("TUNE INTO YOUR COLLECTION", size: 14), server, username, password, status, connect], spacing: 12)
        if model.account != nil { server.isEditable = false; username.isEditable = false; password.isHidden = true }
        root.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20)])
        panel.center(); panel.makeKeyAndOrderFront(nil)
    }
}
