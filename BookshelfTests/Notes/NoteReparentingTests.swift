import Foundation
import CoreTransferable
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class NoteReparentingTests: XCTestCase {
  func testNativeNoteTransferUsesAnApplicationDeclaredType() throws {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: source.appendingPathComponent("Bookshelf/Support/Info.plist"))
    let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let declared = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
    let type = NoteDragTransfer.type.identifier
    XCTAssertTrue(declared.contains { $0["UTTypeIdentifier"] as? String == type })
    if #available(macOS 15.2, *) {
      XCTAssertTrue(NoteDragBatch.exportedContentTypes().contains { $0.identifier == type })
    }
  }

  private func fixture() throws -> (ModelContainer, Book, Book, BookCollection, BookCollection, NoteRecord) {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let a = Book(title: "甲书"), b = Book(title: "乙书")
    let first = BookCollection(name: "原文件夹"), second = BookCollection(name: "当前文件夹")
    for book in [a, b] { context.insert(book) }
    for collection in [first, second] { context.insert(collection) }
    context.insert(CollectionItem(collection: first, book: a))
    context.insert(CollectionItem(collection: second, book: b))
    try context.save()
    var note = NoteRecord(title: "保留名称")
    note.body = "# 正文\n**粗体**与[链接](https://example.com)"; note.tags = ["研究", "书摘"]
    note.collectionIDs = [second.id]
    let saved = try NoteCommands(context: context, undoManager: nil).save(note, expected: nil)
    return (db, a, b, first, second, saved)
  }
  private func payload(_ note: NoteRecord, in context: ModelContext) -> NoteDragPayload {
    NoteDragPayload(libraryID: LibraryServices.forContext(context).dragScopeID, note: note)
  }
  private func assertContent(_ note: NoteRecord, unchanged original: NoteRecord, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(note.id, original.id, file: file, line: line)
    XCTAssertEqual(note.title, original.title, file: file, line: line)
    XCTAssertEqual(note.body, original.body, file: file, line: line)
    XCTAssertEqual(note.tags, original.tags, file: file, line: line)
    XCTAssertEqual(note.createdAt, original.createdAt, file: file, line: line)
    XCTAssertNil(note.deletedAt, file: file, line: line)
  }

  func testAttachAndDetachPreserveContentAndCurrentCollection() throws {
    let (db, a, _, first, second, original) = try fixture(), context = db.mainContext
    let commands = NoteCommands(context: context, undoManager: nil)
    let booksBefore = try LibraryRepository.snapshots(in: context)
    let child = try commands.move(payload(original, in: context), to: .book(a.id))
    assertContent(child, unchanged: original)
    XCTAssertEqual(child.parentBookID, a.id); XCTAssertTrue(child.collectionIDs.isEmpty)
    XCTAssertEqual(LibraryItemTree.rows(books: [a], notes: [child])[0].children.map(\.id), [.note(original.id)])
    let detached = try commands.move(payload(child, in: context), to: .topLevel(collectionID: second.id))
    assertContent(detached, unchanged: original)
    XCTAssertNil(detached.parentBookID); XCTAssertEqual(Set(detached.collectionIDs), [first.id, second.id])
    XCTAssertEqual(try OrganizationStore.notes(in: context).count, 1)
    XCTAssertEqual(try LibraryRepository.snapshots(in: context), booksBefore)
    XCTAssertEqual(Set(LibraryItemTree.rows(books: [a], notes: [detached]).map(\.id)), [.book(a.id), .note(original.id)])
  }

  func testReparentBetweenBooksAndNoOpDoNotDuplicateNotes() throws {
    let (db, a, b, _, _, original) = try fixture(), context = db.mainContext
    let commands = NoteCommands(context: context, undoManager: nil)
    let child = try commands.move(payload(original, in: context), to: .book(a.id))
    let moved = try commands.move(payload(child, in: context), to: .book(b.id))
    assertContent(moved, unchanged: original); XCTAssertEqual(moved.parentBookID, b.id)
    let revision = LibraryNotifier.forContext(context).revision
    XCTAssertEqual(try commands.move(payload(moved, in: context), to: .book(b.id)), moved)
    XCTAssertEqual(LibraryNotifier.forContext(context).revision, revision)
    let detached = try commands.move(payload(moved, in: context), to: .topLevel(collectionID: nil))
    let after = LibraryNotifier.forContext(context).revision
    XCTAssertEqual(try commands.move(payload(detached, in: context), to: .topLevel(collectionID: nil)), detached)
    XCTAssertEqual(LibraryNotifier.forContext(context).revision, after)
  }

  func testMoveUndoRedoRestoresParentAndAllOriginalPlacements() throws {
    let (db, a, _, _, _, original) = try fixture(), context = db.mainContext
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = NoteCommands(context: context, undoManager: undo)
    undo.beginUndoGrouping()
    let child = try commands.move(payload(original, in: context), to: .book(a.id))
    undo.endUndoGrouping()
    XCTAssertEqual(undo.undoActionName, "移动笔记")
    undo.undo(); XCTAssertEqual(try OrganizationStore.notes(in: context)[original.id], original)
    undo.redo(); XCTAssertEqual(try OrganizationStore.notes(in: context)[original.id], child)
    undo.beginUndoGrouping()
    let detached = try commands.move(payload(child, in: context), to: .topLevel(collectionID: nil))
    undo.endUndoGrouping()
    undo.undo(); XCTAssertEqual(try OrganizationStore.notes(in: context)[original.id], child)
    undo.redo(); XCTAssertEqual(try OrganizationStore.notes(in: context)[original.id], detached)
  }

  func testForeignUnsupportedStaleAndMissingDragsDoNotMutate() throws {
    let (db, a, _, _, _, original) = try fixture(), context = db.mainContext
    let commands = NoteCommands(context: context, undoManager: nil)
    let before = try OrganizationStore.notes(in: context)
    let valid = payload(original, in: context)
    let foreign = NoteDragPayload(libraryID: UUID(), note: original)
    var unsupported = valid; unsupported.version = 999
    var altered = original; altered.updatedAt = .distantPast
    var missing = original; missing.id = UUID()
    for invalid in [foreign, unsupported, payload(altered, in: context), payload(missing, in: context)] {
      XCTAssertThrowsError(try commands.move(invalid, to: .book(a.id)))
      XCTAssertEqual(try OrganizationStore.notes(in: context), before)
    }
    XCTAssertThrowsError(try commands.move(valid, to: .book(UUID())))
    var changed = original; changed.body = "拖动期间在另一窗口更新"; changed.updatedAt = original.updatedAt.addingTimeInterval(1)
    let newer = try commands.save(changed, expected: original)
    XCTAssertThrowsError(try commands.move(valid, to: .book(a.id)))
    XCTAssertEqual(try OrganizationStore.notes(in: context)[original.id], newer)
  }

  func testDeletedSourceParentAndDestinationRejectMoves() throws {
    let (db, a, b, _, _, original) = try fixture(), context = db.mainContext
    let commands = NoteCommands(context: context, undoManager: nil)
    let child = try commands.move(payload(original, in: context), to: .book(a.id))
    a.deletedAt = Date(); try context.save()
    XCTAssertThrowsError(try commands.move(payload(child, in: context), to: .topLevel(collectionID: nil)))
    XCTAssertThrowsError(try commands.move(payload(child, in: context), to: .book(b.id)))
    a.deletedAt = nil; b.deletedAt = Date(); try context.save()
    XCTAssertThrowsError(try commands.move(payload(child, in: context), to: .book(b.id)))
    try commands.setTrashed(true, expected: child)
    let deleted = try XCTUnwrap(OrganizationStore.notes(in: context)[child.id])
    XCTAssertThrowsError(try commands.move(payload(deleted, in: context), to: .topLevel(collectionID: nil)))
    XCTAssertEqual(try OrganizationStore.notes(in: context)[child.id], deleted)
  }

  func testInvalidAndSmartCollectionCannotReceiveDetachedNote() throws {
    let (db, a, _, _, _, original) = try fixture(), context = db.mainContext
    let commands = NoteCommands(context: context, undoManager: nil)
    let child = try commands.move(payload(original, in: context), to: .book(a.id))
    let smart = BookCollection(name: "智能")
    smart.smartRulesJSON = try AdvancedBookQuery.savingSearch(scope: .fieldsAndTags, text: "正文").encoded()
    context.insert(smart); try context.save()
    for id in [UUID(), smart.id] {
      XCTAssertThrowsError(try commands.move(payload(child, in: context), to: .topLevel(collectionID: id)))
      XCTAssertEqual(try OrganizationStore.notes(in: context)[child.id], child)
    }
  }

  func testDropPayloadRoundTripsWithoutExposingNoteText() throws {
    let (db, _, _, _, _, original) = try fixture()
    let value = payload(original, in: db.mainContext), encoded = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(NoteDragPayload.self, from: encoded)
    XCTAssertEqual(decoded, value); XCTAssertTrue(decoded.matches(original))
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertNil(fields["body"]); XCTAssertNil(fields["title"]); XCTAssertNil(fields["tags"])
  }

  func testBatchDragCarriesFullSelectionFromAnySelectedRow() throws {
    let library = UUID(), a = NoteRecord(title: "A"), b = NoteRecord(title: "B"), hidden = NoteRecord(title: "隐藏")
    for note in [a, b] {
      let batch = NoteDragBatch.selection(libraryID: library, dragging: note,
        selected: [a.id, b.id, hidden.id], available: [a, b])
      XCTAssertEqual(Set(batch.notes.map(\.noteID)), [a.id, b.id])
      let data = try JSONEncoder().encode(batch)
      XCTAssertEqual(try JSONDecoder().decode(NoteDragBatch.self, from: data), batch)
      XCTAssertEqual(try NoteDragBatch.references(in: [batch, batch]).count, 2)
    }
    let unselected = NoteDragBatch.selection(libraryID: library, dragging: b, selected: [a.id], available: [a, b])
    XCTAssertEqual(unselected.notes.map(\.noteID), [b.id])
  }

  func testInvalidAndConflictingBatchesAreRejected() throws {
    let note = NoteRecord(), reference = NoteDragPayload(libraryID: UUID(), note: note)
    let batch = NoteDragBatch(notes: [reference])
    var unsupported = batch; unsupported.version = 999
    var conflict = reference; conflict.version = 999
    for batches in [[], [NoteDragBatch(notes: [])], [unsupported], [batch, NoteDragBatch(notes: [conflict])]] {
      XCTAssertThrowsError(try NoteDragBatch.references(in: batches))
    }
  }

  func testBatchMoveAndDetachCommitOnceAndUndoAsOneOperation() throws {
    let (db, a, b, first, second, original) = try fixture(), context = db.mainContext
    let setup = NoteCommands(context: context, undoManager: nil)
    var draft = NoteRecord(title: "另一笔记", parentBookID: b.id); draft.body = "保留正文"; draft.tags = ["标签"]
    let other = try setup.save(draft, expected: nil)
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = NoteCommands(context: context, undoManager: undo)
    let before = try OrganizationStore.notes(in: context), booksBefore = try LibraryRepository.snapshots(in: context)
    let revision = LibraryNotifier.forContext(context).revision
    let refs = [payload(original, in: context), payload(other, in: context)]
    undo.beginUndoGrouping()
    let children = try commands.move(refs + refs, to: .book(a.id))
    undo.endUndoGrouping()
    XCTAssertEqual(children.count, 2); XCTAssertEqual(Set(children.compactMap(\.parentBookID)), [a.id])
    XCTAssertTrue(children.allSatisfy { $0.collectionIDs.isEmpty })
    for child in children { assertContent(child, unchanged: try XCTUnwrap(before[child.id])) }
    XCTAssertEqual(LibraryNotifier.forContext(context).revision, revision + 1)
    XCTAssertEqual(undo.undoActionName, "移动 2 条笔记")
    let attached = try OrganizationStore.notes(in: context)
    undo.undo(); XCTAssertEqual(try OrganizationStore.notes(in: context), before)
    XCTAssertFalse(undo.canUndo)
    undo.redo(); XCTAssertEqual(try OrganizationStore.notes(in: context), attached)
    undo.beginUndoGrouping()
    let roots = try commands.move(children.map { payload($0, in: context) }, to: .topLevel(collectionID: second.id))
    undo.endUndoGrouping()
    XCTAssertTrue(roots.allSatisfy { $0.parentBookID == nil && Set($0.collectionIDs) == [first.id, second.id] })
    let detached = try OrganizationStore.notes(in: context)
    undo.undo(); XCTAssertEqual(try OrganizationStore.notes(in: context), attached)
    undo.redo(); XCTAssertEqual(try OrganizationStore.notes(in: context), detached)
    XCTAssertEqual(try LibraryRepository.snapshots(in: context), booksBefore)
    XCTAssertEqual(try OrganizationStore.notes(in: context).count, 2)
  }

  func testDetachBatchKeepsEachOriginalParentsCollections() throws {
    let (db, a, b, first, second, original) = try fixture(), context = db.mainContext
    let commands = NoteCommands(context: context, undoManager: nil)
    let childA = try commands.move(payload(original, in: context), to: .book(a.id))
    let childB = try commands.save(NoteRecord(title: "B", parentBookID: b.id), expected: nil)
    let results = try commands.move([payload(childA, in: context), payload(childB, in: context)], to: .topLevel(collectionID: nil))
    XCTAssertEqual(results[0].collectionIDs, [first.id]); XCTAssertEqual(results[1].collectionIDs, [second.id])
    XCTAssertTrue(results.allSatisfy { $0.parentBookID == nil })
  }

  func testOneInvalidNoteRejectsEntireBatchWithoutWritesOrUndo() throws {
    let (db, a, b, _, _, original) = try fixture(), context = db.mainContext
    let setup = NoteCommands(context: context, undoManager: nil)
    let child = try setup.save(NoteRecord(title: "失效笔记", parentBookID: b.id), expected: nil)
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = NoteCommands(context: context, undoManager: undo)
    var stale = child; stale.updatedAt = .distantPast
    var missing = child; missing.id = UUID()
    var unsupported = payload(child, in: context); unsupported.version = 999
    let badRefs = [payload(stale, in: context), payload(missing, in: context), unsupported,
      NoteDragPayload(libraryID: UUID(), note: child)]
    for bad in badRefs {
      let before = try OrganizationStore.notes(in: context), revision = LibraryNotifier.forContext(context).revision
      XCTAssertThrowsError(try commands.move([payload(original, in: context), bad], to: .book(a.id)))
      XCTAssertEqual(try OrganizationStore.notes(in: context), before)
      XCTAssertEqual(LibraryNotifier.forContext(context).revision, revision)
      XCTAssertFalse(undo.canUndo)
    }
    b.deletedAt = Date(); try context.save()
    let before = try OrganizationStore.notes(in: context)
    XCTAssertThrowsError(try commands.move([payload(original, in: context), payload(child, in: context)], to: .book(a.id)))
    XCTAssertEqual(try OrganizationStore.notes(in: context), before)
    b.deletedAt = nil; try context.save()
    try setup.setTrashed(true, expected: child)
    let afterTrash = try OrganizationStore.notes(in: context)
    XCTAssertThrowsError(try commands.move([payload(original, in: context), payload(child, in: context)], to: .book(a.id)))
    XCTAssertEqual(try OrganizationStore.notes(in: context), afterTrash)
  }

  func testBatchNoOpsPreserveTimestampsAndDoNotCreateUndoEntries() throws {
    let (db, a, _, _, _, original) = try fixture(), context = db.mainContext
    let setup = NoteCommands(context: context, undoManager: nil)
    let child = try setup.save(NoteRecord(title: "已在目标中", parentBookID: a.id), expected: nil)
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = NoteCommands(context: context, undoManager: undo)
    undo.beginUndoGrouping()
    let results = try commands.move([payload(original, in: context), payload(child, in: context)], to: .book(a.id))
    undo.endUndoGrouping()
    XCTAssertEqual(results[1], child)
    undo.undo(); XCTAssertEqual(try OrganizationStore.notes(in: context)[child.id], child)
    undo.removeAllActions()
    let revision = LibraryNotifier.forContext(context).revision
    XCTAssertEqual(try commands.move([payload(child, in: context)], to: .book(a.id)), [child])
    XCTAssertEqual(LibraryNotifier.forContext(context).revision, revision); XCTAssertFalse(undo.canUndo)
  }

  func testBatchPlacementPersistsAcrossDatabaseReopen() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("library.store")
    var ids = Set<UUID>(), parentID = UUID()
    do {
      let db = try LibraryDatabase.open(at: url), context = db.mainContext
      let book = Book(title: "书籍"); context.insert(book); try context.save(); parentID = book.id
      let commands = NoteCommands(context: context, undoManager: nil)
      let notes = try ["第一条", "第二条", "第三条"].map { try commands.save(NoteRecord(title: $0), expected: nil) }
      ids = Set(notes.map(\.id))
      try commands.move(notes.map { payload($0, in: context) }, to: .book(parentID))
    }
    do {
      let db = try LibraryDatabase.open(at: url), context = db.mainContext
      let notes = Array(try OrganizationStore.notes(in: context, ids: ids).values)
      XCTAssertEqual(notes.count, 3); XCTAssertTrue(notes.allSatisfy { $0.parentBookID == parentID })
      try NoteCommands(context: context, undoManager: nil).move(notes.map { payload($0, in: context) }, to: .topLevel(collectionID: nil))
    }
    let db = try LibraryDatabase.open(at: url)
    let notes = try OrganizationStore.notes(in: db.mainContext, ids: ids)
    XCTAssertEqual(notes.count, 3); XCTAssertTrue(notes.values.allSatisfy { $0.parentBookID == nil })
  }

  func testPlacementPersistsAcrossDatabaseReopen() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("library.store")
    var noteID = UUID(), parentID = UUID()
    do {
      let db = try LibraryDatabase.open(at: url), context = db.mainContext
      let book = Book(title: "持久书籍"); context.insert(book); try context.save(); parentID = book.id
      let commands = NoteCommands(context: context, undoManager: nil)
      let original = try commands.save(NoteRecord(title: "持久笔记"), expected: nil); noteID = original.id
      try commands.move(payload(original, in: context), to: .book(book.id))
    }
    do {
      let db = try LibraryDatabase.open(at: url), context = db.mainContext
      let saved = try XCTUnwrap(OrganizationStore.notes(in: context)[noteID]); XCTAssertEqual(saved.parentBookID, parentID)
      try NoteCommands(context: context, undoManager: nil).move(payload(saved, in: context), to: .topLevel(collectionID: nil))
    }
    let reopened = try LibraryDatabase.open(at: url)
    XCTAssertNil(try XCTUnwrap(OrganizationStore.notes(in: reopened.mainContext)[noteID]).parentBookID)
  }
}
