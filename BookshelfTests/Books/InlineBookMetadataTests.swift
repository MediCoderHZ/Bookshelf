import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class InlineBookMetadataTests: XCTestCase {
  private var containers: [ModelContainer] = []
  private func fixture() throws -> (ModelContext, Book, BookMetadataEditingSession, URL) {
    let db = try LibraryDatabase.open(inMemory: true); containers.append(db)
    let context = db.mainContext
    let book = Book(title: "原书名"); book.publisher = "原出版社"; book.pageCount = 123
    context.insert(book); try context.save()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return (context, book, BookMetadataEditingSession(store: BookMetadataDraftStore(directory: directory)), directory)
  }
  private func value(_ field: BookField, _ book: Book) -> BookMetadataValue {
    .read(field, from: BookArchive(book: book))
  }
  private func edit(_ field: BookField, _ text: String, book: Book, context: ModelContext) throws {
    try BookMetadataCommands(context: context, undoManager: nil).save(bookID: book.id, field: field, text: text, expected: value(field, book))
  }

  func testTitleSavesAsOneUndoableFieldEditWithManualProvenance() throws {
    let (context, book, session, directory) = try fixture()
    book.metadataSourceName = "原来源"; book.metadataSourceURL = "https://example.com/book"; try context.save()
    let before = BookArchive(book: book), undo = UndoManager(); undo.groupsByEvent = false
    session.begin(before, field: .title)
    session.update(book.id, field: .title, text: "  修改后的书名  ")
    XCTAssertEqual(book.title, "原书名")
    undo.beginUndoGrouping()
    XCTAssertTrue(session.commit(book.id, field: .title, context: context, undoManager: undo))
    undo.endUndoGrouping()
    XCTAssertEqual(book.title, "修改后的书名")
    XCTAssertEqual(BookRecordMerge.origins(BookArchive(book: book))["title"]?.name, "手动编辑")
    XCTAssertEqual(BookRecordMerge.origins(BookArchive(book: book))["publisher"]?.name, "原来源")
    XCTAssertEqual(book.metadataSourceName, "原来源")
    XCTAssertTrue(BookMetadataDraftStore(directory: directory).load().drafts.isEmpty)
    undo.undo(); XCTAssertEqual(BookArchive(book: book), before)
    undo.redo(); XCTAssertEqual(book.title, "修改后的书名")
  }

  func testFormattingOnlyEditDoesNotChangeTimestampOrCreateHistory() throws {
    let (context, book, _, _) = try fixture()
    let before = BookArchive(book: book), undo = UndoManager()
    try BookMetadataCommands(context: context, undoManager: undo).save(bookID: book.id, field: .publisher,
      text: "  原出版社  ", expected: value(.publisher, book))
    XCTAssertEqual(BookArchive(book: book), before); XCTAssertFalse(undo.canUndo)
  }

  func testAllTextFieldsCanBeEditedAndOptionalFieldsCleared() throws {
    let (context, book, _, _) = try fixture()
    for field in [BookField.subtitle, .originalTitle, .publisher, .publicationDate, .edition, .language, .description] {
      try edit(field, " 新值\n第二行 ", book: book, context: context)
      XCTAssertEqual(value(field, book).text, "新值\n第二行")
      try edit(field, " \n ", book: book, context: context)
      XCTAssertEqual(value(field, book).text, "")
    }
  }

  func testContributorEditingPreservesCommasOrderAndOtherRoles() throws {
    let (context, book, _, _) = try fixture()
    var record = BookArchive(book: book)
    record.contributors = [ContributorArchive(name: "原作者", roleRaw: "author", displayOrder: 0),
      ContributorArchive(name: "译者甲", roleRaw: "translator", displayOrder: 0),
      ContributorArchive(name: "编辑甲", roleRaw: "editor", displayOrder: 2)]
    try LibraryRepository.apply([record], into: context)
    try edit(.authors, "Gerlach, Peter A.；王兴、王兴\n作者乙", book: book, context: context)
    let changed = BookArchive(book: book)
    XCTAssertEqual(changed.contributors.filter { $0.roleRaw == "author" }.map(\.name), ["Gerlach, Peter A.", "王兴", "作者乙"])
    XCTAssertEqual(changed.contributors.filter { $0.roleRaw == "author" }.map(\.displayOrder), [0, 1, 2])
    XCTAssertEqual(changed.contributors.filter { $0.roleRaw != "author" }, record.contributors.filter { $0.roleRaw != "author" }.sorted { $0.roleRaw < $1.roleRaw })
    try edit(.translators, "新译者", book: book, context: context)
    XCTAssertEqual(value(.authors, book).text, "Gerlach, Peter A.、王兴、作者乙")
    try edit(.authors, "", book: book, context: context)
    XCTAssertTrue(BookArchive(book: book).contributors.filter { $0.roleRaw == "author" }.isEmpty)
    XCTAssertEqual(value(.translators, book).text, "新译者")
  }

  func testISBNNormalizationPairAndValidation() throws {
    let (context, book, _, _) = try fixture()
    try edit(.isbn, "0-306-40615-2", book: book, context: context)
    XCTAssertEqual(book.isbn10, "0306406152"); XCTAssertEqual(book.isbn13, "9780306406157")
    let before = BookArchive(book: book)
    try edit(.isbn, "978-0-306-40615-7", book: book, context: context)
    XCTAssertEqual(BookArchive(book: book), before)
    for invalid in ["9780306406158", "123", "garbage9780306406157", "ISBN"] {
      XCTAssertThrowsError(try edit(.isbn, invalid, book: book, context: context))
      XCTAssertEqual(BookArchive(book: book), before)
    }
    try edit(.isbn, "9787309188189", book: book, context: context)
    XCTAssertNil(book.isbn10); XCTAssertEqual(book.isbn13, "9787309188189")
    try edit(.isbn, "", book: book, context: context)
    XCTAssertNil(book.isbn10); XCTAssertNil(book.isbn13)
  }

  func testInvalidTitleAndPagesKeepStoredValueAndInputDraft() throws {
    let (context, book, session, directory) = try fixture()
    session.begin(BookArchive(book: book), field: .title)
    session.update(book.id, field: .title, text: " ")
    XCTAssertFalse(session.commit(book.id, field: .title, context: context, undoManager: nil))
    XCTAssertEqual(book.title, "原书名"); XCTAssertEqual(session.draft(book.id, .title)?.text, " ")
    XCTAssertEqual(session.pendingDrafts.count, 1)
    XCTAssertEqual(BookMetadataDraftStore(directory: directory).load().drafts.count, 1)
    for invalid in ["-1", "0", "1.5", "三百", "999999999999999999999999999999"] {
      XCTAssertThrowsError(try edit(.pageCount, invalid, book: book, context: context))
      XCTAssertEqual(book.pageCount, 123)
    }
    try edit(.pageCount, "４２５", book: book, context: context); XCTAssertEqual(book.pageCount, 425)
    try edit(.pageCount, "", book: book, context: context); XCTAssertNil(book.pageCount)
  }

  func testOtherFieldsChangedDuringEditingArePreserved() throws {
    let (context, book, session, _) = try fixture()
    session.begin(BookArchive(book: book), field: .publisher)
    session.update(book.id, field: .publisher, text: "此窗口出版社")
    try LibraryCommands(context: context, undoManager: nil).update([book]) {
      $0.title = "其他窗口书名"; $0.tags = ["新增标签"]; $0.pageCount = 321
    }
    XCTAssertTrue(session.commit(book.id, field: .publisher, context: context, undoManager: nil))
    XCTAssertEqual(book.publisher, "此窗口出版社"); XCTAssertEqual(book.title, "其他窗口书名")
    XCTAssertEqual(book.pageCount, 321); XCTAssertEqual(BookArchive(book: book).tags, ["新增标签"])
  }

  func testSameFieldConflictRetainsDraftAcrossSessionRestart() throws {
    let (context, book, session, directory) = try fixture()
    session.begin(BookArchive(book: book), field: .publisher)
    session.update(book.id, field: .publisher, text: "未保存出版社")
    try edit(.publisher, "其他窗口出版社", book: book, context: context)
    XCTAssertFalse(session.commit(book.id, field: .publisher, context: context, undoManager: nil))
    XCTAssertEqual(book.publisher, "其他窗口出版社")
    let reloaded = BookMetadataEditingSession(store: BookMetadataDraftStore(directory: directory))
    XCTAssertEqual(reloaded.pendingDrafts.first?.text, "未保存出版社")
    XCTAssertFalse(reloaded.commit(book.id, field: .publisher, context: context, undoManager: nil))
    XCTAssertEqual(book.publisher, "其他窗口出版社")
    reloaded.discard(book.id, field: .publisher)
    reloaded.begin(BookArchive(book: book), field: .publisher)
    XCTAssertEqual(reloaded.draft(book.id, .publisher)?.text, "其他窗口出版社")
    XCTAssertTrue(BookMetadataDraftStore(directory: directory).load().drafts.isEmpty)
  }

  func testDraftsAreIsolatedByBookAndFieldAndDiscardDoesNotSave() throws {
    let (context, book, session, _) = try fixture()
    let other = Book(title: "另一本书"); context.insert(other); try context.save()
    session.begin(BookArchive(book: book), field: .title); session.update(book.id, field: .title, text: "草稿 A")
    session.begin(BookArchive(book: other), field: .title); session.update(other.id, field: .title, text: "草稿 B")
    session.begin(BookArchive(book: book), field: .publisher); session.update(book.id, field: .publisher, text: "出版社草稿")
    session.discard(book.id, field: .title)
    XCTAssertEqual(book.title, "原书名")
    XCTAssertTrue(session.commit(other.id, field: .title, context: context, undoManager: nil))
    XCTAssertTrue(session.commit(book.id, field: .publisher, context: context, undoManager: nil))
    XCTAssertEqual(other.title, "草稿 B"); XCTAssertEqual(book.title, "原书名")
    XCTAssertEqual(book.publisher, "出版社草稿")
  }

  func testTrashedAndMissingBooksCannotBeOverwrittenOrRecreated() throws {
    let (context, book, session, _) = try fixture()
    let id = book.id
    session.begin(BookArchive(book: book), field: .title); session.update(id, field: .title, text: "保留的草稿")
    try LibraryOperations.setTrashed(true, books: [book], context: context, undoManager: nil)
    XCTAssertFalse(session.commit(id, field: .title, context: context, undoManager: nil))
    XCTAssertEqual(book.title, "原书名")
    try LibraryOperations.purge([book], context: context, undoManager: nil)
    XCTAssertFalse(session.commit(id, field: .title, context: context, undoManager: nil))
    XCTAssertTrue(try context.fetch(FetchDescriptor<Book>()).isEmpty)
    XCTAssertEqual(session.draft(id, .title)?.text, "保留的草稿")
  }

  func testCleanEditorRefreshesAfterUndoInsteadOfSavingOldValue() throws {
    let (context, book, session, _) = try fixture()
    let undo = UndoManager(); undo.groupsByEvent = false
    session.begin(BookArchive(book: book), field: .publisher); session.update(book.id, field: .publisher, text: "新出版社")
    undo.beginUndoGrouping(); XCTAssertTrue(session.commit(book.id, field: .publisher, context: context, undoManager: undo)); undo.endUndoGrouping()
    undo.undo()
    session.begin(BookArchive(book: book), field: .publisher)
    XCTAssertEqual(session.draft(book.id, .publisher)?.text, "原出版社")
    XCTAssertTrue(session.commit(book.id, field: .publisher, context: context, undoManager: undo))
    XCTAssertTrue(undo.canRedo)
  }

  func testRecoveryWriteFailureKeepsDraftInMemory() throws {
    let (context, book, _, directory) = try fixture()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("not-a-directory")
    try Data().write(to: file)
    let session = BookMetadataEditingSession(store: BookMetadataDraftStore(directory: file.appendingPathComponent("drafts")))
    session.begin(BookArchive(book: book), field: .pageCount); session.update(book.id, field: .pageCount, text: "abc")
    XCTAssertFalse(session.commit(book.id, field: .pageCount, context: context, undoManager: nil))
    XCTAssertEqual(session.draft(book.id, .pageCount)?.text, "abc"); XCTAssertEqual(book.pageCount, 123)
    XCTAssertNotNil(session.recoveryIssue)
  }

  func testPersistenceAfterReopeningDatabase() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("books.store")
    do {
      let db = try LibraryDatabase.open(at: url), context = db.mainContext
      let book = Book(title: "原书名"); context.insert(book); try context.save()
      try edit(.publisher, "已保存出版社", book: book, context: context)
    }
    let db = try LibraryDatabase.open(at: url)
    XCTAssertEqual(try db.mainContext.fetch(FetchDescriptor<Book>()).first?.publisher, "已保存出版社")
  }
}
