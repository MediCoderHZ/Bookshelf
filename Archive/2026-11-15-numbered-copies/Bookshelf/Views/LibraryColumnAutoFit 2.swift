import AppKit
import SwiftUI

/// Measure the current result set, not just the cells AppKit has instantiated.
@MainActor
enum LibraryColumnAutoFit {
  static func width(for column: LibraryTableColumn, rows: [LibraryItemRow],
    expandedBookIDs: Set<UUID>, fontSize: CGFloat, indentation: CGFloat) -> CGFloat {
    let font = NSFont.systemFont(ofSize: fontSize)
    let headerFont = NSFont.systemFont(ofSize: fontSize)
    var widest = measure(column.title, font: headerFont) + 28 // Header padding and sort indicator.

    func include(_ row: LibraryItemRow, depth: Int) {
      var padding: CGFloat = 16
      if column == .title {
        padding += fontSize + 8 + indentation * CGFloat(depth + 1)
        if row.book?.isFavorite == true { padding += max(11, fontSize - 2) + 8 }
      }
      widest = max(widest, measure(column.text(for: row), font: font) + padding)
    }
    for row in rows {
      include(row, depth: 0)
      if let id = row.book?.id, expandedBookIDs.contains(id) {
        for child in row.children { include(child, depth: 1) }
      }
    }
    return ceil(widest)
  }

  private static func measure(_ text: String, font: NSFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
  }

  /// Use actual header rectangles, so reordering and horizontal scrolling work.
  static func columnIndex(at point: NSPoint, header: NSTableHeaderView, table: NSTableView) -> Int? {
    guard header.visibleRect.contains(point) else { return nil }
    return table.tableColumns.indices.first { index in
      let column = table.tableColumns[index]
      guard !column.isHidden, column.resizingMask.contains(.userResizingMask) else { return false }
      let rect = header.headerRect(ofColumn: index)
      return rect.width > 0 && abs(point.x - rect.maxX) <= 4
    }
  }
}

/// SwiftUI retains its table delegate, selection, sorting and width persistence.
/// Only double clicks on a resize boundary are handled here; drags pass through.
struct LibraryColumnAutoFitBridge: NSViewRepresentable {
  let fittingWidth: (LibraryTableColumn, CGFloat) -> CGFloat

  func makeNSView(context: Context) -> Observer {
    let view = Observer()
    view.fittingWidth = fittingWidth
    return view
  }
  func updateNSView(_ view: Observer, context: Context) { view.fittingWidth = fittingWidth }
  static func dismantleNSView(_ view: Observer, coordinator: ()) { view.stopObserving() }

  final class Observer: NSView {
    var fittingWidth: (LibraryTableColumn, CGFloat) -> CGFloat = { _, _ in 0 }
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        guard let self, event.clickCount == 2, self.fitColumn(for: event) else { return event }
        return nil
      }
    }
    func stopObserving() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    private func fitColumn(for event: NSEvent) -> Bool {
      guard let window, event.window === window, let table = enclosingTable(),
        table.allowsColumnResizing, let header = table.headerView else { return false }
      let point = header.convert(event.locationInWindow, from: nil)
      guard let index = LibraryColumnAutoFit.columnIndex(at: point, header: header, table: table) else { return false }
      let nativeColumn = table.tableColumns[index]
      // Header titles come from the same enum. Native UUID identifiers belong
      // to SwiftUI and change when columns are recreated, so do not persist them.
      guard let column = LibraryTableColumn.allCases.first(where: { $0.title == nativeColumn.title }) else { return false }
      let indentation = (table as? NSOutlineView)?.indentationPerLevel ?? 16
      let width = max(fittingWidth(column, indentation), nativeColumn.headerCell.cellSize.width + 20)
      guard width.isFinite, width > 0 else { return false }
      // Setting width posts AppKit's resize notification. SwiftUI's existing
      // customization binding saves it exactly like a manual resize.
      nativeColumn.width = min(nativeColumn.maxWidth, max(nativeColumn.minWidth, width))
      // Programmatic resizing does not run the header's live-resize tracking.
      // Refresh this column's hosted cells so text reflows immediately, while
      // keeping the outline's selection and expansion intact.
      table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows),
        columnIndexes: IndexSet(integer: index))
      return true
    }

    private func enclosingTable() -> NSTableView? {
      var ancestor = superview
      while let view = ancestor {
        if let table = findTable(in: view) { return table }
        ancestor = view.superview
      }
      return nil
    }
    private func findTable(in view: NSView) -> NSTableView? {
      if let table = view as? NSTableView, table.headerView != nil,
        table.tableColumns.contains(where: { $0.title == LibraryTableColumn.title.title }) { return table }
      for child in view.subviews {
        if let table = findTable(in: child) { return table }
      }
      return nil
    }
  }
}
