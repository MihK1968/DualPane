import AppKit

/// Holds the tabs of one pane. Each tab is a PaneController; the tab bar sits above the current one.
final class PaneContainer: NSViewController, PaneDelegate, TabBarDelegate {
    let side: String
    weak var delegate: PaneDelegate?
    private(set) var tabs: [PaneController] = []
    private(set) var selectedIndex = 0
    var current: PaneController { tabs[selectedIndex] }
    /// True while this pane is removed from the window (second pane hidden).
    var isDetached: Bool { isViewLoaded && view.superview == nil }
    let tabBar = TabBarView()
    private let content = NSView()
    var isActive = false {
        didSet { current.isActive = isActive; tabBar.isActive = isActive }
    }

    init(side: String) {
        self.side = side
        super.init(nibName: nil, bundle: nil)
        let d = UserDefaults.standard
        var paths = d.stringArray(forKey: "tabs.\(side)") ?? []
        if paths.isEmpty, let legacy = d.string(forKey: "path.\(side)") { paths = [legacy] }
        if paths.isEmpty { paths = [NSHomeDirectory()] }
        for p in paths {
            let pc = PaneController(directory: URL(fileURLWithPath: p), side: side)
            pc.delegate = self
            tabs.append(pc)
        }
        selectedIndex = min(max(0, d.integer(forKey: "tabs.\(side).selected")), tabs.count - 1)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(); root.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar); root.addSubview(content)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor), tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor), tabBar.heightAnchor.constraint(equalToConstant: 26),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor), content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        view = root
        showCurrent()
    }

    private func showCurrent() {
        content.subviews.forEach { $0.removeFromSuperview() }
        let v = current.view
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: content.topAnchor), v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor), v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        current.isActive = isActive
        tabBar.reload(titles: tabs.map { $0.directory.path == "/" ? "Macintosh HD" : $0.directory.lastPathComponent }, selected: selectedIndex)
        save()
    }

    func save() {
        let d = UserDefaults.standard
        d.set(tabs.map { $0.directory.path }, forKey: "tabs.\(side)")
        d.set(selectedIndex, forKey: "tabs.\(side).selected")
        DefaultFolderX.scheduleSync()
    }

    // MARK: Tab operations
    @discardableResult
    func newTab(at url: URL? = nil, select: Bool = true) -> PaneController {
        let pc = PaneController(directory: url ?? current.directory, side: side)
        pc.delegate = self
        tabs.insert(pc, at: selectedIndex + 1)
        if select { selectTab(selectedIndex + 1) } else { showCurrent() }
        return pc
    }

    func closeTab(at i: Int) {
        guard tabs.count > 1, tabs.indices.contains(i) else { return }
        let wasActive = tabs[i].isActive
        tabs[i].isActive = false
        tabs.remove(at: i)
        if selectedIndex >= tabs.count { selectedIndex = tabs.count - 1 }
        else if i < selectedIndex { selectedIndex -= 1 }
        showCurrent()
        if wasActive || isActive { current.focus() }
        delegate?.paneDirectoryChanged(current)
    }

    func closeOtherTabs(except i: Int) {
        guard tabs.indices.contains(i) else { return }
        let keep = tabs[i]
        tabs.forEach { if $0 !== keep { $0.isActive = false } }
        tabs = [keep]; selectedIndex = 0
        showCurrent(); if isActive { current.focus() }
    }

    func selectTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        if i != selectedIndex { current.isActive = false; current.endRename(commit: true) }
        selectedIndex = i
        showCurrent()
        if isActive { current.focus() }
        delegate?.paneDirectoryChanged(current)
    }
    func nextTab() { selectTab((selectedIndex + 1) % tabs.count) }
    func previousTab() { selectTab((selectedIndex - 1 + tabs.count) % tabs.count) }
    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), from != to else { return }
        let t = tabs.remove(at: from)
        var dest = to; if from < to { dest -= 1 }
        dest = max(0, min(dest, tabs.count))
        tabs.insert(t, at: dest)
        selectedIndex = tabs.firstIndex { $0 === current } ?? dest
        showCurrent()
    }

    // MARK: TabBarDelegate
    func tabBarDidSelect(_ index: Int) { selectTab(index); current.focus() }
    func tabBarDidClose(_ index: Int) { closeTab(at: index) }
    func tabBarRequestsNewTab() { newTab(); current.focus() }
    func tabBarContextMenu(for index: Int?) -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ a: Selector, _ tag: Int) { let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; i.tag = tag; m.addItem(i) }
        add("New Tab", #selector(ctxNewTab(_:)), index ?? selectedIndex)
        if let i = index {
            add("Duplicate Tab", #selector(ctxDuplicate(_:)), i)
            add("Open in Other Pane", #selector(ctxOtherPane(_:)), i)
            m.addItem(.separator())
            add("Close Tab", #selector(ctxClose(_:)), i)
            add("Close Other Tabs", #selector(ctxCloseOthers(_:)), i)
        }
        return m
    }
    func tabBarDidReorder(from: Int, to: Int) { moveTab(from: from, to: to) }
    @objc private func ctxNewTab(_ s: NSMenuItem) { newTab(); current.focus() }
    @objc private func ctxDuplicate(_ s: NSMenuItem) { newTab(at: tabs[s.tag].directory); current.focus() }
    @objc private func ctxOtherPane(_ s: NSMenuItem) { delegate?.paneRequestsOpenInOtherPane(from: tabs[s.tag], url: tabs[s.tag].directory) }
    @objc private func ctxClose(_ s: NSMenuItem) { closeTab(at: s.tag) }
    @objc private func ctxCloseOthers(_ s: NSMenuItem) { closeOtherTabs(except: s.tag) }

    // MARK: PaneDelegate (forwarded to the window)
    func paneDidBecomeActive(_ pane: PaneController) { delegate?.paneDidBecomeActive(pane) }
    func paneRequestsSwitch(from pane: PaneController) { delegate?.paneRequestsSwitch(from: pane) }
    func paneDirectoryChanged(_ pane: PaneController) {
        tabBar.reload(titles: tabs.map { $0.directory.path == "/" ? "Macintosh HD" : $0.directory.lastPathComponent }, selected: selectedIndex)
        save()
        if pane === current { delegate?.paneDirectoryChanged(pane) }
    }
    func paneRequestsNewTab(from pane: PaneController, url: URL, select: Bool) { newTab(at: url, select: select); if select { current.focus() } }
    func paneRequestsOpenInOtherPane(from pane: PaneController, url: URL) { delegate?.paneRequestsOpenInOtherPane(from: pane, url: url) }
    func paneRequestsShowFolder(from pane: PaneController, toRight: Bool) { delegate?.paneRequestsShowFolder(from: pane, toRight: toRight) }
}

// MARK: - Tab bar

protocol TabBarDelegate: AnyObject {
    func tabBarDidSelect(_ index: Int)
    func tabBarDidClose(_ index: Int)
    func tabBarRequestsNewTab()
    func tabBarContextMenu(for index: Int?) -> NSMenu
    func tabBarDidReorder(from: Int, to: Int)
}

/// Simple drawn tab strip: click selects, middle-click or the × closes, double-click on empty space adds, drag reorders.
final class TabBarView: NSView {
    weak var delegate: TabBarDelegate?
    private var titles: [String] = []
    private var selected = 0
    private var hovered = -1
    private var tracking: NSTrackingArea?
    private let plusWidth: CGFloat = 26
    private var dragging: (index: Int, start: NSPoint, moved: Bool)?
    private var dropTarget = -1
    var isActive = false { didSet { needsDisplay = true } }

    func reload(titles: [String], selected: Int) {
        self.titles = titles; self.selected = selected
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    private func tabRect(_ i: Int) -> NSRect {
        let avail = bounds.width - plusWidth - 4
        let w = min(200, max(60, avail / CGFloat(max(titles.count, 1))))
        return NSRect(x: 2 + CGFloat(i) * w, y: 2, width: w - 2, height: bounds.height - 4)
    }
    private func closeRect(_ i: Int) -> NSRect {
        let r = tabRect(i); return NSRect(x: r.minX + 4, y: r.midY - 7, width: 14, height: 14)
    }
    private var plusRect: NSRect { NSRect(x: bounds.width - plusWidth, y: 2, width: plusWidth - 2, height: bounds.height - 4) }
    private func index(at p: NSPoint) -> Int? { (0..<titles.count).first { tabRect($0).contains(p) } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        for (i, t) in titles.enumerated() {
            let r = tabRect(i)
            let isSel = i == selected
            let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            if isSel {
                (isActive ? NSColor.controlAccentColor.withAlphaComponent(0.55) : NSColor.secondaryLabelColor.withAlphaComponent(0.25)).setFill()
                path.fill()
            } else if i == hovered {
                NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill(); path.fill()
            }
            if i > 0 && !isSel && i - 1 != selected {
                NSColor.separatorColor.setFill(); NSRect(x: r.minX - 1, y: r.minY + 4, width: 1, height: r.height - 8).fill()
            }
            let showClose = (i == hovered || (isSel && titles.count > 1)) && titles.count > 1
            var textRect = r.insetBy(dx: 8, dy: 0)
            if showClose { textRect.origin.x += 14; textRect.size.width -= 14 }
            let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingMiddle
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
            let h = font.ascender - font.descender
            let tr = NSRect(x: textRect.minX, y: r.midY - h / 2 - 1, width: textRect.width, height: h + 2)
            (t as NSString).draw(in: tr, withAttributes: attrs)
            if showClose, let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") {
                let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                let x = img.withSymbolConfiguration(cfg) ?? img
                let cr = closeRect(i)
                x.draw(in: NSRect(x: cr.midX - 4, y: cr.midY - 4, width: 8, height: 8), from: .zero, operation: .sourceOver, fraction: 0.8)
            }
            if dropTarget == i { NSColor.controlAccentColor.setFill(); NSRect(x: r.minX - 2, y: r.minY, width: 2, height: r.height).fill() }
        }
        if dropTarget == titles.count, let last = titles.indices.last {
            let r = tabRect(last); NSColor.controlAccentColor.setFill(); NSRect(x: r.maxX, y: r.minY, width: 2, height: r.height).fill()
        }
        if let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab") {
            let pr = plusRect
            plus.draw(in: NSRect(x: pr.midX - 5, y: pr.midY - 5, width: 10, height: 10), from: .zero, operation: .sourceOver, fraction: 0.7)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = index(at: p) ?? -1
        if h != hovered { hovered = h; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hovered = -1; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if plusRect.contains(p) { delegate?.tabBarRequestsNewTab(); return }
        if event.clickCount == 2, index(at: p) == nil { delegate?.tabBarRequestsNewTab(); return }
        guard let i = index(at: p) else { return }
        if titles.count > 1 && closeRect(i).contains(p) { delegate?.tabBarDidClose(i); return }
        dragging = (i, p, false)
        if i != selected { delegate?.tabBarDidSelect(i) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard var d = dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        if abs(p.x - d.start.x) > 6 { d.moved = true }
        dragging = d
        guard d.moved else { return }
        var t = titles.count
        for i in 0..<titles.count { let r = tabRect(i); if p.x < r.midX { t = i; break } }
        if t != dropTarget { dropTarget = t; needsDisplay = true }
    }
    override func mouseUp(with event: NSEvent) {
        if let d = dragging, d.moved, dropTarget >= 0 { delegate?.tabBarDidReorder(from: d.index, to: dropTarget) }
        dragging = nil; dropTarget = -1; needsDisplay = true
    }
    override func otherMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.buttonNumber == 2, let i = index(at: p) { delegate?.tabBarDidClose(i) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        return delegate?.tabBarContextMenu(for: index(at: p))
    }
}
