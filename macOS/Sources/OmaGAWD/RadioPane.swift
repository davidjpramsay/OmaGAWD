import AppKit
import OmaCore

@MainActor final class RadioPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    let player: PlayerModel
    let stations = MusicTable()
    let name = NSSearchField(), genre = NSTextField(), country = NSTextField(), language = NSTextField()
    private var rows: [RadioStation] = []
    private var reloading = false
    private var savedButton: ActionButton!, discoverButton: ActionButton!, saveButton: ActionButton!, forgetButton: ActionButton!, moreButton: ActionButton!
    private var searchButton: ActionButton!, addButton: ActionButton!
    private var discoverFields: NSStackView!
    private var addPanel: NSPanel?
    init(player: PlayerModel) {
        self.player = player; super.init(frame: .zero)
        setContentHuggingPriority(.init(1), for: .vertical)
        savedButton = ActionButton("SAVED", help: "Saved radio stations") { [weak self] in self?.player.radio.show(.saved); self?.focusStations() }
        discoverButton = ActionButton("DISCOVER", help: "Discover radio stations worldwide") { [weak self] in self?.player.radio.show(.discover); self?.window?.makeFirstResponder(self?.name) }
        addButton = ActionButton("+ STATION", help: "Add a radio station by stream link") { [weak self] in self?.showAddStation() }
        for (field, title) in [(name as NSTextField, "Station name"), (genre, "Genre"), (country, "Country"), (language, "Language")] {
            styleSquareInput(field); field.placeholderString = title; field.setAccessibilityLabel("Radio " + title.lowercased()); field.delegate = self
            field.setContentHuggingPriority(.init(1), for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        name.target = self; name.action = #selector(search)
        searchButton = ActionButton("SEARCH", help: "Search radio stations") { [weak self] in self?.player.radio.search() }
        let clearButton = ActionButton("CLEAR", help: "Clear radio search and filters") { [weak self] in self?.clearSearch() }
        discoverFields = row([genre, country, language]); discoverFields.distribution = .fillEqually
        stations.setAccessibilityLabel("Radio stations")
        for (identifier, title, width) in [("station", "STATION", CGFloat(400)), ("country", "COUNTRY", CGFloat(130))] {
            let column = NSTableColumn(identifier: .init(identifier)); column.title = title; column.width = width
            column.minWidth = identifier == "station" ? 100 : 75; if identifier == "country" { column.maxWidth = 140 }
            stations.addTableColumn(column)
        }
        stations.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle; stations.rowHeight = 25
        stations.intercellSpacing = NSSize(width: 8, height: 2); stations.usesAlternatingRowBackgroundColors = true
        stations.backgroundColor = NSColor.black.withAlphaComponent(0.15); stations.allowsMultipleSelection = false
        stations.delegate = self; stations.dataSource = self; stations.target = self; stations.doubleAction = #selector(activateStation)
        stations.activate = { [weak self] append in self?.activate(append: append) }
        let scroll = NSScrollView(); scroll.documentView = stations; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .lineBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        saveButton = ActionButton("+ SAVE", help: "Save selected radio station") { [weak self] in
            guard let self, let station = selected else { return }
            Task { await self.player.radio.save(station); self.focusStations() }
        }
        forgetButton = ActionButton("− FORGET", help: "Forget saved station; keep queued stations") { [weak self] in
            guard let self, let station = selected else { return }
            Task { await self.player.radio.forget(station.id) }
        }
        moreButton = ActionButton("MORE", help: "Load more radio search results") { [weak self] in self?.player.radio.search(append: true) }
        let append = ActionButton("+ ADD", help: "Add selected station to queue") { [weak self] in self?.activate(append: true) }
        let root = column([
            row([savedButton, discoverButton, spacer(), addButton]), row([name, searchButton, clearButton]), discoverFields, scroll,
            row([saveButton, forgetButton, append, spacer(), moreButton])
        ])
        root.translatesAutoresizingMaskIntoConstraints = false; addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor), root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor)])
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    private var selected: RadioStation? { rows.indices.contains(stations.selectedRow) ? rows[stations.selectedRow] : nil }
    func reload() {
        reloading = true; defer { reloading = false }
        let radio = player.radio
        for (field, value) in [(name as NSTextField, radio.query.name), (genre, radio.query.genre), (country, radio.query.country), (language, radio.query.language)] {
            if field.stringValue != value { field.stringValue = value }
        }
        rows = radio.rows; stations.reloadData(); stations.deselectAll(nil)
        if let index = rows.firstIndex(where: { $0.id == radio.selection }) { stations.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        savedButton.contentTintColor = radio.mode == .saved ? .systemBlue : nil
        discoverButton.contentTintColor = radio.mode == .discover ? .systemBlue : nil
        discoverFields.isHidden = radio.mode != .discover
        searchButton.isHidden = radio.mode != .discover; searchButton.isEnabled = !radio.busy; addButton.isEnabled = !radio.busy
        saveButton.isHidden = radio.mode != .discover; forgetButton.isHidden = radio.mode != .saved
        saveButton.isEnabled = selected != nil && !radio.busy; forgetButton.isEnabled = selected != nil && !radio.busy
        moreButton.isHidden = radio.mode != .discover || !radio.more; moreButton.isEnabled = !radio.busy
    }
    func focusStations() {
        window?.makeFirstResponder(stations)
        if stations.selectedRow < 0 && !rows.isEmpty { stations.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        if stations.selectedRow >= 0 { stations.scrollRowToVisible(stations.selectedRow) }
    }
    func clearSearch() { player.radio.edit(RadioQuery()); window?.makeFirstResponder(name) }
    func cycleFocus(backward: Bool) {
        let views: [NSView] = player.radio.mode == .discover ? [name, genre, country, language, stations] : [name, stations]
        let current = views.firstIndex { view in view === window?.firstResponder || (view as? NSTextField)?.currentEditor() === window?.firstResponder }
        let next = current.map { ($0 + (backward ? views.count - 1 : 1)) % views.count } ?? (backward ? views.count - 1 : 0)
        if views[next] === stations { focusStations() } else { window?.makeFirstResponder(views[next]) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn!.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            let text = label("", size: identifier.rawValue == "station" ? 12 : 10)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(text); cell.textField = text; cell.identifier = identifier
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        let station = rows[row]
        cell.textField?.stringValue = identifier.rawValue == "station" ? station.name : station.countryLabel
        cell.textField?.textColor = station.id == player.queue.song?.id ? .systemBlue : .labelColor
        cell.toolTip = ([station.name, station.genre, station.country, station.language].filter { !$0.isEmpty } + [station.url.absoluteString]).joined(separator: "\n")
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }; player.radio.selection = selected?.id
        saveButton.isEnabled = selected != nil && !player.radio.busy; forgetButton.isEnabled = selected != nil && !player.radio.busy
    }
    func controlTextDidChange(_ obj: Notification) { player.radio.edit(RadioQuery(name: name.stringValue, genre: genre.stringValue, country: country.stringValue, language: language.stringValue)) }
    @objc private func search() { if player.radio.mode == .discover { player.radio.search() } else { focusStations() } }
    @objc private func activateStation() { activate(append: NSEvent.modifierFlags.contains(.option)) }
    private func activate(append: Bool) { guard let station = selected else { return }; if append { player.append([station.song]) } else { player.replace([station.song]) } }
    private func showAddStation() {
        guard let parent = window, addPanel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 230), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Add radio station"; panel.appearance = NSAppearance(named: .darkAqua); panel.isReleasedWhenClosed = false; panel.delegate = self; addPanel = panel
        let name = NSTextField(), url = NSTextField()
        for (field, title) in [(name, "Station name"), (url, "Direct HTTP(S) stream link")] { styleSquareInput(field); field.placeholderString = title; field.setAccessibilityLabel(title) }
        let feedback = label("Use a public audio stream link; no sign-in is needed.", size: 10, color: .secondaryLabelColor)
        feedback.maximumNumberOfLines = 3; feedback.lineBreakMode = .byWordWrapping
        let close = { [weak self, weak panel] in guard let panel else { return }; parent.endSheet(panel); panel.orderOut(nil); self?.addPanel = nil }
        let save = ActionButton("SAVE STATION") {}
        save.perform = { [weak self, weak save] in
            guard let self else { return }
            do {
                let station = try RadioStation(name: name.stringValue, stream: url.stringValue)
                save?.isEnabled = false
                Task {
                    if await self.player.radio.save(station) { close(); self.focusStations() }
                    else { feedback.stringValue = self.player.radio.message; feedback.textColor = .systemOrange; save?.isEnabled = true }
                }
            } catch { feedback.stringValue = error.localizedDescription; feedback.textColor = .systemOrange }
        }
        save.keyEquivalent = "\r"
        let cancel = ActionButton("CANCEL", action: close); cancel.keyEquivalent = "\u{1b}"
        let root = column([label("SAVE A RADIO STATION", size: 14), name, url, feedback, row([save, cancel])], spacing: 12)
        root.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16), root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16), root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16), root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -16)])
        parent.beginSheet(panel); panel.makeFirstResponder(name)
    }
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === addPanel else { return }
        panel.sheetParent?.endSheet(panel); addPanel = nil
    }
}
