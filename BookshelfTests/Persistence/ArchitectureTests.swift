import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class ArchitectureTests: XCTestCase {
  private func record(_ title: String = "架构验收") -> BookArchive { BookArchive(book: Book(title: title)) }
  private func undoManager() -> UndoManager { let manager = UndoManager(); manager.groupsByEvent = false; return manager }

  func testDatabaseOpensWithoutAutosavingDrafts() throws {
    let database = try LibraryDatabase.open(inMemory: true)
    XCTAssertFalse(database.mainContext.autosaveEnabled)
    XCTAssertTrue(try database.mainContext.fetch(FetchDescriptor<Book>()).isEmpty)
  }

  func testExistingStoreCopyWhenProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["BOOKSHELF_COMPAT_STORE"],
      let countText = ProcessInfo.processInfo.environment["BOOKSHELF_COMPAT_COUNT"], let count = Int(countText)
    else { throw XCTSkip("Set BOOKSHELF_COMPAT_STORE and BOOKSHELF_COMPAT_COUNT for a copied pre-refactor store") }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("compat.store")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
    let database = try LibraryDatabase.open(at: url)
    let books = try database.mainContext.fetch(FetchDescriptor<Book>())
    XCTAssertEqual(books.count, count)
    XCTAssertTrue(books.allSatisfy { !$0.title.isEmpty })
    let backup = try LibraryBackupService.exportData(from: database.mainContext)
    XCTAssertEqual(try LibraryBackupService.decode(backup).books.count, count)
  }

  func testRISDetectionHandlesUnicodeAtProbeBoundary() throws {
    let text = "TY  - BOOK\nTI  - " + String(repeating: "图书", count: 2000) + "\nER  - \n"
    let engine = TranslationEngine(registry: TranslatorRegistry())
    XCTAssertEqual(try engine.importFile(Data(text.utf8)).records.count, 1)
    XCTAssertThrowsError(try engine.importFile(Data("not a bibliography".utf8)))
  }

  func testCommandSaveUndoRedoPublishesCommittedSnapshots() throws {
    let database = try LibraryDatabase.open(inMemory: true), ctx = database.mainContext, undo = undoManager()
    let notifier = LibraryNotifier.forContext(ctx)
    var counts: [Int] = []
    let token = notifier.observe { _ in counts.append((try? ctx.fetch(FetchDescriptor<Book>()).count) ?? -1) }
    let draft = record()
    undo.beginUndoGrouping()
    try LibraryCommands(context: ctx, undoManager: undo).save(draft, expected: nil)
    undo.endUndoGrouping()
    XCTAssertEqual(counts, [1]); XCTAssertEqual(notifier.lastChange?.bookIDs, [draft.id])
    undo.undo(); XCTAssertEqual(counts, [1, 0])
    undo.redo(); XCTAssertEqual(counts, [1, 0, 1])
    notifier.removeObserver(token)
    undo.undo(); XCTAssertEqual(counts, [1, 0, 1])
  }

  func testFailedNoteTransactionPublishesNothingAndRollsBackAllRecords() throws {
    let database = try LibraryDatabase.open(inMemory: true), ctx = database.mainContext
    let invalid = NoteRecord(title: "失联笔记", parentBookID: UUID())
    XCTAssertThrowsError(try LibraryRepository.apply([record()], notes: [invalid], into: ctx))
    XCTAssertEqual(LibraryNotifier.forContext(ctx).revision, 0)
    XCTAssertTrue(try ctx.fetch(FetchDescriptor<Book>()).isEmpty)
  }

  func testLibraryScopesDoNotShareEventsOrErrors() throws {
    let a = try LibraryDatabase.open(inMemory: true), b = try LibraryDatabase.open(inMemory: true)
    LibraryServices.forContext(a.mainContext).history.errorMessage = "库 A 的错误"
    try LibraryCommands(context: a.mainContext, undoManager: nil).save(record(), expected: nil)
    XCTAssertNil(LibraryServices.forContext(b.mainContext).history.errorMessage)
    XCTAssertEqual(LibraryNotifier.forContext(b.mainContext).revision, 0)
    XCTAssertEqual(try b.mainContext.fetch(FetchDescriptor<Book>()).count, 0)
    // Even identical records in another context cannot be edited via foreign model objects.
    let source = try XCTUnwrap(a.mainContext.fetch(FetchDescriptor<Book>()).first)
    let snapshot = BookArchive(book: source)
    try LibraryRepository.apply([snapshot], into: b.mainContext)
    XCTAssertThrowsError(try LibraryCommands(context: b.mainContext, undoManager: nil)
      .update([source]) { $0.notes = "错误书库的写入" })
    XCTAssertEqual(try LibraryRepository.snapshots(in: b.mainContext), [snapshot.id: snapshot])
    XCTAssertEqual(LibraryNotifier.forContext(b.mainContext).revision, 1)
  }

  func testStaleEditorCannotOverwriteAnotherCommand() throws {
    let database = try LibraryDatabase.open(inMemory: true), ctx = database.mainContext
    let commands = LibraryCommands(context: ctx, undoManager: nil)
    try commands.save(record(), expected: nil)
    let book = try XCTUnwrap(ctx.fetch(FetchDescriptor<Book>()).first), expected = BookArchive(book: book)
    try commands.update([book]) { $0.publisher = "其他窗口的新出版社" }
    var draft = expected; draft.title = "过期编辑"
    XCTAssertThrowsError(try commands.save(draft, expected: expected))
    XCTAssertEqual(book.publisher, "其他窗口的新出版社"); XCTAssertEqual(book.title, expected.title)
    XCTAssertEqual(LibraryNotifier.forContext(ctx).revision, 2)
  }

  func testStaleNoteCannotOverwriteNewNotes() throws {
    let database = try LibraryDatabase.open(inMemory: true), ctx = database.mainContext
    let commands = LibraryCommands(context: ctx, undoManager: nil)
    try commands.save(record(), expected: nil)
    let book = try XCTUnwrap(ctx.fetch(FetchDescriptor<Book>()).first), expected = BookArchive(book: book)
    try commands.saveNote("新笔记", expected: expected)
    XCTAssertThrowsError(try commands.saveNote("旧窗口笔记", expected: expected))
    XCTAssertEqual(book.notes, "新笔记")
  }

  func testNoOpDoesNotPublishOrCreateUndo() throws {
    let database = try LibraryDatabase.open(inMemory: true), ctx = database.mainContext, undo = undoManager()
    try LibraryCommands(context: ctx, undoManager: nil).save(record(), expected: nil)
    let book = try XCTUnwrap(ctx.fetch(FetchDescriptor<Book>()).first), baseline = BookArchive(book: book)
    try LibraryCommands(context: ctx, undoManager: undo).update([book]) { _ in }
    XCTAssertFalse(undo.canUndo); XCTAssertEqual(BookArchive(book: book), baseline)
    XCTAssertEqual(LibraryNotifier.forContext(ctx).revision, 1)
  }

  func testCollectionCreationRenameAndUndoKeepMembership() throws {
    let database = try LibraryDatabase.open(inMemory: true), ctx = database.mainContext, undo = undoManager()
    let collections = CollectionCommands(context: ctx, undoManager: undo)
    undo.beginUndoGrouping(); let id = try collections.save(name: "文件夹甲", replacing: nil); undo.endUndoGrouping()
    let collection = try XCTUnwrap(ctx.fetch(FetchDescriptor<BookCollection>()).first)
    XCTAssertEqual(collection.id, id)
    undo.undo(); XCTAssertTrue(try ctx.fetch(FetchDescriptor<BookCollection>()).isEmpty)
    undo.redo()
    let restored = try XCTUnwrap(ctx.fetch(FetchDescriptor<BookCollection>()).first)
    try LibraryCommands(context: ctx, undoManager: nil).save(record(), expected: nil)
    let book = try XCTUnwrap(ctx.fetch(FetchDescriptor<Book>()).first)
    try LibraryCommands(context: ctx, undoManager: nil).setMembership([book], collection: restored, included: true)
    let membershipID = try XCTUnwrap(book.collectionItems.first?.id)
    undo.beginUndoGrouping(); _ = try collections.save(name: "文件夹乙", replacing: ManualCollectionRecord(restored)); undo.endUndoGrouping()
    XCTAssertEqual(book.collectionItems.first?.collection?.name, "文件夹乙")
    undo.undo()
    XCTAssertEqual(book.collectionItems.first?.collection?.name, "文件夹甲")
    XCTAssertEqual(book.collectionItems.first?.id, membershipID)
    // The older creation undo must not remove a collection that has since acquired a book.
    undo.undo(); XCTAssertNotNil(LibraryServices.forContext(ctx).history.errorMessage)
    XCTAssertEqual(book.collectionItems.first?.collection?.id, id)
  }

  func testTagsMembershipAndTrashCommandsUseOneWriter() throws {
    let database = try LibraryDatabase.open(inMemory: true), ctx = database.mainContext
    let commands = LibraryCommands(context: ctx, undoManager: nil)
    try commands.save(record(), expected: nil)
    let book = try XCTUnwrap(ctx.fetch(FetchDescriptor<Book>()).first)
    try commands.setTag("  文学 ", included: true, book: book)
    try commands.setTag("文学", included: true, book: book)
    XCTAssertEqual(book.tagLinks.count, 1)
    try commands.setTag("文学", included: false, book: book); XCTAssertTrue(book.tagLinks.isEmpty)
    try LibraryOperations.setTrashed(true, books: [book], context: ctx, undoManager: nil)
    XCTAssertThrowsError(try commands.update([book]) { $0.notes = "不应写入" })
    XCTAssertNil(book.notes)
  }

  func testCentralQueryFindsTranslatorsSeriesAndEquivalentISBN() throws {
    let database = try LibraryDatabase.open(inMemory: true), ctx = database.mainContext
    var draft = record(); draft.isbn10 = "0306406152"
    draft.contributors = [ContributorArchive(name: "测试译者", role: .translator, order: 0)]
    draft.seriesMemberships = [SeriesMembershipArchive(name: "科学书系", volume: "1")]
    try LibraryCommands(context: ctx, undoManager: nil).save(draft, expected: nil)
    let books = try ctx.fetch(FetchDescriptor<Book>())
    for text in ["测试译者", "科学书系", "9780306406157"] {
      XCTAssertEqual(LibraryQueries.results(books, collections: [], request: LibraryQueryRequest(text: text)).count, 1)
    }
    XCTAssertTrue(LibraryQueries.results(books, collections: [], request: LibraryQueryRequest(selection: .smart(UUID()))).isEmpty)
  }

  func testRegistryAdvertisesAllFourCapabilities() throws {
    let registry = TranslatorRegistry()
    try registry.validate()
    XCTAssertEqual(registry.capabilities(for: "douban-books"), [.web, .search])
    XCTAssertEqual(registry.capabilities(for: "goodreads-books"), [.web, .search])
    XCTAssertEqual(registry.capabilities(for: "open-library"), [.search])
    XCTAssertEqual(registry.capabilities(for: "ris"), [.fileImport, .fileExport])
    XCTAssertEqual(registry.capabilities(for: "csv"), [.fileExport])
  }

  func testDuplicateIDsAndDisabledFileTranslatorsAreRejected() throws {
    XCTAssertThrowsError(try TranslatorRegistry(translators: [RISTranslator(), RISTranslator()]).validate())
    let engine = TranslationEngine(registry: TranslatorRegistry(disabledIDs: ["ris", "csv"]))
    XCTAssertThrowsError(try engine.importFile(Data("TY  - BOOK\nTI  - 测试\nER  - \n".utf8)))
    XCTAssertThrowsError(try engine.exportFile([record()], translatorID: "ris"))
    XCTAssertThrowsError(try engine.exportFile([record()], translatorID: "csv"))
  }

  func testNewFileTranslatorWorksWithoutChangingDispatcher() throws {
    let engine = TranslationEngine(registry: TranslatorRegistry(translators: [ExampleExchangeTranslator()]))
    let imported = try engine.importFile(Data("自制图书".utf8), fileExtension: "example")
    XCTAssertEqual(imported.records.first?.title, "自制图书")
    let output = try engine.exportFile(imported.records, translatorID: "example-exchange")
    XCTAssertEqual(String(data: output, encoding: .utf8), "自制图书")
  }

  func testDisabledOpenLibraryAlsoRejectsCachedResults() async throws {
    let engine = TranslationEngine(registry: TranslatorRegistry(disabledIDs: ["open-library"]))
    XCTAssertFalse(engine.registry.searchSources.contains(.openLibrary))
    let result = BookMetadataSearchResult(id: "cached", title: "缓存图书", subtitle: nil, authors: [], publisher: nil,
      publicationDate: nil, isbn10: nil, isbn13: nil, pageCount: nil, languageCode: nil, sourceName: "Open Library")
    do {
      _ = try await engine.resolve(MetadataSearchHit(source: .openLibrary, candidate: nil, metadata: result))
      XCTFail("Disabled cached result should be rejected")
    } catch { guard case WebMetadataError.disabled = error else { return XCTFail("Unexpected error") } }
  }

  func testRegistryPreferencesPersistForSearchImportAndExport() throws {
    let name = "BookshelfArchitecture-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
    let store = TranslatorStore(directory: directory, defaults: defaults)
    for id in ["open-library", "ris", "csv"] { store.setEnabled(false, for: id) }
    let reloaded = TranslatorStore(directory: directory, defaults: defaults)
    for id in ["open-library", "ris", "csv"] {
      XCTAssertFalse(reloaded.isEnabled(id)); XCTAssertTrue(reloaded.isBuiltin(id))
    }
    XCTAssertEqual(reloaded.registry.translators.count, 2)
  }
}

private struct ExampleExchangeTranslator: FileImportTranslator, FileExportTranslator {
  let descriptor = TranslatorDescriptor(id: "example-exchange", name: "示例", version: "1", author: "Tests",
    targetDescription: "自制本地样例", priority: 1)
  let fileExtensions = ["example"], fileExtension = "example", exportSummary = "测试扩展接口"
  @MainActor func detectImport(_ data: Data) -> Bool { !data.isEmpty }
  @MainActor func doImport(_ data: Data) throws -> BibliographicImportResult {
    BibliographicImportResult(records: [BookArchive(book: Book(title: String(decoding: data, as: UTF8.self)))],
      totalCount: 1, notices: [], formatName: "示例")
  }
  @MainActor func doExport(_ records: [BookArchive], includeNotes: Bool) throws -> Data {
    Data(records.map(\.title).joined(separator: "\n").utf8)
  }
}
