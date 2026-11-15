import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class HierarchyNoteTests: XCTestCase {
  func testNoteCreationUsesBookSelectionAndDoesNotTreatSelectedNoteAsItsParent() {
    let bookID = UUID()
    XCTAssertEqual(NoteCreationTarget.resolve(selectedBookIDs: [], hasSelectedNote: false, inTrash: false), .standalone)
    XCTAssertEqual(NoteCreationTarget.resolve(selectedBookIDs: [bookID], hasSelectedNote: false, inTrash: false), .child(bookID))
    XCTAssertEqual(NoteCreationTarget.resolve(selectedBookIDs: [bookID], hasSelectedNote: true, inTrash: false), .standalone)
    XCTAssertEqual(NoteCreationTarget.resolve(selectedBookIDs: [], hasSelectedNote: true, inTrash: false), .standalone)
  }

  func testNoteCreationRejectsAmbiguousBookSelectionAndTrashScope() {
    let selected: Set<UUID> = [UUID(), UUID()]
    XCTAssertEqual(NoteCreationTarget.resolve(selectedBookIDs: selected, hasSelectedNote: false, inTrash: false), .unavailable)
    for ids: Set<UUID> in [[], [UUID()], selected] {
      for hasNote in [false, true] {
        let target = NoteCreationTarget.resolve(selectedBookIDs: ids, hasSelectedNote: hasNote, inTrash: true)
        XCTAssertEqual(target, .unavailable)
        XCTAssertNil(target.draft(collectionID: UUID()))
      }
    }
  }

  func testContextualNotesPersistCorrectParentAndCollectionMembership() throws {
    let db = try database(), ctx = db.mainContext
    let list = try collection("当前文件夹", in: ctx), parent = try book("所选书籍", in: ctx)
    let other = try book("其他书籍", in: ctx)
    let childTarget = NoteCreationTarget.resolve(selectedBookIDs: [parent.id], hasSelectedNote: false, inTrash: false)
    let child = try NoteCommands(context: ctx, undoManager: nil).save(
      XCTUnwrap(childTarget.draft(collectionID: list.id)), expected: nil)
    let independentTarget = NoteCreationTarget.resolve(selectedBookIDs: [], hasSelectedNote: false, inTrash: false)
    let standalone = try NoteCommands(context: ctx, undoManager: nil).save(
      XCTUnwrap(independentTarget.draft(collectionID: list.id)), expected: nil)
    let saved = try OrganizationStore.notes(in: ctx)
    XCTAssertEqual(saved[child.id]?.parentBookID, parent.id)
    XCTAssertEqual(saved[child.id]?.collectionIDs, [])
    XCTAssertNil(saved[standalone.id]?.parentBookID)
    XCTAssertEqual(saved[standalone.id]?.collectionIDs, [list.id])
    XCTAssertFalse(saved.values.contains { $0.parentBookID == other.id })
    let visible = NoteQueries.results(Array(saved.values), books: [parent, other], collections: [list],
      scope: .collection(list.id), text: "")
    XCTAssertEqual(visible.map(\.id), [standalone.id])
    XCTAssertEqual(try XCTUnwrap(independentTarget.draft(collectionID: nil)).collectionIDs, [])
  }

  func testContextualChildNoteCreationUndoRedoPreservesParent() throws {
    let db = try database(), ctx = db.mainContext, undo = undoManager()
    let parent = try book(in: ctx)
    let target = NoteCreationTarget.resolve(selectedBookIDs: [parent.id], hasSelectedNote: false, inTrash: false)
    let draft = try XCTUnwrap(target.draft(collectionID: nil))
    try grouped(undo) { _ = try NoteCommands(context: ctx, undoManager: undo).save(draft, expected: nil) }
    undo.undo()
    XCTAssertNil(try OrganizationStore.notes(in: ctx)[draft.id])
    undo.redo()
    XCTAssertEqual(try OrganizationStore.notes(in: ctx)[draft.id]?.parentBookID, parent.id)
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).map(\.id), [parent.id])
  }

  func testInspectorLocationsOnlyShowMembershipBranchesAndShareAncestors() {
    let root = ManualCollectionRecord(name: "阅读")
    let branch = ManualCollectionRecord(name: "文学", parentID: root.id)
    let first = ManualCollectionRecord(name: "A 小说", parentID: branch.id)
    let second = ManualCollectionRecord(name: "B 随笔", parentID: branch.id)
    let unrelated = ManualCollectionRecord(name: "不相关", parentID: root.id)
    let other = ManualCollectionRecord(name: "其他文件夹")
    let records = [second, unrelated, root, other, first, branch]
    let rows = CollectionTree.locations(for: [first.id, second.id, other.id], in: records)
    XCTAssertEqual(Set(rows.map(\.id)), [root.id, branch.id, first.id, second.id, other.id])
    XCTAssertEqual(rows.count, 5)
    XCTAssertEqual(rows.first { $0.id == first.id }?.depth, 2)
    XCTAssertEqual(rows.first { $0.id == branch.id }?.isDirectMember, false)
    XCTAssertEqual(rows.filter(\.isDirectMember).map(\.id).sorted(by: { $0.uuidString < $1.uuidString }),
      [first.id, second.id, other.id].sorted(by: { $0.uuidString < $1.uuidString }))
    XCTAssertLessThan(rows.firstIndex { $0.id == first.id }!, rows.firstIndex { $0.id == second.id }!)
    XCTAssertTrue(CollectionTree.locations(for: [], in: records).isEmpty)
    XCTAssertTrue(CollectionTree.locations(for: [UUID()], in: records).isEmpty)
  }

  func testInspectorLocationsKeepDirectParentMembershipAndHandleBrokenPaths() {
    let parent = ManualCollectionRecord(name: "父文件夹")
    let child = ManualCollectionRecord(name: "子文件夹", parentID: parent.id)
    let rows = CollectionTree.locations(for: [parent.id, child.id], in: [parent, child])
    XCTAssertEqual(rows.map(\.id), [parent.id, child.id])
    XCTAssertTrue(rows.allSatisfy(\.isDirectMember))
    let orphan = ManualCollectionRecord(name: "孤立文件夹", parentID: UUID())
    var a = ManualCollectionRecord(name: "A"), b = ManualCollectionRecord(name: "B")
    a.parentID = b.id; b.parentID = a.id
    let recovered = CollectionTree.locations(for: [orphan.id, a.id], in: [orphan, a, b])
    XCTAssertEqual(Set(recovered.map(\.id)), [orphan.id, a.id, b.id])
    XCTAssertEqual(recovered.count, 3)
    XCTAssertEqual(recovered.first { $0.id == orphan.id }?.depth, 0)
  }

  private func database() throws -> ModelContainer { try LibraryDatabase.open(inMemory: true) }
  private func undoManager() -> UndoManager { let value = UndoManager(); value.groupsByEvent = false; return value }
  private func grouped(_ undo: UndoManager, _ action: () throws -> Void) rethrows {
    undo.beginUndoGrouping(); defer { undo.endUndoGrouping() }; try action()
  }
  private func collection(_ name: String, parent: UUID? = nil, in context: ModelContext) throws -> ManualCollectionRecord {
    let id = try CollectionCommands(context: context, undoManager: nil).save(name: name, replacing: nil, parentID: parent)
    return try XCTUnwrap(OrganizationStore.collections(in: context)[id])
  }
  private func book(_ name: String = "图书", in context: ModelContext) throws -> Book {
    try LibraryCommands(context: context, undoManager: nil).save(BookArchive(book: Book(title: name)), expected: nil)
    return try XCTUnwrap(context.fetch(FetchDescriptor<Book>()).first { $0.title == name })
  }
  private func note(_ title: String = "笔记", parent: UUID? = nil, collections: [UUID] = [], in context: ModelContext) throws -> NoteRecord {
    var draft = NoteRecord(title: title, parentBookID: parent); draft.body = "正文与阅读想法"; draft.collectionIDs = collections
    try NoteCommands(context: context, undoManager: nil).save(draft, expected: nil)
    return try XCTUnwrap(OrganizationStore.notes(in: context)[draft.id])
  }
  private func archive(_ value: LibraryArchive) throws -> Data {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(value)
  }

  func testHierarchyRejectsCyclesMissingAndSmartParentsWithoutMutating() throws {
    let db = try database(), ctx = db.mainContext
    let root = try collection("根", in: ctx), child = try collection("子", parent: root.id, in: ctx)
    let before = try OrganizationStore.collections(in: ctx)
    let commands = CollectionCommands(context: ctx, undoManager: nil)
    XCTAssertThrowsError(try commands.save(name: root.name, replacing: root, parentID: child.id))
    XCTAssertThrowsError(try commands.save(name: root.name, replacing: root, parentID: root.id))
    XCTAssertThrowsError(try commands.save(name: "孤立", replacing: nil, parentID: UUID()))
    XCTAssertThrowsError(try commands.save(name: "子", replacing: nil))
    XCTAssertEqual(try OrganizationStore.collections(in: ctx), before)
  }

  func testMoveAndRenamePreserveMembershipAndUndo() throws {
    let db = try database(), ctx = db.mainContext, undo = undoManager()
    let a = try collection("甲", in: ctx), b = try collection("乙", in: ctx), child = try collection("子", parent: a.id, in: ctx)
    let item = try book(in: ctx)
    let model = try XCTUnwrap(ctx.fetch(FetchDescriptor<BookCollection>()).first { $0.id == child.id })
    try LibraryCommands(context: ctx, undoManager: nil).setMembership([item], collection: model, included: true)
    let link = try XCTUnwrap(item.collectionItems.first?.id)
    let baseline = ManualCollectionRecord(model)
    try grouped(undo) { _ = try CollectionCommands(context: ctx, undoManager: undo).save(name: "子改名", replacing: baseline, parentID: b.id) }
    XCTAssertEqual(model.parentID, b.id); XCTAssertEqual(item.collectionItems.first?.id, link)
    undo.undo(); XCTAssertEqual(model.parentID, a.id); XCTAssertEqual(model.name, "子")
    undo.redo(); XCTAssertEqual(model.parentID, b.id)
    _ = try CollectionCommands(context: ctx, undoManager: nil).save(name: "只改名称", replacing: ManualCollectionRecord(model))
    XCTAssertEqual(model.parentID, b.id)
  }

  func testRecursiveScopeDoesNotDuplicateBooksOrChangeMembership() throws {
    let db = try database(), ctx = db.mainContext
    let root = try collection("根", in: ctx), child = try collection("子", parent: root.id, in: ctx)
    let item = try book(in: ctx), other = try book("另一本", in: ctx)
    let all = try ctx.fetch(FetchDescriptor<BookCollection>())
    try LibraryCommands(context: ctx, undoManager: nil).setMembership([item], collection: all.first { $0.id == child.id }!, included: true)
    try LibraryCommands(context: ctx, undoManager: nil).setMembership([other], collection: all.first { $0.id == root.id }!, included: true)
    let direct = LibraryQueries.results([item, other], collections: all, request: LibraryQueryRequest(selection: .collection(root.id)))
    XCTAssertEqual(direct.map(\.id), [other.id])
    let recursive = LibraryQueries.results([item, other], collections: all,
      request: LibraryQueryRequest(selection: .collection(root.id), includeSubcollections: true))
    XCTAssertEqual(Set(recursive.map(\.id)), [item.id, other.id])
    XCTAssertEqual(item.collectionItems.count, 1)
    XCTAssertEqual(CollectionTree.path(child.id, in: all.map(ManualCollectionRecord.init)), "根 / 子")
    let standalone = try note(collections: [child.id], in: ctx)
    XCTAssertTrue(NoteQueries.results([standalone], books: [item, other], collections: all.map(ManualCollectionRecord.init),
      scope: .collection(root.id), text: "").isEmpty)
    XCTAssertEqual(NoteQueries.results([standalone], books: [item, other], collections: all.map(ManualCollectionRecord.init),
      scope: .collection(root.id), text: "", includeSubcollections: true).map(\.id), [standalone.id])
  }

  func testRemoveSubtreePreservesBooksNotesAndUndoRestoresPlacements() throws {
    let db = try database(), ctx = db.mainContext, undo = undoManager()
    let root = try collection("根", in: ctx), child = try collection("子", parent: root.id, in: ctx)
    let item = try book(in: ctx)
    let childModel = try XCTUnwrap(ctx.fetch(FetchDescriptor<BookCollection>()).first { $0.id == child.id })
    try LibraryCommands(context: ctx, undoManager: nil).setMembership([item], collection: childModel, included: true)
    let standalone = try note(collections: [child.id], in: ctx)
    let before = try OrganizationStore.collections(in: ctx)
    try grouped(undo) { try CollectionCommands(context: ctx, undoManager: undo).remove(root) }
    XCTAssertTrue(try OrganizationStore.collections(in: ctx).isEmpty)
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 1); XCTAssertTrue(item.collectionItems.isEmpty)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx)[standalone.id]?.collectionIDs, [])
    undo.undo()
    XCTAssertEqual(try OrganizationStore.collections(in: ctx), before)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx)[standalone.id], standalone)
    undo.redo(); XCTAssertTrue(try OrganizationStore.collections(in: ctx).isEmpty)
  }

  func testCreationUndoCannotDeleteNewDescendantsOrNotePlacements() throws {
    let db = try database(), ctx = db.mainContext, undo = undoManager()
    var id = UUID()
    try grouped(undo) { id = try CollectionCommands(context: ctx, undoManager: undo).save(name: "父", replacing: nil) }
    _ = try note(collections: [id], in: ctx)
    undo.undo()
    XCTAssertNotNil(try OrganizationStore.collections(in: ctx)[id])
    XCTAssertNotNil(LibraryServices.forContext(ctx).history.errorMessage)
  }

  func testStandaloneNoteCanAttachDetachEditAndUndo() throws {
    let db = try database(), ctx = db.mainContext, undo = undoManager()
    let item = try book(in: ctx), list = try collection("读书", in: ctx)
    let original = try note(collections: [list.id], in: ctx)
    var attached = original; attached.parentBookID = item.id; attached.tags = [" 思考 ", "思考"]
    try grouped(undo) { try NoteCommands(context: ctx, undoManager: undo).save(attached, expected: original) }
    let saved = try XCTUnwrap(OrganizationStore.notes(in: ctx)[original.id])
    XCTAssertEqual(saved.parentBookID, item.id); XCTAssertTrue(saved.collectionIDs.isEmpty); XCTAssertEqual(saved.tags, ["思考"])
    undo.undo(); XCTAssertEqual(try OrganizationStore.notes(in: ctx)[original.id], original)
    undo.redo()
    var detached = saved; detached.parentBookID = nil; detached.collectionIDs = [list.id]
    try NoteCommands(context: ctx, undoManager: nil).save(detached, expected: saved)
    XCTAssertNil(try OrganizationStore.notes(in: ctx)[original.id]?.parentBookID)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx).count, 1)
  }

  func testStaleNoteCannotOverwriteOrRestoreNewContent() throws {
    let db = try database(), ctx = db.mainContext
    let original = try note(in: ctx), commands = NoteCommands(context: ctx, undoManager: nil)
    var edited = original; edited.body = "新内容"; try commands.save(edited, expected: original)
    XCTAssertThrowsError(try commands.save(original, expected: original))
    XCTAssertThrowsError(try commands.setTrashed(true, expected: original))
    XCTAssertEqual(try OrganizationStore.notes(in: ctx)[original.id]?.body, "新内容")
  }

  func testLegacyNoteConversionPreservesTextAndCanUndo() throws {
    let db = try database(), ctx = db.mainContext, undo = undoManager(), item = try book(in: ctx)
    try LibraryCommands(context: ctx, undoManager: nil).update([item]) { $0.notes = "原有笔记\n第二段" }
    let before = BookArchive(book: item)
    try grouped(undo) { try NoteCommands(context: ctx, undoManager: undo).convertLegacyNote(before) }
    XCTAssertNil(item.notes)
    let converted = try XCTUnwrap(OrganizationStore.notes(in: ctx).values.first)
    XCTAssertEqual(converted.body, before.notes); XCTAssertEqual(converted.parentBookID, item.id)
    undo.undo(); XCTAssertEqual(item.notes, before.notes); XCTAssertTrue(try OrganizationStore.notes(in: ctx).isEmpty)
    undo.redo(); XCTAssertNil(item.notes); XCTAssertEqual(try OrganizationStore.notes(in: ctx).count, 1)
  }

  func testNoteTrashUndoAndParentTrashKeepContents() throws {
    let db = try database(), ctx = db.mainContext, undo = undoManager()
    let item = try book(in: ctx), original = try note(parent: item.id, in: ctx)
    try grouped(undo) { try NoteCommands(context: ctx, undoManager: undo).setTrashed(true, expected: original) }
    XCTAssertNotNil(try OrganizationStore.notes(in: ctx)[original.id]?.deletedAt)
    undo.undo(); XCTAssertEqual(try OrganizationStore.notes(in: ctx)[original.id], original)
    try LibraryOperations.setTrashed(true, books: [item], context: ctx, undoManager: nil)
    XCTAssertTrue(NoteQueries.isTrashed(original, books: [item]))
    XCTAssertEqual(try OrganizationStore.notes(in: ctx)[original.id], original)
    var detached = original; detached.parentBookID = nil
    XCTAssertThrowsError(try NoteCommands(context: ctx, undoManager: nil).save(detached, expected: original))
    try LibraryOperations.setTrashed(false, books: [item], context: ctx, undoManager: nil)
    XCTAssertFalse(NoteQueries.isTrashed(original, books: [item]))
  }

  func testBookCreationUndoProtectsLaterChildNoteAndPurgeRemovesChildren() throws {
    let db = try database(), ctx = db.mainContext, undo = undoManager()
    let draft = BookArchive(book: Book(title: "保护笔记"))
    try grouped(undo) { try LibraryCommands(context: ctx, undoManager: undo).save(draft, expected: nil) }
    let item = try XCTUnwrap(ctx.fetch(FetchDescriptor<Book>()).first)
    _ = try note(parent: item.id, in: ctx)
    undo.undo(); XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 1)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx).count, 1)
    try LibraryOperations.setTrashed(true, books: [item], context: ctx, undoManager: nil)
    try LibraryOperations.purge([item], context: ctx, undoManager: undo)
    XCTAssertTrue(try OrganizationStore.notes(in: ctx).isEmpty); XCTAssertFalse(undo.canUndo)
  }

  func testMergeMovesChildNotesAndUndoReturnsOriginalParents() throws {
    let db = try database(), ctx = db.mainContext, undo = undoManager()
    let a = try book("主记录", in: ctx), b = try book("副记录", in: ctx)
    let original = try note(parent: b.id, in: ctx)
    try grouped(undo) {
      _ = try LibraryOperations.merge([BookArchive(book: a), BookArchive(book: b)], primaryID: a.id, choices: [:], context: ctx, undoManager: undo)
    }
    XCTAssertEqual(try OrganizationStore.notes(in: ctx)[original.id]?.parentBookID, a.id)
    undo.undo(); XCTAssertEqual(try OrganizationStore.notes(in: ctx)[original.id], original); XCTAssertNil(b.deletedAt)
    undo.redo(); XCTAssertEqual(try OrganizationStore.notes(in: ctx)[original.id]?.parentBookID, a.id)
  }

  func testCurrentBackupRoundTripsEmptyTreeAndBothNoteKinds() throws {
    let source = try database(), ctx = source.mainContext
    let root = try collection("父", in: ctx), child = try collection("空子文件夹", parent: root.id, in: ctx)
    let item = try book(in: ctx)
    let standalone = try note("独立", collections: [child.id], in: ctx), attached = try note("子笔记", parent: item.id, in: ctx)
    let data = try LibraryBackupService.exportData(from: ctx), decoded = try LibraryBackupService.decode(data)
    XCTAssertEqual(decoded.schemaVersion, 9); XCTAssertEqual(decoded.collections?.count, 2); XCTAssertEqual(decoded.libraryNotes?.count, 2)
    let target = try database(), undo = undoManager()
    let plan = try LibraryImportPlanner.prepare(data, context: target.mainContext)
    try grouped(undo) { _ = try LibraryImportPlanner.apply(plan, choices: [:], context: target.mainContext, undoManager: undo) }
    XCTAssertEqual(try OrganizationStore.collections(in: target.mainContext)[child.id]?.parentID, root.id)
    XCTAssertEqual(try OrganizationStore.notes(in: target.mainContext)[attached.id]?.parentBookID, item.id)
    XCTAssertEqual(try OrganizationStore.notes(in: target.mainContext)[standalone.id]?.collectionIDs, [child.id])
    undo.undo(); XCTAssertTrue(try OrganizationStore.collections(in: target.mainContext).isEmpty); XCTAssertTrue(try OrganizationStore.notes(in: target.mainContext).isEmpty)
    XCTAssertTrue(try target.mainContext.fetch(FetchDescriptor<Book>()).isEmpty)
    undo.redo(); XCTAssertEqual(try OrganizationStore.notes(in: target.mainContext).count, 2)
    let repeated = try LibraryImportPlanner.prepare(data, context: target.mainContext)
    let result = try LibraryImportPlanner.apply(repeated, choices: [:], context: target.mainContext, undoManager: nil)
    XCTAssertEqual(result.createdNoteCount, 0); XCTAssertEqual(result.skippedNoteCount, 2); XCTAssertEqual(result.createdCollectionCount, 0)
  }

  func testImportNewCopyMapsChildNotesToNewBookID() throws {
    let source = try database(), ctx = source.mainContext
    let item = try book(in: ctx), original = try note(parent: item.id, in: ctx)
    let data = try LibraryBackupService.exportData(from: ctx), target = try database()
    try LibraryRepository.apply([BookArchive(book: item)], into: target.mainContext)
    let plan = try LibraryImportPlanner.prepare(data, context: target.mainContext)
    _ = try LibraryImportPlanner.apply(plan, choices: [item.id: ImportChoice(action: .add, targetID: nil)], context: target.mainContext, undoManager: nil)
    let imported = try XCTUnwrap(OrganizationStore.notes(in: target.mainContext)[original.id])
    XCTAssertNotEqual(imported.parentBookID, item.id)
    XCTAssertTrue(try target.mainContext.fetch(FetchDescriptor<Book>()).contains { $0.id == imported.parentBookID })
  }

  func testImportKeepsLocalCollectionPositionAndNoteContent() throws {
    let db = try database(), ctx = db.mainContext
    let root = try collection("本地父", in: ctx), shared = try collection("共用文件夹", parent: root.id, in: ctx)
    let original = try note("已有笔记", collections: [shared.id], in: ctx)
    var incomingList = ManualCollectionRecord(name: shared.name); incomingList.parentID = nil
    var incomingNote = original; incomingNote.body = "不能覆盖"; incomingNote.collectionIDs = [incomingList.id]
    var added = NoteRecord(title: "新增笔记"); added.collectionIDs = [incomingList.id]
    let data = try archive(LibraryArchive(schemaVersion: 4, exportedAt: Date(), books: [], collections: [incomingList], libraryNotes: [incomingNote, added]))
    let plan = try LibraryImportPlanner.prepare(data, context: ctx)
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: ctx, undoManager: nil)
    XCTAssertEqual(try OrganizationStore.collections(in: ctx)[shared.id]?.parentID, root.id)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx)[original.id], original)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx)[added.id]?.collectionIDs, [shared.id])
  }

  func testSkippedParentSkipsChildAndNoteOnlyImportCanBeDisabled() throws {
    let source = try database(), item = try book(in: source.mainContext)
    _ = try note(parent: item.id, in: source.mainContext)
    _ = try note("独立", in: source.mainContext)
    let data = try LibraryBackupService.exportData(from: source.mainContext), target = try database()
    let plan = try LibraryImportPlanner.prepare(data, context: target.mainContext)
    let disabled = try LibraryImportPlanner.apply(plan, choices: [item.id: ImportChoice(action: .skip, targetID: nil)],
      context: target.mainContext, undoManager: nil, includeOrganization: false)
    XCTAssertEqual(disabled.createdNoteCount, 0)
    let result = try LibraryImportPlanner.apply(plan, choices: [item.id: ImportChoice(action: .skip, targetID: nil)], context: target.mainContext, undoManager: nil)
    XCTAssertEqual(result.createdNoteCount, 1); XCTAssertEqual(result.skippedNoteCount, 1)
    XCTAssertNil(try OrganizationStore.notes(in: target.mainContext).values.first?.parentBookID)
  }

  func testStaleOrganizationPreviewStopsWholeImport() throws {
    let db = try database(), ctx = db.mainContext
    let incoming = NoteRecord(title: "导入笔记")
    let data = try archive(LibraryArchive(schemaVersion: 4, exportedAt: Date(), books: [], libraryNotes: [incoming]))
    let plan = try LibraryImportPlanner.prepare(data, context: ctx)
    _ = try note("并发新增", in: ctx)
    XCTAssertThrowsError(try LibraryImportPlanner.apply(plan, choices: [:], context: ctx, undoManager: nil))
    XCTAssertNil(try OrganizationStore.notes(in: ctx)[incoming.id])
  }

  func testInvalidArchivesRejectCyclesDanglingNotesAndDuplicateIDs() throws {
    var root = ManualCollectionRecord(name: "根"), child = ManualCollectionRecord(name: "子")
    child.parentID = root.id; root.parentID = child.id
    XCTAssertThrowsError(try LibraryBackupService.decode(archive(LibraryArchive(schemaVersion: 4, exportedAt: Date(), books: [], collections: [root, child]))))
    var missing = NoteRecord(title: "失联笔记"); missing.parentBookID = UUID()
    XCTAssertThrowsError(try LibraryBackupService.decode(archive(LibraryArchive(schemaVersion: 4, exportedAt: Date(), books: [], libraryNotes: [missing]))))
    missing.parentBookID = nil
    XCTAssertThrowsError(try LibraryBackupService.decode(archive(LibraryArchive(schemaVersion: 4, exportedAt: Date(), books: [], libraryNotes: [missing, missing]))))
  }

  func testFailedCombinedTransactionRollsBackTreeNotesAndBooks() throws {
    let db = try database(), ctx = db.mainContext
    let list = ManualCollectionRecord(name: "新文件夹")
    let item = BookArchive(book: Book(title: "不能留下"))
    var note = NoteRecord(title: "不能留下"); note.collectionIDs = [UUID()]
    XCTAssertThrowsError(try LibraryRepository.apply([item], manualCollections: [list], notes: [note], into: ctx))
    XCTAssertTrue(try OrganizationStore.collections(in: ctx).isEmpty); XCTAssertTrue(try OrganizationStore.notes(in: ctx).isEmpty)
    XCTAssertEqual(LibraryNotifier.forContext(ctx).revision, 0)
  }

  func testNotesSearchMatchesBodyTagsAndParentBookQuery() throws {
    let db = try database(), ctx = db.mainContext, item = try book(in: ctx)
    var record = NoteRecord(title: "读书心得", parentBookID: item.id); record.body = "边际收益的例子"; record.tags = ["经济"]
    try NoteCommands(context: ctx, undoManager: nil).save(record, expected: nil)
    XCTAssertTrue(NoteQueries.matches(record, text: "边际收益")); XCTAssertTrue(NoteQueries.matches(record, text: "经济"))
    let result = LibraryQueries.results([item], collections: [], request: LibraryQueryRequest(text: "边际收益", noteMatchedBookIDs: [item.id]))
    XCTAssertEqual(result.map(\.id), [item.id])
  }

  func testTreeAndNotesPersistAcrossDatabaseReopen() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("test.store")
    var rootID = UUID(), childID = UUID(), noteID = UUID()
    do {
      let db = try LibraryDatabase.open(at: url)
      rootID = try collection("持久父", in: db.mainContext).id
      childID = try collection("持久子", parent: rootID, in: db.mainContext).id
      noteID = try note(collections: [childID], in: db.mainContext).id
    }
    let reopened = try LibraryDatabase.open(at: url)
    XCTAssertEqual(try OrganizationStore.collections(in: reopened.mainContext)[childID]?.parentID, rootID)
    XCTAssertEqual(try OrganizationStore.notes(in: reopened.mainContext)[noteID]?.collectionIDs, [childID])
  }
}
