import AppKit

/// Main window: toolbar, sidebar, quick-access row and two tabbed panes.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSplitViewDelegate,
                                  PaneDelegate, SidebarDelegate, QuickAccessDelegate, NSMenuItemValidation {
    let splitVC = NSSplitViewController()
    let sidebar = SidebarController()
    let content = NSViewController()
    let quickBar = QuickAccessBar()
    let panesSplit = NSSplitView()
    let left = PaneContainer(side: "left")
    let right = PaneContainer(side: "right")
    private(set) var activeContainer: PaneContainer
    var otherContainer: PaneContainer { activeContainer === left ? right : left }
    var activePane: PaneController { activeContainer.current }
    var otherPane: PaneController { otherContainer.current }

    init() {
        activeContainer = left
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1250, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "DualPane"
        w.minSize = NSSize(width: 640, height: 320)
        w.tabbingMode = .disallowed
        w.toolbarStyle = .unified
        w.titleVisibility = .visible
        super.init(window: w)
        w.delegate = self

        // Content: quick-access row above the two panes.
        let cv = NSView(); cv.translatesAutoresizingMaskIntoConstraints = false
        panesSplit.translatesAutoresizingMaskIntoConstraints = false
        panesSplit.isVertical = true
        panesSplit.dividerStyle = .thin
        panesSplit.delegate = self
        panesSplit.addArrangedSubview(left.view)
        panesSplit.addArrangedSubview(right.view)
        cv.addSubview(quickBar); cv.addSubview(panesSplit)
        NSLayoutConstraint.activate([
            quickBar.topAnchor.constraint(equalTo: cv.safeAreaLayoutGuide.topAnchor), quickBar.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            quickBar.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            panesSplit.topAnchor.constraint(equalTo: quickBar.bottomAnchor), panesSplit.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            panesSplit.trailingAnchor.constraint(equalTo: cv.trailingAnchor), panesSplit.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])
        content.view = cv
        quickBar.delegate = self

        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 160
        sideItem.maximumThickness = 360
        sideItem.canCollapse = true
        sideItem.preferredThicknessFraction = 0.19
        sideItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings
        let mainItem = NSSplitViewItem(viewController: content)
        mainItem.minimumThickness = 480
        splitVC.addSplitViewItem(sideItem)
        splitVC.addSplitViewItem(mainItem)
        splitVC.splitView.autosaveName = "MainSidebarSplit"
        w.contentViewController = splitVC
        sidebar.delegate = self

        left.delegate = self; right.delegate = self
        left.isActive = true
        w.setFrameAutosaveName("MainWindow")
        panesSplit.autosaveName = "MainSplit"

        let tb = NSToolbar(identifier: "MainToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        w.toolbar = tb

        if UserDefaults.standard.bool(forKey: "sidebarCollapsed") { sideItem.isCollapsed = true }
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: splitVC.splitView, queue: .main) { _ in
            UserDefaults.standard.set(sideItem.isCollapsed, forKey: "sidebarCollapsed")
        }
        if let hidden = UserDefaults.standard.string(forKey: "hiddenSide") {
            (hidden == "left" ? left : right).view.removeFromSuperview()
            if hidden == "left" { setActive(right) }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainSplit") == nil {
                self.panesSplit.setPosition(self.panesSplit.bounds.width / 2, ofDividerAt: 0)
            }
            self.activePane.focus()
            self.updateTitle()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        if let item = splitVC.splitViewItems.first { UserDefaults.standard.set(item.isCollapsed, forKey: "sidebarCollapsed") }
    }

    // MARK: Toolbar
    private let backID = NSToolbarItem.Identifier("back")
    private let forwardID = NSToolbarItem.Identifier("forward")
    private let newFolderID = NSToolbarItem.Identifier("newFolder")
    private let newTabID = NSToolbarItem.Identifier("newTab")
    private let terminalID = NSToolbarItem.Identifier("terminal")
    private let secondPaneID = NSToolbarItem.Identifier("secondPane")
    private let hiddenID = NSToolbarItem.Identifier("hiddenFiles")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, backID, forwardID, .flexibleSpace, newTabID, newFolderID, terminalID, hiddenID, secondPaneID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func make(_ symbol: String, _ label: String, _ action: Selector, tip: String) -> NSToolbarItem {
            let i = NSToolbarItem(itemIdentifier: id)
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            i.label = label; i.paletteLabel = label; i.toolTip = tip
            i.action = action; i.target = nil
            i.isBordered = true
            return i
        }
        switch id {
        case backID:
            let i = make("chevron.left", "Back", #selector(PaneController.goBack(_:)), tip: "Back (⌘[)"); i.isNavigational = true; return i
        case forwardID:
            let i = make("chevron.right", "Forward", #selector(PaneController.goForward(_:)), tip: "Forward (⌘])"); i.isNavigational = true; return i
        case newFolderID: return make("folder.badge.plus", "New Folder", #selector(PaneController.newFolder(_:)), tip: "New Folder (F7, ⌘⇧N)")
        case newTabID: return make("plus.rectangle.on.rectangle", "New Tab", #selector(newTab(_:)), tip: "New Tab (⌘T)")
        case terminalID:
            let term = FileOps.terminalApp.name
            return make("apple.terminal", term, #selector(PaneController.openFolderInTerminal(_:)), tip: "Open this folder in \(term)")
        case hiddenID: return make("eye", "Hidden Files", #selector(toggleHidden(_:)), tip: "Show/hide hidden files (⌘⇧.)")
        case secondPaneID: return make("rectangle.split.2x1", "Second Pane", #selector(toggleSecondPane(_:)), tip: "Show/hide the second pane (⌘⇧P)")
        default: return nil
        }
    }

    // MARK: Active pane
    private func setActive(_ c: PaneContainer) {
        guard c !== activeContainer else { return }
        activeContainer.isActive = false
        activeContainer = c
        c.isActive = true
        updateTitle()
    }

    func paneDidBecomeActive(_ pane: PaneController) {
        setActive(left.tabs.contains { $0 === pane } ? left : right)
    }

    func paneRequestsSwitch(from pane: PaneController) {
        let target = otherContainer
        if target.isDetached { return }
        target.current.focus()
    }

    func paneDirectoryChanged(_ pane: PaneController) {
        if pane === activePane { updateTitle() }
    }

    func paneRequestsNewTab(from pane: PaneController, url: URL, select: Bool) {
        (left.tabs.contains { $0 === pane } ? left : right).newTab(at: url, select: select)
    }

    func paneRequestsOpenInOtherPane(from pane: PaneController, url: URL) {
        let c = left.tabs.contains { $0 === pane } ? right : left
        if c.isDetached { attach(c) }
        c.current.navigate(to: url)
    }

    /// ⌥→ in the left pane shows its folder in the right pane, ⌥← in the right pane shows it in the left.
    /// Nothing happens in the other direction or while the second pane is hidden.
    func paneRequestsShowFolder(from pane: PaneController, toRight: Bool) {
        let fromLeft = left.tabs.contains { $0 === pane }
        guard fromLeft == toRight else { return }
        let target = fromLeft ? right : left
        guard !target.isDetached else { return }
        target.current.navigate(to: pane.directory)
    }

    private func updateTitle() {
        let d = activePane.directory
        window?.title = d.path == "/" ? "Macintosh HD" : d.lastPathComponent
        window?.subtitle = (d.path as NSString).abbreviatingWithTildeInPath
        window?.representedURL = d
        sidebar.highlight(d)
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: Sidebar & quick access
    func sidebarDidSelect(_ url: URL, inNewTab: Bool) {
        if inNewTab { activeContainer.newTab(at: url) } else { activePane.navigate(to: url) }
        activePane.focus()
    }
    func sidebarOpenInOtherPane(_ url: URL) { paneRequestsOpenInOtherPane(from: activePane, url: url) }
    func quickAccessDidSelect(_ url: URL, inNewTab: Bool) { sidebarDidSelect(url, inNewTab: inNewTab) }
    func quickAccessCurrentDirectory() -> URL { activePane.directory }

    func splitView(_ sv: NSSplitView, constrainMinCoordinate min: CGFloat, ofSubviewAt i: Int) -> CGFloat { 240 }
    func splitView(_ sv: NSSplitView, constrainMaxCoordinate max: CGFloat, ofSubviewAt i: Int) -> CGFloat { sv.bounds.width - 240 }

    // MARK: Tabs
    @objc func newTab(_ s: Any?) { activeContainer.newTab(); activePane.focus() }
    @objc func closeTab(_ s: Any?) {
        if activeContainer.tabs.count > 1 { activeContainer.closeTab(at: activeContainer.selectedIndex) }
        else { window?.performClose(nil) }
    }
    @objc func nextTab(_ s: Any?) { activeContainer.nextTab() }
    @objc func previousTab(_ s: Any?) { activeContainer.previousTab() }
    @objc func selectTabByNumber(_ s: NSMenuItem) { activeContainer.selectTab(s.tag - 1) }

    // MARK: Cross-pane operations
    @objc func copyToOtherPane(_ s: Any?) { transferToOtherPane(move: false) }
    @objc func moveToOtherPane(_ s: Any?) { transferToOtherPane(move: true) }

    private func transferToOtherPane(move: Bool) {
        let src = activePane, dst = otherPane
        let urls = src.selectedURLs
        guard !urls.isEmpty else { return }
        if otherContainer.isDetached {
            FileOps.alert("The other pane is hidden. Show it first (⌘⇧P).", window: window); return
        }
        FileOps.transfer(urls, to: dst.directory, move: move, window: window) { done in
            src.reload()
            dst.reloadKeeping(done)
        }
    }

    @objc func swapPanes(_ s: Any?) {
        let l = left.current.directory, r = right.current.directory
        left.current.navigate(to: r); right.current.navigate(to: l)
    }

    @objc func mirrorToOtherPane(_ s: Any?) { paneRequestsOpenInOtherPane(from: activePane, url: activePane.directory) }
    @objc func switchPane(_ s: Any?) { paneRequestsSwitch(from: activePane) }

    /// The second pane is hidden by taking it out of the split view entirely (a hidden arranged subview
    /// leaves a stale divider behind).
    private func attach(_ c: PaneContainer) {
        guard c.isDetached else { return }
        panesSplit.insertArrangedSubview(c.view, at: c === left ? 0 : 1)
        // The pane comes back at the width it had when hidden; if the window has grown since, the
        // two panes no longer fill the split view (a dark strip on the right) until they are refitted.
        panesSplit.adjustSubviews()
        panesSplit.setPosition(panesSplit.bounds.width / 2, ofDividerAt: 0)
        UserDefaults.standard.removeObject(forKey: "hiddenSide")
    }
    private func detach(_ c: PaneContainer) {
        guard !c.isDetached else { return }
        c.view.removeFromSuperview()
        panesSplit.adjustSubviews()
        UserDefaults.standard.set(c.side, forKey: "hiddenSide")
    }

    @objc func toggleSecondPane(_ s: Any?) {
        let other = otherContainer
        if other.isDetached { attach(other) } else { detach(other) }
        activePane.focus()
    }

    @objc func toggleHidden(_ s: Any?) { Settings.showHidden.toggle() }

    // MARK: Go
    private func go(_ path: String) {
        activePane.navigate(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        activePane.focus()
    }
    @objc func goHome(_ s: Any?) { go(NSHomeDirectory()) }
    @objc func goDesktop(_ s: Any?) { go("~/Desktop") }
    @objc func goDocuments(_ s: Any?) { go("~/Documents") }
    @objc func goDownloads(_ s: Any?) { go("~/Downloads") }
    @objc func goApplications(_ s: Any?) { go("/Applications") }
    @objc func goComputer(_ s: Any?) { go("/Volumes") }
    @objc func goRoot(_ s: Any?) { go("/") }
    @objc func goFavorite(_ s: NSMenuItem) { if let p = s.representedObject as? String { go(p) } }

    @objc func goToFolder(_ s: Any?) {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Go to the folder:"
        a.addButton(withTitle: "Go"); a.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        tf.stringValue = (activePane.directory.path as NSString).abbreviatingWithTildeInPath
        tf.placeholderString = "~/Documents"
        a.accessoryView = tf
        a.window.initialFirstResponder = tf
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self = self else { return }
            let p = (tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
                self.go(isDir.boolValue ? p : (p as NSString).deletingLastPathComponent)
            } else {
                FileOps.alert("The folder “\(tf.stringValue)” can’t be found.", window: w)
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            return !activePane.selectedItems.isEmpty && !otherContainer.isDetached
        case #selector(toggleHidden(_:)):
            item.state = Settings.showHidden ? .on : .off
            return true
        case #selector(toggleSecondPane(_:)):
            item.title = otherContainer.isDetached ? "Show Second Pane" : "Hide Second Pane"
            return true
        case #selector(closeTab(_:)):
            item.title = activeContainer.tabs.count > 1 ? "Close Tab" : "Close Window"
            return true
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return activeContainer.tabs.count > 1
        case #selector(selectTabByNumber(_:)):
            return item.tag <= activeContainer.tabs.count
        case #selector(swapPanes(_:)), #selector(mirrorToOtherPane(_:)), #selector(switchPane(_:)):
            return !otherContainer.isDetached
        default: return true
        }
    }

    func open(url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue { activePane.navigate(to: url) }
        else { activePane.navigate(to: url.deletingLastPathComponent(), select: url) }
        activePane.focus()
    }
}
