import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class LibraryStorageTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bookshelf-storage-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func directory(_ root: URL, _ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func controller(_ root: URL, access: @escaping (URL) -> Bool = { _ in true }) -> LibraryLocationController {
    LibraryLocationController(defaultStoreURL: root.appendingPathComponent("default.store"),
      configurationURL: root.appendingPathComponent("Support/LibraryLocation.json"), recoveryRoot: root.appendingPathComponent("Support"),
      makeBookmark: { Data($0.path.utf8) }, resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) }, startAccess: access)
  }
  private func backups(_ root: URL, directory: URL? = nil) -> AutomaticBackupController {
    let suite = "Bookshelf.StorageTests." + UUID().uuidString
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    return AutomaticBackupController(directory: directory ?? root.appendingPathComponent("Backups"), preferences: UserDefaults(suiteName: suite)!, appVersion: "test")
  }
  private func seed(_ context: ModelContext) throws {
    let book = Book(title: "原始书籍"), person = Person(name: "作者"), tag = Tag(name: "标签")
    let collection = BookCollection(name: "文件夹"), series = BookSeries(name: "丛书")
    let note = LibraryNote(title: "笔记", body: "完整正文"); note.parentBookID = book.id
    context.insert(book); context.insert(person); context.insert(tag); context.insert(collection); context.insert(series); context.insert(note)
    context.insert(Contribution(book: book, person: person, role: .author, displayOrder: 0))
    context.insert(BookTag(book: book, tag: tag)); context.insert(CollectionItem(collection: collection, book: book))
    context.insert(SeriesMembership(series: series, book: book))
    try context.save()
  }
  private func archive(_ context: ModelContext) throws -> Data {
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryBackupService.exportData(from: context)) as? [String: Any])
    json.removeValue(forKey: "exportedAt")
    return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
  }

  func testMigrationIncludesEditsAfterSelectionPreservesSourceAndPersistsLocation() throws {
    let root = try root(), original = controller(root), backup = backups(root)
    let container = try original.openLibrary(backups: backup); try seed(container.mainContext)
    let target = try directory(root, "自定义 '书库'")
    try original.requestDirectory(target)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("default.store").path))
    let note = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<LibraryNote>()).first)
    note.body = "选择目录之后继续编辑"; try container.mainContext.save()
    let before = try archive(container.mainContext)
    let restarted = controller(root), nextBackup = backups(root)
    let migrated = try restarted.openLibrary(backups: nextBackup)
    XCTAssertEqual(restarted.currentStoreURL, target.appendingPathComponent("default.store"))
    XCTAssertNil(restarted.pendingDirectory); XCTAssertNil(restarted.locationError)
    XCTAssertEqual(try archive(migrated.mainContext), before)
    XCTAssertEqual(try archive(container.mainContext), before)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("default.store").path))
    XCTAssertTrue(nextBackup.entries.contains { $0.kind == .beforeMigration })
    _ = try LibraryIntegrity.checkRecords(in: migrated.mainContext)
    let another = controller(root)
    let reopened = try another.openLibrary(backups: backups(root))
    XCTAssertEqual(another.currentStoreURL, restarted.currentStoreURL)
    XCTAssertEqual(try archive(reopened.mainContext), before)
    // Ongoing backups must use the active custom store, not the retained source.
    let updated = try XCTUnwrap(migrated.mainContext.fetch(FetchDescriptor<LibraryNote>()).first)
    updated.body = "新位置最新正文"; try migrated.mainContext.save()
    let entry = try nextBackup.create()
    let exported = try LibraryBackupService.decode(nextBackup.store.archiveData(for: entry))
    XCTAssertEqual(exported.libraryNotes?.first?.body, "新位置最新正文")
    let snapshot = nextBackup.store.directory.appendingPathComponent(entry.directoryName + "/default.store")
    let copy = try LibraryDatabase.open(at: snapshot)
    XCTAssertEqual(try copy.mainContext.fetch(FetchDescriptor<LibraryNote>()).first?.body, "新位置最新正文")
  }

  func testCancelAndOccupiedDestinationDoNotMoveOrOverwrite() throws {
    let root = try root(), manager = controller(root)
    let container = try manager.openLibrary(backups: backups(root)); try seed(container.mainContext)
    XCTAssertThrowsError(try manager.requestDirectory(root))
    let target = try directory(root, "target")
    let keep = target.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: keep)
    XCTAssertThrowsError(try manager.requestDirectory(target))
    XCTAssertEqual(try Data(contentsOf: keep), Data("keep".utf8))
    let empty = try directory(root, "empty")
    try manager.requestDirectory(empty); try manager.cancelDirectoryChange()
    let reopened = controller(root)
    _ = try reopened.openLibrary(backups: backups(root))
    XCTAssertNil(reopened.pendingDirectory)
    XCTAssertEqual(reopened.currentStoreURL, root.appendingPathComponent("default.store"))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
  }

  func testDestinationOccupiedAfterSelectionFallsBackToOriginalWithError() throws {
    let root = try root(), manager = controller(root)
    let container = try manager.openLibrary(backups: backups(root)); try seed(container.mainContext)
    let target = try directory(root, "target"); try manager.requestDirectory(target)
    let sentinel = target.appendingPathComponent("default.store"); try Data("do not overwrite".utf8).write(to: sentinel)
    let reopened = controller(root)
    let original = try reopened.openLibrary(backups: backups(root))
    XCTAssertNotNil(reopened.locationError); XCTAssertNotNil(reopened.pendingDirectory)
    XCTAssertEqual(reopened.currentStoreURL, root.appendingPathComponent("default.store"))
    XCTAssertEqual(try archive(original.mainContext), try archive(container.mainContext))
    XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "do not overwrite")
  }

  func testUnavailableCustomDirectoryNeverFallsBackToDefaultOrCreatesEmptyLibrary() throws {
    let root = try root(), manager = controller(root)
    let container = try manager.openLibrary(backups: backups(root)); try seed(container.mainContext)
    let target = try directory(root, "target"); try manager.requestDirectory(target)
    _ = try controller(root).openLibrary(backups: backups(root))
    XCTAssertThrowsError(try controller(root, access: { _ in false }).openLibrary(backups: backups(root)))
    try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("disconnected"))
    XCTAssertThrowsError(try controller(root).openLibrary(backups: backups(root)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }

  func testMalformedLocationConfigurationDoesNotOpenDefaultStore() throws {
    let root = try root()
    let support = try directory(root, "Support")
    try Data("broken".utf8).write(to: support.appendingPathComponent("LibraryLocation.json"))
    XCTAssertThrowsError(try controller(root).openLibrary(backups: backups(root)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("default.store").path))
  }

  func testPreviouslyOpenedDefaultLibraryIsNotRecreatedIfItsFileGoesMissing() throws {
    let root = try root(), manager = controller(root)
    _ = try manager.openLibrary(backups: backups(root))
    let source = root.appendingPathComponent("default.store")
    try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("preserved.store"))
    XCTAssertThrowsError(try controller(root).openLibrary(backups: backups(root)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  func testFailedMigrationBackupKeepsSourceActiveAndDestinationEmpty() throws {
    let root = try root(), manager = controller(root)
    let container = try manager.openLibrary(backups: backups(root)); try seed(container.mainContext)
    let target = try directory(root, "target"); try manager.requestDirectory(target)
    let blocker = root.appendingPathComponent("blocked-backups"); try Data("blocked".utf8).write(to: blocker)
    let failedBackups = backups(root, directory: blocker)
    // Skip the separate version-opening backup to reach the relocation backup.
    failedBackups.attach(context: container.mainContext, storeURL: manager.currentStoreURL)
    let restarted = controller(root)
    let original = try restarted.openLibrary(backups: failedBackups)
    XCTAssertEqual(restarted.currentStoreURL, root.appendingPathComponent("default.store"))
    XCTAssertNotNil(restarted.locationError)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    XCTAssertEqual(try archive(original.mainContext), try archive(container.mainContext))
  }

  func testMissingOrEmptyCustomDatabaseIsNotReinitialized() throws {
    let root = try root(), target = try directory(root, "custom"), support = try directory(root, "Support")
    let record = LibraryDirectoryReference(path: target.path, bookmark: Data(target.path.utf8))
    try JSONEncoder().encode(LibraryLocationConfiguration(active: record))
      .write(to: support.appendingPathComponent("LibraryLocation.json"))
    XCTAssertThrowsError(try controller(root).openLibrary(backups: backups(root)))
    let file = target.appendingPathComponent("default.store")
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    try Data().write(to: file)
    XCTAssertThrowsError(try controller(root).openLibrary(backups: backups(root)))
    XCTAssertEqual(try Data(contentsOf: file), Data())
  }

  func testSQLiteCheckIncludesWALRejectsCorruptionForeignKeysAndNonLibrary() throws {
    let root = try root(), file = root.appendingPathComponent("wal.sqlite")
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(id INTEGER REFERENCES parent(id)); INSERT INTO parent VALUES(1); INSERT INTO child VALUES(1);", nil, nil, nil), SQLITE_OK)
    XCTAssertNoThrow(try LibraryIntegrity.checkSQLite(at: file))
    XCTAssertThrowsError(try LibraryIntegrity.checkSQLite(at: file, requireLibrary: true))
    XCTAssertEqual(sqlite3_exec(db, "INSERT INTO child VALUES(2)", nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try LibraryIntegrity.checkSQLite(at: file))
    let corrupt = root.appendingPathComponent("corrupt.store"); try Data("not SQLite".utf8).write(to: corrupt)
    XCTAssertThrowsError(try LibraryIntegrity.checkSQLite(at: corrupt))
    let absent = root.appendingPathComponent("absent.store")
    XCTAssertThrowsError(try LibraryIntegrity.checkSQLite(at: absent))
    XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
  }

  func testIntegrityReportsOrphanNotesAndRelationshipsWithoutRepairing() throws {
    let root = try root(), manager = controller(root)
    let container = try manager.openLibrary(backups: backups(root)); try seed(container.mainContext)
    XCTAssertEqual(try LibraryIntegrity.checkRecords(in: container.mainContext).books, 1)
    let note = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<LibraryNote>()).first)
    note.parentBookID = UUID(); try container.mainContext.save()
    XCTAssertThrowsError(try LibraryIntegrity.checkRecords(in: container.mainContext))
    XCTAssertNotNil(note.parentBookID)
    note.parentBookID = nil
    let link = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<BookTag>()).first)
    link.tag = nil; try container.mainContext.save()
    XCTAssertThrowsError(try LibraryIntegrity.checkRecords(in: container.mainContext))
    XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<BookTag>()), 1)
  }

  func testIntegrityActionDoesNotCommitPendingEdits() async throws {
    let root = try root(), manager = controller(root)
    let container = try manager.openLibrary(backups: backups(root)); try seed(container.mainContext)
    await manager.checkIntegrity()
    XCTAssertTrue(manager.integrityPassed); XCTAssertNotNil(manager.integrityMessage)
    container.mainContext.insert(Book(title: "尚未保存"))
    await manager.checkIntegrity()
    XCTAssertFalse(manager.integrityPassed); XCTAssertTrue(container.mainContext.hasChanges)
    container.mainContext.rollback()
    XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Book>()), 1)
  }
}
