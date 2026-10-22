import AppKit

protocol QuickAccessDelegate: AnyObject {
    func quickAccessDidSelect(_ url: URL, inNewTab: Bool)
    func quickAccessCurrentDirectory() -> URL
}

/// Row of favourite-folder buttons under the toolbar (Path Finder style). Click to go, ⌘-click for a new tab.
/// Drop folders on it to add them; right-click to remove or add the current folder.
final class QuickAccessBar: NSView {
    weak var delegate: QuickAccessDelegate?
    private let stack = NSStackView()
    private var buttons: [NSButton] = []
    private var dropHighlight = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        registerForDraggedTypes([.fileURL])
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: Favorites.changed, object: nil)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func rebuild() {
        buttons.forEach { stack.removeView($0) }
        buttons.removeAll()
        let home = NSButton(image: NSImage(systemSymbolName: "house.fill", accessibilityDescription: "Home")!, target: self, action: #selector(tapped(_:)))
        style(home); home.tag = -1
        home.toolTip = NSHomeDirectory()
        stack.addView(home, in: .leading); buttons.append(home)
        for (i, u) in Favorites.shared.quick.enumerated() {
            let b = NSButton(title: Favorites.displayName(for: u), target: self, action: #selector(tapped(_:)))
            style(b); b.tag = i
            b.toolTip = u.path
            b.lineBreakMode = .byTruncatingMiddle
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
            stack.addView(b, in: .leading); buttons.append(b)
        }
    }

    private func style(_ b: NSButton) {
        b.bezelStyle = .recessed
        b.setButtonType(.momentaryPushIn)
        b.showsBorderOnlyWhileMouseInside = true
        b.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @objc private func tapped(_ sender: NSButton) {
        let url = sender.tag < 0 ? URL(fileURLWithPath: NSHomeDirectory()) : Favorites.shared.quick[safe: sender.tag]
        guard let u = url else { return }
        let newTab = NSEvent.modifierFlags.contains(.command) || NSEvent.pressedMouseButtons & 4 != 0
        delegate?.quickAccessDidSelect(u, inNewTab: newTab)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        if dropHighlight { NSColor.controlAccentColor.withAlphaComponent(0.15).setFill(); bounds.fill() }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    // MARK: Context menu
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let p = convert(event.locationInWindow, from: nil)
        if let b = buttons.first(where: { $0.frame.contains(stack.convert(p, from: self)) && $0.tag >= 0 }) {
            let i = NSMenuItem(title: "Remove “\(b.title)” from Quick Access", action: #selector(removeItem(_:)), keyEquivalent: "")
            i.target = self; i.tag = b.tag; m.addItem(i)
            m.addItem(.separator())
        }
        let a = NSMenuItem(title: "Add Current Folder to Quick Access", action: #selector(addCurrent(_:)), keyEquivalent: "")
        a.target = self; m.addItem(a)
        return m
    }
    @objc private func removeItem(_ s: NSMenuItem) { Favorites.shared.removeQuick(at: s.tag) }
    @objc private func addCurrent(_ s: Any?) { if let d = delegate?.quickAccessCurrentDirectory() { Favorites.shared.addQuick(d) } }

    // MARK: Drop folders to add
    private func folderURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.filter { $0.folderURL != nil }              // folders and Finder aliases to folders
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !folderURLs(sender).isEmpty
        dropHighlight = ok
        return ok ? .link : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        let urls = folderURLs(sender)
        urls.forEach { Favorites.shared.addQuick($0) }
        return !urls.isEmpty
    }
}
