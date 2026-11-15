import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class ReadingStatusRemovalTests: XCTestCase {
  private func fixture(_ file: String, folder: String = "ReadingStatusV5") throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      .appendingPathComponent(folder).appendingPathComponent(file)
  }
  private func assertCleanExport(_ data: Data, names: Set<String> = ["混合全部", "保留搜索词"],
    file: StaticString = #filePath, line: UInt = #line) throws {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    for book in try XCTUnwrap(object["books"] as? [[String: Any]], file: file, line: line) {
      for key in ["readingStatusRaw", "startedAt", "finishedAt", "personalRating"] { XCTAssertNil(book[key], file: file, line: line) }
    }
    let archive = try LibraryBackupService.decode(data)
    XCTAssertEqual(archive.schemaVersion, 7, file: file, line: line)
    XCTAssertEqual(Set((archive.smartCollections ?? []).map(\.name)), names, file: file, line: line)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"field\" : \"status\""), file: file, line: line)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"field\" : \"rating\""), file: file, line: line)
  }

  func testRatingSchemaMigrationAndOldBackupPreserveOtherData() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RatingMigration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.store")
    try FileManager.default.copyItem(at: fixture("library.store", folder: "RatingV6"), to: url)
    let oldBackup = try Data(contentsOf: fixture("legacy-backup.json", folder: "RatingV6"))
    let expected = try LibraryBackupService.decode(oldBackup)
    let db = try LibraryDatabase.open(at: url)
    let data = try LibraryBackupService.exportData(from: db.mainContext)
    let names: Set<String> = ["混合全部", "混合任一", "保留搜索词"]
    try assertCleanExport(data, names: names)
    let actual = try LibraryBackupService.decode(data)
    XCTAssertEqual(actual.books.sorted { $0.id.uuidString < $1.id.uuidString }, expected.books.sorted { $0.id.uuidString < $1.id.uuidString })
    XCTAssertEqual(actual.collections, expected.collections)
    XCTAssertEqual(actual.libraryNotes, expected.libraryNotes)
    let lists = try XCTUnwrap(actual.smartCollections)
    XCTAssertEqual(lists.first { $0.name == "混合全部" }?.query.rules.map(\.field), [.publisher])
    XCTAssertEqual(lists.first { $0.name == "混合任一" }?.query.mode, .any)
    XCTAssertEqual(lists.first { $0.name == "混合任一" }?.query.rules.map(\.field), [.favorite])
    XCTAssertTrue(lists.first { $0.name == "保留搜索词" }!.query.rules.isEmpty)
    XCTAssertEqual(lists.first { $0.name == "保留搜索词" }?.query.savedSearch?.scope, .title)
    XCTAssertEqual(lists.first { $0.name == "保留搜索词" }?.query.savedSearch?.text, "迁移")
    let expectedIDs = try JSONDecoder().decode([String: [UUID]].self,
      from: Data(contentsOf: fixture("ids.json", folder: "RatingV6")))
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

    let imported = try LibraryDatabase.open(inMemory: true)
    let summary = try LibraryBackupService.importData(oldBackup, into: imported.mainContext)
    XCTAssertEqual(summary.createdCount, 2); XCTAssertEqual(summary.createdSmartCount, 3)
    try assertCleanExport(LibraryBackupService.exportData(from: imported.mainContext), names: names)
    let reopened = try LibraryDatabase.open(at: url)
    let again = try LibraryBackupService.decode(LibraryBackupService.exportData(from: reopened.mainContext))
    XCTAssertEqual(actual.books, again.books); XCTAssertEqual(actual.smartCollections, again.smartCollections)
  }

  func testOldBackupDropsRetiredValuesAndRulesBeforeImport() throws {
    let old = try Data(contentsOf: fixture("legacy-backup.json"))
    for version in 1...7 {
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
    XCTAssertTrue(columns.isDisjoint(with: ["ZREADINGSTATUSRAW", "ZSTARTEDAT", "ZFINISHEDAT", "ZPERSONALRATING"]))
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
    let table: [String: Any] = ["columnOrder": [id("title"), id("status"), id("rating"), id("publisher")],
      "perColumnState": [id("title"), ["currentWidth": 133], id("status"), ["currentWidth": 80], id("rating"), ["currentWidth": 65], id("publisher"), ["currentWidth": 222]]]
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
