import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class BatchTrashTests: XCTestCase {
  private func book(_ context: ModelContext, trashed: Bool = false) throws -> Book {
    let book = Book(title: "测试书籍")
    if trashed { book.deletedAt = Date() }
    context.insert(book); try context.save(); return book
  }
  private func note(_ context: ModelContext, parent: Book? = nil, trashed: Bool = false) throws -> NoteRecord {
    var note = NoteRecord(parentBookID: parent?.id)
    note.body = "# 保留正文\n**格式**与阅读内容"
    if trashed { note.deletedAt = Date() }
    try LibraryRepository.apply([], notes: [note], into: context)
    return note
  }
  private func records(_ context: ModelContext) throws -> [UUID: NoteRecord] {
    try OrganizationStore.notes(in: context)
  }

  func testBatchNoteRestorePreservesParentsAndBodyAndUndoesAsOneAction() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let parent = try book(context), a = try note(context, parent: parent, trashed: true)
    let b = try note(context, trashed: true), untouched = try note(context, trashed: true)
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = TrashCommands(context: context, undoManager: undo)
    undo.beginUndoGrouping()
    try commands.restore(commands.preview([.note(a.id), .note(b.id)]))
    undo.endUndoGrouping()
    let restored = try records(context)
    XCTAssertNil(restored[a.id]?.deletedAt); XCTAssertNil(restored[b.id]?.deletedAt)
    XCTAssertEqual(restored[a.id]?.parentBookID, parent.id)
    XCTAssertEqual(restored[a.id]?.body, a.body)
    XCTAssertEqual(restored[untouched.id], untouched)
    undo.undo()
    XCTAssertEqual(try records(context)[a.id], a); XCTAssertEqual(try records(context)[b.id], b)
    undo.redo()
    XCTAssertNil(try records(context)[a.id]?.deletedAt); XCTAssertNil(try records(context)[b.id]?.deletedAt)
  }

  func testMixedRestoreIncludesSelectedChildButLeavesOtherExplicitlyDeletedChild() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let parent = try book(context, trashed: true)
    let inherited = try note(context, parent: parent), selected = try note(context, parent: parent, trashed: true)
    let other = try note(context, parent: parent, trashed: true), standalone = try note(context, trashed: true)
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = TrashCommands(context: context, undoManager: undo)
    let plan = try commands.preview([.book(parent.id), .note(selected.id), .note(standalone.id)])
    XCTAssertTrue(plan.canRestore)
    undo.beginUndoGrouping(); try commands.restore(plan); undo.endUndoGrouping()
    XCTAssertNil(parent.deletedAt)
    XCTAssertNil(try records(context)[selected.id]?.deletedAt)
    XCTAssertNil(try records(context)[standalone.id]?.deletedAt)
    XCTAssertEqual(try records(context)[other.id], other)
    XCTAssertEqual(try records(context)[inherited.id], inherited)
    undo.undo()
    XCTAssertNotNil(parent.deletedAt)
    XCTAssertEqual(try records(context)[selected.id], selected)
    XCTAssertEqual(try records(context)[standalone.id], standalone)
  }

  func testRestoreBlockedParentFailsWholeBatch() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let parent = try book(context, trashed: true)
    let child = try note(context, parent: parent), standalone = try note(context, trashed: true)
    let commands = TrashCommands(context: context, undoManager: nil)
    let plan = try commands.preview([.note(child.id), .note(standalone.id)])
    XCTAssertFalse(plan.canRestore)
    XCTAssertThrowsError(try commands.restore(plan))
    XCTAssertEqual(try records(context)[standalone.id], standalone)
    XCTAssertEqual(try records(context)[child.id], child)
  }

  func testBatchPurgeOnlyRemovesSelectedNotesAndClearsUndo() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let parent = try book(context), a = try note(context, parent: parent)
    let b = try note(context, trashed: true), retained = try note(context, trashed: true)
    let undo = UndoManager(); undo.groupsByEvent = false
    undo.beginUndoGrouping()
    try NoteCommands(context: context, undoManager: undo).setTrashed(true, expected: a)
    undo.endUndoGrouping()
    XCTAssertTrue(undo.canUndo)
    let commands = TrashCommands(context: context, undoManager: undo)
    try commands.purge(commands.preview([.note(a.id), .note(b.id)]))
    XCTAssertNil(try records(context)[a.id]); XCTAssertNil(try records(context)[b.id])
    XCTAssertEqual(try records(context)[retained.id], retained)
    XCTAssertEqual(try context.fetch(FetchDescriptor<Book>()).map(\.id), [parent.id])
    XCTAssertFalse(undo.canUndo)
  }

  func testInheritedChildCanBePermanentlyDeletedWithoutDeletingItsParentOrSibling() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let parent = try book(context, trashed: true)
    let a = try note(context, parent: parent), b = try note(context, parent: parent)
    let commands = TrashCommands(context: context, undoManager: nil)
    try commands.purge(commands.preview([.note(a.id)]))
    XCTAssertEqual(try records(context)[b.id], b); XCTAssertNil(try records(context)[a.id])
    XCTAssertNotNil(parent.deletedAt)
  }

  func testEmptyTrashCountsChildrenOnceAndPreservesActiveRecords() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let active = try book(context), deleted = try book(context, trashed: true)
    let activeNote = try note(context, parent: active), independent = try note(context)
    _ = try note(context, parent: active, trashed: true)
    _ = try note(context, parent: deleted)
    _ = try note(context, parent: deleted, trashed: true)
    _ = try note(context, trashed: true)
    let commands = TrashCommands(context: context, undoManager: nil)
    let plan = try commands.previewEmptyTrash()
    XCTAssertEqual(plan.books.count, 1); XCTAssertEqual(plan.notes.count, 4)
    XCTAssertEqual(plan.summary, "1 本书、4 条笔记")
    XCTAssertTrue(plan.confirmationMessage.contains("当前搜索或筛选未显示"))
    try commands.purge(plan)
    XCTAssertEqual(try context.fetch(FetchDescriptor<Book>()).map(\.id), [active.id])
    XCTAssertEqual(Set(try records(context).keys), [activeNote.id, independent.id])
    XCTAssertThrowsError(try commands.previewEmptyTrash())
  }

  func testEmptyTrashWithOnlyNotes() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    _ = try note(context, trashed: true); _ = try note(context, trashed: true)
    let commands = TrashCommands(context: context, undoManager: nil)
    let plan = try commands.previewEmptyTrash()
    XCTAssertEqual(plan.summary, "2 条笔记")
    try commands.purge(plan)
    XCTAssertTrue(try records(context).isEmpty)
  }

  func testPreviewDoesNotMutateAndCountsSelectedParentAndChildOnce() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let parent = try book(context, trashed: true), a = try note(context, parent: parent)
    let before = try LibraryRepository.snapshots(in: context)
    let commands = TrashCommands(context: context, undoManager: nil)
    let plan = try commands.preview([.book(parent.id), .note(a.id)])
    XCTAssertEqual(plan.notes.count, 1); XCTAssertEqual(plan.books.count, 1)
    XCTAssertEqual(plan.summary, "1 本书、1 条笔记")
    XCTAssertEqual(try LibraryRepository.snapshots(in: context), before)
    XCTAssertEqual(try records(context)[a.id], a)
  }

  func testRestoredNoteAfterConfirmationStopsEntirePurge() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let a = try note(context, trashed: true), b = try note(context, trashed: true)
    let commands = TrashCommands(context: context, undoManager: nil)
    let plan = try commands.preview([.note(a.id), .note(b.id)])
    try NoteCommands(context: context, undoManager: nil).setTrashed(false, expected: a)
    XCTAssertThrowsError(try commands.purge(plan))
    XCTAssertNil(try records(context)[a.id]?.deletedAt)
    XCTAssertEqual(try records(context)[b.id], b)
  }

  func testChangedBodyAfterConfirmationStopsPurge() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    var a = try note(context, trashed: true)
    let commands = TrashCommands(context: context, undoManager: nil)
    let plan = try commands.preview([.note(a.id)])
    a.body = "确认后修改的内容"; try LibraryRepository.apply([], notes: [a], into: context)
    XCTAssertThrowsError(try commands.purge(plan))
    XCTAssertEqual(try records(context)[a.id], a)
  }

  func testNewChildAfterBookConfirmationStopsPurge() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let parent = try book(context, trashed: true)
    let commands = TrashCommands(context: context, undoManager: nil)
    let plan = try commands.preview([.book(parent.id)])
    let child = try note(context, parent: parent)
    XCTAssertThrowsError(try commands.purge(plan))
    XCTAssertEqual(try records(context)[child.id], child)
    XCTAssertEqual(try context.fetch(FetchDescriptor<Book>()).map(\.id), [parent.id])
  }

  func testNewTrashItemAfterEmptyConfirmationRequiresNewConfirmation() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    _ = try note(context, trashed: true)
    let commands = TrashCommands(context: context, undoManager: nil)
    let plan = try commands.previewEmptyTrash()
    _ = try note(context, trashed: true)
    XCTAssertThrowsError(try commands.purge(plan))
    XCTAssertEqual(try records(context).count, 2)
  }

  func testActiveAndMissingSelectionIsRejected() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let active = try book(context), a = try note(context), b = try note(context, trashed: true)
    let commands = TrashCommands(context: context, undoManager: nil)
    XCTAssertThrowsError(try commands.preview([.note(a.id), .note(b.id)]))
    XCTAssertThrowsError(try commands.preview([.book(active.id), .note(b.id)]))
    XCTAssertThrowsError(try commands.preview([.note(UUID())]))
    XCTAssertThrowsError(try commands.preview([.attachment(bookID: active.id, id: UUID()), .note(b.id)]))
    XCTAssertThrowsError(try commands.preview([]))
    XCTAssertEqual(try records(context).count, 2)
  }

  func testPermanentlyDeletedNotesStayDeletedAfterReopeningStore() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("trash.store")
    let retainedID: UUID
    do {
      let db = try LibraryDatabase.open(at: url), context = db.mainContext
      let deleted = try book(context, trashed: true)
      _ = try note(context, parent: deleted); _ = try note(context, trashed: true)
      retainedID = try note(context).id
      let commands = TrashCommands(context: context, undoManager: nil)
      try commands.purge(commands.previewEmptyTrash())
    }
    let db = try LibraryDatabase.open(at: url)
    XCTAssertTrue(try db.mainContext.fetch(FetchDescriptor<Book>()).isEmpty)
    XCTAssertEqual(Set(try records(db.mainContext).keys), [retainedID])
  }
}
