import Foundation
import XCTest
@testable import Bookshelf

@MainActor
final class LibraryTableColumnTests: XCTestCase {
  func testNumericColumnsSortByValuesInsteadOfFormattedText() {
    let small = Book(title: "Small"), large = Book(title: "Large"), unknown = Book(title: "Unknown")
    small.pageCount = 9; large.pageCount = 100
    small.publicationDate = "1999-12"; large.publicationDate = "2026-01"
    for column in [LibraryTableColumn.pageCount, .publicationYear] {
      XCTAssertEqual([large, small, unknown].sorted(using: [column.comparator]).map(\.id), [unknown.id, small.id, large.id])
    }
    XCTAssertEqual(LibraryTableColumn.pageCount.text(for: LibraryItemRow(id: .book(unknown.id), book: unknown, note: nil)), "")
  }

  func testDateSortUsesTimestampsAndReversesWithoutDetachingNotes() {
    let old = Book(title: "Z"), recent = Book(title: "A")
    old.addedAt = Date(timeIntervalSince1970: 1); recent.addedAt = Date(timeIntervalSince1970: 100)
    old.updatedAt = recent.addedAt; recent.updatedAt = old.addedAt
    let note = NoteRecord(title: "Child", parentBookID: old.id)
    let rows = LibraryItemTree.rows(books: [old, recent], notes: [note])
    let added = LibraryItemSort(bookComparator: LibraryTableColumn.addedAt.comparator)
    var modified = LibraryItemSort(bookComparator: LibraryTableColumn.updatedAt.comparator)
    XCTAssertEqual(rows.sorted(using: [added]).map(\.id), [.book(old.id), .book(recent.id)])
    XCTAssertEqual(rows.sorted(using: [modified]).map(\.id), [.book(recent.id), .book(old.id)])
    modified.order = .reverse
    let sorted = rows.sorted(using: [modified])
    XCTAssertEqual(sorted.first?.id, .book(old.id)); XCTAssertEqual(sorted.first?.children.first?.id, .note(note.id))
  }

  func testNoteColumnsShowOwnDatesAndNeverBorrowBookMetadata() {
    var note = NoteRecord(title: "独立笔记")
    note.createdAt = Date(timeIntervalSince1970: 12345); note.updatedAt = Date(timeIntervalSince1970: 45678)
    let row = LibraryItemRow(id: .note(note.id), book: nil, note: note)
    XCTAssertEqual(LibraryTableColumn.bookType.text(for: row), "笔记")
    XCTAssertEqual(LibraryTableColumn.addedAt.text(for: row), note.createdAt.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(L10n.locale)))
    XCTAssertEqual(LibraryTableColumn.updatedAt.text(for: row), note.updatedAt.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(L10n.locale)))
    for column in [LibraryTableColumn.subtitle, .author, .translator, .publisher, .isbn, .publicationYear, .pageCount] {
      XCTAssertEqual(column.text(for: row), "")
    }
  }

  func testSubtitleSortUsesSubtitleAndKeepsChildNotesAttached() {
    let first = Book(title: "Z title"), second = Book(title: "A title"), empty = Book(title: "Empty")
    first.subtitle = "A subtitle"; second.subtitle = "Z subtitle"
    let child = NoteRecord(title: "Child note", parentBookID: second.id)
    let rows = LibraryItemTree.rows(books: [second, first, empty], notes: [child])
    var sort = LibraryItemSort(bookComparator: LibraryTableColumn.subtitle.comparator)
    XCTAssertEqual(rows.sorted(using: [sort]).map(\.id), [.book(empty.id), .book(first.id), .book(second.id)])
    sort.order = .reverse
    let sorted = rows.sorted(using: [sort])
    XCTAssertEqual(sorted.first?.id, .book(second.id))
    XCTAssertEqual(sorted.first?.children.first?.id, .note(child.id))
    XCTAssertEqual(LibraryTableColumn.subtitle.text(for: sorted[0]), "Z subtitle")
    XCTAssertEqual(LibraryTableColumn.subtitle.text(for: sorted[0].children[0]), "")
  }

  func testPublicationAndTypeColumnsPreserveUnknownsAndEditionIdentifiers() {
    let book = Book(title: "测试")
    book.isbn10 = "0306406152"; book.isbn13 = "9780306406157"
    book.bookTypeRaw = BookType.chineseTranslation.rawValue; book.publicationDate = "2025-03-07"
    let row = LibraryItemRow(id: .book(book.id), book: book, note: nil)
    XCTAssertEqual(LibraryTableColumn.bookType.text(for: row), "中文译本")
    XCTAssertEqual(LibraryTableColumn.publicationYear.text(for: row), "2025")
    XCTAssertEqual(LibraryTableColumn.publicationDate.text(for: row), "2025-03-07")
    XCTAssertEqual(LibraryTableColumn.isbn.text(for: row), "9780306406157")
    book.bookTypeRaw = nil; book.isbn13 = nil; book.publicationDate = "未知"
    XCTAssertEqual(LibraryTableColumn.bookType.text(for: row), "")
    XCTAssertEqual(LibraryTableColumn.publicationYear.text(for: row), "")
    XCTAssertEqual(LibraryTableColumn.isbn.text(for: row), "0306406152")
  }
}
