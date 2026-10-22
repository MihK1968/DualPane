import AppKit
import Quartz

// MARK: - Table data source / delegate, rename, drag & drop, context menu, file actions
extension PaneController: NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuItemValidation, NSMenuDelegate {

    // The list is an outline: the pane's folder at the top level and, under every folder row opened
    // with its triangle (folder peek), that folder's own rows.
    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let it = item as? FileItem else { return items.count }
        return children(of: it).count
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let it = item as? FileItem else { return items[index] }
        return children(of: it)[index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileItem)?.opensAsFolder ?? false }

    func outlineViewItemDidExpand(_ n: Notification) {
        guard let it = n.userInfo?["NSObject"] as? FileItem else { return }
        expanded.insert(it.url)
        guard !restoringExpansion else { return }
        // Folders inside it that were open when it was last closed open again with it.
        for c in it.shownChildren where expanded.contains(c.url) && !tableView.isItemExpanded(c) { tableView.expandItem(c) }
        syncSubWatchers()
    }
    // Closing a row also closes the open folders inside it; their notifications arrive inside the
    // outer ones, and only the row the user acted on is forgotten (the inner ones open again with it).
    func outlineViewItemWillCollapse(_ n: Notification) {
        if collapseNesting == 0 { collapsing = n.userInfo?["NSObject"] as? FileItem }
        collapseNesting += 1
    }
    func outlineViewItemDidCollapse(_ n: Notification) {
        collapseNesting = max(0, collapseNesting - 1)
        if !restoringExpansion, let it = n.userInfo?["NSObject"] as? FileItem, it === collapsing { expanded.remove(it.url) }
        if collapseNesting == 0 { collapsing = nil; if !restoringExpansion { syncSubWatchers() } }
    }

    func outlineView(_ ov: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
        guard let col = column, let item = item as? FileItem else { return nil }
        let id = col.identifier
        var cell = ov.makeView(withIdentifier: id, owner: self) as? NSTableCellView
        if cell == nil {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle
            tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            tf.isEditable = false
            tf.drawsBackground = false
            tf.isBordered = false
            c.addSubview(tf)
            c.textField = tf
            if id.rawValue == "name" {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.imageScaling = .scaleProportionallyDown
                c.addSubview(iv)
                c.imageView = iv
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                ])
            } else {
                tf.alignment = id.rawValue == "size" ? .right : .left
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            cell = c
        }
        guard let c = cell, let tf = c.textField else { return nil }
        switch id.rawValue {
        case "name":
            tf.stringValue = item.name
            tf.textColor = item.isHidden ? .tertiaryLabelColor : .labelColor
            c.imageView?.image = item.icon
        case "size":
            tf.stringValue = item.sizeString
            tf.textColor = .secondaryLabelColor
        default:
            tf.stringValue = item.dateString
            tf.textColor = .secondaryLabelColor
        }
        return c
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
        if let p = QLPreviewPanel.shared(), p.isVisible, p.dataSource === tableView { p.reloadData() }
    }

    func outlineView(_ ov: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard let sd = ov.sortDescriptors.first, let k = SortKey(rawValue: sd.key ?? "") else { return }
        sortKey = k; sortAscending = sd.ascending
        applyFilter()
    }

    func outlineView(_ ov: NSOutlineView, typeSelectStringFor column: NSTableColumn?, item: Any) -> String? { nil }

    // MARK: Rename
    func startRename() {
        guard renamingRow < 0, selectedItems.count == 1, let row = tableView.selectedRowIndexes.first, let item = fileItem(atRow: row),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let tf = cell.textField else { return }
        renamingRow = row
        tf.isEditable = true
        tf.delegate = self
        tableView.scrollRowToVisible(row)
        tableView.editColumn(0, row: row, with: nil, select: false)
        if let ed = tf.currentEditor() {
            let ext = (item.name as NSString).pathExtension
            let base = (item.isDirectory || ext.isEmpty) ? item.name.utf16.count : (item.name as NSString).deletingPathExtension.utf16.count
            ed.selectedRange = NSRange(location: 0, length: base)
        }
    }

    /// Rename with several items selected: asks for one name, then every item gets it followed by
    /// _001, _002, … in order of modification date (the oldest first). Each item keeps its own
    /// extension and stays in its own folder (the selection may reach into opened folder rows).
    func batchRename() {
        let sel = selectedItems
        guard sel.count > 1, let window = view.window else { return }
        let a = NSAlert()
        a.messageText = "Rename \(sel.count) items"
        a.informativeText = "Each item gets this name followed by _001, _002, … with the oldest first. Extensions are kept."
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Name"
        a.accessoryView = field
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            let base = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { return }
            // The sheet is still closing; the next alert, if any, must not open underneath it.
            DispatchQueue.main.async { self?.batchRename(sel, to: base) }
        }
    }

    func batchRename(_ items: [FileItem], to base: String) {
        guard !base.contains("/") else { FileOps.alert("A name can’t contain “/”.", window: view.window); return }
        let fm = FileManager.default
        let sorted = items.sorted {
            $0.modified != $1.modified ? $0.modified < $1.modified : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let width = max(3, String(sorted.count).count)
        let finals: [URL] = sorted.enumerated().map { i, it in
            let ext = it.isDirectory ? "" : it.url.pathExtension
            return it.url.deletingLastPathComponent().appendingPathComponent("\(base)_" + String(format: "%0\(width)d", i + 1) + (ext.isEmpty ? "" : ".\(ext)"))
        }
        // A new name may only be taken from one of the selected items, never from another file.
        let sources = Set(sorted.map { $0.url.standardizedFileURL.path.lowercased() })
        let clashes = finals.filter { fm.fileExists(atPath: $0.path) && !sources.contains($0.standardizedFileURL.path.lowercased()) }
        if !clashes.isEmpty {
            let what = clashes.count == 1 ? "“\(clashes[0].lastPathComponent)” already exists."
                                          : "\(clashes.count) of the new names already exist (“\(clashes[0].lastPathComponent)” and others)."
            FileOps.alert(what + " Nothing was renamed.", window: view.window); return
        }
        // Two steps through temporary names, so an item can take over a name another selected item is giving up.
        var temps: [URL] = []
        for it in sorted {
            let tmp = it.url.deletingLastPathComponent().appendingPathComponent(".dualpane-rename-\(UUID().uuidString)")
            do { try fm.moveItem(at: it.url, to: tmp); temps.append(tmp) }
            catch {
                for (t, orig) in zip(temps, sorted) { try? fm.moveItem(at: t, to: orig.url) }
                FileOps.alert("Could not rename “\(it.name)”: \(error.localizedDescription) Nothing was renamed.", window: view.window)
                return
            }
        }
        var done: [URL] = [], errors: [String] = []
        for (i, tmp) in temps.enumerated() {
            do { try fm.moveItem(at: tmp, to: finals[i]); done.append(finals[i]) }
            catch {
                try? fm.moveItem(at: tmp, to: sorted[i].url)
                errors.append("\(sorted[i].name): \(error.localizedDescription)")
            }
        }
        reloadKeeping(done)
        if !errors.isEmpty { FileOps.alert("Some items could not be renamed:\n\n" + errors.joined(separator: "\n"), window: view.window) }
    }

    func endRename(commit: Bool) {
        guard renamingRow >= 0, let cell = tableView.view(atColumn: 0, row: renamingRow, makeIfNecessary: false) as? NSTableCellView, let tf = cell.textField else { renamingRow = -1; return }
        if !commit, let item = fileItem(atRow: renamingRow) { tf.stringValue = item.name }
        if tf.currentEditor() != nil { view.window?.makeFirstResponder(tableView) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === pathField { pathEditEnded(); return }
        guard let tf = obj.object as? NSTextField, renamingRow >= 0, let item = fileItem(atRow: renamingRow) else { renamingRow = -1; return }
        let newName = tf.stringValue
        tf.isEditable = false
        tf.delegate = nil
        renamingRow = -1
        if newName != item.name, let dst = FileOps.rename(item.url, to: newName, window: view.window) {
            reloadKeeping([dst])
        } else {
            tf.stringValue = item.name
        }
        DispatchQueue.main.async { [weak self] in self?.focus() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if control === pathField {
            if sel == #selector(NSResponder.cancelOperation(_:)) { cancelPathEdit(); return true }
            if sel == #selector(NSResponder.insertNewline(_:)) { commitPathEdit(); return true }
            return false
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) { view.window?.makeFirstResponder(tableView); return true }
        return false
    }

    func reloadKeeping(_ urls: [URL]) {
        reload()
        select(urls: urls)
    }

    // MARK: Drag & drop
    func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileItem)?.url as NSURL?
    }

    func outlineView(_ ov: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt p: NSPoint, forItems items: [Any]) {
        session.draggingFormation = .list
        (ov as? PaneTableView)?.dragBegan = true
    }

    private func dropURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// A drop that carries no file URLs but file promises (Mail attachments and messages, Photos,
    /// images dragged out of a browser…): the source writes the files only after we accept.
    private func hasPromises(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    /// Where a drop at this outline position goes: onto a folder row, into that folder; onto a file or
    /// between rows, into the folder those rows belong to (the pane's own folder at the top level).
    /// Also returns the row to highlight (nil highlights the whole list).
    private func dropFolder(item: Any?, index: Int) -> (URL, FileItem?) {
        guard let it = item as? FileItem else { return (directory, nil) }
        if index == NSOutlineViewDropOnItemIndex, !it.opensAsFolder {
            let parent = tableView.parent(forItem: it) as? FileItem
            return (parent?.folderURL ?? directory, parent)
        }
        return (it.folderURL ?? directory, it)
    }

    private func dropTarget(_ info: NSDraggingInfo, into target: URL) -> (URL, [URL], NSDragOperation)? {
        let urls = dropURLs(info)
        if urls.isEmpty {
            guard hasPromises(info) else { return nil }
            let mask = info.draggingSourceOperationMask
            let op = [NSDragOperation.copy, .generic, .move, .link].first { mask.contains($0) } ?? .copy
            return (target, [], op)
        }
        let t = target.standardizedFileURL
        for u in urls {
            let s = u.standardizedFileURL
            if s == t || t.path.hasPrefix(s.path + "/") { return nil }
        }
        let mask = info.draggingSourceOperationMask
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        let sameVolume: Bool = {
            guard let a = try? urls[0].resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
                  let b = try? target.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return false }
            return a.isEqual(b)
        }()
        let wantMove = sameVolume && !optionHeld && mask.contains(.move)
        if wantMove && urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == t }) { return nil }
        let op: NSDragOperation = wantMove ? .move : (mask.contains(.copy) ? .copy : [])
        return op.isEmpty ? nil : (target, urls, op)
    }

    func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let (folder, row) = dropFolder(item: item, index: index)
        ov.setDropItem(row, dropChildIndex: NSOutlineViewDropOnItemIndex)
        guard let (_, _, dragOp) = dropTarget(info, into: folder) else { return [] }
        return dragOp
    }

    func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let (folder, _) = dropFolder(item: item, index: index)
        guard let (target, urls, dragOp) = dropTarget(info, into: folder) else { return false }
        if urls.isEmpty {
            let receivers = (info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
            guard !receivers.isEmpty else { return false }
            statusField.stringValue = "Receiving dropped files…"
            FileOps.receivePromised(receivers, into: target) { [weak self] arrived in
                guard let self = self else { return }
                self.reload()
                self.selectIfShown(arrived)
            }
            return true
        }
        FileOps.transfer(urls, to: target, move: dragOp == .move, window: view.window) { [weak self] done in
            guard let self = self else { return }
            self.reload()
            self.selectIfShown(done)
        }
        return true
    }

    // MARK: Context menu
    func contextMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ a: Selector, _ k: String = "") { let i = NSMenuItem(title: t, action: a, keyEquivalent: k); m.addItem(i) }
        add("Open", #selector(openAction(_:)))
        let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWithItem.submenu = NSMenu(title: "Open With")
        openWithItem.submenu?.delegate = self          // filled with the matching apps when it opens
        m.addItem(openWithItem)
        add("Open in New Tab", #selector(openInNewTab(_:)))
        add("Open in Other Pane", #selector(openInOtherPane(_:)))
        add("Quick Look", #selector(quickLook(_:)))
        add("Rename", #selector(renameSelected(_:)))
        add("Show Package Contents", #selector(showPackageContents(_:)))
        m.addItem(.separator())
        add("Copy to Other Pane", #selector(MainWindowController.copyToOtherPane(_:)))
        add("Move to Other Pane", #selector(MainWindowController.moveToOtherPane(_:)))
        m.addItem(.separator())
        add("New Folder", #selector(newFolder(_:)))
        add("Duplicate", #selector(duplicate(_:)))
        add("Move to Trash", #selector(moveToTrash(_:)))
        m.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)))
        add("Copy", #selector(NSText.copy(_:)))
        add("Paste Items", #selector(NSText.paste(_:)))
        add("Copy Path", #selector(copyPath(_:)))
        m.addItem(.separator())
        add("Reveal in Finder", #selector(revealInFinder(_:)))
        add("Get Info", #selector(getInfo(_:)))
        add("Open in Terminal", #selector(openInTerminal(_:)))
        m.addItem(.separator())
        add("Add to Sidebar", #selector(addToFavorites(_:)))
        add("Add to Quick Access", #selector(addToQuickAccess(_:)))
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Open With" { PaneController.populateOpenWith(menu, urls: selectedURLs, target: self) }
    }

    /// Fills an "Open With" menu like Finder's: the default app first, then every other app
    /// Launch Services knows can open all the selected items, then "Other…" for an open panel.
    static func populateOpenWith(_ menu: NSMenu, urls: [URL], target: PaneController) {
        menu.removeAllItems()
        guard !urls.isEmpty else { menu.addItem(NSMenuItem(title: "No Selection", action: nil, keyEquivalent: "")); return }
        let ws = NSWorkspace.shared
        var apps = ws.urlsForApplications(toOpen: urls[0])
        for u in urls.dropFirst() {
            let s = Set(ws.urlsForApplications(toOpen: u).map { $0.standardizedFileURL })
            apps = apps.filter { s.contains($0.standardizedFileURL) }
        }
        var seen = Set<URL>()
        apps = apps.filter { seen.insert($0.standardizedFileURL).inserted }
        let defaults = Set(urls.compactMap { ws.urlForApplication(toOpen: $0)?.standardizedFileURL })
        let defaultApp = defaults.count == 1 ? defaults.first : nil
        func name(_ a: URL) -> String {
            let n = FileManager.default.displayName(atPath: a.path)
            return (n as NSString).pathExtension == "app" ? (n as NSString).deletingPathExtension : n
        }
        let byName = Dictionary(grouping: apps, by: name)
        func title(_ a: URL) -> String {        // same name twice (two versions): show the version
            var t = name(a)
            if (byName[t]?.count ?? 0) > 1, let v = Bundle(url: a)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { t += " (\(v))" }
            return t
        }
        func item(_ a: URL, suffix: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title(a) + suffix, action: #selector(openWithApp(_:)), keyEquivalent: "")
            i.target = target
            i.representedObject = a.path
            let icon = ws.icon(forFile: a.path); icon.size = NSSize(width: 16, height: 16); i.image = icon
            return i
        }
        if let d = defaultApp, let a = apps.first(where: { $0.standardizedFileURL == d }) ?? Optional(d) {
            menu.addItem(item(a, suffix: " (default)")); menu.addItem(.separator())
        }
        let rest = apps.filter { $0.standardizedFileURL != defaultApp }
            .sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
        for a in rest { menu.addItem(item(a)) }
        if rest.isEmpty && defaultApp == nil { menu.addItem(NSMenuItem(title: "No Applications Found", action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: #selector(openWith(_:)), keyEquivalent: "")
        other.target = target
        menu.addItem(other)
    }

    @objc func openWithApp(_ s: Any?) {
        guard let p = (s as? NSMenuItem)?.representedObject as? String, !selectedURLs.isEmpty else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: URL(fileURLWithPath: p), configuration: NSWorkspace.OpenConfiguration())
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let sel = selectedItems
        switch item.action {
        case #selector(openAction(_:)), #selector(quickLook(_:)), #selector(moveToTrash(_:)), #selector(copy(_:)), #selector(cut(_:)),
             #selector(getInfo(_:)), #selector(duplicate(_:)):
            return !sel.isEmpty
        case #selector(copyPath(_:)):
            item.title = sel.isEmpty ? "Copy Folder Path" : "Copy Path"
            return true
        case #selector(renameSelected(_:)):
            item.title = sel.count > 1 ? "Rename \(sel.count) Items…" : "Rename"
            return !sel.isEmpty
        case #selector(showPackageContents(_:)):
            let ok = sel.count == 1 && sel[0].isPackage
            item.isHidden = !ok
            return ok
        case #selector(paste(_:)), #selector(moveHere(_:)):
            return !((NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []).isEmpty
        case #selector(openInNewTab(_:)), #selector(openInOtherPane(_:)):
            let dirs = sel.filter { $0.opensAsFolder }
            item.title = (item.action == #selector(openInNewTab(_:)) ? "Open in New Tab" : "Open in Other Pane")
            if dirs.isEmpty { item.title = item.action == #selector(openInNewTab(_:)) ? "New Tab Here" : "Show This Folder in Other Pane" }
            return true
        case #selector(addToFavorites(_:)), #selector(addToQuickAccess(_:)):
            let dirs = sel.filter { $0.opensAsFolder }
            let what = dirs.count == 1 ? "“\(dirs[0].name)”" : dirs.isEmpty ? "“\(directory.lastPathComponent)”" : "\(dirs.count) Folders"
            item.title = (item.action == #selector(addToFavorites(_:)) ? "Add \(what) to Sidebar" : "Add \(what) to Quick Access")
            return true
        case #selector(openInTerminal(_:)):
            let dirs = sel.filter { $0.opensAsFolder }
            let what = dirs.count == 1 ? " “\(dirs[0].name)”" : dirs.isEmpty ? "" : " \(dirs.count) Folders"
            item.title = "Open\(what) in \(FileOps.terminalApp.name)"
            return true
        case #selector(goBack(_:)): return canGoBack
        case #selector(goForward(_:)): return canGoForward
        case #selector(goUp(_:)): return directory.path != "/"
        default: return true
        }
    }

    // MARK: Actions (reached through the responder chain)
    @objc func openAction(_ s: Any?) { openSelected() }
    @objc func quickLook(_ s: Any?) { toggleQuickLook() }
    @objc func renameSelected(_ s: Any?) { if selectedItems.count > 1 { batchRename() } else { startRename() } }
    @objc func goUp(_ s: Any?) { goUp() }
    @objc func goBack(_ s: Any?) { goBack() }
    @objc func goForward(_ s: Any?) { goForward() }
    @objc func refresh(_ s: Any?) { reload() }

    /// Folders to act on for "add to favourites"-type commands: the selected folders (aliases to
    /// folders count, and keep their own name in the sidebar), else the current one.
    private var targetFolders: [URL] {
        let dirs = selectedItems.filter { $0.opensAsFolder }.map { $0.url }
        return dirs.isEmpty ? [directory] : dirs
    }
    @objc func openInNewTab(_ s: Any?) {
        for (i, u) in targetFolders.enumerated() { delegate?.paneRequestsNewTab(from: self, url: u, select: i == 0) }
    }
    @objc func openInOtherPane(_ s: Any?) {
        if let u = targetFolders.first { delegate?.paneRequestsOpenInOtherPane(from: self, url: u) }
    }
    @objc func addToFavorites(_ s: Any?) { targetFolders.forEach { Favorites.shared.addSidebar($0) } }
    @objc func addToQuickAccess(_ s: Any?) { targetFolders.forEach { Favorites.shared.addQuick($0) } }

    @objc func showPackageContents(_ s: Any?) {
        guard let p = selectedItems.first, p.isPackage else { return }
        navigate(to: p.url)
    }

    @objc func newFolder(_ s: Any?) {
        guard let u = FileOps.newFolder(in: directory, name: "untitled folder", window: view.window) else { return }
        clearFilter()
        reloadKeeping([u])
        DispatchQueue.main.async { [weak self] in self?.startRename() }
    }

    @objc func newFile(_ s: Any?) {
        guard let u = FileOps.newFile(in: directory, name: "untitled.txt", window: view.window) else { return }
        clearFilter()
        reloadKeeping([u])
        DispatchQueue.main.async { [weak self] in self?.startRename() }
    }

    @objc func duplicate(_ s: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        FileOps.transfer(urls, to: directory, move: false, window: view.window, policy: .keepBoth) { [weak self] done in
            self?.reloadKeeping(done)
        }
    }

    @objc func moveToTrash(_ s: Any?) {
        let sel = selectedItems
        guard !sel.isEmpty else { return }
        // Select the row after the last deleted one, like Finder does.
        let next = (tableView.selectedRowIndexes.last ?? -1) + 1
        let nextURL = fileItem(atRow: next)?.url
        FileOps.trash(sel.map { $0.url }, window: view.window) { [weak self] in
            guard let self = self else { return }
            self.reload()
            if let n = nextURL { self.select(urls: [n]) }
            else if self.tableView.numberOfRows > 0 { self.tableView.selectRowIndexes([self.tableView.numberOfRows - 1], byExtendingSelection: false) }
        }
    }

    @objc func copy(_ s: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    /// The pasteboard change that Cut produced; while the pasteboard still holds it, Paste moves the items.
    private static var cutChangeCount: Int?

    @objc func cut(_ s: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        PaneController.cutChangeCount = pb.changeCount
        statusField.stringValue = "Cut \(urls.count) item\(urls.count == 1 ? "" : "s")  (⌘V moves)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.updateStatus() }
    }

    @objc func paste(_ s: Any?) {
        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        let move = PaneController.cutChangeCount == pb.changeCount      // items put there by Cut are moved
        FileOps.transfer(urls, to: directory, move: move, window: view.window) { [weak self] done in
            self?.reloadKeeping(done)
            if move, !done.isEmpty { pb.clearContents(); PaneController.cutChangeCount = nil }
        }
    }

    @objc func moveHere(_ s: Any?) {
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        FileOps.transfer(urls, to: directory, move: true, window: view.window) { [weak self] done in
            self?.reloadKeeping(done)
            NSPasteboard.general.clearContents()
        }
    }

    /// Copies the selected paths, one per line; with nothing selected, the current folder's path.
    @objc func copyPath(_ s: Any?) {
        let paths = selectedURLs.isEmpty ? [directory.path] : selectedURLs.map { $0.path }
        copyToClipboard(paths.joined(separator: "\n"))
    }

    @objc func revealInFinder(_ s: Any?) {
        let urls = selectedURLs
        if urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
        else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc func getInfo(_ s: Any?) { FileOps.getInfo(selectedURLs.isEmpty ? [directory] : selectedURLs) }
    /// Selected folders (aliases resolved to their original folder), else the current folder.
    @objc func openInTerminal(_ s: Any?) {
        let dirs = selectedItems.compactMap { $0.folderURL }
        FileOps.openTerminal(at: dirs.isEmpty ? [directory] : dirs)
    }

    /// Toolbar button: always the folder this pane shows, whatever is selected.
    @objc func openFolderInTerminal(_ s: Any?) { FileOps.openTerminal(at: [directory]) }

    @objc func openWith(_ s: Any?) {
        // "Other…": pick any application with an open panel.
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        let urls = selectedURLs
        guard !urls.isEmpty, let w = view.window else { return }
        panel.beginSheetModal(for: w) { r in
            guard r == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
