import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class NoteTrashVisibilityTests: XCTestCase {
  private func book(in context: ModelContext) throws -> Book {
    let book = Book(title: "保留的书籍")
    context.insert(book); try context.save()
    return book
  }

  private func note(parent: UUID? = nil, in context: ModelContext) throws -> NoteRecord {
    var record = NoteRecord(parentBookID: parent)
    record.body = "# 删除前的正文\n保留所有阅读内容"
    return try NoteCommands(context: context, undoManager: nil).save(record, expected: nil)
  }

  private func trashNotes(in context: ModelContext, books: [Book], text: String = "") throws -> [NoteRecord] {
    NoteQueries.results(Array(try OrganizationStore.notes(in: context).values), books: books,
      collections: [], scope: .trash, text: text)
  }

  func testDeletedChildOfActiveBookAppearsInMainTrashAndSupportsUndoRestore() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let parent = try book(in: context), original = try note(parent: parent.id, in: context)
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = NoteCommands(context: context, undoManager: undo)
    undo.beginUndoGrouping()
    try commands.setTrashed(true, expected: original)
    undo.endUndoGrouping()
    var deleted = try trashNotes(in: context, books: [parent])
    XCTAssertEqual(deleted.map(\.id), [original.id])
    XCTAssertEqual(deleted.first?.body, original.body)
    XCTAssertNil(parent.deletedAt)
    XCTAssertEqual(LibraryItemTree.rows(books: [], notes: deleted, inTrash: true).map(\.id), [.note(original.id)])
    XCTAssertTrue(LibraryItemTree.rows(books: [parent], notes: deleted)[0].children.isEmpty)
    undo.undo()
    XCTAssertTrue(try trashNotes(in: context, books: [parent]).isEmpty)
    undo.redo()
    deleted = try trashNotes(in: context, books: [parent])
    XCTAssertEqual(deleted.map(\.id), [original.id])
    try NoteCommands(context: context, undoManager: nil).setTrashed(false, expected: XCTUnwrap(deleted.first))
    XCTAssertTrue(try trashNotes(in: context, books: [parent]).isEmpty)
    let restored = try XCTUnwrap(OrganizationStore.notes(in: context)[original.id])
    XCTAssertEqual(restored.body, original.body)
    XCTAssertEqual(restored.parentBookID, parent.id)
    XCTAssertEqual(LibraryItemTree.rows(books: [parent], notes: [restored])[0].children.map(\.id), [.note(original.id)])
  }

  func testStandaloneDeletedNoteIsVisibleWithoutAnyBooks() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let original = try note(in: context)
    try NoteCommands(context: context, undoManager: nil).setTrashed(true, expected: original)
    let notes = try trashNotes(in: context, books: [])
    XCTAssertEqual(notes.map(\.id), [original.id])
    let rows = LibraryItemTree.rows(books: [], notes: notes, inTrash: true)
    XCTAssertEqual(rows.map(\.id), [.note(original.id)])
    XCTAssertEqual(rows.first?.note?.body, original.body)
    XCTAssertEqual(NoteQueries.results(notes, books: [], collections: [], scope: .noteTrash, text: "").map(\.id), notes.map(\.id))
    XCTAssertTrue(NoteQueries.results(notes, books: [], collections: [], scope: .all, text: "").isEmpty)
  }

  func testParentTrashGroupsBothKindsOfChildrenWithoutDuplication() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let parent = try book(in: context)
    let inherited = try note(parent: parent.id, in: context), deleted = try note(parent: parent.id, in: context)
    try NoteCommands(context: context, undoManager: nil).setTrashed(true, expected: deleted)
    try LibraryOperations.setTrashed(true, books: [parent], context: context, undoManager: nil)
    let notes = try trashNotes(in: context, books: [parent])
    XCTAssertEqual(Set(notes.map(\.id)), [inherited.id, deleted.id])
    let rows = LibraryItemTree.rows(books: [parent], notes: notes, inTrash: true)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(Set(rows[0].children.map(\.id)), [.note(inherited.id), .note(deleted.id)])
    XCTAssertThrowsError(try NoteCommands(context: context, undoManager: nil).setTrashed(false,
      expected: XCTUnwrap(notes.first { $0.id == deleted.id })))
    try LibraryOperations.setTrashed(false, books: [parent], context: context, undoManager: nil)
    let remaining = try trashNotes(in: context, books: [parent])
    XCTAssertEqual(remaining.map(\.id), [deleted.id])
    XCTAssertEqual(LibraryItemTree.rows(books: [], notes: remaining, inTrash: true).map(\.id), [.note(deleted.id)])
  }

  func testTrashSearchMatchesNoteBodyAndExcludesActiveNotes() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let parent = try book(in: context), deleted = try note(parent: parent.id, in: context)
    _ = try note(in: context)
    try NoteCommands(context: context, undoManager: nil).setTrashed(true, expected: deleted)
    XCTAssertEqual(try trashNotes(in: context, books: [parent], text: "阅读内容").map(\.id), [deleted.id])
    XCTAssertTrue(try trashNotes(in: context, books: [parent], text: "没有这个词").isEmpty)
  }

  func testDeletedNoteSurvivesReopeningStoreAndRestoresItsBody() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("notes.store")
    let original: NoteRecord
    do {
      let db = try LibraryDatabase.open(at: url), context = db.mainContext
      original = try note(in: context)
      try NoteCommands(context: context, undoManager: nil).setTrashed(true, expected: original)
    }
    let reopened = try LibraryDatabase.open(at: url), context = reopened.mainContext
    let deleted = try XCTUnwrap(trashNotes(in: context, books: []).first)
    XCTAssertEqual(deleted.id, original.id); XCTAssertEqual(deleted.body, original.body)
    try NoteCommands(context: context, undoManager: nil).setTrashed(false, expected: deleted)
    XCTAssertTrue(try trashNotes(in: context, books: []).isEmpty)
    XCTAssertEqual(try OrganizationStore.notes(in: context)[original.id]?.body, original.body)
  }
}
