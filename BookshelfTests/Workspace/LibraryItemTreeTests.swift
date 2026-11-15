import Foundation
import XCTest
@testable import Bookshelf

@MainActor
final class LibraryItemTreeTests: XCTestCase {
  func testChildrenStayWithParentAndKeepStableCreationOrder() {
    let first = Book(title: "B"), second = Book(title: "A")
    var older = NoteRecord(title: "Z", parentBookID: first.id)
    older.createdAt = Date(timeIntervalSince1970: 1)
    var newer = NoteRecord(title: "A", parentBookID: first.id)
    newer.createdAt = Date(timeIntervalSince1970: 2)
    let rows = LibraryItemTree.rows(books: [second, first], notes: [newer, older])
    XCTAssertEqual(rows.map(\.id), [.book(second.id), .book(first.id)])
    XCTAssertTrue(rows[0].children.isEmpty)
    XCTAssertEqual(rows[1].children.map(\.id), [.note(older.id), .note(newer.id)])
    newer.updatedAt = .distantFuture; newer.title = "Changed"
    XCTAssertEqual(LibraryItemTree.rows(books: [first], notes: [newer, older])[0].children.map(\.id), rows[1].children.map(\.id))
  }

  func testStandaloneNotesEnterRootButDeletedAndOutOfScopeChildrenDoNot() {
    let book = Book(title: "Visible"), hidden = Book(title: "Filtered")
    let active = NoteRecord(title: "Active", parentBookID: book.id)
    var deleted = NoteRecord(title: "Deleted", parentBookID: book.id); deleted.deletedAt = Date()
    let standalone = NoteRecord(title: "Independent")
    var deletedStandalone = NoteRecord(title: "Deleted independent"); deletedStandalone.deletedAt = Date()
    let outside = NoteRecord(title: "Outside", parentBookID: hidden.id)
    let rows = LibraryItemTree.rows(books: [book], notes: [active, deleted, standalone, deletedStandalone, outside])
    XCTAssertEqual(rows.map(\.id), [.book(book.id), .note(standalone.id)])
    XCTAssertTrue(rows[1].children.isEmpty)
    XCTAssertEqual(rows[0].children.map(\.id), [.note(active.id)])
    XCTAssertTrue(LibraryItemTree.rows(books: [], notes: [active]).isEmpty)
    XCTAssertEqual(LibraryItemTree.rows(books: [], notes: [standalone, deletedStandalone, outside]).map(\.id), [.note(standalone.id)])
  }

  func testStandaloneNotesSortBetweenBooksWithoutDetachingChildren() {
    let first = Book(title: "A book"), last = Book(title: "C book")
    let child = NoteRecord(title: "A child", parentBookID: last.id)
    var note = NoteRecord(); note.body = "# B note\n正文"
    first.addedAt = Date(timeIntervalSince1970: 10); last.addedAt = Date(timeIntervalSince1970: 30)
    note.createdAt = Date(timeIntervalSince1970: 20)
    first.updatedAt = last.addedAt; last.updatedAt = first.addedAt; note.updatedAt = note.createdAt
    let rows = LibraryItemTree.rows(books: [last, first], notes: [note, child])
    for column in [LibraryTableColumn.title, .addedAt] {
      var comparator = LibraryItemSort(bookComparator: column.comparator)
      let sorted = rows.sorted(using: comparator)
      XCTAssertEqual(sorted.map(\.id), [.book(first.id), .note(note.id), .book(last.id)])
      XCTAssertEqual(sorted.last?.children.map(\.id), [.note(child.id)])
      comparator.order = .reverse
      XCTAssertEqual(rows.sorted(using: comparator).map(\.id), [.book(last.id), .note(note.id), .book(first.id)])
    }
    XCTAssertEqual(rows.sorted(using: LibraryItemSort(bookComparator: LibraryTableColumn.updatedAt.comparator)).map(\.id),
      [.book(last.id), .note(note.id), .book(first.id)])
  }

  func testMixedColumnSortingIsConsistentForEmptyAndNumericMetadata() {
    let first = Book(title: "A"), second = Book(title: "Z"), empty = Book(title: "Empty")
    first.pageCount = 9; second.pageCount = 100
    first.publicationDate = "1999-10"; second.publicationDate = "2026-01"
    first.publisher = "Press 2"; second.publisher = "Press 10"
    first.bookTypeRaw = BookType.chineseOriginal.rawValue; second.bookTypeRaw = BookType.chineseTranslation.rawValue
    let rows = LibraryItemTree.rows(books: [first, second, empty], notes: [NoteRecord(title: "笔记 2"), NoteRecord(title: "笔记 10")])
    for column in LibraryTableColumn.allCases {
      for order in [SortOrder.forward, .reverse] {
        var comparator = LibraryItemSort(bookComparator: column.comparator); comparator.order = order
        for a in rows { for b in rows {
          XCTAssertEqual(comparator.compare(a, b).rawValue, -comparator.compare(b, a).rawValue, column.title)
          for c in rows where comparator.compare(a, b) != .orderedDescending && comparator.compare(b, c) != .orderedDescending {
            XCTAssertNotEqual(comparator.compare(a, c), .orderedDescending, column.title)
          }
        } }
      }
    }
  }

