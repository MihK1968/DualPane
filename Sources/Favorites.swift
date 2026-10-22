import AppKit

/// User-editable lists: sidebar favourites (folders and separators) and the quick-access row.
final class Favorites {
    static let shared = Favorites()
    static let changed = Notification.Name("FavoritesChanged")

    /// One sidebar row: a folder or a separator, at a nesting depth. A row of depth n sits inside the
    /// nearest row above it of depth n-1, so favourites can be grouped under other favourites.
    struct Entry: Equatable {
        var url: URL?                 // nil for a separator
        var depth: Int = 0
        var asSeparator = false       // a folder drawn as a labelled divider: a line with its name on it
        var isSeparator: Bool { url == nil }
        static func folder(_ u: URL, depth: Int = 0) -> Entry { Entry(url: u, depth: depth) }
        static let separator = Entry(url: nil)
    }

    private(set) var sidebar: [Entry] = []
    private(set) var quick: [URL] = []

    private init() { load() }

    // MARK: Sidebar
    /// The row at `index` together with every row nested inside it.
    func sidebarSubtree(at index: Int) -> Range<Int> {
        guard sidebar.indices.contains(index) else { return index..<index }
        var end = index + 1
        while end < sidebar.count, sidebar[end].depth > sidebar[index].depth { end += 1 }
        return index..<end
    }
    func sidebarHasChildren(at index: Int) -> Bool { sidebarSubtree(at: index).count > 1 }
    /// Index of the row that the row at `index` is nested in, if any.
    func sidebarParent(of index: Int) -> Int? {
        guard sidebar.indices.contains(index), sidebar[index].depth > 0 else { return nil }
        return (0..<index).reversed().first { sidebar[$0].depth < sidebar[index].depth }
    }
    /// Depth of a row inserted at `index`: the depth of the row below when that row is nested in the
    /// same list (dropping between a favourite and its first sub-folder lands inside), else the top level.
    func sidebarDepthForInsertion(at index: Int) -> Int {
        guard index > 0, index <= sidebar.count else { return 0 }
        let prev = sidebar[index - 1]
        if index < sidebar.count, sidebar[index].depth > 0, sidebar[index].depth <= prev.depth + 1 { return sidebar[index].depth }
        return 0
    }

    func addSidebar(_ url: URL, at index: Int? = nil, depth: Int? = nil) {
        let u = url.standardizedFileURL
        if sidebar.contains(where: { $0.url == u }) { return }
        let i = min(index ?? sidebar.count, sidebar.count)
        sidebar.insert(.folder(u, depth: depth ?? sidebarDepthForInsertion(at: i)), at: i); normalize(); save()
    }
    /// Adds `url` as the last row inside the favourite at `parent`.
    func addSidebar(_ url: URL, inside parent: Int) {
        guard sidebar.indices.contains(parent), !sidebar[parent].isSeparator else { return }
        addSidebar(url, at: sidebarSubtree(at: parent).upperBound, depth: sidebar[parent].depth + 1)
    }
    func addSidebarSeparator(at index: Int) {
        let i = min(index, sidebar.count)
        sidebar.insert(Entry(url: nil, depth: sidebarDepthForInsertion(at: i)), at: i); normalize(); save()
    }
    /// Removes the row and everything nested inside it.
    func removeSidebar(at index: Int) {
        guard sidebar.indices.contains(index) else { return }
        sidebar.removeSubrange(sidebarSubtree(at: index)); normalize(); save()
    }
    /// Moves the row at `from`, with everything nested inside it, to the gap `to` (an index in the
    /// current list) at `depth`, or at the depth the gap implies, as for an added row.
    func moveSidebar(from: Int, to: Int, depth: Int? = nil) {
        guard sidebar.indices.contains(from) else { return }
        let range = sidebarSubtree(at: from)
        guard to <= range.lowerBound || to >= range.upperBound else { return }   // not into itself
        if to == range.lowerBound { return }
        let block = Array(sidebar[range])
        sidebar.removeSubrange(range)
        var t = to; if to > range.lowerBound { t -= block.count }
        t = max(0, min(t, sidebar.count))
        let delta = (depth ?? sidebarDepthForInsertion(at: t)) - block[0].depth
        sidebar.insert(contentsOf: block.map { var e = $0; e.depth += delta; return e }, at: t)
        normalize(); save()
    }
    /// Moves the row at `from`, with everything nested inside it, to the end of the rows inside `parent`.
    func moveSidebar(from: Int, inside parent: Int) {
        guard sidebar.indices.contains(from), sidebar.indices.contains(parent), !sidebar[parent].isSeparator else { return }
        let range = sidebarSubtree(at: from)
        guard !range.contains(parent) else { return }                                // not into itself
        let block = Array(sidebar[range])
        let parentEntry = sidebar[parent]
        sidebar.removeSubrange(range)
        guard let p = sidebar.firstIndex(of: parentEntry) else { return }
        let delta = parentEntry.depth + 1 - block[0].depth
        sidebar.insert(contentsOf: block.map { var e = $0; e.depth += delta; return e }, at: sidebarSubtree(at: p).upperBound)
        normalize(); save()
    }
    /// Draws the folder at `index` as a labelled divider, or as a plain row again.
    func setSidebarAsSeparator(at index: Int, _ on: Bool) {
        guard sidebar.indices.contains(index), !sidebar[index].isSeparator else { return }
        sidebar[index].asSeparator = on; save()
    }
    /// Moves the row at `index`, with everything nested inside it, out of its parent to just after the parent's rows.
    func moveSidebarOut(at index: Int) {
        guard sidebar.indices.contains(index), sidebar[index].depth > 0 else { return }
        let range = sidebarSubtree(at: index)
        let parentDepth = sidebar[index].depth - 1
        var end = range.upperBound
        while end < sidebar.count, sidebar[end].depth > parentDepth { end += 1 }
        let block = sidebar[range].map { var e = $0; e.depth -= 1; return e }
        sidebar.removeSubrange(range)
        sidebar.insert(contentsOf: block, at: end - block.count)
        normalize(); save()
    }
    /// Depths start at the top level and grow by at most one per row; a separator has nothing inside it.
    private func normalize() {
        var allowed = 0
        for i in sidebar.indices {
            sidebar[i].depth = max(0, min(sidebar[i].depth, allowed))
            allowed = sidebar[i].isSeparator ? sidebar[i].depth : sidebar[i].depth + 1
        }
    }

