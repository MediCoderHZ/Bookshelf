import AppKit
import XCTest
@testable import Bookshelf

@MainActor
final class LibraryColumnAutoFitTests: XCTestCase {
  private func width(_ column: LibraryTableColumn, _ rows: [LibraryItemRow],
    expanded: Set<UUID> = [], fontSize: CGFloat = 13) -> CGFloat {
    LibraryColumnAutoFit.width(for: column, rows: rows, expandedBookIDs: expanded,
      fontSize: fontSize, indentation: 16)
  }

  func testNativeHeaderCopyPreservesPresentationAndOwnsSortState() {
    let header = LibraryTableHeaderCell(wrapping: NSTableHeaderCell(textCell: "添加日期"))
    header.font = .systemFont(ofSize: 18, weight: .regular)
    header.representedObject = false
    autoreleasepool {
      let copy = header.copy() as! LibraryTableHeaderCell
      XCTAssertFalse(copy === header)
      XCTAssertEqual(copy.stringValue, "添加日期")
      XCTAssertEqual(copy.font, header.font)
      XCTAssertEqual(copy.representedObject as? Bool, false)
      copy.representedObject = true
      XCTAssertEqual(header.representedObject as? Bool, false)
    }
    XCTAssertEqual(header.stringValue, "添加日期")
  }

  func testMeasuresWholeResultSetAndCurrentFont() {
    let short = Book(title: "短书名"), long = Book(title: String(repeating: "长书名", count: 20))
    let first = LibraryItemTree.rows(books: [short], notes: [])
    let all = LibraryItemTree.rows(books: [short, long], notes: [])
    XCTAssertGreaterThan(width(.title, all), width(.title, first))
    XCTAssertGreaterThan(width(.title, all, fontSize: 18), width(.title, all))
    XCTAssertGreaterThan(width(.publisher, []), 40) // Header remains legible for empty fields.
  }

  func testExpandedNotesAffectTitleButDoNotBorrowBookMetadata() {
    let book = Book(title: "短标题")
    book.publisher = "出版社"
    let note = NoteRecord(title: String(repeating: "笔记长标题", count: 10), parentBookID: book.id)
    let rows = LibraryItemTree.rows(books: [book], notes: [note])
    XCTAssertGreaterThan(width(.title, rows, expanded: [book.id]), width(.title, rows))
    XCTAssertEqual(width(.publisher, rows, expanded: [book.id]), width(.publisher, rows))
    XCTAssertEqual(width(.title, rows), width(.title, LibraryItemTree.rows(books: [book], notes: [])))
  }

  func testTitleAccountsForHierarchyDecorations() {
    let book = Book(title: String(repeating: "书", count: 20))
    let rows = LibraryItemTree.rows(books: [book], notes: [])
    let before = width(.title, rows)
    let note = NoteRecord(title: book.title, parentBookID: book.id)
    XCTAssertGreaterThan(width(.title, LibraryItemTree.rows(books: [book], notes: [note]), expanded: [book.id]), before)
  }

  func testStandaloneTitlesParticipateInAutoFitWithoutExpansion() {
    let book = Book(title: "书籍")
    let note = NoteRecord(title: String(repeating: "独立笔记长标题", count: 10))
    let booksOnly = LibraryItemTree.rows(books: [book], notes: [])
    let mixed = LibraryItemTree.rows(books: [book], notes: [note])
    XCTAssertGreaterThan(width(.title, mixed), width(.title, booksOnly))
    XCTAssertEqual(width(.title, mixed), width(.title, mixed, expanded: [book.id]))
    XCTAssertEqual(width(.author, mixed), width(.author, booksOnly))
  }

  func testTrashNotesUseOwnTypeAndDateValues() {
    let note = NoteRecord(title: "回收站笔记")
    let rows = [LibraryItemRow(id: .note(note.id), book: nil, note: note)]
    XCTAssertGreaterThan(width(.addedAt, rows), width(.addedAt, []))
    XCTAssertEqual(width(.author, rows), width(.author, []))
  }

  func testBoundaryTargetsLeftColumnAfterReorderingAndIgnoresHeaderInterior() {
    let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let header = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
    table.headerView = header
    for name in ["标题", "作者", "出版社"] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
      column.title = name; column.width = 100; column.resizingMask = [.userResizingMask]
      table.addTableColumn(column)
    }
    let edge = header.headerRect(ofColumn: 0).maxX
    XCTAssertEqual(LibraryColumnAutoFit.columnIndex(at: NSPoint(x: edge, y: 12), header: header, table: table), 0)
    XCTAssertNil(LibraryColumnAutoFit.columnIndex(at: NSPoint(x: 40, y: 12), header: header, table: table))
    XCTAssertNil(LibraryColumnAutoFit.columnIndex(at: NSPoint(x: edge, y: header.visibleRect.maxY + 1), header: header, table: table))
    table.moveColumn(1, toColumn: 0)
    let index = LibraryColumnAutoFit.columnIndex(at: NSPoint(x: header.headerRect(ofColumn: 0).maxX, y: 12), header: header, table: table)
    XCTAssertEqual(index.map { table.tableColumns[$0].title }, "作者")
    table.tableColumns[0].resizingMask = []
    XCTAssertNil(LibraryColumnAutoFit.columnIndex(at: NSPoint(x: header.headerRect(ofColumn: 0).maxX, y: 12), header: header, table: table))
  }
}
