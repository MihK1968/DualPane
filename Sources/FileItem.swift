import AppKit

/// One entry of a directory listing.
final class FileItem: NSObject {
    let url: URL
    @objc let name: String
    let isDirectory: Bool      // true for real folders and symlinks to folders (packages excluded)
    let isPackage: Bool
    let isSymlink: Bool
    let isAlias: Bool          // Finder alias file (not a symlink)
    let isHidden: Bool
    @objc let size: Int64      // -1 for folders
    @objc let modified: Date
    let kind: String

    /// Folder peek (the triangle in the file list): this folder's own listing once it has been opened
    /// in a pane (nil until then), and the rows shown for it after the pane's filter and sort.
    var children: [FileItem]?
    var shownChildren: [FileItem] = []

    private var _icon: NSImage?
    var icon: NSImage {
        if let i = _icon { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        i.size = NSSize(width: 16, height: 16)
        _icon = i
        return i
    }

    init(url: URL) {
        self.url = url
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey,
                                         .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
        let rv = try? url.resourceValues(forKeys: keys)
        name = url.lastPathComponent
        isSymlink = rv?.isSymbolicLink ?? false
        isAlias = (rv?.isAliasFile ?? false) && !isSymlink
        isHidden = rv?.isHidden ?? false
        var dir = rv?.isDirectory ?? false
        var pkg = rv?.isPackage ?? false
        if isSymlink {
            // follow the link to decide how to treat it
            let target = url.resolvingSymlinksInPath()
            let trv = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            dir = trv?.isDirectory ?? false
            pkg = trv?.isPackage ?? false
        }
        isPackage = pkg
        isDirectory = dir && !pkg
        size = isDirectory ? -1 : Int64(rv?.fileSize ?? 0)
        modified = rv?.contentModificationDate ?? .distantPast
        kind = rv?.localizedTypeDescription ?? (isDirectory ? "Folder" : "Document")
        super.init()
    }

    /// Where a Finder alias points (resolved on first use; nil for non-aliases and broken aliases).
    lazy var aliasTarget: URL? = isAlias ? url.aliasTarget : nil

    /// True for folders and for aliases that point to a folder: double-click enters them.
    lazy var opensAsFolder: Bool = {
        if isDirectory { return true }
        guard isAlias, let t = aliasTarget, let rv = try? t.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return rv.isDirectory == true && rv.isPackage != true
    }()

    /// The folder this item stands for (itself, or the alias target), nil for files.
    var folderURL: URL? { isDirectory ? url : (opensAsFolder ? aliasTarget : nil) }

    var sizeString: String {
        size < 0 ? "--" : FileItem.byteFormatter.string(fromByteCount: size)
    }

    var dateString: String { FileItem.dateFormatter.string(from: modified) }

    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    /// Lists a directory. Hidden files are included only when `showHidden` is set.
    static func contents(of directory: URL, showHidden: Bool) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey,
                                      .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: opts)
        return urls.map { FileItem(url: $0) }
    }
}

enum SortKey: String { case name, size, modified }

extension URL {
    /// True for a Finder alias file (symlinks are reported separately).
    var isFinderAlias: Bool {
        guard let rv = try? resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey]) else { return false }
        return rv.isAliasFile == true && rv.isSymbolicLink != true
    }

    /// Target of a Finder alias; nil when this is not an alias or the original cannot be found.
    /// `mount` lets a server volume be mounted to find the original.
    func aliasTarget(mount: Bool = true) -> URL? {
        guard isFinderAlias else { return nil }
        var opts: URL.BookmarkResolutionOptions = [.withoutUI]
        if !mount { opts.insert(.withoutMounting) }
        return try? URL(resolvingAliasFileAt: self, options: opts)
    }
    var aliasTarget: URL? { aliasTarget(mount: true) }

    /// Follows a Finder alias and any symlinks; returns the standardized URL (self when nothing resolves).
    func resolvingAlias(mount: Bool = true) -> URL {
        (aliasTarget(mount: mount) ?? self).resolvingSymlinksInPath().standardizedFileURL
    }

    /// The folder this URL opens: itself for a folder, the original for an alias to a folder, nil for files.
    var folderURL: URL? {
        let u = resolvingAlias()
        return (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? u : nil
    }
}

extension Array where Element == FileItem {
    /// Folders always first, then the chosen key. Names compare like Finder does.
    func sorted(by key: SortKey, ascending: Bool) -> [FileItem] {
        return sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let r: ComparisonResult
            switch key {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .size: r = a.size == b.size ? a.name.localizedStandardCompare(b.name) : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .modified: r = a.modified == b.modified ? a.name.localizedStandardCompare(b.name) : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
            }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }
}
