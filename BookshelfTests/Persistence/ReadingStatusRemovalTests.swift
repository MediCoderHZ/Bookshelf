import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class ReadingStatusRemovalTests: XCTestCase {
  func testCoverSchemaMigrationPreservesMetadataNotesAndRelationships() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoverMigration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.store")
    try FileManager.default.copyItem(at: fixture("library.store", folder: "CoverV8"), to: url)
    var queryPhase = "before migration"
    func values(_ sql: String) throws -> [String] {
      var database: OpaquePointer?, statement: OpaquePointer?
      guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
      defer { sqlite3_finalize(statement); sqlite3_close(database) }
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "FixtureQuery", code: 1, userInfo: [NSLocalizedDescriptionKey: queryPhase + ": " + sql + ": " + String(cString: sqlite3_errmsg(database))]) }
      var result: [String] = []
      while sqlite3_step(statement) == SQLITE_ROW { result.append(String(cString: sqlite3_column_text(statement, 0))) }
      return result.sorted()
    }
    let tables = ["ZCONTRIBUTION", "ZBOOKTAG", "ZCOLLECTIONITEM", "ZPERSON", "ZTAG"]
    let oldIDs = try tables.map { try values("SELECT hex(ZID) FROM " + $0) }
    XCTAssertTrue(try values("SELECT name FROM sqlite_master WHERE type = 'table'").contains("ZCOVERASSET"))
    let expected = try LibraryBackupService.decode(Data(contentsOf: fixture("legacy-backup.json", folder: "CoverV8")))
    let db = try LibraryDatabase.open(at: url)
    let exported = try LibraryBackupService.exportData(from: db.mainContext)
    try assertCleanExport(exported, names: ["混合筛选"])
    let actual = try LibraryBackupService.decode(exported)
    XCTAssertEqual(actual.books, expected.books)
    XCTAssertEqual(actual.collections, expected.collections)
    XCTAssertEqual(actual.libraryNotes, expected.libraryNotes)
    XCTAssertEqual(actual.smartCollections?.first?.query.rules.map(\.field), [.publisher])
    let origins = BookRecordMerge.origins(try XCTUnwrap(actual.books.first))
    XCTAssertNil(origins["cover"]); XCTAssertEqual(origins["publisher"]?.name, "旧出版来源")
    queryPhase = "after migration"
    XCTAssertEqual(try tables.map { try values("SELECT hex(ZID) FROM " + $0) }, oldIDs)
    XCTAssertFalse(try values("SELECT name FROM pragma_table_info('ZBOOK')").contains("ZCOVERFILENAME"))
    XCTAssertFalse(try values("SELECT name FROM sqlite_master WHERE type = 'table'").contains("ZCOVERASSET"))
    let reopened = try LibraryDatabase.open(at: url)
    let again = try LibraryBackupService.decode(LibraryBackupService.exportData(from: reopened.mainContext))
    XCTAssertEqual(again.books, actual.books); XCTAssertEqual(again.smartCollections, actual.smartCollections)
  }

  func testLegacyCoverBackupIgnoresImagesAndRetainsRemainingData() throws {
    let data = try Data(contentsOf: fixture("legacy-backup.json", folder: "CoverV8"))
    let expected = try LibraryBackupService.decode(data)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var books = try XCTUnwrap(object["books"] as? [[String: Any]])
    // Obsolete image bytes and paths are never decoded, loaded or copied.
    books[0]["coverData"] = "not base64"
    books[0]["coverFileName"] = "../unused.png"
    object["books"] = books
    let db = try LibraryDatabase.open(inMemory: true)
    let summary = try LibraryBackupService.importData(JSONSerialization.data(withJSONObject: object), into: db.mainContext)
    XCTAssertEqual(summary.createdCount, 1); XCTAssertEqual(summary.createdSmartCount, 1)
    let exported = try LibraryBackupService.exportData(from: db.mainContext)
    try assertCleanExport(exported, names: ["混合筛选"])
    let actual = try LibraryBackupService.decode(exported)
    XCTAssertEqual(actual.books.first?.title, expected.books.first?.title)
    XCTAssertEqual(actual.books.first?.contributors, expected.books.first?.contributors)
    XCTAssertEqual(actual.books.first?.tags, expected.books.first?.tags)
    XCTAssertEqual(actual.libraryNotes?.first?.body, expected.libraryNotes?.first?.body)
    let clean = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
    let book = try XCTUnwrap((clean["books"] as? [[String: Any]])?.first)
    XCTAssertNil(book["coverData"]); XCTAssertNil(book["coverFileName"])
    XCTAssertFalse((book["metadataFieldSourcesJSON"] as? String ?? "").contains("\"cover\""))
    let undo = UndoManager(); undo.groupsByEvent = false
    let saved = try XCTUnwrap(db.mainContext.fetch(FetchDescriptor<Book>()).first)
    undo.beginUndoGrouping()
    try LibraryOperations.setTrashed(true, books: [saved], context: db.mainContext, undoManager: undo)
    undo.endUndoGrouping(); undo.undo()
    XCTAssertNil(saved.deletedAt)
    XCTAssertEqual(saved.title, expected.books.first?.title)
  }

  func testCoverLayoutPreferenceRemovedWithoutChangingOtherSettings() throws {
    let suite = "CoverRemoval-" + UUID().uuidString
    let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.set("grid", forKey: "defaultLayout"); prefs.set(16, forKey: "libraryInterfaceFontSize")
    RetiredReadingData.cleanPreferences(prefs)
    XCTAssertNil(prefs.object(forKey: "defaultLayout"))
    XCTAssertEqual(prefs.integer(forKey: "libraryInterfaceFontSize"), 16)
  }

  private func fixture(_ file: String, folder: String = "ReadingStatusV5") throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      .appendingPathComponent(folder).appendingPathComponent(file)
  }
  private func assertCleanExport(_ data: Data, names: Set<String> = ["混合全部", "保留搜索词"],
    file: StaticString = #filePath, line: UInt = #line) throws {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    for book in try XCTUnwrap(object["books"] as? [[String: Any]], file: file, line: line) {
      for key in ["readingStatusRaw", "startedAt", "finishedAt", "personalRating", "isFavorite", "coverData", "coverFileName"] { XCTAssertNil(book[key], file: file, line: line) }
    }
    let archive = try LibraryBackupService.decode(data)
    XCTAssertEqual(archive.schemaVersion, 9, file: file, line: line)
    XCTAssertEqual(Set((archive.smartCollections ?? []).map(\.name)), names, file: file, line: line)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"field\" : \"status\""), file: file, line: line)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"field\" : \"rating\""), file: file, line: line)
  }

  func testRatingSchemaMigrationAndOldBackupPreserveOtherData() throws {
    try assertSchemaMigration(folder: "RatingV6", retainedExtra: nil)
  }

  func testFavoriteSchemaMigrationAndOldBackupPreserveOtherData() throws {
    try assertSchemaMigration(folder: "FavoriteV7", retainedExtra: .pageCount)
  }

  private func assertSchemaMigration(folder: String, retainedExtra: SearchBookField?) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RatingMigration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.store")
    try FileManager.default.copyItem(at: fixture("library.store", folder: folder), to: url)
    let oldBackup = try Data(contentsOf: fixture("legacy-backup.json", folder: folder))
    let expected = try LibraryBackupService.decode(oldBackup)
    let db = try LibraryDatabase.open(at: url)
    let data = try LibraryBackupService.exportData(from: db.mainContext)
    let names: Set<String> = retainedExtra == nil ? ["混合全部", "保留搜索词"] : ["混合全部", "混合任一", "保留搜索词"]
    try assertCleanExport(data, names: names)
    let actual = try LibraryBackupService.decode(data)
    XCTAssertEqual(actual.books.sorted { $0.id.uuidString < $1.id.uuidString }, expected.books.sorted { $0.id.uuidString < $1.id.uuidString })
    XCTAssertEqual(actual.collections, expected.collections)
    XCTAssertEqual(actual.libraryNotes, expected.libraryNotes)
    let lists = try XCTUnwrap(actual.smartCollections)
    XCTAssertEqual(lists.first { $0.name == "混合全部" }?.query.rules.map(\.field), [.publisher])
    if let retainedExtra {
      XCTAssertEqual(lists.first { $0.name == "混合任一" }?.query.mode, .any)
      XCTAssertEqual(lists.first { $0.name == "混合任一" }?.query.rules.map(\.field), [retainedExtra])
    } else { XCTAssertNil(lists.first { $0.name == "混合任一" }) }
    XCTAssertTrue(lists.first { $0.name == "保留搜索词" }!.query.rules.isEmpty)
    XCTAssertEqual(lists.first { $0.name == "保留搜索词" }?.query.savedSearch?.scope, .title)
    XCTAssertEqual(lists.first { $0.name == "保留搜索词" }?.query.savedSearch?.text, "迁移")
    let expectedIDs = try JSONDecoder().decode([String: [UUID]].self,
      from: Data(contentsOf: fixture("ids.json", folder: folder)))
    XCTAssertEqual(Set(try db.mainContext.fetch(FetchDescriptor<Contribution>()).map(\.id)), Set(expectedIDs["contributions"]!))
    XCTAssertEqual(Set(try db.mainContext.fetch(FetchDescriptor<BookTag>()).map(\.id)), Set(expectedIDs["tags"]!))
    XCTAssertEqual(Set(try db.mainContext.fetch(FetchDescriptor<CollectionItem>()).map(\.id)), Set(expectedIDs["memberships"]!))

    var database: OpaquePointer?, statement: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement); sqlite3_close(database) }
    XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA table_info(ZBOOK)", -1, &statement, nil), SQLITE_OK)
    var columns = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW { columns.insert(String(cString: sqlite3_column_text(statement, 1))) }
    XCTAssertTrue(columns.contains("ZTITLE"))
    XCTAssertFalse(columns.contains("ZPERSONALRATING"))
    XCTAssertFalse(columns.contains("ZISFAVORITE"))

    let imported = try LibraryDatabase.open(inMemory: true)
    let summary = try LibraryBackupService.importData(oldBackup, into: imported.mainContext)
    XCTAssertEqual(summary.createdCount, 2); XCTAssertEqual(summary.createdSmartCount, names.count)
    try assertCleanExport(LibraryBackupService.exportData(from: imported.mainContext), names: names)
    let reopened = try LibraryDatabase.open(at: url)
    let again = try LibraryBackupService.decode(LibraryBackupService.exportData(from: reopened.mainContext))
    XCTAssertEqual(actual.books, again.books); XCTAssertEqual(actual.smartCollections, again.smartCollections)
  }

  func testOldBackupDropsRetiredValuesAndRulesBeforeImport() throws {
    let old = try Data(contentsOf: fixture("legacy-backup.json"))
    for version in 1...8 {
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
      object["schemaVersion"] = version
      let data = try JSONSerialization.data(withJSONObject: object)
      let db = try LibraryDatabase.open(inMemory: true)
      let summary = try LibraryBackupService.importData(data, into: db.mainContext)
      XCTAssertEqual(summary.createdCount, 2); XCTAssertEqual(summary.createdSmartCount, 2)
      let exported = try LibraryBackupService.exportData(from: db.mainContext)
      try assertCleanExport(exported)
      let lists = try SmartCollectionService.snapshots(in: db.mainContext).values
      XCTAssertEqual(lists.first { $0.name == "混合全部" }?.query.rules.map(\.field), [.publisher])
      XCTAssertNil(lists.first { $0.name == "混合任一" })
      XCTAssertTrue(lists.first { $0.name == "保留搜索词" }!.query.rules.isEmpty)
      XCTAssertEqual(lists.first { $0.name == "保留搜索词" }?.query.savedSearch?.text, "迁移")
    }
  }

  func testDiskMigrationPhysicallyRemovesColumnsAndPreservesRelationships() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StatusMigration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.store")
    try FileManager.default.copyItem(at: fixture("library.store"), to: url)
    let expected = try LibraryBackupService.decode(Data(contentsOf: fixture("legacy-backup.json")))
    let expectedIDs = try JSONDecoder().decode([String: [UUID]].self, from: Data(contentsOf: fixture("ids.json")))
    let db = try LibraryDatabase.open(at: url), context = db.mainContext
    let exported = try LibraryBackupService.exportData(from: context)
    try assertCleanExport(exported)
    let actual = try LibraryBackupService.decode(exported)
    XCTAssertEqual(actual.books.sorted { $0.id.uuidString < $1.id.uuidString }, expected.books.sorted { $0.id.uuidString < $1.id.uuidString })
    XCTAssertEqual(actual.collections, expected.collections)
    XCTAssertEqual(actual.libraryNotes, expected.libraryNotes)
    XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Contribution>()).map(\.id)), Set(expectedIDs["contributions"]!))
    XCTAssertEqual(Set(try context.fetch(FetchDescriptor<BookTag>()).map(\.id)), Set(expectedIDs["tags"]!))
    XCTAssertEqual(Set(try context.fetch(FetchDescriptor<CollectionItem>()).map(\.id)), Set(expectedIDs["memberships"]!))
    var database: OpaquePointer?, statement: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement); sqlite3_close(database) }
    XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA table_info(ZBOOK)", -1, &statement, nil), SQLITE_OK)
    var columns = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
      columns.insert(String(cString: sqlite3_column_text(statement, 1)))
    }
    XCTAssertTrue(columns.contains("ZTITLE"))
    XCTAssertTrue(columns.isDisjoint(with: ["ZREADINGSTATUSRAW", "ZSTARTEDAT", "ZFINISHEDAT", "ZPERSONALRATING", "ZISFAVORITE"]))
    let reopened = try LibraryDatabase.open(at: url)
    let roundTrip = try LibraryBackupService.decode(LibraryBackupService.exportData(from: reopened.mainContext))
    XCTAssertEqual(roundTrip.books, actual.books)
    XCTAssertEqual(roundTrip.smartCollections, actual.smartCollections)
  }

  func testPreferencesRemoveStatusWithoutResettingOtherColumnsOrSelection() throws {
    let suite = "StatusRemoval-" + UUID().uuidString, prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    var state = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryWorkspaceState())) as? [String: Any])
    state["selection"] = ["status": ["_0": "reading"]]
    prefs.set(try JSONSerialization.data(withJSONObject: state), forKey: LibraryWorkspaceState.storageKey)
    func id(_ name: String) -> [String: Any] { ["base": ["explicit": ["_0": name]]] }
    let table: [String: Any] = ["columnOrder": [id("title"), id("status"), id("rating"), id("favorite"), id("publisher")],
      "perColumnState": [id("title"), ["currentWidth": 133], id("status"), ["currentWidth": 80], id("rating"), ["currentWidth": 65], id("favorite"), ["currentWidth": 40], id("publisher"), ["currentWidth": 222]]]
    prefs.set(try JSONSerialization.data(withJSONObject: table), forKey: "libraryTableColumnCustomization.v1")
    prefs.set("unchanged", forKey: "unrelated")
    let backup = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture("legacy-backup.json"))) as? [String: Any])
    let key = "bookTypeSmartCollectionsRetired.v1.test.backup"
    prefs.set(try JSONSerialization.data(withJSONObject: backup["smartCollections"]!), forKey: key)
    XCTAssertEqual(LibraryWorkspaceState.load(from: prefs).selection, .all)
    let cleaned = try XCTUnwrap(prefs.data(forKey: "libraryTableColumnCustomization.v1"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: cleaned) as? [String: Any])
    XCTAssertEqual((object["columnOrder"] as? [Any])?.count, 2)
    let pairs = try XCTUnwrap(object["perColumnState"] as? [Any])
    XCTAssertEqual(pairs.count, 4); XCTAssertEqual((pairs[1] as? [String: Int])?["currentWidth"], 133)
    XCTAssertEqual((pairs[3] as? [String: Int])?["currentWidth"], 222)
    XCTAssertFalse(String(decoding: cleaned, as: UTF8.self).contains("status"))
    XCTAssertFalse(String(decoding: cleaned, as: UTF8.self).contains("rating"))
    XCTAssertFalse(String(decoding: cleaned, as: UTF8.self).contains("favorite"))
    state["selection"] = ["favorites": [:]] as [String: Any]
    prefs.set(try JSONSerialization.data(withJSONObject: state), forKey: LibraryWorkspaceState.storageKey)
    XCTAssertEqual(LibraryWorkspaceState.load(from: prefs).selection, .all)
    XCTAssertFalse(String(decoding: prefs.data(forKey: LibraryWorkspaceState.storageKey)!, as: UTF8.self).contains("favorites"))
    XCTAssertEqual(prefs.string(forKey: "unrelated"), "unchanged")
    let snapshot = prefs.persistentDomain(forName: suite)!
    RetiredReadingData.cleanPreferences(prefs)
    XCTAssertTrue(NSDictionary(dictionary: snapshot).isEqual(to: prefs.persistentDomain(forName: suite)!))
    let retired = try JSONSerialization.jsonObject(with: XCTUnwrap(prefs.data(forKey: key))) as? [Any]
    XCTAssertEqual(retired?.count, 2)
  }

  func testUnknownFieldsAndVersionsStillFailInsteadOfBeingDiscarded() throws {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture("legacy-backup.json"))) as? [String: Any])
    object["schemaVersion"] = 999
    XCTAssertThrowsError(try LibraryBackupService.decode(JSONSerialization.data(withJSONObject: object)))
    object["schemaVersion"] = 5
    var lists = try XCTUnwrap(object["smartCollections"] as? [[String: Any]])
    var query = try XCTUnwrap(lists[0]["query"] as? [String: Any])
    query["rules"] = [["id": UUID().uuidString, "field": "futureField", "comparison": "equals", "value": "unknown"]]
    lists[0]["query"] = query; object["smartCollections"] = lists
    XCTAssertThrowsError(try LibraryBackupService.decode(JSONSerialization.data(withJSONObject: object)))
  }
}
