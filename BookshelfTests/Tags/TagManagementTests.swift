import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class TagManagementTests: XCTestCase {
  private func database() throws -> ModelContainer { try LibraryDatabase.open(inMemory: true) }
  private func manager() -> UndoManager { let undo = UndoManager(); undo.groupsByEvent = false; return undo }
  private func grouped(_ undo: UndoManager, _ action: () throws -> Void) rethrows {
    undo.beginUndoGrouping(); defer { undo.endUndoGrouping() }; try action()
  }
  private func book(_ name: String, tags: [String], trash: Bool = false, in ctx: ModelContext) throws -> Book {
    var record = BookArchive(book: Book(title: name))
    record.tags = tags; record.notes = "原有书籍备注"; record.publisher = "原出版社"
    if trash { record.deletedAt = Date() }
    try LibraryRepository.apply([record], into: ctx)
    return try XCTUnwrap(ctx.fetch(FetchDescriptor<Book>()).first { $0.id == record.id })
  }
  private func note(_ tags: [String], parent: UUID? = nil, trash: Bool = false, in ctx: ModelContext) throws -> NoteRecord {
    var record = NoteRecord(title: "笔记", parentBookID: parent)
    record.body = "保留的正文"; record.tags = tags
    if trash { record.deletedAt = Date() }
    try LibraryRepository.apply([], notes: [record], into: ctx)
    return record
  }
  private func tag(_ name: String, in ctx: ModelContext) throws -> TagRecord {
    try XCTUnwrap(TagStore.snapshots(in: ctx).values.first { $0.name == name })
  }

  func testRenameKeepsIdentityAndLinksUpdatesTrashAndNotesAndUndoes() throws {
    let db = try database(), ctx = db.mainContext, undo = manager()
    let active = try book("在库", tags: ["旧名", "保留"], in: ctx)
    let trash = try book("已删除", tags: ["旧名"], trash: true, in: ctx)
    _ = try note(["旧名", "保留"], parent: active.id, in: ctx)
    _ = try note(["旧名"], trash: true, in: ctx)
    let source = try tag("旧名", in: ctx), beforeTags = try TagStore.snapshots(in: ctx)
    let beforeBooks = try LibraryRepository.snapshots(in: ctx), beforeNotes = try OrganizationStore.notes(in: ctx)
    let links = Set(try ctx.fetch(FetchDescriptor<BookTag>()).map(\.id))
    try grouped(undo) {
      XCTAssertEqual(try TagCommands(context: ctx, undoManager: undo).rename(source, to: " 新名 "), source.id)
    }
    XCTAssertEqual(try tag("新名", in: ctx).id, source.id)
    XCTAssertEqual(Set(try ctx.fetch(FetchDescriptor<BookTag>()).map(\.id)), links)
    XCTAssertEqual(active.tagDisplayName, "保留、新名")
    XCTAssertNotNil(trash.deletedAt)
    XCTAssertTrue(try OrganizationStore.notes(in: ctx).values.allSatisfy { $0.tags.contains("新名") && $0.body == "保留的正文" })
    let afterBooks = try LibraryRepository.snapshots(in: ctx), afterNotes = try OrganizationStore.notes(in: ctx)
    undo.undo()
    XCTAssertEqual(try TagStore.snapshots(in: ctx), beforeTags)
    XCTAssertEqual(try LibraryRepository.snapshots(in: ctx), beforeBooks)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx), beforeNotes)
    undo.redo()
    XCTAssertEqual(try LibraryRepository.snapshots(in: ctx), afterBooks)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx), afterNotes)
  }

  func testMergeUnionsReferencesDeduplicatesAndRestoresOriginalTagsOnUndo() throws {
    let db = try database(), ctx = db.mainContext, undo = manager()
    let a = try book("重叠", tags: ["来源", "目标", "保留"], in: ctx)
    _ = try book("来源独有", tags: ["来源"], trash: true, in: ctx)
    _ = try book("目标独有", tags: ["目标"], in: ctx)
    let standalone = try note(["来源", "目标", "保留"], in: ctx)
    _ = try note(["来源"], parent: a.id, trash: true, in: ctx)
    let source = try tag("来源", in: ctx), target = try tag("目标", in: ctx)
    let beforeTags = try TagStore.snapshots(in: ctx), beforeBooks = try LibraryRepository.snapshots(in: ctx)
    let beforeNotes = try OrganizationStore.notes(in: ctx)
    try grouped(undo) {
      XCTAssertEqual(try TagCommands(context: ctx, undoManager: undo).rename(source, to: "目标", merging: target), target.id)
    }
    let after = try TagStore.snapshots(in: ctx)
    XCTAssertNil(after[source.id]); XCTAssertEqual(after[target.id]?.bookIDs.count, 3)
    XCTAssertEqual(after[target.id]?.noteIDs.count, 2)
    XCTAssertEqual(a.tagLinks.filter { $0.tag?.id == target.id }.count, 1)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx)[standalone.id]?.tags, ["目标", "保留"])
    XCTAssertEqual(a.publisher, "原出版社"); XCTAssertEqual(a.notes, "原有书籍备注")
    undo.undo()
    XCTAssertEqual(try TagStore.snapshots(in: ctx), beforeTags)
    XCTAssertEqual(try LibraryRepository.snapshots(in: ctx), beforeBooks)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx), beforeNotes)
    undo.redo(); XCTAssertEqual(try TagStore.snapshots(in: ctx), after)
  }

  func testDeleteRemovesOnlyTagAndCanUndoRedo() throws {
    let db = try database(), ctx = db.mainContext, undo = manager()
    _ = try book("在库", tags: ["移除", "保留"], in: ctx)
    _ = try book("回收站", tags: ["移除"], trash: true, in: ctx)
    _ = try note(["移除", "保留"], trash: true, in: ctx)
    let beforeTags = try TagStore.snapshots(in: ctx), beforeBooks = try LibraryRepository.snapshots(in: ctx)
    let beforeNotes = try OrganizationStore.notes(in: ctx), source = try tag("移除", in: ctx)
    try grouped(undo) { try TagCommands(context: ctx, undoManager: undo).remove(source) }
    XCTAssertNil(try TagStore.snapshots(in: ctx)[source.id])
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 2)
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<LibraryNote>()).count, 1)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx).values.first?.tags, ["保留"])
    XCTAssertTrue(try ctx.fetch(FetchDescriptor<Book>()).allSatisfy { !$0.tagLinks.contains { $0.tag?.name == "移除" } })
    undo.undo()
    XCTAssertEqual(try TagStore.snapshots(in: ctx), beforeTags)
    XCTAssertEqual(try LibraryRepository.snapshots(in: ctx), beforeBooks)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx), beforeNotes)
    undo.redo(); XCTAssertNil(try TagStore.snapshots(in: ctx)[source.id])
  }

  func testUnusedTagOperationsStillNotifyAndUndo() throws {
    let db = try database(), ctx = db.mainContext, undo = manager()
    let unused = Tag(name: "未使用"); ctx.insert(unused); try ctx.save()
    let source = try tag("未使用", in: ctx), notifier = LibraryNotifier.forContext(ctx)
    let revision = notifier.revision
    try grouped(undo) { try TagCommands(context: ctx, undoManager: undo).remove(source) }
    XCTAssertGreaterThan(notifier.revision, revision)
    XCTAssertEqual(notifier.lastChange?.tagIDs, [source.id])
    undo.undo(); XCTAssertEqual(try TagStore.snapshots(in: ctx)[source.id], source)
  }

  func testNormalizationRequiresExplicitMergeAndAllowsOwnSpellingChange() throws {
    let db = try database(), ctx = db.mainContext
    _ = try book("图书", tags: ["Café", "其他"], in: ctx)
    let commands = TagCommands(context: ctx, undoManager: nil)
    let cafe = try tag("Café", in: ctx), other = try tag("其他", in: ctx)
    let before = try TagStore.snapshots(in: ctx)
    XCTAssertThrowsError(try commands.rename(other, to: " ＣＡＦＥ "))
    XCTAssertThrowsError(try commands.rename(other, to: " \n "))
    XCTAssertEqual(try TagStore.snapshots(in: ctx), before)
    XCTAssertEqual(try commands.rename(cafe, to: "CAFE"), cafe.id)
    let changed = try commands.record(cafe.id)
    XCTAssertEqual(changed.name, "CAFE")
    XCTAssertEqual(try commands.rename(other, to: "café", merging: changed), cafe.id)
    XCTAssertEqual(try TagStore.snapshots(in: ctx).count, 1)
  }

  func testStalePreviewAndUndoRejectNewReferences() throws {
    let db = try database(), ctx = db.mainContext, undo = manager()
    _ = try book("原书", tags: ["原名"], in: ctx)
    let source = try tag("原名", in: ctx)
    _ = try book("新书", tags: ["原名"], in: ctx)
    let commands = TagCommands(context: ctx, undoManager: undo)
    XCTAssertThrowsError(try commands.remove(source))
    XCTAssertThrowsError(try commands.rename(source, to: "改名"))
    try grouped(undo) { try commands.rename(try commands.record(source.id), to: "改名") }
    _ = try note(["改名"], in: ctx)
    let before = try TagStore.snapshots(in: ctx)
    undo.undo()
    XCTAssertEqual(try TagStore.snapshots(in: ctx), before)
    XCTAssertNotNil(LibraryServices.forContext(ctx).history.errorMessage)
  }

  func testUndoDeletionCannotOverwriteReusedName() throws {
    let db = try database(), ctx = db.mainContext, undo = manager()
    _ = try book("原书", tags: ["名称"], in: ctx)
    let source = try tag("名称", in: ctx)
    try grouped(undo) { try TagCommands(context: ctx, undoManager: undo).remove(source) }
    _ = try book("新书", tags: ["名称"], in: ctx)
    let reused = try tag("名称", in: ctx), books = try LibraryRepository.snapshots(in: ctx)
    undo.undo()
    XCTAssertNotEqual(reused.id, source.id)
    XCTAssertEqual(try TagStore.snapshots(in: ctx)[reused.id], reused)
    XCTAssertEqual(try LibraryRepository.snapshots(in: ctx), books)
    XCTAssertNotNil(LibraryServices.forContext(ctx).history.errorMessage)
  }

  func testFailedTransactionRollsBackTagIdentityAndDoesNotNotify() throws {
    let db = try database(), ctx = db.mainContext
    _ = try book("图书", tags: ["原名"], in: ctx)
    let before = try TagStore.snapshots(in: ctx), books = try LibraryRepository.snapshots(in: ctx)
    var renamed = try tag("原名", in: ctx); renamed.name = "改名"
    let invalid = NoteRecord(title: "无效归属", parentBookID: UUID())
    let notifier = LibraryNotifier.forContext(ctx), revision = notifier.revision
    XCTAssertThrowsError(try LibraryRepository.apply([], notes: [invalid], tags: [renamed], into: ctx))
    XCTAssertEqual(try TagStore.snapshots(in: ctx), before)
    XCTAssertEqual(try LibraryRepository.snapshots(in: ctx), books)
    XCTAssertEqual(notifier.revision, revision)
  }

  func testUndoCannotAbsorbNewNoteUsingDeletedName() throws {
    let db = try database(), ctx = db.mainContext, undo = manager()
    _ = try book("原书", tags: ["原名"], in: ctx)
    let source = try tag("原名", in: ctx)
    try grouped(undo) { try TagCommands(context: ctx, undoManager: undo).remove(source) }
    _ = try note(["原名"], in: ctx)
    let books = try LibraryRepository.snapshots(in: ctx), notes = try OrganizationStore.notes(in: ctx)
    undo.undo()
    XCTAssertNil(try TagStore.snapshots(in: ctx)[source.id])
    XCTAssertEqual(try LibraryRepository.snapshots(in: ctx), books)
    XCTAssertEqual(try OrganizationStore.notes(in: ctx), notes)
    XCTAssertNotNil(LibraryServices.forContext(ctx).history.errorMessage)
  }

  func testRenameToNoteOnlyLabelPreservesExistingNoteAndUndo() throws {
    let db = try database(), ctx = db.mainContext, undo = manager()
    _ = try book("图书", tags: ["旧名"], in: ctx)
    let existing = try note(["新名"], in: ctx)
    let source = try tag("旧名", in: ctx)
    try grouped(undo) { try TagCommands(context: ctx, undoManager: undo).rename(source, to: "新名") }
    XCTAssertEqual(try tag("新名", in: ctx).noteIDs, [existing.id])
    XCTAssertEqual(try OrganizationStore.notes(in: ctx)[existing.id], existing)
    undo.undo(); XCTAssertEqual(try TagStore.snapshots(in: ctx)[source.id], source)
    undo.redo(); XCTAssertEqual(try tag("新名", in: ctx).noteIDs, [existing.id])
    XCTAssertEqual(try OrganizationStore.notes(in: ctx)[existing.id], existing)
  }

  func testTagAndBookEditsShareUndoHistory() throws {
    let db = try database(), ctx = db.mainContext, undo = manager()
    let item = try book("原书名", tags: ["原标签"], in: ctx)
    let original = BookArchive(book: item)
    try grouped(undo) { try LibraryCommands(context: ctx, undoManager: undo).update([item]) { $0.title = "新书名" } }
    try grouped(undo) { try TagCommands(context: ctx, undoManager: undo).rename(try tag("原标签", in: ctx), to: "新标签") }
    undo.undo(); XCTAssertEqual(item.title, "新书名"); XCTAssertEqual(item.tagDisplayName, "原标签")
    undo.undo(); XCTAssertEqual(BookArchive(book: item), original)
    undo.redo(); undo.redo()
    XCTAssertEqual(item.title, "新书名"); XCTAssertEqual(item.tagDisplayName, "新标签")
  }
}
