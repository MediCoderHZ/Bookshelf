import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class InlineNoteEditingTests: XCTestCase {
  private var containers: [ModelContainer] = []
  private func fixture() throws -> (ModelContext, NoteEditingSession, URL) {
    let container = try LibraryDatabase.open(inMemory: true)
    containers.append(container)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return (container.mainContext, NoteEditingSession(recovery: NoteDraftRecoveryStore(directory: directory)), directory)
  }
  private func stored(_ id: UUID, in context: ModelContext) throws -> NoteRecord {
    try XCTUnwrap(OrganizationStore.notes(in: context, ids: [id])[id])
  }
  private func create(_ name: String, in context: ModelContext) throws -> NoteRecord {
    try NoteCommands(context: context, undoManager: nil).save(NoteRecord(title: name), expected: nil)
  }

  func testEditsArePersistedBeforeReturningWithoutRewritingRawInput() throws {
    let (context, session, directory) = try fixture()
    let note = try create("原题", in: context), state = session.open(note)
    session.update(state, context: context, undoManager: nil) { $0.value.title = " 新标题 " }
    session.update(state, context: context, undoManager: nil) { $0.value.body = "第一行\n第二行：中文输入" }
    session.update(state, context: context, undoManager: nil) { $0.tagsText = "阅读、思考、" }
    let saved = try stored(note.id, in: context)
    XCTAssertEqual(saved.title, "新标题"); XCTAssertEqual(saved.body, "第一行\n第二行：中文输入")
    XCTAssertEqual(Set(saved.tags), ["阅读", "思考"])
    XCTAssertEqual(state.value.title, " 新标题 "); XCTAssertEqual(state.tagsText, "阅读、思考、")
    state.reconcile(saved)
    XCTAssertEqual(state.tagsText, "阅读、思考、")
    XCTAssertFalse(state.hasUnsavedChanges); XCTAssertNil(state.errorMessage)
    XCTAssertTrue(NoteDraftRecoveryStore(directory: directory).load().drafts.isEmpty)
  }

  func testSwitchingNotesCannotApplyTextToAnotherRecord() throws {
    let (context, session, _) = try fixture()
    let a = try create("A", in: context), b = try create("B", in: context)
    let first = session.open(a), second = session.open(b)
    session.update(first, context: context, undoManager: nil) { $0.value.body = "A 的正文" }
    session.update(second, context: context, undoManager: nil) { $0.value.body = "B 的正文" }
    XCTAssertEqual(try stored(a.id, in: context).body, "A 的正文")
    XCTAssertEqual(try stored(b.id, in: context).body, "B 的正文")
    XCTAssertTrue(session.open(try stored(a.id, in: context)) === first)
    XCTAssertEqual(first.value.body, "A 的正文")
  }

  func testEquivalentEditDoesNotCreateHistoryOrChangeTimestamp() throws {
    let (context, session, _) = try fixture()
    let note = try create("标题", in: context), state = session.open(note), undo = UndoManager()
    session.update(state, context: context, undoManager: undo) { $0.value.title = " 标题 " }
    XCTAssertFalse(undo.canUndo); XCTAssertEqual(try stored(note.id, in: context), note)
    XCTAssertEqual(LibraryServices.forContext(context).history.revision, 0)
  }

  func testExternalConflictKeepsDraftAcrossSessionRestartAndAllowsSafeCopy() throws {
    let (context, session, directory) = try fixture()
    let note = try create("原笔记", in: context), state = session.open(note)
    var changed = note; changed.body = "另一个窗口的新内容"
    let current = try NoteCommands(context: context, undoManager: nil).save(changed, expected: note)
    session.update(state, context: context, undoManager: nil) { $0.value.body = "此窗口的未保存内容" }
    XCTAssertTrue(state.hasUnsavedChanges); XCTAssertNotNil(state.errorMessage)
    state.reconcile(current)
    XCTAssertEqual(state.value.body, "此窗口的未保存内容")
    XCTAssertEqual(try stored(note.id, in: context), current)
    let restored = NoteEditingSession(recovery: NoteDraftRecoveryStore(directory: directory))
    let recovered = try XCTUnwrap(restored.pendingDrafts.first)
    XCTAssertEqual(recovered.value.body, state.value.body)
    XCTAssertFalse(restored.save(recovered, context: context, undoManager: nil))
    let copy = try restored.saveCopy(recovered, context: context, undoManager: nil)
    XCTAssertNotEqual(copy.id, note.id); XCTAssertEqual(copy.body, state.value.body)
    XCTAssertEqual(try stored(note.id, in: context), current)
    XCTAssertTrue(restored.pendingDrafts.isEmpty)
    XCTAssertTrue(NoteDraftRecoveryStore(directory: directory).load().drafts.isEmpty)
  }

  func testUndoRedoRefreshesCleanEditorWithoutSavingAgain() throws {
    let (context, session, _) = try fixture()
    let note = try create("原标题", in: context), state = session.open(note), undo = UndoManager()
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    session.update(state, context: context, undoManager: undo) { $0.value.body = "已自动保存" }
    undo.endUndoGrouping()
    let saved = try stored(note.id, in: context)
    undo.undo(); state.reconcile(try stored(note.id, in: context))
    XCTAssertEqual(state.value, note); XCTAssertTrue(undo.canRedo)
    undo.redo(); state.reconcile(try stored(note.id, in: context))
    XCTAssertEqual(state.value, saved); XCTAssertFalse(state.hasUnsavedChanges)
  }

  func testTrashedParentCannotBeOverwrittenAndRecoveryCopyBecomesStandalone() throws {
    let (context, session, _) = try fixture()
    let book = Book(title: "父书籍")
    try LibraryCommands(context: context, undoManager: nil).save(BookArchive(book: book), expected: nil)
    let parent = try XCTUnwrap(context.fetch(FetchDescriptor<Book>()).first)
    let note = try NoteCommands(context: context, undoManager: nil).save(NoteRecord(title: "子笔记", parentBookID: parent.id), expected: nil)
    let state = session.open(note)
    try LibraryOperations.setTrashed(true, books: [parent], context: context, undoManager: nil)
    session.update(state, context: context, undoManager: nil) { $0.value.body = "保留草稿" }
    XCTAssertTrue(state.hasUnsavedChanges); XCTAssertEqual(try stored(note.id, in: context), note)
    let copy = try session.saveCopy(state, context: context, undoManager: nil)
    XCTAssertNil(copy.parentBookID); XCTAssertEqual(copy.body, "保留草稿")
  }

  func testRecoveryWriteFailureKeepsEditableDraftInMemory() throws {
    let (context, _, directory) = try fixture()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("file")
    try Data("not a directory".utf8).write(to: file)
    let session = NoteEditingSession(recovery: NoteDraftRecoveryStore(directory: file.appendingPathComponent("drafts")))
    let note = try create("笔记", in: context), state = session.open(note)
    var newer = note; newer.body = "已保存的新版本"
    try NoteCommands(context: context, undoManager: nil).save(newer, expected: note)
    session.update(state, context: context, undoManager: nil) { $0.value.body = "不能丢失的草稿" }
    XCTAssertEqual(state.value.body, "不能丢失的草稿")
    XCTAssertTrue(state.hasUnsavedChanges)
    XCTAssertTrue(state.errorMessage?.contains("恢复副本也未能写入") == true)
  }

  func testBrokenRecoveryFileDoesNotHideOtherDraftsOrDeleteFiles() throws {
    let (context, _, directory) = try fixture()
    let recovery = NoteDraftRecoveryStore(directory: directory)
    let note = try create("可恢复", in: context)
    try recovery.save(NoteDraftSnapshot(baseline: note, draft: note, tagsText: ""))
    let damaged = directory.appendingPathComponent("broken.json")
    try Data("invalid".utf8).write(to: damaged)
    let loaded = recovery.load()
    XCTAssertEqual(loaded.drafts.count, 1); XCTAssertEqual(loaded.errors.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path))
  }
}
