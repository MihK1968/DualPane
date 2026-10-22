import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var mainController: MainWindowController!

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: ["showHidden": true])   // hidden files are shown unless turned off (⌘⇧.)
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        mainController = MainWindowController()
        DefaultFolderX.openFolders = { [weak self] in
            guard let mc = self?.mainController else { return [] }
            return (mc.left.tabs + mc.right.tabs).map { $0.directory }
        }
        mainController.showWindow(nil)
        mainController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Command line: DualPane /some/path
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
            mainController.open(url: URL(fileURLWithPath: (arg as NSString).expandingTildeInPath))
        }
        for u in pendingURLs { mainController.open(url: u) }
        pendingURLs = []
        // Self-test hook: DUALPANE_SNAPSHOT=/path.png [DUALPANE_TYPE=letters] renders the window to a PNG and quits.
        if let snap = ProcessInfo.processInfo.environment["DUALPANE_SNAPSHOT"] {
            let typed = ProcessInfo.processInfo.environment["DUALPANE_TYPE"] ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                for name in (ProcessInfo.processInfo.environment["DUALPANE_ACTIONS"] ?? "").split(separator: ",") where !name.isEmpty {
                    let sel = NSSelectorFromString(String(name))
                    var r: NSResponder? = self.mainController.window?.firstResponder ?? self.mainController.window
                    while let x = r { if x.responds(to: sel) { _ = x.perform(sel, with: nil); break }; r = x.nextResponder }
                }
                for ch in typed {
                    let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: self.mainController.window!.windowNumber,
                                              context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0)!
                    self.mainController.activePane.tableView.keyDown(with: ev)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let w = self.mainController.window, let v = w.contentView?.superview,
                       let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        w.layoutIfNeeded(); v.layoutSubtreeIfNeeded(); w.displayIfNeeded()
                        v.cacheDisplay(in: v.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: snap)) }
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Items handed over by LaunchServices (`open -a DualPane …`, a double-clicked folder). At a cold
    /// launch they arrive before applicationDidFinishLaunching, when there is no window yet, so they
    /// wait here until it exists.
    private var pendingURLs: [URL] = []

    func application(_ app: NSApplication, open urls: [URL]) {
        guard let mc = mainController else { pendingURLs += urls; return }
        for u in urls { mc.open(url: u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { DefaultFolderX.withdrawAll() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainController?.showWindow(nil) }
        return true
    }

    // MARK: Menu
    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.tag = tag
        return i
    }
    private func fkey(_ n: Int) -> String {
        let codes = [1: NSF1FunctionKey, 2: NSF2FunctionKey, 3: NSF3FunctionKey, 4: NSF4FunctionKey, 5: NSF5FunctionKey,
                     6: NSF6FunctionKey, 7: NSF7FunctionKey, 8: NSF8FunctionKey, 9: NSF9FunctionKey, 10: NSF10FunctionKey]
        return String(Character(UnicodeScalar(codes[n]!)!))
    }
    private func special(_ k: Int) -> String { String(Character(UnicodeScalar(k)!)) }

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu(title: "DualPane")
        appMenu.addItem(item("About DualPane", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide DualPane", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit DualPane", #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(submenu(appMenu))

        let file = NSMenu(title: "File")
        file.addItem(item("Open", #selector(PaneController.openAction(_:)), "o"))
        let openAlt = item("Open", #selector(PaneController.openAction(_:)), special(NSDownArrowFunctionKey)); openAlt.isAlternate = false
        file.addItem(openAlt)
        let openWith = item("Open With", nil)
        openWith.submenu = NSMenu(title: "Open With")
        openWith.submenu?.delegate = self            // filled from the active pane's selection when it opens
        file.addItem(openWith)
        file.addItem(item("Open in New Tab", #selector(PaneController.openInNewTab(_:)), "o", [.command, .control]))
        file.addItem(item("Open in Other Pane", #selector(PaneController.openInOtherPane(_:)), "o", [.command, .shift, .option]))
        file.addItem(item("Quick Look", #selector(PaneController.quickLook(_:)), "y"))
        file.addItem(item("Show Package Contents", #selector(PaneController.showPackageContents(_:))))
        file.addItem(.separator())
        file.addItem(item("New Folder", #selector(PaneController.newFolder(_:)), fkey(7), []))
        file.addItem(item("New Folder", #selector(PaneController.newFolder(_:)), "n", [.command, .shift]))
        file.addItem(item("New File", #selector(PaneController.newFile(_:)), "n", [.command, .option]))
        file.addItem(item("Rename", #selector(PaneController.renameSelected(_:)), fkey(2), []))
        file.addItem(item("Duplicate", #selector(PaneController.duplicate(_:)), "d"))
        file.addItem(.separator())
        file.addItem(item("Copy to Other Pane", #selector(MainWindowController.copyToOtherPane(_:)), fkey(5), []))
        file.addItem(item("Move to Other Pane", #selector(MainWindowController.moveToOtherPane(_:)), fkey(6), []))
        file.addItem(.separator())
        file.addItem(item("Move to Trash", #selector(PaneController.moveToTrash(_:)), special(NSBackspaceCharacter)))
        file.addItem(item("Move to Trash", #selector(PaneController.moveToTrash(_:)), fkey(8), []))
        file.addItem(.separator())
        file.addItem(item("Get Info", #selector(PaneController.getInfo(_:)), "i"))
        file.addItem(item("Reveal in Finder", #selector(PaneController.revealInFinder(_:)), "f", [.command, .shift]))
        file.addItem(item("Open in Terminal", #selector(PaneController.openInTerminal(_:)), "t", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item("New Tab", #selector(MainWindowController.newTab(_:)), "t"))
        file.addItem(item("Close Tab", #selector(MainWindowController.closeTab(_:)), "w"))
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Add to Sidebar", #selector(PaneController.addToFavorites(_:)), "t", [.command, .control]))
        file.addItem(item("Add to Quick Access", #selector(PaneController.addToQuickAccess(_:))))
        main.addItem(submenu(file))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste Items", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Move Items Here", #selector(PaneController.moveHere(_:)), "v", [.command, .option]))
        edit.addItem(item("Copy Path", #selector(PaneController.copyPath(_:)), "c", [.command, .option]))
        edit.addItem(.separator())
        edit.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        main.addItem(submenu(edit))

        let view = NSMenu(title: "View")
        view.addItem(item("Show Hidden Files", #selector(MainWindowController.toggleHidden(_:)), ".", [.command, .shift]))
        view.addItem(item("Refresh", #selector(PaneController.refresh(_:)), "r"))
        view.addItem(item("All Files in Subfolders", #selector(PaneController.toggleBranchView(_:)), "b"))
        view.addItem(.separator())
        view.addItem(item("Switch Pane", #selector(MainWindowController.switchPane(_:)), "\t", []))
        view.addItem(item("Swap Panes", #selector(MainWindowController.swapPanes(_:)), "u"))
        view.addItem(item("Same Folder in Other Pane", #selector(MainWindowController.mirrorToOtherPane(_:)), "e"))
        view.addItem(item("Hide Second Pane", #selector(MainWindowController.toggleSecondPane(_:)), "p", [.command, .shift]))
        view.addItem(item("Show/Hide Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .option]))
        view.addItem(.separator())
        view.addItem(item("Next Tab", #selector(MainWindowController.nextTab(_:)), "\t", [.control]))
        view.addItem(item("Previous Tab", #selector(MainWindowController.previousTab(_:)), "\t", [.control, .shift]))
        for n in 1...9 { let i = item("Tab \(n)", #selector(MainWindowController.selectTabByNumber(_:)), "\(n)"); i.tag = n; view.addItem(i) }
        main.addItem(submenu(view))

        let go = NSMenu(title: "Go")
        go.addItem(item("Back", #selector(PaneController.goBack(_:)), "["))
        go.addItem(item("Forward", #selector(PaneController.goForward(_:)), "]"))
        go.addItem(item("Enclosing Folder", #selector(PaneController.goUp(_:)), special(NSUpArrowFunctionKey)))
        go.addItem(.separator())
        go.addItem(item("Home", #selector(MainWindowController.goHome(_:)), "h", [.command, .shift]))
        go.addItem(item("Desktop", #selector(MainWindowController.goDesktop(_:)), "d", [.command, .shift]))
        go.addItem(item("Documents", #selector(MainWindowController.goDocuments(_:)), "o", [.command, .shift]))
        go.addItem(item("Downloads", #selector(MainWindowController.goDownloads(_:)), "l", [.command, .option]))
        go.addItem(item("Applications", #selector(MainWindowController.goApplications(_:)), "a", [.command, .shift]))
        go.addItem(item("Volumes", #selector(MainWindowController.goComputer(_:)), "c", [.command, .shift]))
        go.addItem(item("Macintosh HD", #selector(MainWindowController.goRoot(_:)), "/", [.command, .shift]))
        go.addItem(.separator())
        let favItem = item("Favorites", nil)
        favMenu = NSMenu(title: "Favorites")
        favItem.submenu = favMenu
        go.addItem(favItem)
        rebuildFavoritesMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildFavoritesMenu), name: Favorites.changed, object: nil)
        go.addItem(.separator())
        go.addItem(item("Go to Folder…", #selector(MainWindowController.goToFolder(_:)), "g", [.command, .shift]))
        go.addItem(item("Edit Path", #selector(PaneController.editPath(_:)), "l"))
        main.addItem(submenu(go))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        main.addItem(submenu(windowMenu))
        NSApp.windowsMenu = windowMenu

        let help = NSMenu(title: "Help")
        help.addItem(item("Keyboard Shortcuts", #selector(AppDelegate.showHelp(_:)), "?"))
        main.addItem(submenu(help))
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open With", let pane = mainController?.activePane else { return }
        PaneController.populateOpenWith(menu, urls: pane.selectedURLs, target: pane)
        if let other = menu.items.last, other.title == "Other…" { other.keyEquivalent = "o"; other.keyEquivalentModifierMask = [.command, .option] }
    }

    private var favMenu: NSMenu!
    @objc private func rebuildFavoritesMenu() {
        favMenu.removeAllItems()
        for e in Favorites.shared.sidebar {
            guard let u = e.url else { favMenu.addItem(.separator()); continue }
            let i = item(Favorites.displayName(for: u), #selector(MainWindowController.goFavorite(_:)))
            i.representedObject = u.path
            i.image = Favorites.icon(for: u)
            i.indentationLevel = e.depth
            favMenu.addItem(i)
        }
    }

    private func submenu(_ m: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
        i.submenu = m
        return i
    }

    @objc func showHelp(_ s: Any?) {
        let a = NSAlert()
        a.messageText = "DualPane keyboard shortcuts"
        a.informativeText = """
        Type letters        narrow the list to names containing what you typed
        Backspace           delete last filter letter, or go to parent folder
        Esc                 clear filter / deselect
        Return / ⌘↓         open selected (folders are entered)
        ⌘↑                  enclosing folder          ⌘[ / ⌘]   back / forward
        Tab                 switch pane               ⌘E         same folder in other pane
        ⌘T / ⌘W             new tab / close tab       ⌃Tab, ⌘1…9 switch tabs
        ⌘⌥S                 show/hide sidebar         ⌘⇧P        show/hide second pane
        ⌘^T                 add folder to sidebar     ⌘^O        open folder in new tab
        Space / ⌘Y          Quick Look                ⌘U         swap panes
        ⌘B                  all files in all subfolders in one list, so typing searches them all (again: back)
        F5 / F6             copy / move to other pane
        F7 / ⌘⇧N            new folder                F2 / ⌘Return  rename (or click the name of the selected item and wait)
        F8 / ⌘⌫             move to Trash             ⌘D         duplicate
        ⌘C / ⌘V / ⌘⌥V       copy / paste / move items here
        ⌘⌥C                 copy path(s); the folder path when nothing is selected
        ⌘L / click path bar edit the path as text (⌘C copies it, Return goes there, Esc cancels)
        ⌘⇧.                 show hidden files (on by default)   ⌘⇧G  go to folder
        ⌘⇧F / ⌘I            reveal in Finder / Get Info
        ⌘⌥T                 open the selected folder (else this one) in iTerm, or Terminal if iTerm is not installed
        Drag & drop         same disk moves, other disk copies, ⌥ forces copy;
                            Mail attachments, Photos and browser images are received as copies
        Finder aliases      open their original folder; drag them into the sidebar to use as labels
        """
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
