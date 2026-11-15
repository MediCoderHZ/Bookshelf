import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class BookCollectionDropTests: XCTestCase {
  private func payload(_ ids: Set<UUID>, in context: ModelContext) -> BookDragPayload {
    BookDragPayload(libraryID: LibraryServices.forContext(context).dragScopeID, bookIDs: ids)
  }
  private func fixture() throws -> (ModelContainer, Book, Book, BookCollection, BookCollection) {
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let a = Book(title: "甲"), b = Book(title: "乙")
    let source = BookCollection(name: "原文件夹"), destination = BookCollection(name: "目标子文件夹")
    destination.parentID = source.id
    for book in [a, b] { ctx.insert(book) }
    for collection in [source, destination] { ctx.insert(collection) }
    ctx.insert(CollectionItem(collection: source, book: a))
    try ctx.save()
    return (db, a, b, source, destination)
  }
  private func memberships(_ book: Book) -> Set<UUID> { Set(book.collectionItems.compactMap(\.collection?.id)) }

  func testDraggingSelectedRowCarriesAllVisibleSelectedBooks() throws {
    let (db, a, b, _, destination) = try fixture(), ctx = db.mainContext
    let scope = LibraryServices.forContext(ctx).dragScopeID, hidden = UUID()
    let selection = try XCTUnwrap(BookDragPayload.selection(libraryID: scope, dragging: b.id,
      selected: [a.id, b.id, hidden], available: [a.id, b.id]))
    XCTAssertEqual(selection.bookIDs, [a.id, b.id])
    // Even if the table supplies only the dragged row's provider, both books join.
    XCTAssertEqual(try LibraryCommands(context: ctx, undoManager: nil)
      .addDroppedBooks([selection], to: destination.id), 2)
    XCTAssertTrue(memberships(a).contains(destination.id))
    XCTAssertTrue(memberships(b).contains(destination.id))
    XCTAssertEqual(BookDragPayload.selection(libraryID: scope, dragging: a.id,
      selected: [b.id], available: [a.id, b.id])?.bookIDs, [a.id])
    XCTAssertNil(BookDragPayload.selection(libraryID: scope, dragging: hidden,
      selected: [hidden], available: [a.id, b.id]))
  }

  func testBatchDropAddsMembershipsInOneCommitAndCanUndoTogether() throws {
    let (db, a, b, source, destination) = try fixture(), ctx = db.mainContext
    let note = LibraryNote(title: "保留笔记", body: "正文"); note.parentBookID = a.id
    ctx.insert(note); try ctx.save()
    let originalNotes = try OrganizationStore.notes(in: ctx)
    let undo = UndoManager(); undo.groupsByEvent = false
    let notifier = LibraryNotifier.forContext(ctx), revision = notifier.revision
    let commands = LibraryCommands(context: ctx, undoManager: undo)
    undo.beginUndoGrouping()
    XCTAssertEqual(try commands.addDroppedBooks([payload([a.id], in: ctx), payload([b.id], in: ctx)], to: destination.id), 2)
    undo.endUndoGrouping()
    XCTAssertEqual(notifier.revision, revision + 1)
    XCTAssertEqual(memberships(a), [source.id, destination.id]); XCTAssertEqual(memberships(b), [destination.id])
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 2)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx), originalNotes)
    undo.undo()
    XCTAssertEqual(memberships(a), [source.id]); XCTAssertTrue(memberships(b).isEmpty)
    undo.redo()
    XCTAssertEqual(memberships(a), [source.id, destination.id]); XCTAssertEqual(memberships(b), [destination.id])
  }

  func testDuplicatePayloadsAndExistingMembershipsAreNoOps() throws {
    let (db, a, b, source, destination) = try fixture(), ctx = db.mainContext
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = LibraryCommands(context: ctx, undoManager: undo)
    let existingLink = try XCTUnwrap(a.collectionItems.first?.id), before = BookArchive(book: a)
    XCTAssertEqual(try commands.addDroppedBooks([payload([a.id], in: ctx)], to: source.id), 0)
    XCTAssertFalse(undo.canUndo); XCTAssertEqual(BookArchive(book: a), before)
    XCTAssertEqual(a.collectionItems.first?.id, existingLink)
    undo.beginUndoGrouping()
    XCTAssertEqual(try commands.addDroppedBooks([payload([a.id, b.id], in: ctx), payload([a.id], in: ctx)], to: destination.id), 2)
    undo.endUndoGrouping()
    let after = LibraryHistory.snapshots([a, b]), revision = LibraryNotifier.forContext(ctx).revision
    XCTAssertEqual(try commands.addDroppedBooks([payload([a.id, b.id], in: ctx)], to: destination.id), 0)
    XCTAssertEqual(LibraryHistory.snapshots([a, b]), after)
    XCTAssertEqual(LibraryNotifier.forContext(ctx).revision, revision)
    XCTAssertEqual(a.collectionItems.filter { $0.collection?.id == destination.id }.count, 1)
  }

  func testMissingTrashedAndNoteIDsRejectEntireBatch() throws {
    let (db, a, b, _, destination) = try fixture(), ctx = db.mainContext
    let note = LibraryNote(title: "笔记"); ctx.insert(note); try ctx.save()
    let commands = LibraryCommands(context: ctx, undoManager: nil)
    for id in [UUID(), note.id] {
      let before = LibraryHistory.snapshots([a, b])
      XCTAssertThrowsError(try commands.addDroppedBooks([payload([a.id, id], in: ctx)], to: destination.id))
      XCTAssertEqual(LibraryHistory.snapshots([a, b]), before)
    }
    b.deletedAt = Date(); try ctx.save()
    let before = LibraryHistory.snapshots([a, b])
    XCTAssertThrowsError(try commands.addDroppedBooks([payload([a.id, b.id], in: ctx)], to: destination.id))
    XCTAssertEqual(LibraryHistory.snapshots([a, b]), before)
  }

  func testSmartAndMissingTargetsAreRejected() throws {
    let (db, a, b, _, destination) = try fixture(), ctx = db.mainContext
    let smartID = try SmartCollectionService.save(name: "中文原版书",
      query: AdvancedBookQuery(rules: [BookSearchRule(field: .bookType, comparison: .equals, value: BookType.chineseOriginal.rawValue)]),
      context: ctx, undoManager: nil)
    try CollectionCommands(context: ctx, undoManager: nil).remove(ManualCollectionRecord(destination))
    let before = LibraryHistory.snapshots([a, b])
    for id in [smartID, destination.id, UUID()] {
      XCTAssertThrowsError(try LibraryCommands(context: ctx, undoManager: nil)
        .addDroppedBooks([payload([a.id, b.id], in: ctx)], to: id))
      XCTAssertEqual(LibraryHistory.snapshots([a, b]), before)
    }
  }

  func testForeignLibraryEmptyAndUnknownVersionPayloadsAreRejected() throws {
    let (db, a, b, _, destination) = try fixture(), ctx = db.mainContext
    let other = try LibraryDatabase.open(inMemory: true)
    var future = payload([a.id], in: ctx); future.version = 2
    let before = LibraryHistory.snapshots([a, b])
    for values in [[], [payload([], in: ctx)], [future], [payload([a.id], in: other.mainContext)],
      [payload([a.id], in: ctx), payload([b.id], in: other.mainContext)]] {
      XCTAssertThrowsError(try LibraryCommands(context: ctx, undoManager: nil).addDroppedBooks(values, to: destination.id))
      XCTAssertEqual(LibraryHistory.snapshots([a, b]), before)
    }
  }

  func testNativeItemProviderPreservesPayloadAndRejectsMalformedData() async throws {
    let value = BookDragPayload(libraryID: UUID(), bookIDs: [UUID(), UUID()])
    let provider = try XCTUnwrap(BookDragTransfer.provider(for: value, title: "测试书籍"))
    let decoded = try await BookDragTransfer.load(provider)
    XCTAssertEqual(decoded, value)
    XCTAssertThrowsError(try JSONDecoder().decode(BookDragPayload.self, from: Data("invalid".utf8)))
  }

  func testWholeSelectionLoadsWithoutDependingOnRedundantProviders() async throws {
    let (db, a, b, _, destination) = try fixture(), ctx = db.mainContext
    let value = payload([a.id, b.id], in: ctx)
    let first = try XCTUnwrap(BookDragTransfer.provider(for: value, title: "两本书"))
    let unavailable = NSItemProvider()
    unavailable.registerDataRepresentation(forTypeIdentifier: BookDragTransfer.type.identifier, visibility: .all) { completion in
      completion(nil, NSError(domain: "RedundantDragProvider", code: 1))
      return nil
    }
    let decoded = try await BookDragTransfer.loadSelection(from: [first, unavailable])
    XCTAssertEqual(decoded, value)
    XCTAssertEqual(try LibraryCommands(context: ctx, undoManager: nil)
      .addDroppedBooks([decoded], to: destination.id), 2)
    do {
      _ = try await BookDragTransfer.loadSelection(from: [])
      XCTFail("An empty drag must be rejected")
    } catch { XCTAssertTrue(error is LibraryOperationError) }
  }
}
