import AppKit

enum ConflictPolicy { case replace, keepBoth, skip }

/// Filesystem operations. Each runs on a background queue and reports back on the main queue.
enum FileOps {
    private static let queue = DispatchQueue(label: "dualpane.fileops", qos: .userInitiated)

    /// Returns a destination URL in `dir` for `name` that does not exist yet ("name copy", "name copy 2", ...).
    static func uniqueURL(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 1
        while true {
            let suffix = n == 1 ? " copy" : " copy \(n)"
            let newName = ext.isEmpty ? base + suffix : base + suffix + "." + ext
            candidate = dir.appendingPathComponent(newName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Asks the user how to handle existing items. Returns nil when cancelled.
    static func askConflictPolicy(window: NSWindow?, conflicts: [String], verb: String) -> ConflictPolicy? {
        let a = NSAlert()
        a.messageText = conflicts.count == 1
            ? "“\(conflicts[0])” already exists in the destination."
            : "\(conflicts.count) items already exist in the destination."
        a.informativeText = "Replace the existing items with the ones you are \(verb)ing, keep both, or skip them?"
        a.addButton(withTitle: "Replace")
        a.addButton(withTitle: "Keep Both")
        a.addButton(withTitle: "Skip")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        let r = a.runModal()
        switch r {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .keepBoth
        case .alertThirdButtonReturn: return .skip
        default: return nil
        }
    }

    /// Copies or moves `sources` into `destDir`. Conflicts are resolved by asking once.
    static func transfer(_ sources: [URL], to destDir: URL, move: Bool, window: NSWindow?, policy forced: ConflictPolicy? = nil,
                         completion: @escaping ([URL]) -> Void) {
        let fm = FileManager.default
        let sources = sources.filter { $0.deletingLastPathComponent().standardizedFileURL != destDir.standardizedFileURL || !move }
        guard !sources.isEmpty else { completion([]); return }
        // Refuse to move a folder into itself.
        for s in sources where destDir.standardizedFileURL.path.hasPrefix(s.standardizedFileURL.path + "/") || destDir.standardizedFileURL == s.standardizedFileURL {
            alert("Cannot \(move ? "move" : "copy") “\(s.lastPathComponent)” into itself.", window: window)
            completion([]); return
        }
        let conflicts = sources.map { $0.lastPathComponent }.filter { fm.fileExists(atPath: destDir.appendingPathComponent($0).path) }
        var policy: ConflictPolicy = forced ?? .keepBoth
        if !conflicts.isEmpty && forced == nil {
            guard let p = askConflictPolicy(window: window, conflicts: conflicts, verb: move ? "mov" : "copy") else { completion([]); return }
            policy = p
        }
        let progress = ProgressSheet(title: move ? "Moving…" : "Copying…", total: sources.count, window: window)
        progress.show()
        queue.async {
            var done: [URL] = []
            var errors: [String] = []
            for (i, src) in sources.enumerated() {
                DispatchQueue.main.async { progress.update(i + 1, name: src.lastPathComponent) }
                if progress.cancelled { break }
                var dst = destDir.appendingPathComponent(src.lastPathComponent)
                if fm.fileExists(atPath: dst.path) {
                    switch policy {
                    case .skip: continue
                    case .keepBoth: dst = uniqueURL(for: src.lastPathComponent, in: destDir)
                    case .replace:
                        do { try fm.removeItem(at: dst) } catch { errors.append("\(src.lastPathComponent): \(error.localizedDescription)"); continue }
                    }
                }
                do {
                    if move { try fm.moveItem(at: src, to: dst) } else { try fm.copyItem(at: src, to: dst) }
                    done.append(dst)
                } catch {
                    errors.append("\(src.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                progress.close()
                if !errors.isEmpty { alert("Some items could not be \(move ? "moved" : "copied"):\n\n" + errors.joined(separator: "\n"), window: window) }
                completion(done)
            }
        }
    }

    /// Receives promised files (a drag from Mail, Photos, a browser…) into a private temporary
    /// folder, then moves each one into `destDir` as it arrives. An existing name is kept and the
    /// new file gets a "copy" suffix, as for a paste. `completion` runs on the main queue
    /// after every file (the promise API has no "all done" callback), with the files so far.
    static func receivePromised(_ receivers: [NSFilePromiseReceiver], into destDir: URL, completion: @escaping ([URL]) -> Void) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("DualPane-drop-" + UUID().uuidString, isDirectory: true)
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) } catch { alert("Could not receive the dropped files: \(error.localizedDescription)", window: nil); return }
        let opQueue = OperationQueue()
        opQueue.qualityOfService = .userInitiated
        var arrived: [URL] = []
        for r in receivers {
            r.receivePromisedFiles(atDestination: tmp, options: [:], operationQueue: opQueue) { url, error in
                var moved: URL?
                if error == nil {
                    let dst = uniqueURL(for: url.lastPathComponent, in: destDir)
                    do { try fm.moveItem(at: url, to: dst); moved = dst } catch { }
                }
                DispatchQueue.main.async {
                    if let e = error { alert("“\(url.lastPathComponent)” could not be received: \(e.localizedDescription)", window: nil) }
                    else if let m = moved { arrived.append(m) }
                    else { alert("“\(url.lastPathComponent)” could not be moved into “\(destDir.lastPathComponent)”.", window: nil) }
                    completion(arrived)
                    // The temporary folder is removed once the senders have had time to finish writing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                        if (try? fm.contentsOfDirectory(atPath: tmp.path))?.isEmpty == true { try? fm.removeItem(at: tmp) }
                    }
                }
            }
        }
    }

    static func trash(_ urls: [URL], window: NSWindow?, completion: @escaping () -> Void) {
        queue.async {
            var errors: [String] = []
            for u in urls {
                do { try FileManager.default.trashItem(at: u, resultingItemURL: nil) }
                catch { errors.append("\(u.lastPathComponent): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                if !errors.isEmpty { alert("Some items could not be moved to the Trash:\n\n" + errors.joined(separator: "\n"), window: window) }
                completion()
            }
        }
    }

    @discardableResult
    static func newFolder(in dir: URL, name: String, window: NSWindow?) -> URL? {
        let url = uniqueURL(for: name, in: dir)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url }
        catch { alert("Could not create folder: \(error.localizedDescription)", window: window); return nil }
    }

    @discardableResult
    static func newFile(in dir: URL, name: String, window: NSWindow?) -> URL? {
        let url = uniqueURL(for: name, in: dir)
        if FileManager.default.createFile(atPath: url.path, contents: Data()) { return url }
        alert("Could not create file “\(name)”.", window: window); return nil
    }

    @discardableResult
    static func rename(_ url: URL, to newName: String, window: NSWindow?) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent, !trimmed.contains("/") else { return nil }
        let dst = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: dst.path) && dst.path.lowercased() != url.path.lowercased() {
            alert("“\(trimmed)” already exists.", window: window); return nil
        }
        do { try FileManager.default.moveItem(at: url, to: dst); return dst }
        catch { alert("Could not rename: \(error.localizedDescription)", window: window); return nil }
    }

