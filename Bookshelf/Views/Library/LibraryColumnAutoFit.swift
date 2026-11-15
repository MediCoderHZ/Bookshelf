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
/// Normalize native header typography and handle double clicks on resize boundaries;
/// all other mouse events, including column resizing and sorting, pass through.
struct LibraryColumnAutoFitBridge: NSViewRepresentable {
  var fontSize: CGFloat = 13
  var primarySort: KeyPathComparator<Book>?
  let fittingWidth: (LibraryTableColumn, CGFloat) -> CGFloat

  func makeNSView(context: Context) -> Observer {
    let view = Observer()
    view.fittingWidth = fittingWidth
    view.fontSize = fontSize
    view.primarySort = primarySort
    return view
  }
  func updateNSView(_ view: Observer, context: Context) {
    view.fittingWidth = fittingWidth
    view.fontSize = fontSize
    view.primarySort = primarySort
    view.scheduleHeaderStyle()
  }
  static func dismantleNSView(_ view: Observer, coordinator: ()) { view.stopObserving() }

  final class Observer: NSView {
    var fittingWidth: (LibraryTableColumn, CGFloat) -> CGFloat = { _, _ in 0 }
    var fontSize: CGFloat = 13
    var primarySort: KeyPathComparator<Book>?
    private var monitor: Any?
    private var headerStyleScheduled = false

    func scheduleHeaderStyle() {
      guard !headerStyleScheduled else { return }
      headerStyleScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.headerStyleScheduled = false
        self.applyHeaderStyle()
      }
    }

    private func applyHeaderStyle() {
      guard window != nil, let table = enclosingTable() else { return }
      let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
      let sortColumn = primarySort.flatMap { sort in
        LibraryTableColumn.allCases.first { $0.comparator.keyPath == sort.keyPath }
      }
      for column in table.tableColumns {
        if !(column.headerCell is LibraryTableHeaderCell) {
          column.headerCell = LibraryTableHeaderCell(wrapping: column.headerCell)
        }
        column.headerCell.font = font
        // Use native owned storage; the header copy preserves this sort state.
        column.headerCell.representedObject = column.title == sortColumn?.title
          ? primarySort.map { $0.order == .forward } : nil
      }
      table.headerView?.needsDisplay = true
    }

    override func layout() {
      super.layout()
      scheduleHeaderStyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      guard window != nil else { return }
      scheduleHeaderStyle()
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

/// SwiftUI's header cell forces a heavier font for the sorted column at draw time,
/// even with an explicit Text font. Use AppKit's standard text drawing instead.
/// Keep this NSCopying cell free of Swift stored properties: AppKit copies it
/// while drawing, and NSCell's copy implementation only owns its native ivars.
final class LibraryTableHeaderCell: NSTableHeaderCell {
  init(wrapping original: NSTableHeaderCell) {
    super.init(textCell: original.stringValue)
    alignment = original.alignment
    controlSize = original.controlSize
    lineBreakMode = .byTruncatingTail
    usesSingleLineMode = true
    isEnabled = original.isEnabled
    menu = original.menu
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func copy(with zone: NSZone? = nil) -> Any {
    let cell = super.copy(with: zone) as! LibraryTableHeaderCell
    // NSCell intentionally drops representedObject when making a drawing copy.
    cell.representedObject = representedObject
    return cell
  }

  override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
    let textFont = NSFont.systemFont(ofSize: font?.pointSize ?? 13, weight: .regular)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    let text = NSAttributedString(string: stringValue, attributes: [
      .font: textFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
    ])
    // Match body-cell padding and reserve space for the native sort arrow.
    let titleFrame = NSRect(x: cellFrame.minX + 8,
      y: cellFrame.midY - text.size().height / 2,
      width: max(0, cellFrame.width - 28), height: text.size().height)
    text.draw(in: titleFrame)
    if let ascending = representedObject as? Bool {
      drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: 0)
    }
  }
}
