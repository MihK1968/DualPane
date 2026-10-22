import AppKit
import Quartz

protocol PaneDelegate: AnyObject {
    func paneDidBecomeActive(_ pane: PaneController)
    func paneRequestsSwitch(from pane: PaneController)
    func paneDirectoryChanged(_ pane: PaneController)
    func paneRequestsNewTab(from pane: PaneController, url: URL, select: Bool)
    func paneRequestsOpenInOtherPane(from pane: PaneController, url: URL)
    /// ⌥→ / ⌥←: show this pane's folder in the pane on that side.
    func paneRequestsShowFolder(from pane: PaneController, toRight: Bool)
}

enum Settings {
    static var showHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "showHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "showHidden"); NotificationCenter.default.post(name: .settingsChanged, object: nil) }
    }
}
extension Notification.Name { static let settingsChanged = Notification.Name("DualPaneSettingsChanged") }

/// One file-list pane: path bar, table, status line, with Total Commander style type-to-filter.
final class PaneController: NSViewController, PaneKeyHandler, NSToolbarItemValidation {
    weak var delegate: PaneDelegate?
    private(set) var directory: URL
    private var allItems: [FileItem] = []
    private(set) var items: [FileItem] = []
    var sortKey: SortKey = .name
    var sortAscending = true
    private(set) var filter = "" { didSet { applyFilter(); updateStatus() } }
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    var isActive = false { didSet { updateHeader() } }

    let headerView = NSView()
    let pathControl = PathBar()
    let pathField = NSTextField()      // editable full path, shown when the empty bar is clicked or with ⌘L
    let copyButton = NSButton()
    private static let rootName = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
    // Non-zero initial frames: AppKit skips autoresizing when the old superview size is zero.
    let tableView = PaneTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let bottomBar = NSView()
    let statusField = NSTextField(labelWithString: "")
    let filterField = NSTextField(labelWithString: "")
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadTimer: Timer?
    var renamingRow = -1
    // Folder peek: folder rows opened with their triangle, by the row's URL, so that a reload (which
    // lists everything afresh) can open them again. Forgotten when the pane goes to another folder.
    var expanded: Set<URL> = []
    var restoringExpansion = false
    var collapsing: FileItem?
    var collapseNesting = 0
    private var subWatchers: [URL: DispatchSourceFileSystemObject] = [:]

    let side: String
    init(directory url: URL, side: String) {
        self.side = side
        var start = url.resolvingAlias()
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: start.path, isDirectory: &isDir) || !isDir.boolValue {
            start = URL(fileURLWithPath: NSHomeDirectory())
        }
        directory = start
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: View
    override func loadView() {
        let root = PaneRootView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.onAppearanceChange = { [weak self] in self?.updateHeader(); self?.updateStatus() }

        headerView.wantsLayer = true
        headerView.translatesAutoresizingMaskIntoConstraints = false
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        pathControl.focusRingType = .none
        pathControl.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.onEmptyClick = { [weak self] in self?.beginPathEdit() }
        pathControl.menuProvider = { [weak self] hit in self?.pathBarMenu(for: hit) }
        headerView.addSubview(pathControl)

        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        pathField.controlSize = .small
        pathField.bezelStyle = .roundedBezel
        pathField.focusRingType = .none
        pathField.usesSingleLineMode = true
        pathField.cell?.isScrollable = true
        pathField.cell?.wraps = false
        pathField.lineBreakMode = .byClipping
        pathField.placeholderString = "/path/to/folder"
        pathField.toolTip = "Type a path and press Return; Esc goes back to the crumbs"
        pathField.delegate = self
        pathField.isHidden = true
        headerView.addSubview(pathField)

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.isBordered = false
        copyButton.setButtonType(.momentaryChange)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy folder path")
        copyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        copyButton.imagePosition = .imageOnly
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = "Copy folder path (⌘⌥C with nothing selected)"
        copyButton.target = self
        copyButton.action = #selector(copyFolderPath(_:))
        headerView.addSubview(copyButton)

        // Columns
        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Name"; name.width = 320; name.minWidth = 120
        name.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "Size"; size.width = 80; size.minWidth = 60; size.maxWidth = 120
        size.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
        let date = NSTableColumn(identifier: .init("modified"))
        date.title = "Date Modified"; date.width = 150; date.minWidth = 100; date.maxWidth = 220
        date.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: false)
        [name, size, date].forEach { tableView.addTableColumn($0) }
        tableView.outlineTableColumn = name           // the triangle and the indentation live in the name column
        tableView.autoresizesOutlineColumn = false

