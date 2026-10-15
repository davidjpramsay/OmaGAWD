import AppKit
import OmaCore

@MainActor final class CollectionPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Section { case saved, recent }
    private let model: PlayerModel
    private let apiFactory: (Account) -> JellyfinPlaylists
    private let scope = NSSegmentedControl(labels: ["Jellyfin", "On device"], trackingMode: .selectOne, target: nil, action: nil)
    private let name = NSTextField()
    private let list = MusicTable(), tracks = MusicTable()
    private let status = label("", size: 11, color: .secondaryLabelColor)
    private var create: ActionButton!, rename: ActionButton!, forget: ActionButton!, load: ActionButton!, play: ActionButton!, refresh: ActionButton!
    private var lists: [SavedCollection] = [], hosted: [HostedPlaylist] = [], preview: [Song] = []
    private var previewID: String?, accountIdentity: LibraryIdentity?
    private var selectedID: String?
    private var section = Section.saved, active = false, updating = false
    private(set) var busy = false
    private var readTask: Task<Void, Never>?, writeTask: Task<Void, Never>?
    private var revision = 0
    private var timer: Timer?
    private var hostedMode: Bool { section == .saved && scope.selectedSegment == 0 }
    init(model: PlayerModel, apiFactory: @escaping (Account) -> JellyfinPlaylists = { JellyfinPlaylists($0) }) {
        self.model = model; self.apiFactory = apiFactory; super.init(frame: .zero)
        scope.selectedSegment = 0; scope.target = self; scope.action = #selector(scopeChanged)
        name.placeholderString = "Playlist name"; name.setAccessibilityLabel("Playlist name"); styleSquareInput(name)
        name.setContentHuggingPriority(.init(1), for: .horizontal)
        create = ActionButton("SAVE QUEUE") { [weak self] in self?.save() }
        rename = ActionButton("RENAME") { [weak self] in self?.renameSelected() }
        forget = ActionButton("DELETE") { [weak self] in self?.forgetSelected() }
        load = ActionButton("LOAD") { [weak self] in self?.open(autoplay: false) }
        play = ActionButton("PLAY") { [weak self] in self?.open(autoplay: true) }
        refresh = ActionButton("REFRESH") { [weak self] in self?.refreshHosted() }
        for (table, title) in [(list, "PLAYLISTS"), (tracks, "SONGS")] {
            let col = NSTableColumn(identifier: .init(title)); col.title = title; col.width = 480
            table.addTableColumn(col); table.delegate = self; table.dataSource = self; table.headerView = NSTableHeaderView()
            table.rowHeight = 25; table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.setAccessibilityLabel(title.capitalized); table.target = self; table.doubleAction = #selector(doubleClick(_:))
            table.activate = { [weak self] append in self?.open(autoplay: true, append: append) }
        }
        list.nextKeyView = tracks; tracks.nextKeyView = list
        let listScroll = NSScrollView(); listScroll.documentView = list; listScroll.hasVerticalScroller = true; listScroll.borderType = .lineBorder
        let trackScroll = NSScrollView(); trackScroll.documentView = tracks; trackScroll.hasVerticalScroller = true; trackScroll.borderType = .lineBorder
        listScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        trackScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        status.maximumNumberOfLines = 3; status.lineBreakMode = .byWordWrapping
        let root = column([row([scope, spacer(), refresh]), row([name, create]), listScroll, trackScroll, row([load, play, rename, spacer(), forget]), status])
        root.translatesAutoresizingMaskIntoConstraints = false; addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor), root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor)])
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); readTask?.cancel(); writeTask?.cancel() }
    func show(_ section: Section) {
        readTask?.cancel(); revision += 1; busy = writeTask != nil
        self.section = section; selectedID = nil; previewID = nil; preview = []; active = true
        reload(); setActive(true)
        if hostedMode { refreshHosted() }
        window?.makeFirstResponder(list)
    }
    func setActive(_ value: Bool) {
        let wasActive = active
        active = value; timer?.invalidate(); timer = nil
        if value && hostedMode {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshHosted() } }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        if value && !wasActive && hostedMode { refreshHosted() }
        if !value { readTask?.cancel(); revision += 1; busy = writeTask != nil }
    }
    func focus() { window?.makeFirstResponder(list) }
    func cycleFocus() { window?.makeFirstResponder(window?.firstResponder === list ? tracks : list) }
    @objc private func scopeChanged() { show(.saved) }
    func reload() {
        let identity = model.account.map(LibraryIdentity.init)
        if identity != accountIdentity {
            accountIdentity = identity; readTask?.cancel(); revision += 1
            hosted = []; preview = []; previewID = nil; selectedID = nil; busy = writeTask != nil
            if active && hostedMode { refreshHosted() }
        }
        lists = section == .recent ? model.collections.recent : model.collections.playlists
        scope.isHidden = section == .recent; name.isHidden = section == .recent; create.isHidden = section == .recent
        rename.isHidden = hostedMode || section == .recent; refresh.isHidden = !hostedMode
        forget.title = section == .recent ? "CLEAR RECENT" : hostedMode ? "DELETE" : "FORGET"
        create.title = hostedMode ? "CREATE" : "SAVE QUEUE"
        create.setAccessibilityLabel(create.title); forget.setAccessibilityLabel(forget.title)
        list.tableColumns.first?.title = section == .recent ? "RECENT ALBUMS / STATIONS" : "PLAYLISTS"
        list.setAccessibilityLabel(section == .recent ? "Recent albums and stations" : "Playlists")
        create.isEnabled = !busy && !model.queue.entries.isEmpty && (!hostedMode || (model.account != nil && model.queue.entries.allSatisfy(\.song.requiresAccount) && model.sessionSnapshot().library == identity))
        updating = true; list.reloadData()
        if let id = selectedID, let index = rowIDs.firstIndex(of: id) { list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { list.deselectAll(nil); selectedID = nil; preview = []; previewID = nil }
        updating = false
        if !hostedMode, let item = selectedCollection { preview = item.snapshot.entries.map(\.song); previewID = item.id }
        tracks.reloadData(); updateActions()
        if !busy {
            if hostedMode { status.stringValue = model.account == nil ? "Connect to Jellyfin in Settings → Sources." : hosted.isEmpty ? "No music playlists yet. Create one from your Jellyfin queue." : "\(hosted.count) Jellyfin playlists · Create saves a private playlist." }
            else { status.stringValue = lists.isEmpty ? (section == .recent ? "Albums and stations appear after you play them." : "Save your queue with a name to keep it on this Mac.") : "\(lists.count) \(section == .recent ? "recent albums / stations" : "saved playlists")" }
        }
    }
    private var rowIDs: [String] { hostedMode ? hosted.map(\.id) : lists.map(\.id) }
    private var selectedCollection: SavedCollection? { lists.first { $0.id == selectedID } }
    private func updateActions() {
        let chosen = selectedID != nil
        load.isEnabled = !busy && chosen && !preview.isEmpty && previewID == selectedID
        play.isEnabled = load.isEnabled
        rename.isEnabled = !busy && chosen
        forget.isEnabled = !busy && (section == .recent ? !lists.isEmpty : hostedMode ? hosted.first(where: { $0.id == selectedID })?.canDelete == true : chosen)
        refresh.isEnabled = !busy && model.account != nil
        name.isEnabled = !busy
        create.isEnabled = !busy && !model.queue.entries.isEmpty && (!hostedMode || (model.account != nil && model.queue.entries.allSatisfy(\.song.requiresAccount) && model.sessionSnapshot().library == model.account.map(LibraryIdentity.init)))
        list.isEnabled = writeTask == nil; tracks.isEnabled = !busy
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === list ? rowIDs.count : preview.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === list {
            text = hostedMode ? "\(hosted[row].name)    \(hosted[row].count.map(String.init) ?? "")" : "\(lists[row].name)    \(lists[row].snapshot.entries.count)"
        } else { let song = preview[row]; text = "\(song.artist) — \(song.title)    \(song.isRadio ? "LIVE" : clockText(song.duration))" }
        let field = label(text, size: 11); field.toolTip = text; return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, notification.object as? NSTableView === list else { return }
        guard rowIDs.indices.contains(list.selectedRow) else { selectedID = nil; preview = []; previewID = nil; tracks.reloadData(); updateActions(); return }
        selectedID = rowIDs[list.selectedRow]
        if hostedMode { readPreview() }
        else { preview = selectedCollection?.snapshot.entries.map(\.song) ?? []; previewID = selectedID; tracks.reloadData(); updateActions() }
    }
    @objc private func doubleClick(_ sender: MusicTable) { open(autoplay: true) }
    private func readPreview() {
        guard let account = model.account, let id = selectedID else { return }
        readTask?.cancel(); revision += 1; let generation = revision, identity = LibraryIdentity(account)
        preview = []; previewID = nil; tracks.reloadData(); busy = true; status.stringValue = "Loading playlist…"; updateActions()
        readTask = Task {
            do {
                let songs = try await self.apiFactory(account).songs(id)
                guard !Task.isCancelled, revision == generation, model.account.map(LibraryIdentity.init) == identity, selectedID == id else { return }
                preview = songs; previewID = id; status.stringValue = "\(songs.count) songs"
            } catch { if !Task.isCancelled, revision == generation { status.stringValue = error.localizedDescription } }
            guard revision == generation else { return }; busy = false; tracks.reloadData(); updateActions()
        }
    }
    private func refreshHosted() {
        guard active, hostedMode, !busy, let account = model.account else { return }
        readTask?.cancel(); revision += 1; let generation = revision, identity = LibraryIdentity(account)
        busy = true; status.stringValue = "Refreshing Jellyfin playlists…"; updateActions()
        readTask = Task {
            do {
                let rows = try await self.apiFactory(account).catalog()
                guard !Task.isCancelled, revision == generation, model.account.map(LibraryIdentity.init) == identity else { return }
                hosted = rows; busy = false; reload()
                if selectedID != nil { readPreview() }
            } catch { guard !Task.isCancelled, revision == generation else { return }; busy = false; status.stringValue = error.localizedDescription; updateActions() }
        }
    }
    private func save() {
        let title: String
        do { title = try CollectionStore.name(name.stringValue) } catch { status.stringValue = error.localizedDescription; return }
        guard !busy else { return }
        if !hostedMode { Task { await model.savePlaylist(title); reload() }; return }
        guard let account = model.account, model.sessionSnapshot().library == LibraryIdentity(account) else { return }
        let songs = model.queue.entries.map(\.song), identity = LibraryIdentity(account)
        busy = true; status.stringValue = "Creating private playlist…"; updateActions()
        writeTask = Task {
            defer { writeTask = nil; busy = false; updateActions() }
            do {
                let created = try await self.apiFactory(account).create(title, songs: songs)
                guard model.account.map(LibraryIdentity.init) == identity else { return }
                hosted.append(created); selectedID = created.id; preview = songs; previewID = created.id; name.stringValue = ""; reload(); status.stringValue = "Private playlist created on Jellyfin."
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    private func renameSelected() { guard let id = selectedID else { return }; let title = name.stringValue; Task { await model.renamePlaylist(id, name: title); reload() } }
    private func forgetSelected() {
        if section == .recent { Task { await model.clearRecent(); reload() }; return }
        guard let id = selectedID else { return }
        if !hostedMode { Task { await model.forgetPlaylist(id); reload() }; return }
        guard let item = hosted.first(where: { $0.id == id }), item.canDelete, let account = model.account, let window else { return }
        let alert = NSAlert(); alert.messageText = "Delete “\(item.name)” from Jellyfin?"; alert.informativeText = "This removes the server playlist. Songs and your current queue are kept."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, !self.busy, self.model.account.map(LibraryIdentity.init) == LibraryIdentity(account) else { return }
            self.busy = true; self.status.stringValue = "Deleting playlist…"; self.updateActions()
            self.writeTask = Task {
                defer { self.writeTask = nil; self.busy = false; self.updateActions() }
                do {
                    try await self.apiFactory(account).delete(id)
                    guard self.model.account.map(LibraryIdentity.init) == LibraryIdentity(account) else { return }
                    self.hosted.removeAll { $0.id == id }; self.selectedID = nil; self.preview = []; self.previewID = nil; self.reload(); self.status.stringValue = "Playlist deleted. Songs and queue were kept."
                } catch { self.status.stringValue = error.localizedDescription }
            }
        }
    }
    private func open(autoplay: Bool, append: Bool = false) {
        guard !busy, previewID == selectedID, !preview.isEmpty else { return }
        if hostedMode, model.account.map(LibraryIdentity.init) != accountIdentity { return }
        if append {
            let selected = window?.firstResponder === tracks && preview.indices.contains(tracks.selectedRow) ? tracks.selectedRow : nil
            if !hostedMode, let item = selectedCollection { model.appendCollection(item, selectedIndex: selected) }
            else { model.append(selected.map { [preview[$0]] } ?? preview) }
            return
        }
        let row = window?.firstResponder === tracks && preview.indices.contains(tracks.selectedRow) ? tracks.selectedRow : 0
        if hostedMode {
            guard let account = model.account, accountIdentity == LibraryIdentity(account) else { return }
            let entries = preview.map(QueueEntry.init)
            let item = SavedCollection(id: selectedID!, name: "Jellyfin playlist", snapshot: PlayerSession(entries: entries, current: entries.first?.id, position: 0, selectedFolder: model.selectedFolder, stopped: true, library: LibraryIdentity(account)))
            model.loadCollection(item, autoplay: autoplay, startIndex: row)
        } else if let item = selectedCollection { model.loadCollection(item, autoplay: autoplay, startIndex: row) }
    }
}
