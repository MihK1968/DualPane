import AppKit

protocol SidebarDelegate: AnyObject {
    func sidebarDidSelect(_ url: URL, inNewTab: Bool)
    func sidebarOpenInOtherPane(_ url: URL)
}

/// Finder-style source list: Devices (volumes) and user-editable Favorites.
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: SidebarDelegate?

    final class Node {
        enum Kind { case group, device, favorite, separator }
        let kind: Kind
        let title: String
        let url: URL?
        var children: [Node] = []
        var favoriteIndex = -1
        var depth = 0                 // favourites: nesting level, 0 = top
        var labelled = false          // favourites: drawn as a divider line with the name on it
        weak var parent: Node?        // favourites: the group or the favourite this row is nested in
        var ejectable = false
        /// `url` with Finder aliases and symlinks followed, for matching against pane folders.
        lazy var resolved: URL? = url?.resolvingAlias(mount: false)
        init(kind: Kind, title: String, url: URL? = nil) { self.kind = kind; self.title = title; self.url = url }
    }

    private let outline = SidebarOutlineView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
    private let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
    private var devices = Node(kind: .group, title: "Devices")
    private var favorites = Node(kind: .group, title: "Favorites")
    private var flatFavorites: [Node] = []        // every favourite row in list order (index = favoriteIndex)
    private var suppressSelection = false
    private var rebuilding = false
    /// Paths of the favourites whose nested rows are hidden; remembered across launches.
    private var collapsed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "favoritesCollapsed") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "favoritesCollapsed") }
    }
    private static let dragType = NSPasteboard.PasteboardType("ee.korgesaar.dualpane.sidebar-item")

    override func loadView() {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let col = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(col)
        outline.autoresizingMask = [.width]
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 16        // nested favourites step in; the triangle sits in that space
        outline.dataSource = self
        outline.delegate = self
        outline.sidebar = self
        outline.registerForDraggedTypes([.fileURL, SidebarController.dragType])
        outline.setDraggingSourceOperationMask([.move], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy, .link], forLocal: false)
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.doubleAction = #selector(rowDoubleClicked(_:))
        v.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor), scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(rebuild), name: Favorites.changed, object: nil)
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(rebuild), name: NSWorkspace.didMountNotification, object: nil)
        wc.addObserver(self, selector: #selector(rebuild), name: NSWorkspace.didUnmountNotification, object: nil)
        wc.addObserver(self, selector: #selector(rebuild), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        rebuild()
    }
    override func viewDidLayout() { super.viewDidLayout(); outline.sizeLastColumnToFit() }
    deinit { NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc func rebuild() {
        let selectedURL = (outline.item(atRow: outline.selectedRow) as? Node)?.url
        devices = Node(kind: .group, title: "Devices")
        let computer = Node(kind: .device, title: Host.current().localizedName ?? "Computer", url: URL(fileURLWithPath: "/Volumes"))
        devices.children.append(computer)
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for v in vols {
            let rv = try? v.resourceValues(forKeys: Set(keys))
            guard rv?.volumeIsBrowsable != false else { continue }
            let n = Node(kind: .device, title: rv?.volumeName ?? v.lastPathComponent, url: v)
            n.ejectable = (rv?.volumeIsEjectable ?? false) || (rv?.volumeIsRemovable ?? false)
            devices.children.append(n)
        }
        favorites = Node(kind: .group, title: "Favorites")
        flatFavorites = []
        var stack: [Node] = [favorites]           // stack[d] is the parent of a row at depth d
        for (i, e) in Favorites.shared.sidebar.enumerated() {
            let n = e.url.map { Node(kind: .favorite, title: Favorites.displayName(for: $0), url: $0) } ?? Node(kind: .separator, title: "")
            n.favoriteIndex = i
            n.depth = e.depth
            n.labelled = e.asSeparator
            let parent = stack[min(e.depth, stack.count - 1)]
            n.parent = parent
            parent.children.append(n)
            stack = Array(stack[0...min(e.depth, stack.count - 1)])
            if n.kind == .favorite { stack.append(n) }
            flatFavorites.append(n)
        }
        suppressSelection = true; rebuilding = true
        outline.reloadData()
        outline.expandItem(devices); outline.expandItem(favorites)
        let hidden = collapsed
        for n in flatFavorites where !n.children.isEmpty && !hidden.contains(n.url?.path ?? "") { outline.expandItem(n) }
        rebuilding = false
        if let u = selectedURL { highlight(u) }
        suppressSelection = false
    }

    // Collapsing a row also collapses the rows nested in it (their notifications arrive inside the
    // outer pair); only the row that was acted on is remembered, so the nested ones reopen with it.
    private var collapsing: Node?
    private var collapseNesting = 0
    func outlineViewItemWillCollapse(_ n: Notification) {
        if collapseNesting == 0 { collapsing = n.userInfo?["NSObject"] as? Node }
        collapseNesting += 1
    }
    func outlineViewItemDidCollapse(_ n: Notification) {
        collapseNesting = max(0, collapseNesting - 1)
        if let node = n.userInfo?["NSObject"] as? Node, node === collapsing { noteExpansion(node, expanded: false) }
        if collapseNesting == 0 { collapsing = nil }
    }
    func outlineViewItemDidExpand(_ n: Notification) { noteExpansion(n.userInfo?["NSObject"] as? Node, expanded: true) }
    private func noteExpansion(_ node: Node?, expanded: Bool) {
        guard !rebuilding, let node = node, node.kind == .favorite, let p = node.url?.path else { return }
        var c = collapsed
        if expanded { c.remove(p) } else { c.insert(p) }
        collapsed = c
    }

    /// Select the row matching `url` (if any) without navigating.
    func highlight(_ url: URL) {
        suppressSelection = true
        defer { suppressSelection = false }
        // Compare resolved paths: panes follow symlinks (~/OneDrive… lands in ~/Library/CloudStorage/…)
        // and Finder aliases.
        let std = url.resolvingSymlinksInPath().standardizedFileURL
        for n in flatFavorites + devices.children where n.resolved == std {
            let r = outline.row(forItem: n)
            if r >= 0 { outline.selectRowIndexes([r], byExtendingSelection: false); return }
        }
        outline.deselectAll(nil)
    }

    // MARK: Data source
    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? Node else { return 2 }
        return n.children.count
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? Node else { return index == 0 ? devices : favorites }
        return n.children[index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? Node else { return false }
        return n.kind == .group || (n.kind == .favorite && !n.children.isEmpty)
    }
    func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? Node)?.kind == .group }
    func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let n = item as? Node else { return false }
        return n.kind == .device || n.kind == .favorite
    }
    func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? Node)?.kind == .separator ? 9 : 24
    }

    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        switch n.kind {
        case .group:
            let id = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = ov.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id, icon: false)
            cell.textField?.stringValue = n.title
            return cell
        case .separator:
            let id = NSUserInterfaceItemIdentifier("SepCell")
            if let v = ov.makeView(withIdentifier: id, owner: self) { return v }
            let v = NSView(); v.identifier = id
            let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(line)
            NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
                                         line.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
                                         line.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
            return v
        case .favorite where n.labelled:
            let id = NSUserInterfaceItemIdentifier("LabelSepCell")
            let cell = ov.makeView(withIdentifier: id, owner: self) as? LabelSepCell ?? makeLabelSeparatorCell(id)
            cell.label.stringValue = n.title
            cell.toolTip = n.url?.path
            return cell
        default:
            let id = NSUserInterfaceItemIdentifier("DataCell")
            let cell = ov.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id, icon: true)
            cell.textField?.stringValue = n.title
            if let u = n.url {
                let exists = FileManager.default.fileExists(atPath: u.path)
                cell.imageView?.image = n.url.map { Favorites.icon(for: $0) }
                cell.textField?.textColor = exists ? .labelColor : .tertiaryLabelColor
                cell.toolTip = u.path
            }
            return cell
        }
    }

    /// A favourite shown as a divider: a line across the row with its name centred on it in italics.
    /// It still opens on click like any favourite. The label is deliberately not the cell's `textField`:
    /// a source list restyles that outlet with its own font, which would undo the italics.
    final class LabelSepCell: NSTableCellView { let label = NSTextField(labelWithString: "") }

    private func makeLabelSeparatorCell(_ id: NSUserInterfaceItemIdentifier) -> LabelSepCell {
        let c = LabelSepCell(); c.identifier = id
        let tf = c.label; tf.translatesAutoresizingMaskIntoConstraints = false
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        tf.font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: base.pointSize) ?? base
        tf.alignment = .center
        tf.lineBreakMode = .byTruncatingMiddle
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.setContentHuggingPriority(.required, for: .horizontal)      // the label keeps its own width; the lines take the rest
        c.addSubview(tf)
        let left = NSBox(); left.boxType = .separator; left.translatesAutoresizingMaskIntoConstraints = false
        let right = NSBox(); right.boxType = .separator; right.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(left); c.addSubview(right)
        NSLayoutConstraint.activate([
            tf.centerXAnchor.constraint(equalTo: c.centerXAnchor), tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            tf.widthAnchor.constraint(lessThanOrEqualTo: c.widthAnchor, multiplier: 0.8),
            left.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4), left.trailingAnchor.constraint(equalTo: tf.leadingAnchor, constant: -6),
            right.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 6), right.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
            left.centerYAnchor.constraint(equalTo: c.centerYAnchor), right.centerYAnchor.constraint(equalTo: c.centerYAnchor),
        ])
        return c
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, icon: Bool) -> NSTableCellView {
        let c = NSTableCellView(); c.identifier = id
        let tf = NSTextField(labelWithString: ""); tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingMiddle
        c.addSubview(tf); c.textField = tf
        if icon {
            let iv = NSImageView(); iv.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(iv); c.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4), iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            ])
        } else {
            tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 0).isActive = true
        }
        NSLayoutConstraint.activate([tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4), tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
        return c
    }

    // MARK: Selection → navigation
    @objc private func rowClicked(_ s: Any?) {
        guard !suppressSelection, let n = outline.item(atRow: outline.clickedRow) as? Node, let u = n.url else { return }
        if let ev = NSApp.currentEvent, outline.frameOfOutlineCell(atRow: outline.clickedRow).contains(outline.convert(ev.locationInWindow, from: nil)) {
            return                                   // the disclosure triangle only shows or hides the nested rows
        }
        delegate?.sidebarDidSelect(u, inNewTab: NSEvent.modifierFlags.contains(.command))
    }
    @objc private func rowDoubleClicked(_ s: Any?) {
        guard let n = outline.item(atRow: outline.clickedRow) as? Node, let u = n.url else { return }
        delegate?.sidebarDidSelect(u, inNewTab: true)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Keyboard navigation inside the sidebar (arrow keys) also navigates.
        guard !suppressSelection, outline.window?.firstResponder === outline,
              NSApp.currentEvent?.type == .keyDown,
              let n = outline.item(atRow: outline.selectedRow) as? Node, let u = n.url else { return }
        delegate?.sidebarDidSelect(u, inNewTab: false)
    }

    // MARK: Context menu (built by the outline view subclass)
    func menu(for node: Node?) -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ a: Selector, _ tag: Int = 0) { let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; i.tag = tag; m.addItem(i) }
        if let n = node, n.url != nil, n.kind != .group {
            add("Open in New Tab", #selector(ctxNewTab(_:)))
            add("Open in Other Pane", #selector(ctxOtherPane(_:)))
            add("Reveal in Finder", #selector(ctxReveal(_:)))
            m.addItem(.separator())
            if n.kind == .favorite {
                add("Show as Separator", #selector(ctxToggleLabelled(_:)), n.favoriteIndex)
                m.items.last?.state = n.labelled ? .on : .off
                add("Add Folder Inside…", #selector(ctxAddInside(_:)), n.favoriteIndex)
                if let pn = n.parent, pn.kind == .favorite { add("Move Out of “\(pn.title)”", #selector(ctxMoveOut(_:)), n.favoriteIndex) }
                add(n.children.isEmpty ? "Remove from Sidebar" : "Remove from Sidebar (with the folders inside)", #selector(ctxRemove(_:)), n.favoriteIndex)
            }
            if n.kind == .device && n.ejectable { add("Eject", #selector(ctxEject(_:))) }
        }
        if let n = node, n.kind == .separator { add("Remove Separator", #selector(ctxRemove(_:)), n.favoriteIndex) }
        let idx = node.map { $0.kind == .favorite || $0.kind == .separator ? $0.favoriteIndex : Favorites.shared.sidebar.count } ?? Favorites.shared.sidebar.count
        add("Add Separator", #selector(ctxAddSeparator(_:)), idx)
        contextNode = node
        return m
    }
    private var contextNode: Node?
    @objc private func ctxNewTab(_ s: Any?) { if let u = contextNode?.url { delegate?.sidebarDidSelect(u, inNewTab: true) } }
    @objc private func ctxOtherPane(_ s: Any?) { if let u = contextNode?.url { delegate?.sidebarOpenInOtherPane(u) } }
    @objc private func ctxReveal(_ s: Any?) { if let u = contextNode?.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc private func ctxRemove(_ s: NSMenuItem) { Favorites.shared.removeSidebar(at: s.tag) }
    @objc private func ctxMoveOut(_ s: NSMenuItem) { Favorites.shared.moveSidebarOut(at: s.tag) }
    @objc private func ctxToggleLabelled(_ s: NSMenuItem) { Favorites.shared.setSidebarAsSeparator(at: s.tag, s.state != .on) }
    /// Picks folders with an open panel and adds them inside the favourite the menu was opened on.
    @objc private func ctxAddInside(_ s: NSMenuItem) {
        guard let w = view.window, let n = contextNode else { return }
        let parent = s.tag
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.prompt = "Add"
        p.message = "Choose folders to add inside “\(n.title)”"
        p.directoryURL = n.url
        p.beginSheetModal(for: w) { r in
            guard r == .OK else { return }
            for u in p.urls { Favorites.shared.addSidebar(u, inside: parent) }
        }
    }
    @objc private func ctxAddSeparator(_ s: NSMenuItem) { Favorites.shared.addSidebarSeparator(at: s.tag) }
    @objc private func ctxEject(_ s: Any?) {
        guard let u = contextNode?.url else { return }
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: u) }
        catch { FileOps.alert("Could not eject: \(error.localizedDescription)", window: view.window) }
    }

    // MARK: Drag & drop (reorder favourites, drop folders to add; onto a favourite = inside it)
    func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let n = item as? Node, n.kind == .favorite || n.kind == .separator else { return nil }
        let pi = NSPasteboardItem()
        pi.setString(String(n.favoriteIndex), forType: SidebarController.dragType)
        if let u = n.url { pi.setString(u.absoluteString, forType: .fileURL) }
        return pi
    }

    /// Where a drop lands: inside a favourite (dropped onto its row), or in the gap before child `k`
    /// of a parent (the Favorites group or a favourite); `k` past the end means after its last child.
    enum DropTarget { case inside(Node), between(Node, Int) }

    func dropTarget(item: Any?, index: Int) -> DropTarget? {
        guard let n = item as? Node else {
            return index >= 1 || index < 0 ? .between(favorites, favorites.children.count) : nil   // below the Favorites group at root level
        }
        switch n.kind {
        case .group: return n === favorites ? .between(favorites, index < 0 ? favorites.children.count : index) : nil
        case .favorite: return index < 0 ? .inside(n) : .between(n, index)
        case .separator:
            guard let p = n.parent, let i = p.children.firstIndex(where: { $0 === n }) else { return nil }
            return .between(p, i)                 // onto a separator: before it, at its level
        case .device: return nil
        }
    }

    /// The gap before child `k` of `parent` as an index in the favourites list, and the depth rows get there.
    func gap(in parent: Node, childIndex k: Int) -> (index: Int, depth: Int) {
        let depth = parent === favorites ? 0 : parent.depth + 1
        if k < parent.children.count { return (parent.children[k].favoriteIndex, depth) }
        if parent === favorites { return (Favorites.shared.sidebar.count, 0) }
        return (Favorites.shared.sidebarSubtree(at: parent.favoriteIndex).upperBound, depth)
    }

    func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pb = info.draggingPasteboard
        let dragged = pb.string(forType: SidebarController.dragType).flatMap { Int($0) }
        if dragged == nil {
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.contains(where: { $0.folderURL != nil }) { return [] }     // folders, and Finder aliases to folders
        }
        guard let target = dropTarget(item: item, index: index) else { return [] }
        let moving = dragged.map { Favorites.shared.sidebarSubtree(at: $0) }
        switch target {
        case .inside(let n):
            if let r = moving, r.contains(n.favoriteIndex) { return [] }                      // not into itself
            ov.setDropItem(n, dropChildIndex: NSOutlineViewDropOnItemIndex)
        case .between(let p, let k):
            if let r = moving, p !== favorites, r.contains(p.favoriteIndex) { return [] }
            ov.setDropItem(p, dropChildIndex: k)
        }
        return dragged == nil ? .link : .move
    }

    func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = dropTarget(item: item, index: index) else { return false }
        let pb = info.draggingPasteboard
        let dragged = pb.string(forType: SidebarController.dragType).flatMap { Int($0) }
        let urls = ((pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
            .filter { $0.folderURL != nil }                   // an alias is kept as is: it shows its own name
        switch target {
        case .inside(let n):
            if let from = dragged { Favorites.shared.moveSidebar(from: from, inside: n.favoriteIndex) }
            else { for u in urls { Favorites.shared.addSidebar(u, inside: n.favoriteIndex) } }
        case .between(let p, let k):
            let g = gap(in: p, childIndex: k)
            if let from = dragged { Favorites.shared.moveSidebar(from: from, to: g.index, depth: g.depth) }
            else { var at = g.index; for u in urls { Favorites.shared.addSidebar(u, at: at, depth: g.depth); at += 1 } }
        }
        return true
    }
}

/// Outline view that selects the right-clicked row and asks the controller for a context menu.
final class SidebarOutlineView: NSOutlineView {
    weak var sidebar: SidebarController?
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        let node = r >= 0 ? item(atRow: r) as? SidebarController.Node : nil
        return sidebar?.menu(for: node)
    }
}
