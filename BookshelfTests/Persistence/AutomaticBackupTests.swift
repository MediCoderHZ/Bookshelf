import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class AutomaticBackupTests: XCTestCase {
  private var containers: [ModelContainer] = []
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bookshelf-backup-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func preferences() -> UserDefaults {
    let suite = "Bookshelf.BackupTests." + UUID().uuidString
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    return UserDefaults(suiteName: suite)!
  }
  private func context() throws -> ModelContext {
    let container = try LibraryDatabase.open(inMemory: true); containers.append(container)
    let book = Book(title: "保留书籍"), trash = Book(title: "回收站书籍")
    trash.deletedAt = Date(timeIntervalSince1970: 100)
    var child = NoteRecord(title: "子笔记", parentBookID: book.id)
    child.body = "# 原始正文\n\n**完整保留**"
    var standalone = NoteRecord(title: "独立笔记"); standalone.body = "单独保存"
    try LibraryRepository.apply([BookArchive(book: book), BookArchive(book: trash)], notes: [child, standalone], into: container.mainContext)
    return container.mainContext
  }
  private func controller(_ root: URL, context: ModelContext, prefs: UserDefaults? = nil) -> AutomaticBackupController {
    let result = AutomaticBackupController(directory: root.appendingPathComponent("Backups"), preferences: prefs ?? preferences(), appVersion: "1 (1)")
    result.attach(context: context, storeURL: nil)
    return result
  }

  func testJSONBackupRestoresBooksTrashNotesAndAssociationsIntoEmptyLibrary() throws {
    let ctx = try context(), root = try root(), controller = controller(root, context: ctx)
    let before = try LibraryBackupService.decode(LibraryBackupService.exportData(from: ctx))
    let entry = try controller.create()
    let data = try controller.store.archiveData(for: entry)
    let target = try LibraryDatabase.open(inMemory: true); containers.append(target)
    _ = try LibraryBackupService.importData(data, into: target.mainContext)
    let restored = try LibraryBackupService.decode(LibraryBackupService.exportData(from: target.mainContext))
    XCTAssertEqual(Set(restored.books.map(\.id)), Set(before.books.map(\.id)))
    XCTAssertEqual(restored.books.filter { $0.deletedAt != nil }.count, 1)
    XCTAssertEqual(restored.libraryNotes, before.libraryNotes)
    XCTAssertEqual(entry.bookCount, 2); XCTAssertEqual(entry.noteCount, 2)
    XCTAssertEqual(try LibraryBackupService.decode(LibraryBackupService.exportData(from: ctx)).libraryNotes, before.libraryNotes)
  }

  func testScheduleCatchesUpOnRestartWithoutDuplicatingRecentBackup() throws {
    let ctx = try context(), root = try root(), prefs = preferences()
    let first = controller(root, context: ctx, prefs: prefs), now = Date()
    first.checkIfDue(now: now)
    first.checkIfDue(now: now.addingTimeInterval(3599))
    XCTAssertEqual(first.entries.count, 1)
    let restarted = controller(root, context: ctx, prefs: prefs)
    restarted.checkIfDue(now: now.addingTimeInterval(3600))
    XCTAssertEqual(restarted.entries.count, 2)
    restarted.checkIfDue(now: now.addingTimeInterval(3601))
    XCTAssertEqual(restarted.entries.count, 2)
  }

  func testDisablingScheduleDoesNotDisableManualOrUpgradeBackups() throws {
    let c = controller(try root(), context: try context())
    c.isEnabled = false
    c.checkIfDue()
    XCTAssertTrue(c.entries.isEmpty)
    _ = try c.create()
    try c.prepareForUpdate()
    XCTAssertEqual(Set(c.entries.map(\.kind)), [.manual, .beforeUpdate])
    XCTAssertTrue(c.upgradePending)
  }

  func testRetentionSeparatesUpgradeHistoryAndPreservesUnrelatedFiles() throws {
    let ctx = try context(), root = try root(), store = AutomaticBackupStore(directory: root)
    let data = try LibraryBackupService.exportData(from: ctx)
    let unrelated = root.appendingPathComponent("my-important-backup.json")
    try Data("keep".utf8).write(to: unrelated)
    for i in 0..<5 {
      _ = try store.create(kind: .scheduled, data: data, storeURL: nil, recoveryRoot: nil, appVersion: "1", now: Date(timeIntervalSince1970: Double(i)))
    }
    for i in 5..<8 {
      _ = try store.create(kind: .beforeUpdate, data: data, storeURL: nil, recoveryRoot: nil, appVersion: "1", now: Date(timeIntervalSince1970: Double(i)))
    }
    try store.prune(regularLimit: 2, upgradeLimit: 2)
    let entries = try store.entries()
    XCTAssertEqual(Set(entries.filter { !$0.kind.isUpgrade }.map(\.createdAt)), [3, 4])
    XCTAssertEqual(Set(entries.filter { $0.kind.isUpgrade }.map(\.createdAt)), [6, 7])
    XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
  }

  func testCorruptedBackupIsNeitherRestoredNorPruned() throws {
    let c = controller(try root(), context: try context())
    let entry = try c.create()
    let folder = c.store.directory.appendingPathComponent(entry.directoryName)
    try Data("corrupted".utf8).write(to: folder.appendingPathComponent("library.json"))
    XCTAssertThrowsError(try c.store.archiveData(for: entry))
    for _ in 0..<3 { _ = try c.create() }
    try c.store.prune(regularLimit: 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertEqual(try c.store.entries().count, 1)
  }

  func testFailedBackupPreservesOldVersionsAndRemovesOnlyItsStagingDirectory() throws {
    let root = try root(), ctx = try context(), c = controller(root, context: ctx)
    let entry = try c.create()
    let corrupt = root.appendingPathComponent("broken.store")
    try Data("not SQLite".utf8).write(to: corrupt)
    XCTAssertThrowsError(try c.store.create(kind: .beforeUpdate, data: LibraryBackupService.exportData(from: ctx),
      storeURL: corrupt, recoveryRoot: nil, appVersion: "2"))
    XCTAssertEqual(try c.store.entries(), [entry])
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: c.store.directory.path).contains { $0.hasPrefix(".pending-") })
  }

  func testUncommittedModelChangesAreNotSavedByBackup() throws {
    let ctx = try context(), c = controller(try root(), context: ctx)
    ctx.insert(Book(title: "未确认的表单"))
    XCTAssertThrowsError(try c.create())
    XCTAssertTrue(ctx.hasChanges); XCTAssertTrue(c.entries.isEmpty)
    ctx.rollback()
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 2)
  }

  func testRecoveryDraftsAreIncludedWithoutBeingModified() throws {
    let root = try root(), ctx = try context()
    let recovery = root.appendingPathComponent("RecoverySource")
    let folder = recovery.appendingPathComponent("NoteDraftRecovery")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("draft.json"), original = Data("{\"body\":\"尚未保存\"}".utf8)
    try original.write(to: file)
    let store = AutomaticBackupStore(directory: root.appendingPathComponent("Backups"))
    let entry = try store.create(kind: .manual, data: LibraryBackupService.exportData(from: ctx), storeURL: nil,
      recoveryRoot: recovery, appVersion: "1")
    let copy = store.directory.appendingPathComponent(entry.directoryName + "/Recovery/NoteDraftRecovery/draft.json")
    XCTAssertEqual(try Data(contentsOf: copy), original)
    XCTAssertEqual(try Data(contentsOf: file), original)
  }

  func testSQLiteSnapshotIncludesCommittedWALAndReopensWithoutSidecars() throws {
    let root = try root(), source = root.appendingPathComponent("live.store"), copy = root.appendingPathComponent("copy.store")
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE notes(body TEXT); INSERT INTO notes VALUES('最新笔记');", nil, nil, nil), SQLITE_OK)
    XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: source.path + "-wal")[.size] as? Int) ?? 0, 0)
    try AutomaticBackupStore.snapshotSQLite(from: source, to: copy)
    var read: OpaquePointer?, statement: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(copy.path, &read, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement); sqlite3_close(read) }
    XCTAssertEqual(sqlite3_prepare_v2(read, "SELECT body FROM notes", -1, &statement, nil), SQLITE_OK)
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "最新笔记")
    XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path + "-wal"))
  }

  func testVersionGuardBacksUpBeforeOpeningAndRetriesAfterFailure() throws {
    let root = try root(), source = root.appendingPathComponent("live.store"), prefs = preferences()
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE old_schema(value TEXT); INSERT INTO old_schema VALUES('original');", nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    let blocker = root.appendingPathComponent("blocked"); try Data().write(to: blocker)
    let failed = AutomaticBackupController(directory: blocker, preferences: prefs, appVersion: "2")
    XCTAssertThrowsError(try failed.prepareToOpenStore(at: source))
    XCTAssertNil(prefs.string(forKey: "automaticBackup.lastOpenedVersion"))
    let c = AutomaticBackupController(directory: root.appendingPathComponent("Backups"), preferences: prefs, appVersion: "2")
    try c.prepareToOpenStore(at: source)
    XCTAssertEqual(c.entries.count, 1); XCTAssertEqual(c.entries.first?.kind, .beforeMigration)
    c.attach(context: try context(), storeURL: source)
    try c.prepareToOpenStore(at: source)
    XCTAssertEqual(c.entries.count, 1)
    let newer = AutomaticBackupController(directory: c.store.directory, preferences: prefs, appVersion: "3")
    try newer.prepareToOpenStore(at: source)
    XCTAssertEqual(newer.entries.count, 2)
  }

  func testUpgradeGateFailsClosedAndDoesNotChangeLibraryWhenBackupUnavailable() throws {
    let root = try root(), ctx = try context(), blocker = root.appendingPathComponent("file")
    try Data().write(to: blocker)
    let c = AutomaticBackupController(directory: blocker, preferences: preferences(), appVersion: "1")
    c.attach(context: ctx, storeURL: nil)
    let updater = AppUpdater(bundle: Bundle(for: Self.self), backups: c)
    XCTAssertNoThrow(try c.prepareForTermination()) // Normal quit never traps the user.
    XCTAssertThrowsError(try updater.prepareUpdateBackup())
    XCTAssertThrowsError(try c.prepareForTermination()) // Pending install must not quit without a backup.
    XCTAssertNotNil(c.lastError)
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 2)
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<LibraryNote>()).count, 2)
    updater.cancelPendingUpdate()
    XCTAssertNoThrow(try c.prepareForTermination()) // Skipping/canceling the update restores normal quit.
    let missing = AppUpdater(bundle: Bundle(for: Self.self))
    XCTAssertThrowsError(try missing.prepareUpdateBackup())
  }

  func testFinalUpgradeBackupIncludesEditsAfterUpdateWasDiscovered() throws {
    let ctx = try context(), c = controller(try root(), context: ctx)
    try c.prepareForUpdate()
    var note = try XCTUnwrap(OrganizationStore.notes(in: ctx).values.first)
    note.body = "下载更新期间继续写的笔记"
    try LibraryRepository.apply([], notes: [note], into: ctx)
    try c.prepareForTermination()
    let entry = try XCTUnwrap(c.entries.first)
    let archive = try LibraryBackupService.decode(c.store.archiveData(for: entry))
    XCTAssertEqual(archive.libraryNotes?.first(where: { $0.id == note.id })?.body, note.body)
    XCTAssertEqual(c.entries.count, 2)
  }
}