    static func alert(_ text: String, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = text
        a.alertStyle = .warning
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    /// Finder "Get Info" window for the given files.
    static func getInfo(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let list = urls.map { "POSIX file \"\($0.path.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
        let src = "tell application \"Finder\"\nactivate\nrepeat with f in {\(list)}\nopen information window of (f as alias)\nend repeat\nend tell"
        NSAppleScript(source: src)?.executeAndReturnError(nil)
    }

    /// The terminal used by "Open in …": iTerm when it is installed, else Apple's Terminal.
    static var terminalApp: (url: URL, name: String) {
        if let iterm = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") {
            return (iterm, "iTerm")
        }
        return (URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), "Terminal")
    }

    /// Opens each folder as a new session in the terminal (iTerm opens a tab per folder, Terminal a window).
    static func openTerminal(at dirs: [URL]) {
        guard !dirs.isEmpty else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(dirs, withApplicationAt: terminalApp.url, configuration: cfg)
    }
}

/// A small modal-less progress sheet with a Cancel button.
final class ProgressSheet {
    private let panel: NSPanel
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private weak var parent: NSWindow?
    private(set) var cancelled = false
    private let total: Int
    private var shown = false
    private var showTimer: Timer?

    init(title: String, total: Int, window: NSWindow?) {
        self.total = total
        parent = window
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 110), styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = title
        let v = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        label.frame = NSRect(x: 20, y: 70, width: 380, height: 20)
        label.lineBreakMode = .byTruncatingMiddle
        bar.frame = NSRect(x: 20, y: 44, width: 380, height: 20)
        bar.minValue = 0; bar.maxValue = Double(total); bar.isIndeterminate = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: 320, y: 10, width: 80, height: 28)
        cancel.bezelStyle = .rounded
        v.addSubview(label); v.addSubview(bar); v.addSubview(cancel)
        panel.contentView = v
    }

    func show() {
        // Only show if the operation takes more than a moment.
        showTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self, !self.shown else { return }
            self.shown = true
            if let p = self.parent { p.beginSheet(self.panel) } else { self.panel.makeKeyAndOrderFront(nil) }
        }
    }

    func update(_ n: Int, name: String) {
        bar.doubleValue = Double(n)
        label.stringValue = "\(n) of \(total): \(name)"
    }

    func close() {
        showTimer?.invalidate()
        guard shown else { return }
        if let p = parent { p.endSheet(panel) } else { panel.orderOut(nil) }
    }

    @objc private func cancelTapped() { cancelled = true }
}
