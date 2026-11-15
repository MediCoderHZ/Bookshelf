import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class CollectionReorderingTests: XCTestCase {
  private func add(_ name: String, parent: UUID? = nil, in ctx: ModelContext) throws -> UUID {
    try CollectionCommands(context: ctx, undoManager: nil).save(name: name, replacing: nil, parentID: parent)
  }
  private func addSmart(in ctx: ModelContext) throws -> UUID {
    try SmartCollectionService.save(name: "Smart",
      query: AdvancedBookQuery(rules: [BookSearchRule(field: .title, comparison: .contains, value: "书")]),
      context: ctx, undoManager: nil)
  }
  private func items(_ ctx: ModelContext) throws -> [CollectionOrderingItem] {
    try ctx.fetch(FetchDescriptor<BookCollection>()).map(CollectionOrderingItem.init)
  }
  private func order(_ ctx: ModelContext, parent: UUID? = nil) throws -> [UUID] {
    try items(ctx).filter { $0.parentID == parent }.sorted(by: CollectionOrdering.precedes).map(\.id)
  }
  private func payload(_ id: UUID, _ ctx: ModelContext) throws -> CollectionDragPayload {
    try CollectionDragPayload(libraryID: LibraryServices.forContext(ctx).dragScopeID,
      item: XCTUnwrap(items(ctx).first { $0.id == id }))
  }
  private func grouped<T>(_ undo: UndoManager, _ action: () throws -> T) rethrows -> T {
    undo.beginUndoGrouping(); defer { undo.endUndoGrouping() }; return try action()
  }

  func testSiblingReorderIsOneCommitAndUndoRestoresOriginalOrder() throws {
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let a = try add("A", in: ctx), b = try add("B", in: ctx), c = try add("C", in: ctx)
    let before = try OrganizationStore.collections(in: ctx), revision = LibraryNotifier.forContext(ctx).revision
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = CollectionCommands(context: ctx, undoManager: undo)
    XCTAssertTrue(try grouped(undo) { try commands.move(payload(c, ctx), to: .before(a)) })
    XCTAssertEqual(try order(ctx), [c, a, b])
    XCTAssertEqual(LibraryNotifier.forContext(ctx).revision, revision + 1)
    XCTAssertEqual(undo.undoActionName, "移动文件夹")
    let after = try OrganizationStore.collections(in: ctx)
    undo.undo(); XCTAssertEqual(try OrganizationStore.collections(in: ctx), before)
    undo.redo(); XCTAssertEqual(try OrganizationStore.collections(in: ctx), after)
    XCTAssertTrue(try grouped(undo) { try commands.move(payload(c, ctx), to: .after(b)) })
    XCTAssertEqual(try order(ctx), [a, b, c])
  }

  func testMoveSubtreeIntoAnotherCollectionAndBackPreservesMemberships() throws {
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let a = try add("A", in: ctx), b = try add("B", in: ctx)
    let child = try add("Child", parent: a, in: ctx), grandchild = try add("Grandchild", parent: child, in: ctx)
    let book = Book(title: "保留书籍"); ctx.insert(book)
    let parent = try XCTUnwrap(ctx.fetch(FetchDescriptor<BookCollection>()).first { $0.id == child })
    let link = CollectionItem(collection: parent, book: book); ctx.insert(link)
    let note = LibraryNote(title: "保留笔记", body: "正文"); note.collectionIDs = [grandchild]; ctx.insert(note)
    try ctx.save()
    let originalBook = BookArchive(book: book), originalNote = NoteRecord(note)
    let descendantRecords = try OrganizationStore.collections(in: ctx, ids: [child, grandchild])
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = CollectionCommands(context: ctx, undoManager: undo)
    XCTAssertTrue(try grouped(undo) { try commands.move(payload(a, ctx), to: .inside(b)) })
    XCTAssertEqual(try order(ctx), [b]); XCTAssertEqual(try order(ctx, parent: b), [a])
    XCTAssertEqual(try OrganizationStore.collections(in: ctx, ids: [child, grandchild]), descendantRecords)
    XCTAssertEqual(BookArchive(book: book), originalBook); XCTAssertEqual(NoteRecord(note), originalNote)
    XCTAssertEqual(book.collectionItems.first?.id, link.id)
    XCTAssertEqual(CollectionTree.path(grandchild, in: Array(try OrganizationStore.collections(in: ctx).values)), "B / A / Child / Grandchild")
    XCTAssertTrue(try grouped(undo) { try commands.move(payload(a, ctx), to: .inside(nil)) })
    XCTAssertEqual(try order(ctx), [b, a]); XCTAssertEqual(try order(ctx, parent: a), [child])
    undo.undo(); XCTAssertEqual(try order(ctx, parent: b), [a])
    undo.undo(); XCTAssertEqual(try order(ctx), [a, b])
    XCTAssertNil(LibraryServices.forContext(ctx).history.errorMessage)
  }

  func testCyclesMissingTargetsAndSmartHierarchyAreRejectedWithoutChanges() throws {
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let a = try add("A", in: ctx), child = try add("Child", parent: a, in: ctx), smart = try addSmart(in: ctx)
    let before = try items(ctx), revision = LibraryNotifier.forContext(ctx).revision
    let commands = CollectionCommands(context: ctx, undoManager: nil)
    for destination in [CollectionDropDestination.inside(a), .inside(child), .before(child), .after(child), .inside(smart), .inside(UUID()), .before(UUID())] {
      XCTAssertThrowsError(try commands.move(payload(a, ctx), to: destination))
    }
    XCTAssertThrowsError(try commands.move(payload(smart, ctx), to: .inside(a)))
    XCTAssertThrowsError(try commands.move(payload(smart, ctx), to: .before(child)))
    XCTAssertEqual(try items(ctx), before); XCTAssertEqual(LibraryNotifier.forContext(ctx).revision, revision)
  }

  func testForeignUnknownVersionAndStaleSourceCannotOverwriteNewState() throws {
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let a = try add("A", in: ctx), b = try add("B", in: ctx)
    let stale = try payload(a, ctx), commands = CollectionCommands(context: ctx, undoManager: nil)
    let record = try XCTUnwrap(OrganizationStore.collections(in: ctx)[a])
    _ = try commands.save(name: "Renamed", replacing: record)
    let before = try items(ctx)
    let foreign = try CollectionDragPayload(libraryID: UUID(), item: XCTUnwrap(items(ctx).first { $0.id == a }))
    var future = try payload(a, ctx); future.version = 2
    for value in [stale, foreign, future] { XCTAssertThrowsError(try commands.move(value, to: .inside(b))) }
    XCTAssertEqual(try items(ctx), before)
    let valid = try payload(a, ctx)
    try commands.remove(try XCTUnwrap(OrganizationStore.collections(in: ctx)[b]))
    let afterRemoval = try items(ctx)
    XCTAssertThrowsError(try commands.move(valid, to: .inside(b)))
    XCTAssertEqual(try items(ctx), afterRemoval)
  }

  func testSmartAndManualRootOrderShareUndoAndEditsKeepPosition() throws {
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let a = try add("A", in: ctx), b = try add("B", in: ctx), smart = try addSmart(in: ctx)
    let originalSmart = try XCTUnwrap(SmartCollectionService.snapshots(in: ctx)[smart])
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = CollectionCommands(context: ctx, undoManager: undo)
    XCTAssertTrue(try grouped(undo) { try commands.move(payload(smart, ctx), to: .before(a)) })
    XCTAssertEqual(try order(ctx), [smart, a, b])
    XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx)[smart]?.query, originalSmart.query)
    undo.undo(); XCTAssertEqual(try order(ctx), [a, b, smart])
    undo.redo(); XCTAssertEqual(try order(ctx), [smart, a, b])
    let expected = try XCTUnwrap(SmartCollectionService.snapshots(in: ctx)[smart])
    _ = try SmartCollectionService.save(name: "Z Smart", query: expected.query, replacing: expected, context: ctx, undoManager: nil)
    _ = try grouped(undo) { try commands.save(name: "Z Manual", replacing: XCTUnwrap(OrganizationStore.collections(in: ctx)[a])) }
    XCTAssertEqual(try order(ctx), [smart, a, b])
    let added = try add("A new", in: ctx)
    XCTAssertEqual(try order(ctx), [smart, a, b, added])
  }

  func testDroppingAtSamePositionDoesNotWriteOrCreateUndo() throws {
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let a = try add("A", in: ctx), b = try add("B", in: ctx)
    let before = try OrganizationStore.collections(in: ctx), revision = LibraryNotifier.forContext(ctx).revision
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = CollectionCommands(context: ctx, undoManager: undo)
    XCTAssertFalse(try commands.move(payload(a, ctx), to: .before(b)))
    XCTAssertFalse(try commands.move(payload(b, ctx), to: .inside(nil)))
    XCTAssertFalse(try commands.move(payload(a, ctx), to: .after(a)))
    XCTAssertFalse(undo.canUndo); XCTAssertEqual(LibraryNotifier.forContext(ctx).revision, revision)
    XCTAssertEqual(try OrganizationStore.collections(in: ctx), before)
  }

  func testHierarchyAndMixedOrderPersistAcrossReopenAndBackupImport() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.store")
    var expected: [UUID: Int] = [:], parentIDs: [UUID: UUID] = [:], data = Data()
    do {
      let db = try LibraryDatabase.open(at: url), ctx = db.mainContext
      let a = try add("A", in: ctx), b = try add("B", in: ctx), c = try add("C", in: ctx), smart = try addSmart(in: ctx)
      let commands = CollectionCommands(context: ctx, undoManager: nil)
      _ = try commands.move(payload(c, ctx), to: .inside(a))
      _ = try commands.move(payload(smart, ctx), to: .before(a))
      _ = try commands.move(payload(b, ctx), to: .inside(a))
      _ = try commands.move(payload(b, ctx), to: .before(c))
      expected = Dictionary(uniqueKeysWithValues: try items(ctx).map { ($0.id, $0.sortOrder) })
      parentIDs = Dictionary(uniqueKeysWithValues: try items(ctx).compactMap { item in item.parentID.map { (item.id, $0) } })
      data = try LibraryBackupService.exportData(from: ctx)
    }
    let reopened = try LibraryDatabase.open(at: url)
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: try items(reopened.mainContext).map { ($0.id, $0.sortOrder) }), expected)
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: try items(reopened.mainContext).compactMap { item in item.parentID.map { (item.id, $0) } }), parentIDs)
    let target = try LibraryDatabase.open(inMemory: true)
    let plan = try LibraryImportPlanner.prepare(data, context: target.mainContext)
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: target.mainContext, undoManager: nil)
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: try items(target.mainContext).map { ($0.id, $0.sortOrder) }), expected)
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: try items(target.mainContext).compactMap { item in item.parentID.map { (item.id, $0) } }), parentIDs)
  }

  func testOlderArchivesWithoutRanksDecodeAndKeepLegacyDisplayOrder() throws {
    let manual = ManualCollectionRecord(name: "Manual")
    let smart = SmartCollectionArchive(name: "Smart", query: AdvancedBookQuery(rules: [BookSearchRule(field: .title, comparison: .contains, value: "书")]))
    func withoutOrder<T: Encodable>(_ value: T) throws -> Data {
      var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
      json.removeValue(forKey: "sortOrder"); return try JSONSerialization.data(withJSONObject: json)
    }
    XCTAssertEqual(try JSONDecoder().decode(ManualCollectionRecord.self, from: withoutOrder(manual)), manual)
    XCTAssertEqual(try JSONDecoder().decode(SmartCollectionArchive.self, from: withoutOrder(smart)), smart)
    let a = CollectionOrderingItem(name: "A"), z = CollectionOrderingItem(name: "Z")
    let search = CollectionOrderingItem(name: "A Smart", isSmart: true)
    XCTAssertEqual([search, z, a].sorted(by: CollectionOrdering.precedes).map(\.id), [a.id, z.id, search.id])
  }

  func testCollectionDragProviderRoundTripCarriesScopeAndExpectedPlacement() async throws {
    let item = CollectionOrderingItem(name: "子文件夹", parentID: UUID(), sortOrder: 4)
    let original = CollectionDragPayload(libraryID: UUID(), item: item)
    let loaded = try await CollectionDragTransfer.load(CollectionDragTransfer.provider(for: original, title: item.name))
    XCTAssertEqual(loaded, original); XCTAssertTrue(loaded.matches(item))
  }
}