        tableView.keyHandler = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20
        tableView.style = .fullWidth
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.autosaveName = "paneTable.\(side)"
        tableView.autosaveTableColumns = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.autoresizingMask = [.width]
        // File URLs (Finder, our own panes) and file promises (Mail attachments, Photos, Safari images…).
        tableView.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.menu = contextMenu()
        if let sd = tableView.sortDescriptors.first, let k = SortKey(rawValue: sd.key ?? "") { sortKey = k; sortAscending = sd.ascending }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        bottomBar.wantsLayer = true
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        filterField.alignment = .right
        filterField.lineBreakMode = .byTruncatingHead
        bottomBar.addSubview(statusField)
        bottomBar.addSubview(filterField)

        root.addSubview(headerView); root.addSubview(scrollView); root.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: root.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 26),
            pathControl.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 4),
            pathControl.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -2),
            pathControl.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            pathField.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 4),
            pathField.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -2),
            pathField.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -4),
            copyButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 20),
            copyButton.heightAnchor.constraint(equalToConstant: 20),
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 22),
            statusField.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 8),
            statusField.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            filterField.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -8),
            filterField.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            filterField.leadingAnchor.constraint(greaterThanOrEqualTo: statusField.trailingAnchor, constant: 12),
        ])
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filterField.setContentCompressionResistancePriority(.required, for: .horizontal)
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appActivated), name: NSApplication.didBecomeActiveNotification, object: nil)
        // Keep the table exactly as wide as the clip view, so columns are re-fitted when the pane changes size
        // (autoresizing alone is delta-based and leaves a restored-from-defaults table wider than the pane).
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        updateHeader()
        navigate(to: directory, recordHistory: false)
    }

    @objc private func settingsChanged() { load() }
    @objc private func clipResized() {
        let w = scrollView.contentView.bounds.width
        guard w > 0, abs(tableView.frame.width - w) > 0.5 else { return }
        tableView.setFrameSize(NSSize(width: w, height: tableView.frame.height))
    }
    @objc private func appActivated() { scheduleReload() }

    private func updateHeader() {
        guard isViewLoaded else { return }
        headerView.layer?.backgroundColor = isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.windowBackgroundColor.cgColor
        headerView.layer?.borderWidth = 0
    }

    // MARK: Navigation
    func navigate(to requested: URL, recordHistory: Bool = true, select: URL? = nil) {
        var url = requested
        // Finder aliases (sidebar favourites may be alias files) open their original folder.
        if requested.isFinderAlias {
            guard let t = requested.aliasTarget else {
                FileOps.alert("“\(requested.lastPathComponent)” can’t be opened because the original item can’t be found.", window: view.window); return
            }
            url = t
        }
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        guard fm.isReadableFile(atPath: url.path) else {
            FileOps.alert("You don’t have permission to open “\(url.lastPathComponent)”.", window: view.window); return
        }
        // Follow symlinks: the URL-based directory enumerator refuses to list a symlinked folder
        // (~/OneDrive… → ~/Library/CloudStorage/OneDrive… came back "Not a directory"), and Finder
        // shows the target too.
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        if recordHistory, target != directory.standardizedFileURL {
            backStack.append(directory); forwardStack.removeAll()
        }
        if !pathField.isHidden { cancelPathEdit() }
        endRename(commit: false)
        if target != directory.standardizedFileURL { expanded = [] }
        directory = target
        updatePathItems()
        if !filter.isEmpty { filter = "" }
        let keep = select.map { [$0.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent($0.lastPathComponent)] } ?? []
        load(selecting: keep, scrollTop: select == nil)
        startWatching()
        delegate?.paneDirectoryChanged(self)
    }

    func goUp() {
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return }
        navigate(to: parent, select: directory)
    }
    func goBack() {
        guard let u = backStack.popLast() else { return }
        forwardStack.append(directory); navigate(to: u, recordHistory: false, select: nil)
    }
    func goForward() {
        guard let u = forwardStack.popLast() else { return }
        backStack.append(directory); navigate(to: u, recordHistory: false, select: nil)
    }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let u = (sender.cell as? NSPathCell)?.clickedPathComponentCell?.url ?? sender.clickedPathItem?.url else { return }
        focus()
        if NSEvent.modifierFlags.contains(.command) { delegate?.paneRequestsNewTab(from: self, url: u, select: true) }
        else { navigate(to: u) }
    }

    // MARK: Path bar
    /// One crumb per POSIX component starting at the volume root, so the bar shows the real path.
    /// (NSPathControl's own rendering of a URL hides ~/Library/CloudStorage and shows provider names.)
    private func updatePathItems() {
        // NSPathControlItem.url is read-only, so the crumbs are built as NSPathComponentCells (whose url is settable).
        var cells: [NSPathComponentCell] = []
        var u = URL(fileURLWithPath: "/")
        for (i, c) in directory.pathComponents.enumerated() {
            if i > 0 { u.appendPathComponent(c) }
            let cell = NSPathComponentCell()
            cell.title = i == 0 ? PaneController.rootName : c
            cell.font = pathControl.font
            let icon = NSWorkspace.shared.icon(forFile: u.path)
            icon.size = NSSize(width: 16, height: 16)
            cell.image = icon
            cell.url = u
            cells.append(cell)
        }
        (pathControl.cell as? NSPathCell)?.pathComponentCells = cells
        pathControl.needsDisplay = true
        pathControl.toolTip = directory.path
    }

    /// Swap the crumbs for an editable text field holding the full path, all selected (⌘C copies it at once).
    func beginPathEdit() {
        becameActive()
        pathField.stringValue = directory.path
        pathControl.isHidden = true
        pathField.isHidden = false
        view.window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }
    /// The field stopped being edited (Return, Esc, or focus moved elsewhere): put the crumbs back.
    func pathEditEnded() {
        pathField.isHidden = true
        pathControl.isHidden = false
    }
    func cancelPathEdit() {
        guard !pathField.isHidden else { return }
        if pathField.currentEditor() != nil { view.window?.makeFirstResponder(tableView) }
        pathEditEnded()
    }
    func commitPathEdit() {
        let text = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelPathEdit()
        guard !text.isEmpty else { return }
        let p = (text as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else {
            FileOps.alert("The folder “\(text)” can’t be found.", window: view.window); return
        }
        let u = URL(fileURLWithPath: p)
        if isDir.boolValue { navigate(to: u) } else { navigate(to: u.deletingLastPathComponent(), select: u) }
    }
    @objc func editPath(_ s: Any?) { beginPathEdit() }
    @objc func copyFolderPath(_ s: Any?) { copyToClipboard(directory.path) }

    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        statusField.stringValue = "Copied  " + text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.updateStatus() }
    }

    /// Context menu of the path bar; `hit` is the crumb under the mouse, nil on the empty part.
    private func pathBarMenu(for hit: URL?) -> NSMenu {
        let target = hit ?? directory
        let name = target.path == "/" ? PaneController.rootName : target.lastPathComponent
        let m = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self; i.representedObject = target.path; m.addItem(i)
        }
        add("Copy Path of “\(name)”", #selector(copyPathItem(_:)))
        add("Edit Path…", #selector(editPath(_:)))
        m.addItem(.separator())
        add("Open “\(name)” in New Tab", #selector(openPathItemInNewTab(_:)))
        add("Open “\(name)” in Other Pane", #selector(openPathItemInOtherPane(_:)))
        m.addItem(.separator())
        add("Reveal “\(name)” in Finder", #selector(revealPathItem(_:)))
        return m
    }
    private func pathItemURL(_ s: Any?) -> URL? { ((s as? NSMenuItem)?.representedObject as? String).map { URL(fileURLWithPath: $0) } }
    @objc private func copyPathItem(_ s: Any?) { if let u = pathItemURL(s) { copyToClipboard(u.path) } }
    @objc private func openPathItemInNewTab(_ s: Any?) { if let u = pathItemURL(s) { delegate?.paneRequestsNewTab(from: self, url: u, select: true) } }
    @objc private func openPathItemInOtherPane(_ s: Any?) { if let u = pathItemURL(s) { delegate?.paneRequestsOpenInOtherPane(from: self, url: u) } }
    @objc private func revealPathItem(_ s: Any?) { if let u = pathItemURL(s) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return canGoBack
        case #selector(goForward(_:)): return canGoForward
        default: return true
        }
    }

    // MARK: Loading, sorting, filtering
    func reload() { load() }

    private func load(selecting: [URL]? = nil, scrollTop: Bool = false) {
        let keep = selecting ?? selectedItems.map { $0.url }
        do {
            allItems = try FileItem.contents(of: directory, showHidden: Settings.showHidden)
            statusField.textColor = .secondaryLabelColor
        } catch {
            allItems = []
            statusField.textColor = .systemRed
        }
        applyFilter(keeping: keep)
        if scrollTop { tableView.scrollRowToVisible(0) }
        else if let r = tableView.selectedRowIndexes.first { tableView.scrollRowToVisible(r) }
        updateStatus()
    }

    func applyFilter(keeping: [URL]? = nil) {
        let keep = keeping ?? selectedItems.map { $0.url }
        items = shown(allItems)
        for it in allItems { refreshShownChildren(it) }
        restoringExpansion = true                      // a reload must not count as the user closing rows
        tableView.reloadData()
        restoreExpansion()
        var sel = IndexSet()
        for r in 0..<tableView.numberOfRows { if let u = fileItem(atRow: r)?.url, keep.contains(u) { sel.insert(r) } }
        if sel.isEmpty && tableView.numberOfRows > 0 && !filter.isEmpty { sel.insert(0) }
        tableView.selectRowIndexes(sel, byExtendingSelection: false)
        if let r = sel.first, !filter.isEmpty { tableView.scrollRowToVisible(r) }
    }

    /// One folder's listing as the pane shows it: the typed filter (names that contain the text
    /// anywhere, "pp" finds application_for_defence) and the sort order.
    private func shown(_ list: [FileItem]) -> [FileItem] {
        var l = list
        if !filter.isEmpty { l = l.filter { $0.name.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        return l.sorted(by: sortKey, ascending: sortAscending)
    }
    private func refreshShownChildren(_ item: FileItem) {
        guard let c = item.children else { return }
        item.shownChildren = shown(c)
        for x in c { refreshShownChildren(x) }
    }

    // MARK: Folder peek
    /// The rows under an opened folder row; the folder is listed the first time it is asked for.
    func children(of item: FileItem) -> [FileItem] {
        if item.children == nil {
            let folder = (item.folderURL ?? item.url).resolvingSymlinksInPath()
            let c = (try? FileItem.contents(of: folder, showHidden: Settings.showHidden)) ?? []
            item.children = c
            item.shownChildren = shown(c)
        }
        return item.shownChildren
    }
    func fileItem(atRow r: Int) -> FileItem? { r >= 0 && r < tableView.numberOfRows ? tableView.item(atRow: r) as? FileItem : nil }
    func row(of url: URL) -> Int? { (0..<tableView.numberOfRows).first { fileItem(atRow: $0)?.url == url } }

    /// After a reload the rows are new objects and the outline view shows them all closed: open again
    /// every folder row that was open, nested ones after their parent.
    private func restoreExpansion() {
        func open(_ list: [FileItem]) {
            for it in list where expanded.contains(it.url) {
                tableView.expandItem(it)
                open(it.shownChildren)
            }
        }
        if !expanded.isEmpty { open(items) }
        restoringExpansion = false
        syncSubWatchers()
    }

    /// One directory watcher per open folder row, so changes inside it show up like those in the pane's own folder.
    func syncSubWatchers() {
        var want = Set<URL>()
        for r in 0..<tableView.numberOfRows {
            if let it = fileItem(atRow: r), tableView.isItemExpanded(it), let f = it.folderURL { want.insert(f.resolvingSymlinksInPath()) }
        }
        for (u, src) in subWatchers where !want.contains(u) { src.cancel(); subWatchers[u] = nil }
        for u in want where subWatchers[u] == nil { subWatchers[u] = makeWatcher(u) { [weak self] in self?.scheduleReload() } }
    }

    func updateStatus() {
        let sel = selectedItems
        let folders = items.filter { $0.isDirectory }.count
        var s = "\(items.count) item\(items.count == 1 ? "" : "s")"
        if folders > 0 { s += " (\(folders) folder\(folders == 1 ? "" : "s"))" }
        if !sel.isEmpty {
            let bytes = sel.reduce(Int64(0)) { $0 + max($1.size, 0) }
            s += "  •  \(sel.count) selected"
            if bytes > 0 { s += ", " + FileItem.byteFormatter.string(fromByteCount: bytes) }
        }
        if filter.isEmpty && allItems.count != items.count { s += " of \(allItems.count)" }
        statusField.stringValue = s
        if filter.isEmpty {
            filterField.stringValue = ""
            bottomBar.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            filterField.stringValue = items.isEmpty ? "⌕ \(filter)  (no match)" : "⌕ \(filter)  \(items.count)/\(allItems.count)"
            filterField.textColor = items.isEmpty ? .systemRed : .labelColor
            bottomBar.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
        }
    }

    func clearFilter() { if !filter.isEmpty { filter = "" } }

    // MARK: Selection helpers
    var selectedItems: [FileItem] { tableView.selectedRowIndexes.compactMap { fileItem(atRow: $0) } }
    var selectedURLs: [URL] { selectedItems.map { $0.url } }
    func quickLookURLs() -> [URL] { selectedURLs }

    func select(urls: [URL]) {
        var sel = IndexSet()
        for r in 0..<tableView.numberOfRows { if let u = fileItem(atRow: r)?.url, urls.contains(u) { sel.insert(r) } }
        tableView.selectRowIndexes(sel, byExtendingSelection: false)
        if let r = sel.first { tableView.scrollRowToVisible(r) }
    }
    /// Selects these items when they are in the list; after a drop into a folder that is not open, nothing changes.
    func selectIfShown(_ urls: [URL]) {
        if urls.contains(where: { row(of: $0) != nil }) { select(urls: urls) }
    }

    func focus() { view.window?.makeFirstResponder(tableView) }
    func becameActive() { delegate?.paneDidBecomeActive(self) }

    // MARK: Opening
    @objc func openSelected() {
        let sel = selectedItems
        if sel.count == 1, sel[0].opensAsFolder { navigate(to: sel[0].url); return }
        let files = sel.filter { !$0.opensAsFolder }
        if files.isEmpty, let d = sel.first(where: { $0.opensAsFolder }) { navigate(to: d.url); return }
        for f in files { NSWorkspace.shared.open(f.url) }
    }

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) }
        else if !selectedItems.isEmpty { panel.makeKeyAndOrderFront(nil) }
    }

    // MARK: Keys
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command), ctrl = mods.contains(.control)
        let optOnly = mods.intersection([.command, .shift, .option, .control]) == .option
        if renamingRow >= 0 { return false }
        switch event.keyCode {
        case 123 where optOnly: delegate?.paneRequestsShowFolder(from: self, toRight: false); return true   // ⌥←
        case 124 where optOnly: delegate?.paneRequestsShowFolder(from: self, toRight: true); return true    // ⌥→
        case 36, 76:                                   // Return / Enter
            if cmd { renameSelected(nil) } else { openSelected() }
            return true
        case 48:                                       // Tab
            delegate?.paneRequestsSwitch(from: self); return true
        case 53:                                       // Escape
            if !filter.isEmpty { filter = "" } else { tableView.deselectAll(nil) }
            return true
        case 51, 117:                                  // Backspace / Forward delete
            if cmd { return false }
            if !filter.isEmpty { filter.removeLast(); return true }
            if event.keyCode == 51 { goUp(); return true }
            return false
        case 49:                                       // Space
            toggleQuickLook(); return true
        case 126 where cmd: goUp(); return true
        case 125 where cmd: openSelected(); return true
        case 123, 124, 125, 126, 115, 119, 116, 121: return false
        default: break
        }
        if cmd || ctrl { return false }
        guard let chars = event.characters, !chars.isEmpty else { return false }
        let printable = chars.unicodeScalars.allSatisfy { s in
            !CharacterSet.controlCharacters.contains(s) && !CharacterSet.illegalCharacters.contains(s) && !(0xF700...0xF8FF).contains(s.value)
        }
        guard printable else { return false }
        filter += chars
        return true
    }

    // MARK: Directory watching
    private func startWatching() {
        stopWatching()
        watcher = makeWatcher(directory) { [weak self] in self?.directoryEvent() }
    }
    private func stopWatching() {
        watcher?.cancel(); watcher = nil
        for (_, src) in subWatchers { src.cancel() }
        subWatchers = [:]
    }
    private func makeWatcher(_ url: URL, handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib, .link], queue: .main)
        src.setEventHandler(handler: handler)
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    private func directoryEvent() {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) || !isDir.boolValue {
            var u = directory
            while u.path != "/" && !FileManager.default.fileExists(atPath: u.path) { u = u.deletingLastPathComponent() }
            navigate(to: u, recordHistory: false)
            return
        }
        scheduleReload()
    }

    func scheduleReload() {
        reloadTimer?.invalidate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self = self, self.renamingRow < 0 else { return }
            self.load()
        }
    }

    deinit { stopWatching(); NotificationCenter.default.removeObserver(self) }
}

/// Path control that reports clicks on its empty area (used to open the path editor)
/// and asks its owner for the context menu of the crumb under the mouse.
final class PathBar: NSPathControl {
    var onEmptyClick: (() -> Void)?
    var menuProvider: ((URL?) -> NSMenu?)?

    private func hitURL(_ event: NSEvent) -> URL? {
        let p = convert(event.locationInWindow, from: nil)
        return (cell as? NSPathCell)?.pathComponentCell(at: p, withFrame: bounds, in: self)?.url
    }
    override func mouseDown(with event: NSEvent) {
        if hitURL(event) == nil { onEmptyClick?(); return }
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(hitURL(event)) ?? super.menu(for: event)
    }
}

/// Root view of a pane; re-tints layer colours when light/dark mode changes.
final class PaneRootView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearanceChange?() }
}