  func testCollectionAndSavedSearchProduceScopedStandaloneRootRows() {
    let parent = ManualCollectionRecord(name: "父文件夹")
    let child = ManualCollectionRecord(name: "子文件夹", parentID: parent.id)
    var matching = NoteRecord(title: "经济笔记"); matching.collectionIDs = [child.id]
    let outside = NoteRecord(title: "经济书库笔记")
    var deleted = matching; deleted.id = UUID(); deleted.deletedAt = Date()
    let notes = [matching, outside, deleted]
    let direct = NoteQueries.results(notes, books: [], collections: [parent, child], scope: .collection(parent.id), text: "经济")
    XCTAssertTrue(LibraryItemTree.rows(books: [], notes: direct).isEmpty)
    let recursive = NoteQueries.results(notes, books: [], collections: [parent, child], scope: .collection(parent.id), text: "经济", includeSubcollections: true)
    XCTAssertEqual(LibraryItemTree.rows(books: [], notes: recursive).map(\.id), [.note(matching.id)])
    let saved = NoteQueries.results(notes, books: [], collections: [], scope: .smart(UUID()), text: "",
      smartQuery: .savingSearch(scope: .fieldsAndTags, text: "经济 -书库"))
    XCTAssertEqual(LibraryItemTree.rows(books: [], notes: saved).map(\.id), [.note(matching.id)])
  }

  func testTrashedParentRetainsChildrenForReadOnlyPreview() {
    let book = Book(title: "Trash"); book.deletedAt = Date()
    let note = NoteRecord(title: "Preserved", parentBookID: book.id)
    let row = LibraryItemTree.rows(books: [book], notes: [note])[0]
    XCTAssertEqual(row.children.first?.note, note)
    XCTAssertTrue(NoteQueries.isTrashed(note, books: [book]))
  }

  func testBookAndNoteIDsCannotCollide() {
    let book = Book(title: "Book")
    var note = NoteRecord(title: "Note", parentBookID: book.id); note.id = book.id
    let row = LibraryItemTree.rows(books: [book], notes: [note])[0]
    XCTAssertNotEqual(row.id, row.children[0].id)
    XCTAssertNil(row.children[0].book)
  }

  func testSelectionSeparatesBookBatchOperationsFromNotes() {
    let a = UUID(), b = UUID(), note = UUID()
    let batch = LibraryItemTree.selection([.book(a), .book(b)], previous: [.book(a)])
    XCTAssertEqual(batch.books, [a, b]); XCTAssertTrue(batch.notes.isEmpty)
    let selectNote = LibraryItemTree.selection([.book(a), .note(note)], previous: [.book(a)])
    XCTAssertTrue(selectNote.books.isEmpty); XCTAssertEqual(selectNote.notes, [note])
    let selectBook = LibraryItemTree.selection([.book(b), .note(note)], previous: [.note(note)])
    XCTAssertEqual(selectBook.books, [b]); XCTAssertTrue(selectBook.notes.isEmpty)
    let cleared = LibraryItemTree.selection([], previous: [.note(note)])
    XCTAssertTrue(cleared.books.isEmpty); XCTAssertTrue(cleared.notes.isEmpty)
  }

  func testNoteSelectionSupportsCommandShiftAndDeselectWithoutChoosingOneNote() {
    let a = UUID(), b = UUID(), c = UUID(), book = UUID()
    let command = LibraryItemTree.selection([.note(a), .note(b)], previous: [.note(a)])
    XCTAssertEqual(command.notes, [a, b]); XCTAssertTrue(command.books.isEmpty)
    let shift = LibraryItemTree.selection([.note(a), .book(book), .note(b), .note(c)], previous: [.note(a)])
    XCTAssertEqual(shift.notes, [a, b, c]); XCTAssertTrue(shift.books.isEmpty)
    let deselect = LibraryItemTree.selection([.note(b), .note(c)], previous: [.note(a), .note(b), .note(c)])
    XCTAssertEqual(deselect.notes, [b, c])
    let books = LibraryItemTree.selection([.note(a), .note(b), .book(book)], previous: [.note(a), .note(b)])
    XCTAssertEqual(books.books, [book]); XCTAssertTrue(books.notes.isEmpty)
  }

  func testColumnSortUsesBookComparatorWithoutPromotingNotes() {
    let a = Book(title: "A"), b = Book(title: "B")
    let note = NoteRecord(title: "First", parentBookID: b.id)
    let rows = LibraryItemTree.rows(books: [b, a], notes: [note])
    var comparator = LibraryItemSort(bookComparator: KeyPathComparator(\Book.title))
    XCTAssertEqual(rows.sorted(using: comparator).map(\.id), [.book(a.id), .book(b.id)])
    comparator.order = .reverse
    XCTAssertEqual(comparator.bookComparator.order, .reverse)
    XCTAssertEqual(rows.sorted(using: comparator).map(\.id), [.book(b.id), .book(a.id)])
    XCTAssertEqual(rows.sorted(using: comparator)[0].children.first?.id, .note(note.id))
  }
}
