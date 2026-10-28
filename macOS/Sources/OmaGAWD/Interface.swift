import AppKit
import UniformTypeIdentifiers
import OmaCore

final class PaddedSourceCell: NSPopUpButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle(title, withFrame: frame.insetBy(dx: 5, dy: 0), in: controlView)
    }
}

class ActionButton: NSButton {
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

final class PlaybackModeButton: ActionButton {
    private(set) var symbolName = ""
    private(set) var modeActive = false
    init(action: @escaping () -> Void) {
        super.init("", action: action)
        imagePosition = .imageOnly; imageScaling = .scaleProportionallyDown
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        widthAnchor.constraint(equalToConstant: 36).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(symbol: String, help: String, active: Bool) {
        let color: NSColor = active ? .controlAccentColor : .labelColor
        if symbolName != symbol || modeActive != active {
            symbolName = symbol
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?.withSymbolConfiguration(configuration)
            image?.isTemplate = false
        }
        toolTip = help; setAccessibilityLabel(help)
        if modeActive != active { modeActive = active; needsDisplay = true }
        contentTintColor = color
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard modeActive else { return }
        NSColor.controlAccentColor.set()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
        border.lineWidth = 1; border.stroke()
        let marker = NSRect(x: bounds.midX - 2, y: isFlipped ? bounds.maxY - 4 : bounds.minY + 2, width: 4, height: 2)
        NSBezierPath(roundedRect: marker, xRadius: 1, yRadius: 1).fill()
    }
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
    private var palette: [(lit: CGColor, dim: CGColor)]?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        palette = nil; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if palette == nil {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                palette = [NSColor.systemGreen, .systemYellow, .systemOrange].map {
                    let color = $0.usingColorSpace(.deviceRGB)!
                    return (color.withAlphaComponent(0.95).cgColor, color.withAlphaComponent(0.12).cgColor)
                }
            }
        }
        let pitch = bounds.width / 16, height = bounds.height / 12
        // Six cached colours and six batched fills replace 192 dynamic colour
        // resolutions per frame; the bar geometry and thresholds stay identical.
        for (index, bars) in [0..<7, 7..<10, 10..<12].enumerated() {
            var lit: [CGRect] = [], dim: [CGRect] = []
            for band in 0..<16 { for bar in bars {
                let rect = CGRect(x: CGFloat(band) * pitch, y: CGFloat(bar) * height,
                                  width: max(1, pitch - 2), height: max(1, height - 1))
                if Float(bar) < levels[band] * 12 { lit.append(rect) } else { dim.append(rect) }
            } }
            context.setFillColor(palette![index].dim); context.fill(dim)
            context.setFillColor(palette![index].lit); context.fill(lit)
        }
    }
}
final class MusicTable: NSTableView {
    var activate: ((Bool) -> Void)?
    var chooseSelection: (() -> Void)?
    var removeSelection: (() -> Void)?
    var moveSelection: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "a", !event.modifierFlags.intersection([.command, .control]).isEmpty {
            if allowsMultipleSelection { selectAll(nil) } else if numberOfRows > 0 { selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }; return
        }
        switch event.keyCode {
        case 36, 76: activate?(event.modifierFlags.contains(.option))
        case 51, 117: if let removeSelection { removeSelection() } else { super.keyDown(with: event) }
        case 126,125: if event.modifierFlags.contains(.option), let moveSelection { moveSelection(event.keyCode == 126 ? -1 : 1) } else { super.keyDown(with: event) }
        case 49:
            if selectedRow < 0 && numberOfRows > 0 { selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            chooseSelection?()
        case 115, 119:
            if numberOfRows > 0 {
                let row = event.keyCode == 115 ? 0 : numberOfRows - 1
                if allowsMultipleSelection && event.modifierFlags.contains(.shift), selectedRow >= 0 { selectRowIndexes(IndexSet(integersIn: min(row, selectedRow)...max(row, selectedRow)), byExtendingSelection: false) }
                else { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                scrollRowToVisible(row)
            }
        default: super.keyDown(with: event)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let index = self.row(at: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.option) {
            if index >= 0 { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); chooseSelection?(); activate?(true) }; return
        }
        super.mouseDown(with: event)
        if index >= 0 { chooseSelection?() }
    }
}
// Borderless panels must explicitly accept key focus for search and shortcuts.
final class DockedPlayerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class PlayerWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var updates: AppUpdates?
    let model: PlayerModel
    let titleLabel = label("Your records. One little receiver.", size: 14, color: .controlAccentColor)
    let detailLabel = label("Jellyfin + local music", color: .secondaryLabelColor)
    let formatLabel = label("NATIVE AUDIO  /  macOS", size: 10, color: .tertiaryLabelColor)
    let elapsed = label("0:00", size: 26, color: .controlAccentColor)
    let stateLabel = label("STOPPED", size: 10, color: .controlAccentColor)
    let sourceBadge = label("LOCAL", size: 10, color: .secondaryLabelColor)
    let seekElapsed = label("0:00", size: 10, color: .secondaryLabelColor)
    let total = label("0:00", size: 10, color: .secondaryLabelColor)
    let dancingLlama = DancingLlamaView()
    let spectrum = SpectrumView()
    let seek = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let volume = NSSlider(value: 0.7, minValue: 0, maxValue: 1, target: nil, action: nil)
    let search = NSSearchField()
    private var refreshButton: ActionButton!
    private var addButton: ActionButton!
    private(set) var collectionPane: CollectionPane!
    private var playlistSection = 0
    private let playlistSections = NSSegmentedControl(labels: ["Queue", "Saved", "Recent"], trackingMode: .selectOne, target: nil, action: nil)
    private(set) var settingsPane: PlayerSettings!
    private(set) var settingsVisible = false
    private var settingsReturnCompact = false
    private var settingsButton: NSButton!
    let source = NSPopUpButton()
    let footer = label("", size: 10, color: .secondaryLabelColor)
    let artistTable = MusicTable(), albumTable = MusicTable(), songTable = MusicTable(), queueTable = MusicTable()
    var artists: [String] = [], albums: [(id: String, name: String)] = [], visibleSongs: [Song] = []
    var artist: String?, album: String?
    private var allSelected = false
    private var artistSongCount = 0, albumSongCount = 0
    var refreshing = false
    var libraryPane: NSView!, queuePane: NSView!, desk: NSView!
    private(set) var radioPane: RadioPane!
    private var filterTablesHeight: NSLayoutConstraint!
    private var contentStack: NSStackView!
    private var seekRow: NSStackView!
    private(set) var receiver: NSView!
    private var deskButton: ActionButton!
    private var transportButtons: [ActionButton] = []
    var playlist = false
    var compact = false
    var monitor: Any?
    private var outsideClickMonitor: Any?
    var timer: Timer?
    var playButton: ActionButton!, playlistButton: ActionButton!, libraryButton: ActionButton!
    private(set) var shuffleButton: PlaybackModeButton!, repeatButton: PlaybackModeButton!
    var hotKeyWarning: String?
    private var placementScreenNumber: NSNumber?
    private var positioning = false
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    init(model: PlayerModel) {
        self.model = model
        let panel = DockedPlayerPanel(contentRect: NSRect(x: 0, y: 0, width: 610, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "OmaGAWD"; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovable = false; panel.isMovableByWindowBackground = false
        panel.isRestorable = false; panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = MusicDropView(frame: panel.contentView?.bounds ?? .zero)
        panel.isOpaque = false; panel.backgroundColor = .clear
        super.init(window: panel); panel.delegate = self
        build()
        (panel.contentView as? MusicDropView)?.importMusic = { [weak model] in model?.dropMusic($0, append: true) }
        model.onChange = { [weak self] in self?.reload() }; model.onTick = { [weak self] in self?.tick() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event) ? nil : event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionAtTopRight() }
        }
        spaceObserver = workspaceNotifications.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.window?.isVisible == true { self?.positionAtTopRight() } }
        }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { workspaceNotifications.removeObserver(spaceObserver) }
        timer?.invalidate()
    }
    private func build() {
        guard let content = window?.contentView else { return }
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!, target: self, action: #selector(showSettings(_:)))
        settingsButton = settings
        settings.isBordered = false
        settings.imageScaling = .scaleProportionallyDown
        settings.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        settings.contentTintColor = .secondaryLabelColor
        settings.toolTip = "Settings"
        settings.setAccessibilityLabel("Settings")
        settings.widthAnchor.constraint(equalToConstant: 26).isActive = true
        settings.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let brand = label("OMAGAWD", size: 12)
        brand.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        let headerRule = ReceiverRule()
        headerRule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        headerRule.widthAnchor.constraint(greaterThanOrEqualToConstant: 12).isActive = true
        headerRule.setContentHuggingPriority(.init(1), for: .horizontal)
        sourceBadge.setAccessibilityLabel("Playback source")
        let branding = row([dancingLlama, brand, headerRule, sourceBadge, settings], spacing: 10)
        branding.distribution = .fill
        branding.heightAnchor.constraint(equalToConstant: DancingLlamaView.canvasSize.height).isActive = true
        spectrum.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let left = column([elapsed, stateLabel, spectrum], spacing: 4); left.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let right = column([titleLabel, detailLabel, formatLabel], spacing: 6)
        // Long album names must truncate instead of setting the panel's minimum
        // fitting width; AppKit otherwise grows it past its anchored display edge.
        for text in [titleLabel, detailLabel, formatLabel] {
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        right.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let displayRule = ReceiverRule()
        displayRule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let displayContent = row([left, displayRule, right], spacing: 10)
        displayContent.distribution = .fill
        displayRule.heightAnchor.constraint(equalTo: left.heightAnchor).isActive = true
        let display = ReceiverSurface(content: displayContent, recessed: true, padding: 8)
        display.heightAnchor.constraint(equalToConstant: 96).isActive = true
        right.setContentHuggingPriority(.init(1), for: .horizontal)
        for slider in [seek, volume] {
            slider.cell = ReceiverSliderCell(); slider.minValue = 0; slider.maxValue = 1
            slider.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        seek.target = self; seek.action = #selector(seekChanged); seek.isContinuous = false; seek.setAccessibilityLabel("Playback position")
        volume.target = self; volume.action = #selector(volumeChanged); volume.doubleValue = Double(model.volume); volume.setAccessibilityLabel("Volume")
        volume.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        volume.setContentHuggingPriority(.init(1), for: .horizontal)
        playButton = ActionButton("▶", help: "Play or pause") { [weak model] in model?.toggle() }
        shuffleButton = PlaybackModeButton { [weak model] in model?.toggleShuffle() }
        repeatButton = PlaybackModeButton { [weak model] in model?.cycleRepeat() }
        transportButtons = [ActionButton("◀|", help: "Previous track") { [weak model] in model?.previous() }, playButton,
                            ActionButton("■", help: "Stop") { [weak model] in model?.stop() }, ActionButton("|▶", help: "Next track") { [weak model] in model?.next() }]
        deskButton = ActionButton("PL", help: "Show or hide music desk") { [weak self] in self?.toggleCompact() }
        let controls = row(transportButtons + [shuffleButton, repeatButton, label("VOL", size: 10, color: .secondaryLabelColor), volume, deskButton], spacing: 5)
        controls.distribution = .fill
        seekElapsed.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        total.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        total.alignment = .right
        seekRow = row([seekElapsed, seek, total], spacing: 10)
        receiver = ReceiverSurface(content: column([branding, display, seekRow, controls], spacing: 7))
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
            model.refreshLibrary()
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
        addButton = ActionButton("+ ADD", help: "Add selected artist, album or songs to queue") { [weak self] in guard let self else { return }; self.model.append(self.chosenSongs()) }
        addButton.isEnabled = false
        let add = row([addButton, spacer(), label("⌥ click / Return to add", size: 10, color: .secondaryLabelColor)])
        libraryPane = column([searchRow, filterTables, songScroll, add])
        let queueActions = row([ActionButton("− SELECTED") { [weak self] in self?.removeQueue() }, ActionButton("↑") { [weak self] in self?.moveQueue(-1) }, ActionButton("↓") { [weak self] in self?.moveQueue(1) }, spacer(), ActionButton("CLEAR") { [weak model] in model?.clear() }])
        playlistSections.selectedSegment = 0; playlistSections.target = self; playlistSections.action = #selector(playlistSectionChanged)
        collectionPane = CollectionPane(model: model); collectionPane.isHidden = true
        queuePane = column([playlistSections, queueScroll, queueActions, collectionPane]); queuePane.isHidden = true
        radioPane = RadioPane(player: model); radioPane.isHidden = true
        settingsPane = PlayerSettings(model: model, player: self); settingsPane.isHidden = true
        desk = column([tabs, libraryPane, radioPane, queuePane, settingsPane]); desk.setContentHuggingPriority(.init(1), for: .vertical)
        footer.maximumNumberOfLines = 2; footer.lineBreakMode = .byWordWrapping
        let root = column([receiver, desk, footer], spacing: 12)
        contentStack = root
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), root.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
        for t in [artistTable,albumTable,songTable] { t.activate = { [weak self, weak t] append in self?.activate(t, append: append) } }
        for t in [artistTable, albumTable] { t.chooseSelection = { [weak self, weak t] in self?.selectBrowserRow(t, explicit: true) } }
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
        if tableView === artistTable { return artists.isEmpty ? 0 : artists.count + 1 }; if tableView === albumTable { return albums.isEmpty ? 0 : albums.count + 1 }; if tableView === songTable { return visibleSongs.count }; return model.queue.entries.count
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
        if tableView === artistTable { text = row == 0 ? "All artists...    \(artistSongCount)" : artists[row - 1] }
        else if tableView === albumTable { text = row == 0 ? "All albums...    \(albumSongCount)" : albums[row - 1].name }
        else if tableView === songTable { let s = visibleSongs[row]; text = "\(s.track > 0 ? String(format: "%02d  ", s.track) : "")\(s.title)    \(clockText(s.duration))" }
        else { let e = model.queue.entries[row]; text = "\(e.id == model.queue.current ? "▶" : String(row + 1))  \(e.song.artist) — \(e.song.title)    \(e.song.isRadio ? "LIVE" : clockText(e.song.duration))" }
        cell.textField?.stringValue = text; cell.toolTip = text
        cell.textField?.textColor = tableView === queueTable && model.queue.entries[row].id == model.queue.current ? .controlAccentColor : .labelColor
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, let table = notification.object as? MusicTable else { return }
        if table === artistTable || table === albumTable { selectBrowserRow(table, explicit: false) }
        updateAddButton()
    }
    private func selectBrowserRow(_ table: MusicTable?, explicit: Bool) {
        guard !refreshing, let table, table.selectedRow >= 0 else { return }
        let index = table.selectedRow - 1
        allSelected = table.selectedRow == 0
        if table === artistTable {
            let next = artists.indices.contains(index) ? artists[index] : nil
            if explicit || artist != next {
                artist = next; album = nil; songTable.deselectAll(nil); filter(reloadArtists: false)
            }
        } else if table === albumTable {
            let next = albums.indices.contains(index) ? albums[index].id : nil
            if explicit || album != next {
                album = next; songTable.deselectAll(nil); filter(reloadArtists: false, reloadAlbums: false)
            }
        }
        updateAddButton()
    }
    func controlTextDidChange(_ obj: Notification) { artist = nil; album = nil; allSelected = false; songTable.deselectAll(nil); filter() }
    private func filter(reloadArtists: Bool = true, reloadAlbums: Bool = true) {
        refreshing = true; defer { refreshing = false }
        let matches = LibraryFilter.songs(model.songs, query: search.stringValue)
        let selection = LibraryFilter.validSelection(in: matches, artist: artist, album: album)
        artist = selection.artist; album = selection.album
        artistSongCount = matches.count
        if reloadArtists {
            artists = Array(Set(matches.map(\.artist))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            artistTable.reloadData(); artistTable.deselectAll(nil)
            if let artist, let i = artists.firstIndex(of: artist) { artistTable.selectRowIndexes(IndexSet(integer: i + 1), byExtendingSelection: false) }
            else if allSelected && !artists.isEmpty { artistTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        }
        let artistSongs = matches.filter { artist == nil || $0.artist == artist }
        albumSongCount = artistSongs.count
        if reloadAlbums {
            var seen = Set<String>(); albums = artistSongs.filter { seen.insert($0.albumID).inserted }.map { ($0.albumID, $0.album) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            albumTable.reloadData(); albumTable.deselectAll(nil)
            if let album, let i = albums.firstIndex(where: { $0.id == album }) { albumTable.selectRowIndexes(IndexSet(integer: i + 1), byExtendingSelection: false) }
            else if allSelected && !albums.isEmpty { albumTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        }
        visibleSongs = artistSongs.filter { album == nil || $0.albumID == album }; songTable.reloadData(); updateAddButton()
    }
    func reload() {
        let selected = Set(queueTable.selectedRowIndexes.compactMap { model.queue.entries.indices.contains($0) ? model.queue.entries[$0].id : nil })
        filter(); queueTable.reloadData()
        queueTable.selectRowIndexes(IndexSet(model.queue.entries.indices.filter { selected.contains(model.queue.entries[$0].id) }), byExtendingSelection: false)
        source.removeAllItems()
        if !model.folders.isEmpty {
            for folder in model.folders { source.addItem(withTitle: model.folders.count == 1 ? "Jellyfin" : "Jellyfin · \(folder.name)"); source.lastItem?.representedObject = folder.id }
        } else {
            source.addItem(withTitle: "Jellyfin"); source.lastItem?.representedObject = "jellyfin"; source.lastItem?.isEnabled = false
        }
        source.addItem(withTitle: "Local Music"); source.lastItem?.representedObject = "local"
        source.addItem(withTitle: "Radio"); source.lastItem?.representedObject = "radio"
        if model.selectedFolder != "local", model.selectedFolder != "radio", !model.folders.contains(where: { $0.id == model.selectedFolder }) {
            source.addItem(withTitle: "Jellyfin (unavailable)"); source.lastItem?.representedObject = model.selectedFolder; source.lastItem?.isEnabled = false
        }
        if let item = source.itemArray.first(where: { ($0.representedObject as? String) == model.selectedFolder }) { source.select(item) }
        footer.stringValue = model.message; footer.textColor = model.error ? .systemOrange : .secondaryLabelColor
        updateDeskPanes(); radioPane.reload()
        playlistButton.title = "PLAYLIST \(model.queue.entries.count)"; source.isEnabled = !model.busy
        refreshButton.isEnabled = !model.busy && !model.refreshingFolders
        collectionPane.reload(); settingsPane.refresh()
        tick()
    }
    func tick() {
        let radio = model.queue.song?.isRadio == true
        let wasRadio = seekRow.isHidden
        seekRow.isHidden = radio
        sourceBadge.stringValue = model.queue.song.map { $0.isRadio ? "RADIO" : $0.file != nil ? "LOCAL" : "JELLYFIN" }
            ?? (model.selectedFolder == "radio" ? "RADIO" : model.selectedFolder == "local" ? "LOCAL" : "JELLYFIN")
        titleLabel.stringValue = model.queue.song?.title ?? "Your records. One little receiver."
        if radio {
            titleLabel.stringValue = model.radioTitle.isEmpty ? model.queue.song!.title : model.radioTitle
            detailLabel.stringValue = "\(model.queue.song!.title) / \(model.queue.song!.artist)"
            formatLabel.stringValue = model.bitRate > 0 ? "LIVE RADIO  /  \(Int(model.bitRate / 1000)) KBPS" : "LIVE RADIO"
        } else {
            detailLabel.stringValue = model.queue.song.map { "\($0.artist) / \($0.album)" } ?? "Jellyfin + local music"
            formatLabel.stringValue = model.bitRate > 0 ? "\(Int(model.bitRate / 1000)) KBPS  /  ORIGINAL AUDIO" : model.queue.song == nil ? "SELECT SOMETHING GAWD" : "ORIGINAL AUDIO"
        }
        if titleLabel.toolTip != titleLabel.stringValue { titleLabel.toolTip = titleLabel.stringValue }
        if detailLabel.toolTip != detailLabel.stringValue { detailLabel.toolTip = detailLabel.stringValue }
        elapsed.stringValue = model.queue.song?.isRadio == true ? "LIVE" : clockText(model.position)
        seekElapsed.stringValue = clockText(model.position)
        total.stringValue = model.queue.song?.isRadio == true ? "LIVE" : clockText(model.duration)
        stateLabel.stringValue = model.stopped ? "■ STOPPED" : model.buffering ? "BUFFERING" : model.playing ? (radio ? "▶ RADIO" : model.queue.song?.file == nil ? "▶ STREAMING" : "▶ PLAYING") : "Ⅱ PAUSED"
        for button in transportButtons { button.isEnabled = !model.queue.entries.isEmpty }
        playButton.contentTintColor = model.playing || model.buffering ? .controlAccentColor : nil
        deskButton.contentTintColor = compact ? nil : .controlAccentColor
        seek.maxValue = max(1, model.duration); seek.doubleValue = model.position; seek.isEnabled = model.canSeek
        volume.floatValue = model.volume
        playButton.title = model.playing || model.buffering ? "Ⅱ" : "▶"
        shuffleButton.update(symbol: "shuffle", help: model.queue.shuffle ? "Shuffle: on" : "Shuffle: off", active: model.queue.shuffle)
        let repeatHelp = model.queue.repeatMode == .one ? "Repeat: one song" : model.queue.repeatMode == .all ? "Repeat: all songs" : "Repeat: off"
        repeatButton.update(symbol: model.queue.repeatMode == .one ? "repeat.1" : "repeat", help: repeatHelp, active: model.queue.repeatMode != .off)
        playlistButton.contentTintColor = !settingsVisible && playlist ? .controlAccentColor : nil
        libraryButton.contentTintColor = !settingsVisible && !playlist ? .controlAccentColor : nil
        settingsButton.contentTintColor = settingsVisible ? .controlAccentColor : .secondaryLabelColor
        if compact && wasRadio != radio { positionAtTopRight() }
        updateSpectrumTimer()
        if !model.playing { spectrum.levels = Array(repeating: 0, count: 16) }
    }
    @objc private func seekChanged() { model.seek(seek.doubleValue) }
    @objc private func volumeChanged() { model.volume = volume.floatValue }
    @objc private func sourceChanged() {
        guard let id = source.selectedItem?.representedObject as? String else { return }
        artist = nil; album = nil; allSelected = false; songTable.deselectAll(nil); model.selectFolder(id); showPlaylist(false); if id == "radio" { radioPane.focusStations() }
    }
    @objc private func doubleClick(_ sender: MusicTable) { if sender === queueTable { model.play(sender.clickedRow) } else { activate(sender, append: NSEvent.modifierFlags.contains(.option)) } }
    private func activate(_ table: MusicTable?, append: Bool) {
        var selected: [Song] = []
        if table === artistTable, artistTable.selectedRow == 0, !artists.isEmpty { selected = LibraryFilter.songs(model.songs, query: search.stringValue) }
        else if table === artistTable, artists.indices.contains(artistTable.selectedRow - 1) { let name = artists[artistTable.selectedRow - 1]; selected = model.songs.filter { $0.artist == name } }
        else if table === albumTable, albumTable.selectedRow == 0, !albums.isEmpty { selected = LibraryFilter.songs(model.songs, query: search.stringValue).filter { artist == nil || $0.artist == artist } }
        else if table === albumTable, albums.indices.contains(albumTable.selectedRow - 1) { let id = albums[albumTable.selectedRow - 1].id; selected = model.songs.filter { $0.albumID == id } }
        else if table === songTable { selected = songTable.selectedRowIndexes.compactMap { visibleSongs.indices.contains($0) ? visibleSongs[$0] : nil } }
        if append { model.append(selected) } else { model.replace(selected) }
    }
    private func chosenSongs() -> [Song] {
        let selected = songTable.selectedRowIndexes.compactMap { visibleSongs.indices.contains($0) ? visibleSongs[$0] : nil }
        if !selected.isEmpty { return selected }
        return allSelected || artist != nil || album != nil ? visibleSongs : []
    }
    private func updateAddButton() { addButton?.isEnabled = !chosenSongs().isEmpty }
    private func removeQueue() { model.remove(Set(queueTable.selectedRowIndexes.compactMap { model.queue.entries.indices.contains($0) ? model.queue.entries[$0].id : nil })) }
    private func moveQueue(_ delta: Int) {
        let i = queueTable.selectedRow; guard model.queue.entries.indices.contains(i), model.queue.entries.indices.contains(i + delta) else { return }
        model.move(model.queue.entries[i].id, by: delta); queueTable.selectRowIndexes(IndexSet(integer: i + delta), byExtendingSelection: false); queueTable.scrollRowToVisible(i + delta)
    }
    func showPlaylist(_ value: Bool) {
        settingsVisible = false; settingsReturnCompact = false
        if compact { toggleCompact() }; playlist = value; updateDeskPanes()
        collectionPane.setActive(value && playlistSection != 0 && model.visible)
        if !value && model.selectedFolder == "radio" { radioPane.focusStations() } else if value && playlistSection != 0 { collectionPane.show(playlistSection == 1 ? .saved : .recent) } else { window?.makeFirstResponder(value ? queueTable : artistTable) }; tick()
    }
    func showCollectionSection(_ section: Int) {
        showPlaylist(true); playlistSections.selectedSegment = min(2, max(0, section)); playlistSectionChanged()
    }
    @objc private func playlistSectionChanged() {
        playlistSection = playlistSections.selectedSegment
        let children = (queuePane as! NSStackView).arrangedSubviews
        children[1].isHidden = playlistSection != 0; children[2].isHidden = playlistSection != 0
        collectionPane.isHidden = playlistSection == 0
        if playlistSection != 0 { collectionPane.show(playlistSection == 1 ? .saved : .recent) }
        else { collectionPane.setActive(false); window?.makeFirstResponder(queueTable) }
    }
    func toggleCompact() {
        compact.toggle(); desk.isHidden = compact
        collectionPane.setActive(!settingsVisible && !compact && playlist && playlistSection != 0 && model.visible)
        footer.isHidden = compact
        positionAtTopRight()
    }
    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { hide(); return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "f", flags.contains(.command) || flags.contains(.control) {
            if model.selectedFolder == "radio" { showPlaylist(false); radioPane.clearSearch(); return true }
            showPlaylist(false); search.stringValue = ""; artist = nil; album = nil; allSelected = false; songTable.deselectAll(nil); filter(); window?.makeFirstResponder(search); return true
        }
        if !settingsVisible && playlist && playlistSection != 0 && !compact && event.keyCode == 48 && flags.isDisjoint(with: [.command, .control, .option]) && !(window?.firstResponder is NSTextView) { collectionPane.cycleFocus(); return true }
        if !settingsVisible && !playlist && !compact && event.keyCode == 48 && flags.isDisjoint(with: [.command, .control, .option]) {
            if model.selectedFolder == "radio" { radioPane.cycleFocus(backward: flags.contains(.shift)); return true }
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
            if key == "p" { if !settingsVisible && playlist && !compact { toggleCompact() } else { showPlaylist(true) }; return true }
            if key == "l" { if !settingsVisible && !playlist && !compact { toggleCompact() } else { showPlaylist(false) }; return true }
        }
        return false
    }
    func show(near button: NSStatusBarButton? = nil) {
        guard let window else { return }
        // Capture the user's display before activating our own panel. A retained
        // status-item window can belong to a different display or full-screen Space.
        let screens = NSScreen.screens
        let index = PlayerPanelLayout.screenIndex(at: NSEvent.mouseLocation, frames: screens.map(\.frame))
        let screen = index.map { screens[$0] } ?? button?.window?.screen ?? NSScreen.main
        placementScreenNumber = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        positionAtTopRight()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); model.visible = true
        collectionPane.setActive(!settingsVisible && playlist && playlistSection != 0 && !compact)
        if outsideClickMonitor == nil {
            // Global mouse monitors exclude this app. A file-picker sheet keeps
            // its parent visible until the user finishes or cancels it.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.hide()
            }
        }
        updateSpectrumTimer()
    }
    private func positionAtTopRight() {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == placementScreenNumber }
            ?? window?.screen ?? NSScreen.main
        guard let screen else { return }
        layout(in: screen.visibleFrame)
    }
    func layout(in visibleFrame: NSRect) {
        guard let window, !positioning else { return }
        positioning = true; defer { positioning = false }
        let available = PlayerPanelLayout.frame(in: visibleFrame)
        filterTablesHeight.constant = min(300, max(125, available.height * 0.26))
        // Size the receiver to its content instead of stretching rows to 320 points.
        let visibleRows = contentStack.arrangedSubviews.filter { !$0.isHidden }
        let compactHeight = visibleRows.reduce(CGFloat(24)) { $0 + $1.fittingSize.height }
            + CGFloat(max(0, visibleRows.count - 1)) * contentStack.spacing
        let frame = PlayerPanelLayout.frame(in: visibleFrame, compactHeight: compact ? compactHeight : nil)
        window.maxSize = frame.size
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard !positioning else { return }
        positionAtTopRight()
    }
    private func updateSpectrumTimer() {
        dancingLlama.setPlaybackState(playing: model.playing, stopped: model.stopped, visible: model.visible,
                                     reduceMotion: model.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if !model.visible || !model.playing { timer?.invalidate(); timer = nil; return }
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                guard let self, self.model.visible, self.model.playing else { return }
                let levels = self.model.spectrum.read(); self.spectrum.levels = zip(self.spectrum.levels, levels).map { max($1, $0 - 0.07 * 20 / 30) }
                self.dancingLlama.setPlaybackState(playing: true, stopped: false, visible: true,
                                                 reduceMotion: self.model.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                }
            }; t.tolerance = 0.005; RunLoop.main.add(t, forMode: .common); timer = t
        }
    }
    func hide() {
        if let sheet = window?.attachedSheet { sheet.makeKeyAndOrderFront(nil); return }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        collectionPane.setActive(false); window?.orderOut(nil); model.visible = false; updateSpectrumTimer()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowDidChangeOcclusionState(_ notification: Notification) { model.visible = window?.occlusionState.contains(.visible) == true; collectionPane.setActive(model.visible && !settingsVisible && playlist && playlistSection != 0 && !compact); updateSpectrumTimer() }
    @objc private func showSettings(_ sender: NSButton) { openSettings() }
    func openSettings(section: Int = 0) {
        if !settingsVisible { settingsReturnCompact = compact }
        if compact { toggleCompact() }
        settingsVisible = true; updateDeskPanes(); settingsPane.show(section: section)
        if window?.isVisible != true { show() }
        tick()
    }
    func closeSettings() {
        guard settingsVisible else { return }
        settingsVisible = false; updateDeskPanes()
        if settingsReturnCompact && !compact { toggleCompact() }
        settingsReturnCompact = false
        if !compact {
            if playlist && playlistSection != 0 { collectionPane.focus() }
            else if !playlist && model.selectedFolder == "radio" { radioPane.focusStations() }
            else { window?.makeFirstResponder(playlist ? queueTable : artistTable) }
        }
        tick()
    }
    private func updateDeskPanes() {
        libraryPane.isHidden = settingsVisible || playlist || model.selectedFolder == "radio"
        radioPane.isHidden = settingsVisible || playlist || model.selectedFolder != "radio"
        queuePane.isHidden = settingsVisible || !playlist
        settingsPane.isHidden = !settingsVisible
        collectionPane.setActive(!settingsVisible && !compact && playlist && playlistSection != 0 && model.visible)
    }
    func refitAfterPicker() { positionAtTopRight() }
    @objc func manageSources() { openSettings(section: 1) }
    func showAccount() { openSettings(section: 1); settingsPane.showAccount() }
}