    // MARK: Quick access row
    func addQuick(_ url: URL, at index: Int? = nil) {
        let u = url.standardizedFileURL
        if quick.contains(u) { return }
        quick.insert(u, at: min(index ?? quick.count, quick.count)); save()
    }
    func removeQuick(at index: Int) { guard quick.indices.contains(index) else { return }; quick.remove(at: index); save() }
    func moveQuick(from: Int, to: Int) {
        guard quick.indices.contains(from) else { return }
        let e = quick.remove(at: from)
        var t = to; if from < to { t -= 1 }
        quick.insert(e, at: max(0, min(t, quick.count))); save()
    }

    // MARK: Persistence
    private func save() {
        let d = UserDefaults.standard
        // One string per row: a ">" per nesting level, then "|" for a folder drawn as a divider, then
        // the path, or "---" for a separator.
        d.set(sidebar.map { e in String(repeating: ">", count: e.depth) + (e.asSeparator ? "|" : "") + (e.url?.path ?? "---") }, forKey: "favorites")
        d.set(quick.map { $0.path }, forKey: "quickItems")
        NotificationCenter.default.post(name: Favorites.changed, object: self)
    }

    private func load() {
        let d = UserDefaults.standard
        let home = NSHomeDirectory()
        if let saved = d.stringArray(forKey: "favorites") {
            sidebar = saved.map { s in
                let depth = s.prefix { $0 == ">" }.count
                var rest = String(s.dropFirst(depth))
                let divider = rest.hasPrefix("|")
                if divider { rest.removeFirst() }
                if rest == "---" { return Entry(url: nil, depth: depth) }
                return Entry(url: URL(fileURLWithPath: rest), depth: depth, asSeparator: divider)
            }
            normalize()
        } else {
            var seed = ["/Applications", home, home + "/Desktop", home + "/Documents", home + "/Downloads",
                        home + "/Library/Mobile Documents/com~apple~CloudDocs"]
            let extra = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [])
                .filter { $0.hasPrefix("OneDrive") || $0 == "Google Drive" }.sorted().map { home + "/" + $0 }
            seed += extra
            sidebar = seed.filter { FileManager.default.fileExists(atPath: $0) }.map { .folder(URL(fileURLWithPath: $0)) }
        }
        if let saved = d.stringArray(forKey: "quickItems") {
            quick = saved.map { URL(fileURLWithPath: $0) }
        } else {
            quick = [home + "/Documents", "/Applications", home + "/Downloads", home + "/Desktop"].map { URL(fileURLWithPath: $0) }
        }
    }

    /// Display name for a favourite (volume names for mount points, else the folder name).
    static func displayName(for url: URL) -> String {
        if url.path == "/" { return "Macintosh HD" }
        if url.path.hasSuffix("com~apple~CloudDocs") { return "iCloud Drive" }
        if let n = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName { return n }
        return url.lastPathComponent
    }

    static func icon(for url: URL, size: CGFloat = 16) -> NSImage {
        // An alias to a folder shows that folder's icon, as in Finder's sidebar.
        let shown = url.aliasTarget(mount: false).flatMap { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? $0 : nil } ?? url
        let i = NSWorkspace.shared.icon(forFile: shown.path)
        i.size = NSSize(width: size, height: size)
        return i
    }
}
