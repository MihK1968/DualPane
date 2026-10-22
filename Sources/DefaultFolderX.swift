import AppKit

/// Keeps Default Folder X's "Finder Windows ▸ Recently Closed" list in step with the folders open in
/// DualPane's tabs, so they are one click away in every Open/Save dialog. Default Folder X recognises
/// only its own fixed set of file browsers (Finder, Path Finder, ForkLift, QSpace, Bloom), so this goes
/// through its AppleScript commands AddRecentFinderWindow / RemoveRecentFinderWindow instead.
/// A folder that was already on the list is moved to the top but stays the user's own entry: only the
/// ones DualPane added are withdrawn again when their tab closes or moves on. Nothing happens while
/// Default Folder X is not running. The first command makes macOS ask once whether DualPane may control
/// Default Folder X.
enum DefaultFolderX {
    /// Supplies the folders currently open in the window; set by the app delegate.
    static var openFolders: () -> [URL] = { [] }

    private static let bundleIDs = ["com.stclairsoft.DefaultFolderX5", "com.stclairsoft.DefaultFolderX5-setapp"]
    private static let queue = DispatchQueue(label: "ee.korgesaar.DualPane.DefaultFolderX")
    private static var published: Set<String> = []     // paths DualPane added; touched on `queue` only
    private static var promoted: Set<String> = []      // paths that were already listed and were only moved up
    private static var refused = false                  // the user denied the Automation permission
    private static var pending: DispatchWorkItem?
    private static let enabled = ProcessInfo.processInfo.environment["DUALPANE_SNAPSHOT"] == nil   // not during self-tests

    /// Call after any tab change; bursts are coalesced into one update half a second later.
    static func scheduleSync() {
        guard enabled else { return }
        pending?.cancel()
        let work = DispatchWorkItem {
            guard let pid = runningPID() else { return }
            let folders = Set(openFolders().map { $0.standardizedFileURL.path })
            queue.async { sync(folders, pid: pid) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Takes back everything DualPane added; called when the app quits and its tabs close with it.
    static func withdrawAll() {
        guard enabled else { return }
        pending?.cancel()
        let pid = runningPID()
        queue.sync {
            if let pid = pid { for p in published { _ = send("rRfw", path: p, pid: pid, timeout: 2) } }
            published = []
        }
    }

    private static func runningPID() -> pid_t? {
        for id in bundleIDs {
            if let a = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return a.processIdentifier }
        }
        return nil
    }

    // Runs on `queue`.
    private static func sync(_ wanted: Set<String>, pid: pid_t) {
        guard !refused else { return }
        for p in published.subtracting(wanted) {                    // tab closed or moved on
            if send("rRfw", path: p, pid: pid) { published.remove(p) }
        }
        promoted.formIntersection(wanted)                          // the user's own entries stay listed
        let new = wanted.subtracting(published).subtracting(promoted)
        guard !new.isEmpty else { return }
        let listed = Set(currentList(pid: pid))
        for p in new.sorted() where send("aRfw", path: p, pid: pid) {
            if listed.contains(p) { promoted.insert(p) } else { published.insert(p) }
        }
    }

    private static func event(_ id: String, pid: pid_t) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: code("DFDX"), eventID: code(id),
                               targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                               returnID: -1, transactionID: 0)      // kAutoGenerateReturnID, kAnyTransactionID
    }

    private static func send(_ id: String, path: String, pid: pid_t, timeout: TimeInterval = 5) -> Bool {
        let ev = event(id, pid: pid)
        ev.setParam(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: path)), forKeyword: code("----"))
        do {
            let reply = try ev.sendEvent(options: [.waitForReply], timeout: timeout)
            if let n = reply.paramDescriptor(forKeyword: code("errn")), n.int32Value != 0 {
                NSLog("Default Folder X refused %@ for %@: error %d", id, path, n.int32Value); return false
            }
            return true
        } catch { note(error); return false }
    }

    private static func currentList(pid: pid_t) -> [String] {
        guard let reply = try? event("gRfw", pid: pid).sendEvent(options: [.waitForReply], timeout: 5),
              let list = reply.paramDescriptor(forKeyword: code("----")) else { return [] }
        return (0..<list.numberOfItems).compactMap {
            list.atIndex($0 + 1)?.coerce(toDescriptorType: code("furl"))?.fileURLValue?.standardizedFileURL.path
        }
    }

    private static func note(_ error: Error) {
        if (error as NSError).code == -1743 { refused = true }     // errAEEventNotPermitted: Automation denied
        NSLog("Default Folder X: %@", error.localizedDescription)
    }

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}
