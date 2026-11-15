import AppKit
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class BookTypeTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func saveType(_ type: BookType, book: Book, context: ModelContext, undo: UndoManager? = nil) throws {
    try BookMetadataCommands(context: context, undoManager: undo).save(bookID: book.id, field: .bookType,
      text: type.rawValue, expected: .read(.bookType, from: BookArchive(book: book)))
  }

  func testTypeChangePreservesHiddenTranslatorAndOriginalMetadataWithOneUndo() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let book = Book(title: "译本"); book.bookTypeRaw = BookType.chineseTranslation.rawValue
    book.originalTitle = "Original Title"; book.originalLanguageCode = "ja"; book.languageCode = "zh-Hant"
    book.publisher = "原出版社"; context.insert(book)
    let person = Person(name: "译者甲"); context.insert(person)
    context.insert(Contribution(book: book, person: person, role: .translator, displayOrder: 0)); try context.save()
    let before = BookArchive(book: book), undo = UndoManager(); undo.groupsByEvent = false
    undo.beginUndoGrouping(); try saveType(.englishOriginal, book: book, context: context, undo: undo); undo.endUndoGrouping()
    XCTAssertEqual(book.bookType, .englishOriginal)
    XCTAssertEqual(book.translators.map(\.name), ["译者甲"])
    XCTAssertEqual(book.originalTitle, "Original Title"); XCTAssertEqual(book.originalLanguageCode, "ja")
    XCTAssertEqual(book.languageCode, "zh-Hant"); XCTAssertEqual(book.publisher, "原出版社")
    XCTAssertFalse(BookMetadataLayout.allows(.translators, type: book.bookType))
    XCTAssertEqual(BookRecordMerge.origins(BookArchive(book: book))["bookType"]?.name, "手动编辑")
    undo.undo(); XCTAssertEqual(BookArchive(book: book), before); XCTAssertFalse(undo.canUndo)
    XCTAssertTrue(BookMetadataLayout.requiresVisible(.translators, type: book.bookType))
    undo.redo(); XCTAssertEqual(book.bookType, .englishOriginal)
  }

  func testEmptyTranslationShowsTranslatorAndOriginalTypesHideIt() {
    XCTAssertEqual(BookType.allCases.map(\.title), ["中文原版书", "英文原版书", "中文译本"])
    XCTAssertTrue(BookMetadataLayout.requiresVisible(.translators, type: .chineseTranslation))
    for type in [BookType.chineseOriginal, .englishOriginal] {
      XCTAssertFalse(BookMetadataLayout.allows(.translators, type: type))
      XCTAssertTrue(BookMetadataLayout.requiresVisible(.authors, type: type))
    }
    XCTAssertTrue(BookMetadataLayout.allows(.translators, type: nil))
  }

  func testNoInferenceFromTitleLanguageOrMissingTranslator() {
    let book = Book(title: "中文书名"); book.languageCode = "en"
    XCTAssertNil(book.bookType)
    let source = BookMetadataSearchResult(id: "test", title: "中文译名", subtitle: nil, authors: ["作者"],
      publisher: nil, publicationDate: nil, isbn10: nil, isbn13: nil, pageCount: nil, languageCode: "zh",
      sourceName: "测试来源", translators: ["译者"])
    let record = BookArchive(metadata: source)
    XCTAssertNil(record.bookTypeRaw); XCTAssertEqual(record.contributors.last?.name, "译者")
  }

  func testInvalidSameValueConflictAndTrashedEditsDoNotOverwrite() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let book = Book(title: "类型校验"); context.insert(book); try context.save()
    let old = BookMetadataValue.read(.bookType, from: BookArchive(book: book))
    let commands = BookMetadataCommands(context: context, undoManager: nil)
    XCTAssertThrowsError(try commands.save(bookID: book.id, field: .bookType, text: "其他类型", expected: old))
    try saveType(.chineseOriginal, book: book, context: context)
    let before = BookArchive(book: book), undo = UndoManager()
    try saveType(.chineseOriginal, book: book, context: context, undo: undo)
    XCTAssertEqual(BookArchive(book: book), before); XCTAssertFalse(undo.canUndo)
    XCTAssertThrowsError(try commands.save(bookID: book.id, field: .bookType, text: BookType.englishOriginal.rawValue, expected: old))
    book.deletedAt = Date(); try context.save()
    XCTAssertThrowsError(try saveType(.englishOriginal, book: book, context: context))
    XCTAssertEqual(book.bookType, .chineseOriginal)
  }

  func testOriginalLanguageUsesExistingAutosaveRecoveryAndUndo() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let book = Book(title: "译本"); context.insert(book); try context.save()
    let session = BookMetadataEditingSession(store: BookMetadataDraftStore(directory: try directory()))
    session.begin(BookArchive(book: book), field: .originalLanguage)
    session.update(book.id, field: .originalLanguage, text: "日语")
    let undo = UndoManager(); undo.groupsByEvent = false
    undo.beginUndoGrouping(); XCTAssertTrue(session.commit(book.id, field: .originalLanguage, context: context, undoManager: undo)); undo.endUndoGrouping()
    XCTAssertEqual(book.originalLanguageCode, "日语")
    undo.undo(); XCTAssertNil(book.originalLanguageCode)
    undo.redo(); XCTAssertEqual(book.originalLanguageCode, "日语")
  }

  func testTypeFiltersAndSmartCollectionRoundTripIncludeUnclassifiedRecords() throws {
    let book = Book(title: "筛选"); book.bookTypeRaw = BookType.chineseTranslation.rawValue
    let rule = BookSearchRule(field: .bookType, comparison: .equals, value: BookType.chineseTranslation.rawValue)
    var query = AdvancedBookQuery(rules: [rule]); XCTAssertTrue(query.matches(book))
    XCTAssertEqual(try AdvancedBookQuery.decode(query.encoded()), query)
    book.bookTypeRaw = BookType.englishOriginal.rawValue; XCTAssertFalse(query.matches(book))
    query.rules[0].comparison = .notEquals; XCTAssertTrue(query.matches(book))
    book.bookTypeRaw = nil; query.rules[0].comparison = .isEmpty; XCTAssertTrue(query.matches(book))
    query.rules[0].comparison = .isNotEmpty; XCTAssertFalse(query.matches(book))
    XCTAssertNil(query.validationMessage)
  }

  func testNewBackupRestoresTypesOriginalLanguageAndSmartFilter() throws {
    let source = try LibraryDatabase.open(inMemory: true), target = try LibraryDatabase.open(inMemory: true)
    for type in BookType.allCases {
      let book = Book(title: type.title); book.bookTypeRaw = type.rawValue; book.originalLanguageCode = type.isTranslation ? "en" : nil
      source.mainContext.insert(book)
    }
    let legacy = Book(title: "未设置"); source.mainContext.insert(legacy)
    let smart = SmartCollectionArchive(name: "中文译本", query: AdvancedBookQuery(rules: [BookSearchRule(field: .bookType, comparison: .equals, value: BookType.chineseTranslation.rawValue)]))
    try source.mainContext.save(); try LibraryRepository.apply([], smartCollections: [smart], into: source.mainContext)
    let data = try LibraryBackupService.exportData(from: source.mainContext)
    XCTAssertEqual(try LibraryBackupService.decode(data).schemaVersion, 9)
    let plan = try LibraryImportPlanner.prepare(data, context: target.mainContext)
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: target.mainContext, undoManager: nil)
    let restored = try target.mainContext.fetch(FetchDescriptor<Book>())
    XCTAssertEqual(restored.count, 4); XCTAssertEqual(Set(restored.compactMap(\.bookType)), Set(BookType.allCases))
    XCTAssertEqual(restored.first { $0.bookType == .chineseTranslation }?.originalLanguageCode, "en")
    XCTAssertNil(restored.first { $0.id == legacy.id }?.bookTypeRaw)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: target.mainContext)[smart.id]?.query, smart.query)
  }

  func testOldBackupsWithoutNewFieldsLoadWithoutGuessing() throws {
    var record = BookArchive(book: Book(title: "旧书"))
    record.contributors = [ContributorArchive(name: "译者", roleRaw: "translator", displayOrder: 0)]
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    for version in 1...4 {
      let data = try encoder.encode(LibraryArchive(schemaVersion: version, exportedAt: Date(), books: [record]))
      let restored = try LibraryBackupService.decode(data).books[0]
      XCTAssertNil(restored.bookTypeRaw); XCTAssertNil(restored.originalLanguageCode)
      XCTAssertEqual(restored.contributors, record.contributors)
    }
  }

  func testMetadataRefreshAndMergeRespectExplicitFieldChoices() {
    var current = BookArchive(book: Book(title: "当前")); current.bookTypeRaw = BookType.chineseTranslation.rawValue
    current.originalLanguageCode = "ja"
    current.contributors = [ContributorArchive(name: "译者", roleRaw: "translator", displayOrder: 0)]
    var incoming = BookArchive(book: Book(title: "来源")); incoming.publisher = "新出版社"
    let refreshed = BookRecordMerge.applyingMetadata(incoming, to: current, fields: [.publisher])
    XCTAssertEqual(refreshed.bookType, current.bookType); XCTAssertEqual(refreshed.originalLanguageCode, "ja")
    XCTAssertEqual(refreshed.contributors, current.contributors)
    incoming.bookTypeRaw = BookType.englishOriginal.rawValue; incoming.originalLanguageCode = "en"
    let merged = BookRecordMerge.combine(primary: current, others: [incoming], choices: [.bookType: incoming.id, .originalLanguage: incoming.id])
    XCTAssertEqual(merged.bookType, .englishOriginal); XCTAssertEqual(merged.originalLanguageCode, "en")
    XCTAssertEqual(merged.contributors, current.contributors)
  }

  func testRISRoundTripsAllTypesAndRetainedTranslator() throws {
    for type in BookType.allCases {
      var record = BookArchive(book: Book(title: "导出")); record.bookTypeRaw = type.rawValue; record.originalLanguageCode = "ja"
      record.contributors = [ContributorArchive(name: "保留译者", roleRaw: "translator", displayOrder: 0)]
      let data = BibliographicExchange.export([record], format: .ris)
      let result = try BibliographicExchange.decodeRIS(data)
      XCTAssertTrue(result.notices.isEmpty)
      XCTAssertEqual(result.records[0].bookType, type); XCTAssertEqual(result.records[0].originalLanguageCode, "ja")
      XCTAssertEqual(result.records[0].contributors, record.contributors)
      XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("TY  - BOOK"))
    }
  }

  func testOtherApplicationsRISCustomFieldsAreNotMistakenForBookType() throws {
    let data = Data("TY  - BOOK\nTI  - 测试\nLA  - en\nC1  - other\nC2  - unrelated\nA4  - Translator\nER  - \n".utf8)
    let result = try BibliographicExchange.decodeRIS(data)
    XCTAssertNil(result.records[0].bookTypeRaw); XCTAssertNil(result.records[0].originalLanguageCode)
    XCTAssertEqual(result.notices.count, 2); XCTAssertEqual(result.records[0].contributors.count, 1)
  }

  func testCSVIncludesTypeAndOriginalLanguageWithoutLosingISBNTextProtection() {
    var record = BookArchive(book: Book(title: "清单")); record.bookTypeRaw = BookType.chineseTranslation.rawValue
    record.originalLanguageCode = "=unsafe"; record.isbn13 = "9780306406157"
    let csv = String(decoding: BibliographicExchange.export([record], format: .csv), as: UTF8.self)
    XCTAssertTrue(csv.contains("\"条目类型\",\"原作语言\""))
    XCTAssertTrue(csv.contains("\"中文译本\",\"'=unsafe\"")); XCTAssertTrue(csv.contains("\"'9780306406157\""))
  }

  func testDiskPersistenceOfTypeAndOriginalLanguage() throws {
    let url = try directory().appendingPathComponent("library.store")
    do {
      let db = try LibraryDatabase.open(at: url), book = Book(title: "持久化")
      db.mainContext.insert(book); try db.mainContext.save()
      try saveType(.chineseTranslation, book: book, context: db.mainContext)
      try BookMetadataCommands(context: db.mainContext, undoManager: nil).save(bookID: book.id, field: .originalLanguage,
        text: "English", expected: .read(.originalLanguage, from: BookArchive(book: book)))
    }
    let reopened = try LibraryDatabase.open(at: url)
    let book = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<Book>()).first)
    XCTAssertEqual(book.bookType, .chineseTranslation); XCTAssertEqual(book.originalLanguageCode, "English")
  }

  func testMigrationFromPreviousApplicationStorePreservesCompleteLibrary() throws {
    guard let path = ProcessInfo.processInfo.environment["BOOKSHELF_LEGACY_TYPE_FIXTURE"] else {
      throw XCTSkip("Set BOOKSHELF_LEGACY_TYPE_FIXTURE to a store generated by the previous application model.")
    }
    let original = URL(fileURLWithPath: path), copy = try directory().appendingPathComponent("legacy")
    try FileManager.default.copyItem(at: original, to: copy)
    let before = try LibraryBackupService.decode(Data(contentsOf: copy.appendingPathComponent("before.json")))
    let db = try LibraryDatabase.open(at: copy.appendingPathComponent("library.store"))
    let books = try db.mainContext.fetch(FetchDescriptor<Book>())
    XCTAssertEqual(Set(books.map(\.id)), Set(before.books.map(\.id)))
    for expected in before.books {
      let actual = try XCTUnwrap(books.first { $0.id == expected.id })
      XCTAssertEqual(BookArchive(book: actual), expected)
      XCTAssertNil(actual.bookTypeRaw); XCTAssertNil(actual.originalLanguageCode)
    }
    let notes = try OrganizationStore.notes(in: db.mainContext)
    XCTAssertEqual(notes.count, before.libraryNotes?.count)
    for note in before.libraryNotes ?? [] { XCTAssertEqual(notes[note.id], note) }
    let collections = try OrganizationStore.collections(in: db.mainContext)
    for collection in before.collections ?? [] { XCTAssertEqual(collections[collection.id], collection) }
    let book = try XCTUnwrap(books.first { $0.deletedAt == nil })
    try saveType(.chineseTranslation, book: book, context: db.mainContext)
    XCTAssertEqual(book.bookType, .chineseTranslation)
    XCTAssertEqual(try LibraryBackupService.decode(LibraryBackupService.exportData(from: db.mainContext)).schemaVersion, 9)
  }
}
