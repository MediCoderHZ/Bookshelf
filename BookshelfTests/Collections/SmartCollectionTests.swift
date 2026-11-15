import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class SmartCollectionTests: XCTestCase {
  private func container() throws -> ModelContainer {
    try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
  }
  private func query(_ field: SearchBookField = .publisher, _ comparison: SearchComparison = .contains, _ value: String = "测试") -> AdvancedBookQuery {
    AdvancedBookQuery(rules: [BookSearchRule(field: field, comparison: comparison, value: value)])
  }
  private func undoManager() -> UndoManager { let u = UndoManager(); u.groupsByEvent = false; return u }
  private func archive(books: [BookArchive] = [], smart: [SmartCollectionArchive]? = nil, version: Int = 3) throws -> Data {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(LibraryArchive(schemaVersion: version, exportedAt: Date(), books: books, smartCollections: smart))
  }

  func testAllAnyEmptyAndTrashSemantics() {
    let book = Book(title: "测试书"); book.publisher = "出版社"; book.pageCount = 400
    var q = AdvancedBookQuery(rules: [BookSearchRule(field: .publisher, comparison: .contains, value: "出版社"),
      BookSearchRule(field: .pageCount, comparison: .atLeast, value: "450")])
    XCTAssertFalse(q.matches(book)); q.mode = .any; XCTAssertTrue(q.matches(book))
    XCTAssertTrue(AdvancedBookQuery().matches(book))
    book.deletedAt = Date()
    XCTAssertFalse(q.matches(book)); XCTAssertFalse(AdvancedBookQuery().matches(book))
  }

  func testTextNormalizationISBNEquivalenceAndUnknownValues() {
    let book = Book(title: "ＣＡＦÉ 文学"); book.isbn13 = "9780306406157"
    XCTAssertTrue(query(.title, .contains, "cafe").matches(book))
    XCTAssertTrue(query(.isbn, .equals, "0-306-40615-2").matches(book))
    XCTAssertTrue(query(.isbn, .contains, "978-030").matches(book))
    XCTAssertTrue(query(.publisher, .isEmpty, "").matches(book))
    XCTAssertTrue(query(.publisher, .notContains, "别家").matches(book))
    XCTAssertFalse(query(.publisher, .equals, "出版社").matches(book))
  }

  func testNumericComparisonsPreserveMissingValues() {
    let book = Book(title: "数字验收")
    XCTAssertFalse(query(.pageCount, .atMost, "5").matches(book))
    XCTAssertTrue(query(.pageCount, .isEmpty, "").matches(book))
    book.pageCount = 0; book.publicationDate = "2024-07"
    XCTAssertTrue(query(.pageCount, .equals, "0").matches(book))
    XCTAssertTrue(query(.publicationYear, .atLeast, "2024").matches(book))
    XCTAssertNil(BookSearchRule.publicationYear("20245"))
    XCTAssertNil(BookSearchRule.publicationYear("未知"))
    XCTAssertEqual(BookSearchRule.publicationYear("2003年8月"), 2003)
  }

  func testInvalidRulesAndUnknownVersionsNeverMatch() throws {
    let book = Book(title: "书")
    for q in [query(.pageCount, .equals, "4.2"), query(.pageCount, .equals, "nan"), query(.pageCount, .atMost, "-1"),
      query(.publisher, .atLeast, "1"), query(.title, .contains, " ")] {
      XCTAssertNotNil(q.validationMessage); XCTAssertFalse(q.matches(book)); XCTAssertThrowsError(try q.encoded())
    }
    var q = query(); q.version = 2
    XCTAssertFalse(q.matches(book))
    XCTAssertThrowsError(try AdvancedBookQuery.decode("{\"version\":9,\"mode\":\"all\",\"rules\":[]}"))
  }

  func testDynamicPublisherAndNotesConditionsDoNotCreateMembership() throws {
    let c = try container(), ctx = c.mainContext
    let book = Book(title: "动态书籍"); ctx.insert(book); try ctx.save()
    let id = try SmartCollectionService.save(name: "已读", query: query(.publisher, .equals, "测试出版社"), context: ctx, undoManager: nil)
    let smart = try XCTUnwrap(ctx.fetch(FetchDescriptor<BookCollection>()).first { $0.id == id })
    XCTAssertFalse(smart.smartQuery!.matches(book))
    book.publisher = "测试出版社"; try ctx.save()
    XCTAssertTrue(smart.smartQuery!.matches(book))
    LibraryOrganization.setMembership(of: book, in: smart, included: true, context: ctx)
    XCTAssertTrue(smart.items.isEmpty); XCTAssertTrue(book.collectionItems.isEmpty)
    book.notes = "阅读笔记"; book.publisher = "测试出版社"
    XCTAssertTrue(query(.notes, .isNotEmpty, "").matches(book))
    XCTAssertTrue(query(.publisher, .equals, "测试出版社").matches(book))
    book.deletedAt = Date(); XCTAssertFalse(smart.smartQuery!.matches(book))
  }

  func testCreateEditRemoveSupportUndoRedoWithoutChangingBooks() throws {
    let c = try container(), ctx = c.mainContext, undo = undoManager()
    let book = Book(title: "保持原书"); book.notes = "保留"; ctx.insert(book); try ctx.save()
    let original = BookArchive(book: book)
    undo.beginUndoGrouping()
    let id = try SmartCollectionService.save(name: "候选", query: query(), context: ctx, undoManager: undo)
    undo.endUndoGrouping()
    undo.undo(); XCTAssertTrue(try SmartCollectionService.snapshots(in: ctx).isEmpty)
    undo.redo()
    let expected = try XCTUnwrap(SmartCollectionService.snapshots(in: ctx)[id])
    undo.beginUndoGrouping()
    _ = try SmartCollectionService.save(name: "改名", query: query(.pageCount, .isEmpty, ""), replacing: expected, context: ctx, undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx)[id]?.name, "改名")
    undo.undo(); XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx)[id], expected)
    let collection = try XCTUnwrap(ctx.fetch(FetchDescriptor<BookCollection>()).first)
    undo.beginUndoGrouping(); try SmartCollectionService.remove(collection, context: ctx, undoManager: undo); undo.endUndoGrouping()
    XCTAssertTrue(try SmartCollectionService.snapshots(in: ctx).isEmpty)
    undo.undo(); XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx)[id], expected)
    XCTAssertEqual(BookArchive(book: book), original)
    XCTAssertNil(LibraryServices.forContext(ctx).history.errorMessage)
  }

  func testDuplicateNamesAndStaleEditsAreRejected() throws {
    let c = try container(), ctx = c.mainContext
    let id = try SmartCollectionService.save(name: "查询", query: query(), context: ctx, undoManager: nil)
    XCTAssertThrowsError(try SmartCollectionService.save(name: " 查询 ", query: query(), context: ctx, undoManager: nil))
    let old = try XCTUnwrap(SmartCollectionService.snapshots(in: ctx)[id])
    _ = try SmartCollectionService.save(name: "新版", query: query(), replacing: old, context: ctx, undoManager: nil)
    XCTAssertThrowsError(try SmartCollectionService.save(name: "覆盖", query: query(), replacing: old, context: ctx, undoManager: nil))
    XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx)[id]?.name, "新版")
  }

  func testSmartBackupRoundTripAndOldArchivesKeepExistingQueries() throws {
    let c = try container(), ctx = c.mainContext
    _ = try SmartCollectionService.save(name: "待补信息", query: query(.isbn, .isEmpty, ""), context: ctx, undoManager: nil)
    let data = try LibraryBackupService.exportData(from: ctx)
    let decoded = try LibraryBackupService.decode(data)
    XCTAssertEqual(decoded.schemaVersion, 9); XCTAssertEqual(decoded.smartCollections?.count, 1)
    let target = try container()
    let plan = try LibraryImportPlanner.prepare(data, context: target.mainContext)
    let summary = try LibraryImportPlanner.apply(plan, choices: [:], context: target.mainContext, undoManager: nil)
    XCTAssertEqual(summary.createdSmartCount, 1)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: target.mainContext).values.first?.query, decoded.smartCollections?.first?.query)
    for version in [1,2] {
      let old = try LibraryImportPlanner.prepare(archive(version: version), context: target.mainContext)
      _ = try LibraryImportPlanner.apply(old, choices: [:], context: target.mainContext, undoManager: nil)
      XCTAssertEqual(try SmartCollectionService.snapshots(in: target.mainContext).count, 1)
    }
  }

  func testImportBookAndSmartCollectionUndoRedoTogether() throws {
    let c = try container(), ctx = c.mainContext, undo = undoManager()
    let smart = SmartCollectionArchive(name: "导入查询", query: query())
    let incoming = BookArchive(book: Book(title: "导入书籍"))
    let plan = try LibraryImportPlanner.prepare(archive(books: [incoming], smart: [smart]), context: ctx)
    undo.beginUndoGrouping()
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: ctx, undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 1)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx).count, 1)
    undo.undo()
    XCTAssertTrue(try ctx.fetch(FetchDescriptor<Book>()).isEmpty)
    XCTAssertTrue(try SmartCollectionService.snapshots(in: ctx).isEmpty)
    undo.redo()
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 1)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx).count, 1)
    XCTAssertNil(LibraryServices.forContext(ctx).history.errorMessage)
  }

  func testImportConflictsSkipAndCanExcludeSmartDefinitions() throws {
    let c = try container(), ctx = c.mainContext
    let id = try SmartCollectionService.save(name: "本地条件", query: query(), context: ctx, undoManager: nil)
    let original = try SmartCollectionService.snapshots(in: ctx)
    let records = [SmartCollectionArchive(id: id, name: "新名字", query: query(.pageCount, .isEmpty, "")),
      SmartCollectionArchive(name: "本地条件", query: query()), SmartCollectionArchive(name: "新增条件", query: query()),
      SmartCollectionArchive(name: " 新增条件 ", query: query(.notes, .isNotEmpty, ""))]
    let plan = try LibraryImportPlanner.prepare(archive(smart: records), context: ctx)
    XCTAssertEqual(plan.existingSmartIDs.count, 3)
    let disabled = try LibraryImportPlanner.apply(plan, choices: [:], context: ctx, undoManager: nil, includeSmartCollections: false)
    XCTAssertEqual(disabled.createdSmartCount, 0); XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx), original)
    let imported = try LibraryImportPlanner.apply(plan, choices: [:], context: ctx, undoManager: nil)
    XCTAssertEqual(imported.createdSmartCount, 1); XCTAssertEqual(imported.skippedSmartCount, 3)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx)[id], original[id])
  }

  func testFailedNoteTransactionRollsBackSmartDefinitionAndBooksTogether() throws {
    let c = try container(), ctx = c.mainContext
    let book = BookArchive(book: Book(title: "不能留下"))
    let smart = SmartCollectionArchive(name: "必须回滚", query: query())
    let note = NoteRecord(title: "失联笔记", parentBookID: UUID())
    XCTAssertThrowsError(try LibraryRepository.apply([book], smartCollections: [smart], notes: [note], into: ctx))
    XCTAssertTrue(try ctx.fetch(FetchDescriptor<Book>()).isEmpty)
    XCTAssertTrue(try SmartCollectionService.snapshots(in: ctx).isEmpty)
  }

  func testSameNamedManualCollectionRemainsManualDuringBackupImport() throws {
    let c = try container(), ctx = c.mainContext
    let manual = BookCollection(name: "同名文件夹"), book = Book(title: "普通归属")
    ctx.insert(manual); ctx.insert(book)
    LibraryOrganization.setMembership(of: book, in: manual, included: true, context: ctx)
    try ctx.save()
    let smart = SmartCollectionArchive(id: manual.id, name: manual.name, query: query())
    let plan = try LibraryImportPlanner.prepare(archive(smart: [smart]), context: ctx)
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: ctx, undoManager: nil)
    XCTAssertFalse(manual.isSmart); XCTAssertEqual(book.collectionItems.first?.collection?.id, manual.id)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx).count, 1)
    let target = try container()
    _ = try LibraryBackupService.importData(LibraryBackupService.exportData(from: ctx), into: target.mainContext)
    let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<Book>()).first)
    XCTAssertFalse(try XCTUnwrap(restored.collectionItems.first?.collection).isSmart)
  }

  func testSmartRulesPersistAfterReopeningStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = ModelConfiguration(url: directory.appendingPathComponent("library.store"))
    let q = query(.pageCount, .isEmpty, "")
    do {
      let c = try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self, configurations: configuration)
      _ = try SmartCollectionService.save(name: "重启保留", query: q, context: c.mainContext, undoManager: nil)
    }
    let reopened = try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self, configurations: configuration)
    let saved = try XCTUnwrap(SmartCollectionService.snapshots(in: reopened.mainContext).values.first)
    XCTAssertEqual(saved.name, "重启保留"); XCTAssertEqual(saved.query, q)
  }

  func testInvalidSmartDefinitionsRejectArchiveWithoutMutations() throws {
    let record = SmartCollectionArchive(name: "不完整", query: AdvancedBookQuery())
    XCTAssertThrowsError(try LibraryBackupService.decode(archive(smart: [record])))
    let duplicate = SmartCollectionArchive(name: "重复 ID", query: query())
    XCTAssertThrowsError(try LibraryBackupService.decode(archive(smart: [duplicate,duplicate])))
  }

  private func presetKeys(_ context: ModelContext) -> (installed: String, retired: String) {
    let storeID = context.container.configurations.map { $0.url.standardizedFileURL.absoluteString }.sorted().joined(separator: "|")
    return ("bookTypeSmartCollectionsInstalled.v1." + storeID, "bookTypeSmartCollectionsRetired.v1." + storeID)
  }

  private func legacyPresets(in context: ModelContext, preferences: UserDefaults) throws -> [SmartCollectionArchive] {
    let records = BookType.allCases.map { type in
      SmartCollectionArchive(name: type.title, query: query(.bookType, .equals, type.rawValue))
    }
    try LibraryRepository.apply([], smartCollections: records, into: context)
    preferences.set(true, forKey: presetKeys(context).installed)
    return records
  }

  func testRetiringPresetsPreservesBooksNotesMembershipAndBackup() throws {
    let suite = "BookshelfTypeRetirement." + UUID().uuidString
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let presets = try legacyPresets(in: ctx, preferences: preferences)
    let book = Book(title: "保留的书"); book.bookTypeRaw = BookType.chineseOriginal.rawValue
    book.publisher = "测试出版社"
    let collection = BookCollection(name: "我的文件夹"), note = LibraryNote(title: "笔记", body: "保留正文")
    ctx.insert(book); ctx.insert(collection); ctx.insert(note)
    note.parentBookID = book.id
    ctx.insert(CollectionItem(collection: collection, book: book)); try ctx.save()
    let beforeBook = BookArchive(book: book), beforeNote = NoteRecord(note)
    try SmartCollectionService.retireBookTypeDefaults(in: ctx, preferences: preferences)
    XCTAssertTrue(try SmartCollectionService.snapshots(in: ctx).isEmpty)
    XCTAssertEqual(BookArchive(book: book), beforeBook)
    XCTAssertEqual(NoteRecord(note), beforeNote)
    XCTAssertEqual(book.collectionItems.compactMap(\.collection?.id), [collection.id])
    let data = try XCTUnwrap(preferences.data(forKey: presetKeys(ctx).retired + ".backup"))
    let backup = try JSONDecoder().decode([SmartCollectionArchive].self, from: data)
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: backup.map { ($0.id, $0) }),
      Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) }))
  }

  func testRetiringPresetsPreservesCustomAndEditedCollections() throws {
    let suite = "BookshelfTypeRetirement." + UUID().uuidString
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let old = try legacyPresets(in: ctx, preferences: preferences)
    var renamed = old[0]; renamed.name = "我的中文书"
    var edited = old[1]; edited.query = query(.publisher, .contains, "出版社")
    try LibraryRepository.apply([], smartCollections: [renamed, edited], into: ctx)
    let manual = BookCollection(name: BookType.chineseTranslation.title)
    ctx.insert(manual); try ctx.save()
    let customID = try SmartCollectionService.save(name: "自建类型查询",
      query: query(.bookType, .equals, BookType.chineseTranslation.rawValue), context: ctx, undoManager: nil)
    let before = try SmartCollectionService.snapshots(in: ctx)
    try SmartCollectionService.retireBookTypeDefaults(in: ctx, preferences: preferences)
    let after = try SmartCollectionService.snapshots(in: ctx)
    XCTAssertEqual(after, before.filter { $0.key != old[2].id })
    XCTAssertNotNil(after[customID])
    XCTAssertTrue(try ctx.fetch(FetchDescriptor<BookCollection>()).contains { $0.id == manual.id && !$0.isSmart })
  }

  func testRetirementHandlesCollisionNamesAndNeverDeletesLaterUserSearches() throws {
    let suite = "BookshelfTypeRetirement." + UUID().uuidString
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    var old = try legacyPresets(in: ctx, preferences: preferences)
    old[0].name += "（类型）"; old[1].name += "（类型 2）"
    try LibraryRepository.apply([], smartCollections: old, into: ctx)
    try SmartCollectionService.retireBookTypeDefaults(in: ctx, preferences: preferences)
    XCTAssertTrue(try SmartCollectionService.snapshots(in: ctx).isEmpty)
    _ = try SmartCollectionService.save(name: BookType.chineseOriginal.title,
      query: query(.bookType, .equals, BookType.chineseOriginal.rawValue), context: ctx, undoManager: nil)
    let before = try SmartCollectionService.snapshots(in: ctx)
    let backup = preferences.data(forKey: presetKeys(ctx).retired + ".backup")
    try SmartCollectionService.retireBookTypeDefaults(in: ctx, preferences: preferences)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx), before)
    XCTAssertEqual(preferences.data(forKey: presetKeys(ctx).retired + ".backup"), backup)
  }

  func testNewLibrariesDoNotInstallPresetsOrRemoveUserTypeSearches() throws {
    let suite = "BookshelfTypeRetirement." + UUID().uuidString
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    try SmartCollectionService.retireBookTypeDefaults(in: ctx, preferences: preferences)
    XCTAssertTrue(try SmartCollectionService.snapshots(in: ctx).isEmpty)
    let other = try LibraryDatabase.open(inMemory: true), otherContext = other.mainContext
    _ = try SmartCollectionService.save(name: BookType.englishOriginal.title,
      query: query(.bookType, .equals, BookType.englishOriginal.rawValue), context: otherContext, undoManager: nil)
    let before = try SmartCollectionService.snapshots(in: otherContext)
    try SmartCollectionService.retireBookTypeDefaults(in: otherContext, preferences: preferences)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: otherContext), before)
  }

  func testRetirementPersistsAcrossReopeningAndIsScopedToEachStore() throws {
    let suite = "BookshelfTypeRetirement." + UUID().uuidString
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("first.store")
    do {
      let db = try LibraryDatabase.open(at: url)
      _ = try legacyPresets(in: db.mainContext, preferences: preferences)
      try SmartCollectionService.retireBookTypeDefaults(in: db.mainContext, preferences: preferences)
    }
    let reopened = try LibraryDatabase.open(at: url)
    try SmartCollectionService.retireBookTypeDefaults(in: reopened.mainContext, preferences: preferences)
    XCTAssertTrue(try SmartCollectionService.snapshots(in: reopened.mainContext).isEmpty)
    let other = try LibraryDatabase.open(at: directory.appendingPathComponent("second.store"))
    _ = try legacyPresets(in: other.mainContext, preferences: preferences)
    try SmartCollectionService.retireBookTypeDefaults(in: other.mainContext, preferences: preferences)
    XCTAssertTrue(try SmartCollectionService.snapshots(in: other.mainContext).isEmpty)
    XCTAssertNotNil(preferences.data(forKey: presetKeys(reopened.mainContext).retired + ".backup"))
    XCTAssertNotNil(preferences.data(forKey: presetKeys(other.mainContext).retired + ".backup"))
  }
}
