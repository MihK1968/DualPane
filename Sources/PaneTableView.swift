import AppKit
import Quartz

protocol PaneKeyHandler: AnyObject {
    /// Return true when the key was consumed.
    func handleKey(_ event: NSEvent) -> Bool
    func becameActive()
    func quickLookURLs() -> [URL]
    func startRename()
}

/// File list (an outline view: folder rows open with a triangle to show their contents in place)
/// that routes typed characters to the pane's quick filter and hosts the Quick Look panel for its selection.
final class PaneTableView: NSOutlineView {
    weak var keyHandler: PaneKeyHandler?
    /// Set by the pane when a drag starts out of this table, so a click-and-drag never renames.
    var dragBegan = false
    private var pendingRename: DispatchWorkItem?

    override func keyDown(with event: NSEvent) {
        cancelPendingRename()
        if keyHandler?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    func cancelPendingRename() { pendingRename?.cancel(); pendingRename = nil }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { keyHandler?.becameActive() }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        cancelPendingRename()                       // a second click (double-click) cancels the slow-click rename
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        let plain = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
        let onSelectedName = plain && event.clickCount == 1 && r >= 0 && selectedRowIndexes == IndexSet(integer: r) && clickIsOnName(p, row: r)
        dragBegan = false
        super.mouseDown(with: event)                // returns after the mouse-up (or after a drag)
        guard onSelectedName, !dragBegan, selectedRowIndexes == IndexSet(integer: r),
              let up = window?.currentEvent, up.type == .leftMouseUp,
              hypot(up.locationInWindow.x - event.locationInWindow.x, up.locationInWindow.y - event.locationInWindow.y) < 4 else { return }
        // Finder-style slow double-click: a single click on the name of the already selected row
        // starts renaming once the double-click interval has passed without a second click.
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.selectedRowIndexes == IndexSet(integer: r), self.window?.firstResponder === self else { return }
            self.keyHandler?.startRename()
        }
        pendingRename = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// True when `p` (in table coordinates) lies on the name text of `row`, not on the icon or the empty part of the cell.
    private func clickIsOnName(_ p: NSPoint, row r: Int) -> Bool {
        guard column(at: p) == 0, let cell = view(atColumn: 0, row: r, makeIfNecessary: false) as? NSTableCellView, let tf = cell.textField else { return false }
        var f = convert(tf.frame, from: cell)
        f.size.width = min(f.width, tf.attributedStringValue.size().width + 6)
        return f.insetBy(dx: 0, dy: -2).contains(p)
    }

    // Right-click selects the row under the cursor (unless it is already part of the selection).
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        if r >= 0 && !selectedRowIndexes.contains(r) { selectRowIndexes([r], byExtendingSelection: false) }
        if r < 0 { deselectAll(nil) }
        return super.menu(for: event)
    }

    // MARK: Quick Look
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension PaneTableView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { keyHandler?.quickLookURLs().count ?? 0 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        (keyHandler?.quickLookURLs()[index] as NSURL?)
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Let arrow keys move the table selection while the panel is open.
        if event.type == .keyDown, [125, 126].contains(event.keyCode) { keyDown(with: event); return true }
        return false
    }
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL, let h = keyHandler else { return .zero }
        let urls = h.quickLookURLs()
        guard let idx = urls.firstIndex(of: url) else { return .zero }
        let row = selectedRowIndexes.sorted()[safe: idx] ?? -1
        guard row >= 0, let w = window else { return .zero }
        let r = frameOfCell(atColumn: 0, row: row)
        let iconRect = NSRect(x: r.minX, y: r.minY, width: r.height, height: r.height)
        return w.convertToScreen(convert(iconRect, to: nil))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
