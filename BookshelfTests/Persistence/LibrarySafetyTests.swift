import AppKit
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class LibrarySafetyTests: XCTestCase {
  private func container() throws -> ModelContainer {
    try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
  }
  private func undoManager() -> UndoManager {
    let manager = UndoManager()
    manager.groupsByEvent = false
    return manager
  }
  private func archive(_ records: [BookArchive], version: Int = 2) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(LibraryArchive(schemaVersion: version, exportedAt: Date(), books: records))
  }
  private func fixture(_ name: String, isbn: String? = nil, context: ModelContext) -> Book {
    let book = Book(title: name)
    book.isbn13 = isbn
    context.insert(book)
    return book
  }
  private func organize(_ book: Book, tag: String, collection: String, context: ModelContext) {
    let t = Tag(name: tag), c = BookCollection(name: collection)
    context.insert(t); context.insert(c)
    context.insert(BookTag(book: book, tag: t))
    context.insert(CollectionItem(collection: c, book: book))
  }

  func testISBNEquivalenceAndDifferentEditionProtection() throws {
    XCTAssertEqual(ISBN.identity("0-306-40615-2"), "9780306406157")
    XCTAssertNil(ISBN.identity("9780306406158"))
    let a = Book(title: "同名书"), b = Book(title: "同名书")
    a.isbn13 = "9780306406157"; b.isbn13 = "9780743273565"
    XCTAssertTrue(DuplicateDetector.duplicateIDs(in: [a, b]).isEmpty)
    XCTAssertEqual(DuplicateDetector.firstMatch(title: "other", isbn: "0306406152", authorNames: [], excluding: nil, in: [a])?.book.id, a.id)
    b.deletedAt = Date()
    XCTAssertNil(DuplicateDetector.firstMatch(title: b.title, isbn: b.isbn13, authorNames: [], excluding: a.id, in: [b]))
  }

  func testImportPreviewDoesNotMutateAndConflictsDefaultToSkip() throws {
    let c = try container(), ctx = c.mainContext
    let local = fixture("旧书", context: ctx)
    local.notes = "本地笔记"
    try ctx.save()
    var incoming = BookArchive(book: local)
    incoming.publisher = "新出版社"
    let plan = try LibraryImportPlanner.prepare(archive([incoming]), context: ctx)
    XCTAssertEqual(plan.items[0].defaultChoice.action, .skip)
    XCTAssertNil(local.publisher)
    let result = try LibraryImportPlanner.apply(plan, choices: [:], context: ctx, undoManager: nil)
    XCTAssertEqual(result.skippedCount, 1)
    XCTAssertNil(local.publisher)
    XCTAssertEqual(local.notes, "本地笔记")
  }

  func testImportDifferentISBNEvenWithSameIDCannotOverwrite() throws {
    let c = try container(), ctx = c.mainContext
    let local = fixture("同名书", isbn: "9780306406157", context: ctx)
    local.notes = "必须保留"
    try ctx.save()
    var incoming = BookArchive(book: local)
    incoming.isbn13 = "9780743273565"
    incoming.publisher = "另一版本"
    let plan = try LibraryImportPlanner.prepare(archive([incoming]), context: ctx)
    XCTAssertThrowsError(try LibraryImportPlanner.apply(plan,
      choices: [incoming.id: ImportChoice(action: .update, targetID: local.id)], context: ctx, undoManager: nil))
    let result = try LibraryImportPlanner.apply(plan,
      choices: [incoming.id: ImportChoice(action: .add)], context: ctx, undoManager: nil)
    XCTAssertEqual(result.createdCount, 1)
    XCTAssertEqual(local.isbn13, "9780306406157")
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 2)
    XCTAssertEqual(local.notes, "必须保留")
  }

  func testImportUpdatePreservesNotesClassificationAndCanUndoRedo() throws {
    let c = try container(), ctx = c.mainContext, undo = undoManager()
    let book = fixture("导入验收", context: ctx)
    book.publisher = "手动出版社"; book.notes = "本地笔记"
    organize(book, tag: "本地标签", collection: "本地文件夹", context: ctx)
    try ctx.save()
    let before = BookArchive(book: book)
    var incoming = before
    incoming.publisher = "备份出版社"; incoming.notes = "备份笔记"
    incoming.tags = ["备份标签"]; incoming.collections = ["备份文件夹"]
    let plan = try LibraryImportPlanner.prepare(archive([incoming]), context: ctx)
    undo.beginUndoGrouping()
    _ = try LibraryImportPlanner.apply(plan, choices: [incoming.id: ImportChoice(action: .update, targetID: book.id)], context: ctx, undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertEqual(book.publisher, "备份出版社")
    XCTAssertTrue(book.notes?.contains("本地笔记") == true)
    XCTAssertTrue(book.notes?.contains("备份笔记") == true)
    XCTAssertEqual(Set(book.collectionItems.compactMap(\.collection?.name)), ["本地文件夹", "备份文件夹"])
    undo.undo()
    XCTAssertNil(LibraryServices.forContext(ctx).history.errorMessage)
    XCTAssertEqual(BookArchive(book: book), before)
    undo.redo()
    XCTAssertEqual(book.publisher, "备份出版社")
    XCTAssertEqual(Set(book.tagLinks.compactMap(\.tag?.name)), ["本地标签", "备份标签"])
  }

  func testImportBatchDuplicatesAndStalePreviewAreHandled() throws {
    let c = try container(), ctx = c.mainContext
    let original = fixture("重复", isbn: "9780306406157", context: ctx)
    try ctx.save()
    var a = BookArchive(book: original), b = a
    a.id = UUID(); b.id = UUID()
    let plan = try LibraryImportPlanner.prepare(archive([a,b]), context: ctx)
    XCTAssertTrue(plan.items[1].repeatedInFile)
    XCTAssertThrowsError(try LibraryImportPlanner.apply(plan, choices: [
      a.id: ImportChoice(action: .fill, targetID: original.id),
      b.id: ImportChoice(action: .fill, targetID: original.id)
    ], context: ctx, undoManager: nil))
    original.notes = "预览后新增"; try ctx.save()
    XCTAssertThrowsError(try LibraryImportPlanner.apply(plan,
      choices: [a.id: ImportChoice(action: .update, targetID: original.id)], context: ctx, undoManager: nil))
    XCTAssertEqual(original.notes, "预览后新增")
  }

  func testTrashKeepsRelationshipsAndSupportsUndoRedo() throws {
    let c = try container(), ctx = c.mainContext, undo = undoManager()
    let book = fixture("回收站验收", context: ctx)
    organize(book, tag: "保留标签", collection: "保留文件夹", context: ctx)
    book.notes = "保留笔记"
    try ctx.save()
    let before = BookArchive(book: book)
    undo.beginUndoGrouping()
    try LibraryOperations.setTrashed(true, books: [book], context: ctx, undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertFalse(LibraryFilter.matches(book, selection: .all, tagIDs: [], query: ""))
    XCTAssertTrue(LibraryFilter.matches(book, selection: .trash, tagIDs: [], query: ""))
    XCTAssertEqual(book.notes, "保留笔记")
    undo.undo()
    XCTAssertEqual(BookArchive(book: book), before)
    undo.redo()
    XCTAssertNotNil(book.deletedAt)
    try LibraryOperations.setTrashed(false, books: [book], context: ctx, undoManager: nil)
    XCTAssertNil(book.deletedAt)
    XCTAssertEqual(book.collectionItems.compactMap(\.collection?.name), ["保留文件夹"])
  }

  func testMergeRetainsOriginalsAndUnionThenUndoRestoresBothExactly() throws {
    let c = try container(), ctx = c.mainContext, undo = undoManager()
    let a = fixture("合并书", isbn: "9780306406157", context: ctx)
    let b = fixture("合并书", isbn: "9780306406157", context: ctx)
    a.publisher = "出版社 A"; b.publisher = "出版社 B"
    a.notes = "笔记 A"; b.notes = "笔记 B"
    a.metadataSourceName = "A"; b.metadataSourceName = "B"
    organize(a, tag: "甲", collection: "一", context: ctx)
    organize(b, tag: "乙", collection: "二", context: ctx)
    try ctx.save()
    let before = LibraryHistory.snapshots([a,b])
    undo.beginUndoGrouping()
    _ = try LibraryOperations.merge([BookArchive(book:a), BookArchive(book:b)], primaryID:a.id,
      choices:[.publisher:b.id], context:ctx, undoManager:undo)
    undo.endUndoGrouping()
    XCTAssertEqual(a.publisher, "出版社 B")
    XCTAssertTrue(a.notes?.contains("笔记 A") == true && a.notes?.contains("笔记 B") == true)
    XCTAssertEqual(Set(a.tagLinks.compactMap(\.tag?.name)), ["甲", "乙"])
    XCTAssertEqual(Set(a.collectionItems.compactMap(\.collection?.name)), ["一", "二"])
    XCTAssertEqual(BookRecordMerge.origins(BookArchive(book:a))["publisher"]?.name, "B")
    XCTAssertNotNil(b.deletedAt); XCTAssertEqual(b.mergedIntoID, a.id)
    XCTAssertEqual(b.notes, "笔记 B")
    undo.undo()
    XCTAssertNil(LibraryServices.forContext(ctx).history.errorMessage)
    XCTAssertEqual(LibraryHistory.snapshots([a,b]), before)
    undo.redo()
    XCTAssertNotNil(b.deletedAt)
    XCTAssertEqual(a.publisher, "出版社 B")
  }

  func testDifferentEditionMergeAndStaleMergeAreRejected() throws {
    let c = try container(), ctx = c.mainContext
    let a = fixture("书", isbn:"9780306406157", context:ctx)
    let b = fixture("书", isbn:"9780743273565", context:ctx)
    try ctx.save()
    XCTAssertThrowsError(try LibraryOperations.merge([BookArchive(book:a),BookArchive(book:b)],
      primaryID:a.id, choices:[:], context:ctx, undoManager:nil))
    b.isbn13 = a.isbn13; try ctx.save()
    let records = [BookArchive(book:a),BookArchive(book:b)]
    a.notes = "新的笔记"; try ctx.save()
    XCTAssertThrowsError(try LibraryOperations.merge(records, primaryID:a.id, choices:[:], context:ctx, undoManager:nil))
    XCTAssertNil(a.deletedAt); XCTAssertNil(b.deletedAt)
  }

  func testMergeKeepsSubstringNotesAndRepeatedImportDoesNotRepeatBlocks() {
    let a = Book(title: "A"), b = Book(title: "B")
    a.notes = "这是完整笔记"; b.notes = "完整笔记"
    let first = BookRecordMerge.combine(primary: BookArchive(book: a), others: [BookArchive(book: b)])
    XCTAssertEqual(first.notes, "这是完整笔记\n\n—— 合并保留的笔记 ——\n\n完整笔记")
    let second = BookRecordMerge.combine(primary: first, others: [BookArchive(book: b)])
    XCTAssertEqual(first.notes, second.notes)
  }

  func testImportAdditionUndoRemovesOnlyAddedBookAndRedoRestoresIt() throws {
    let c = try container(), ctx = c.mainContext, undo = undoManager()
    let existing = fixture("原有书籍", context: ctx)
    try ctx.save()
    let incoming = BookArchive(book: Book(title: "导入新书"))
    let plan = try LibraryImportPlanner.prepare(archive([incoming]), context: ctx)
    undo.beginUndoGrouping()
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: ctx, undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 2)
    undo.undo()
    XCTAssertNil(LibraryServices.forContext(ctx).history.errorMessage)
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).map(\.id), [existing.id])
    undo.redo()
    XCTAssertEqual(Set(try ctx.fetch(FetchDescriptor<Book>()).map(\.id)), [existing.id, incoming.id])
  }

  func testFieldUpdatesKeepUnselectedAndMissingValuesAndTrackOrigins() {
    let book = Book(title:"手动书名")
    book.publisher = "手动出版社"; book.notes = "私人笔记"; book.isbn13 = "9780306406157"
    let original = BookArchive(book:book)
    var incoming = original
    incoming.title = "网页书名"; incoming.publisher = "网页出版社"; incoming.pageCount = 300
    incoming.metadataSourceName = "豆瓣图书"; incoming.metadataSourceURL = "https://book.douban.com/subject/123/"
    incoming.metadataRetrievedAt = Date(); incoming.bookDescription = nil
    let defaults = MetadataUpdateProposal(current: original, incoming: incoming).defaultSelection
    XCTAssertTrue(defaults.contains(.pageCount))
    XCTAssertFalse(defaults.contains(.title))
    XCTAssertFalse(defaults.contains(.publisher))
    let updated = BookRecordMerge.applyingMetadata(incoming, to:original, fields:[.publisher,.pageCount,.description])
    XCTAssertEqual(updated.title, "手动书名")
    XCTAssertEqual(updated.publisher, "网页出版社")
    XCTAssertEqual(updated.notes, "私人笔记")
    XCTAssertEqual(updated.isbn13, original.isbn13)
    XCTAssertEqual(BookRecordMerge.origins(updated)["publisher"]?.name, "豆瓣图书")
    XCTAssertNil(BookRecordMerge.origins(updated)["title"])
  }

  func testUndoCannotOverwriteSubsequentUntrackedChanges() throws {
    let c = try container(), ctx = c.mainContext, undo = undoManager()
    let book = fixture("撤销保护", context:ctx)
    try ctx.save()
    undo.beginUndoGrouping()
    try LibraryOperations.setTrashed(true, books:[book], context:ctx, undoManager:undo)
    undo.endUndoGrouping()
    book.notes = "后续修改"; try ctx.save()
    undo.undo()
    XCTAssertNotNil(LibraryServices.forContext(ctx).history.errorMessage)
    XCTAssertEqual(book.notes, "后续修改")
    XCTAssertNotNil(book.deletedAt)
    LibraryServices.forContext(ctx).history.errorMessage = nil
  }

  func testPurgeRequiresTrashAndKeepsOtherBooks() throws {
    let c = try container(), ctx = c.mainContext
    let a = fixture("A", context:ctx), b = fixture("B", context:ctx)
    try ctx.save()
    XCTAssertThrowsError(try LibraryOperations.purge([a], context:ctx, undoManager:nil))
    try LibraryOperations.setTrashed(true, books:[a], context:ctx, undoManager:nil)
    try LibraryOperations.purge([a], context:ctx, undoManager:nil)
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).map(\.id), [b.id])
  }

  func testOldBackupAndTrashRoundTrip() throws {
    let c = try container(), ctx = c.mainContext
    let book = fixture("旧版", context:ctx)
    try ctx.save()
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: archive([BookArchive(book:book)], version:1)) as? [String:Any])
    var rows = try XCTUnwrap(object["books"] as? [[String:Any]])
    for key in ["deletedAt","mergedIntoID","metadataFieldSourcesJSON"] { rows[0].removeValue(forKey:key) }
    object["books"] = rows
    let decoded = try LibraryBackupService.decode(JSONSerialization.data(withJSONObject:object))
    XCTAssertNil(decoded.books[0].deletedAt)
    book.deletedAt = Date()
    let backup = try LibraryBackupService.exportData(from:ctx)
    XCTAssertEqual(try LibraryBackupService.decode(backup).schemaVersion,9)
    let target = try container()
    _ = try LibraryBackupService.importData(backup, into:target.mainContext)
    XCTAssertNotNil(try target.mainContext.fetch(FetchDescriptor<Book>()).first?.deletedAt)
  }

  func testTrashSurvivesReopeningPersistentStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = ModelConfiguration(url: directory.appendingPathComponent("library.store"))
    let id = UUID()
    do {
      let c = try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self, configurations: configuration)
      let book = fixture("持久化验收", context: c.mainContext)
      book.id = id; book.notes = "重启后保留"
      try LibraryOperations.setTrashed(true, books: [book], context: c.mainContext, undoManager: nil)
    }
    let reopened = try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self, configurations: configuration)
    let book = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<Book>()).first)
    XCTAssertEqual(book.id, id)
    XCTAssertEqual(book.notes, "重启后保留")
    XCTAssertNotNil(book.deletedAt)
    try LibraryOperations.setTrashed(false, books: [book], context: reopened.mainContext, undoManager: nil)
    XCTAssertNil(book.deletedAt)
  }

}
