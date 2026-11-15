import Foundation
import XCTest
@testable import Bookshelf

@MainActor
final class LibraryWorkspaceStateTests: XCTestCase {
  func testRoundTripPreservesSelectionExpansionAndCollapsedInspector() {
    let suite = "Bookshelf.WorkspaceTests.\(UUID())"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    var state = LibraryWorkspaceState(selection: .collection(UUID()), bookIDs: [UUID(), UUID()])
    state.expandedCollectionIDs = [UUID(), UUID()]
    state.expandedBookIDs = [UUID()]
    state.expandedPanels = []
    state.activePanel = .tags
    state.save(to: preferences)
    XCTAssertEqual(LibraryWorkspaceState.load(from: preferences), state)
  }

  func testLegacyFolderPanelPreferencePreservesEntireWorkspace() throws {
    let suite = "Bookshelf.WorkspaceTests.\(UUID())"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    var expected = LibraryWorkspaceState(selection: .collection(UUID()), bookIDs: [UUID()])
    expected.expandedCollectionIDs = [UUID(), UUID()]
    expected.expandedBookIDs = [UUID()]
    expected.expandedPanels = [.info, .collections]
    expected.activePanel = .collections
    for oldLabel in ["书库与书单", "书库与文件夹"] {
      var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
      legacy["activePanel"] = oldLabel
      legacy["expandedPanels"] = ["信息", oldLabel]
      preferences.set(try JSONSerialization.data(withJSONObject: legacy), forKey: LibraryWorkspaceState.storageKey)
      let restored = LibraryWorkspaceState.load(from: preferences)
      XCTAssertEqual(restored, expected)
      restored.save(to: preferences)
      let saved = try XCTUnwrap(preferences.data(forKey: LibraryWorkspaceState.storageKey))
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
      XCTAssertEqual(object["activePanel"] as? String, "文件夹")
      XCTAssertEqual(Set(object["expandedPanels"] as? [String] ?? []), ["信息", "文件夹"])
      XCTAssertEqual(try JSONDecoder().decode(LibraryWorkspaceState.self, from: saved), expected)
    }
  }

  func testCorruptPreferencesFallBackWithoutTouchingLibrary() {
    let suite = "Bookshelf.WorkspaceTests.\(UUID())"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(Data("invalid".utf8), forKey: LibraryWorkspaceState.storageKey)
    XCTAssertEqual(LibraryWorkspaceState.load(from: preferences), LibraryWorkspaceState())
  }

  func testMissingCollectionFallsBackAndDropsMissingSelections() {
    let book = Book(title: "保留的书")
    var state = LibraryWorkspaceState(selection: .collection(UUID()), bookIDs: [book.id, UUID()])
    state.expandedBookIDs = [book.id, UUID()]
    state.expandedCollectionIDs = [UUID()]
    let restored = state.validated(books: [book], collections: [], notes: [], includeSubcollections: false)
    XCTAssertEqual(restored.selection, .all)
    XCTAssertEqual(restored.bookIDs, [book.id])
    XCTAssertEqual(restored.expandedBookIDs, [book.id])
    XCTAssertTrue(restored.expandedCollectionIDs.isEmpty)
  }

  func testRemovedSidebarScopesRestoreToAllBooks() {
    let book = Book(title: "保留的书")
    for selection in [LibrarySelection.recent, .notes, .standaloneNotes, .smart(UUID())] {
      let state = LibraryWorkspaceState(selection: selection, bookIDs: [book.id])
      let restored = state.validated(books: [book], collections: [], notes: [], includeSubcollections: false)
      XCTAssertEqual(restored.selection, .all)
      XCTAssertEqual(restored.bookIDs, [book.id])
    }
  }

  func testLegacyNoteWorkspaceRestoresSelectionInUnifiedLibrary() {
    let book = Book(title: "书籍"), standalone = NoteRecord(title: "独立笔记")
    let child = NoteRecord(title: "子笔记", parentBookID: book.id)
    for (scope, note) in [(LibrarySelection.notes, child), (.standaloneNotes, standalone)] {
      let state = LibraryWorkspaceState(selection: scope, noteID: note.id)
      let restored = state.validated(books: [book], collections: [], notes: [standalone, child], includeSubcollections: false)
      XCTAssertEqual(restored.selection, .all)
      XCTAssertEqual(restored.noteID, note.id)
      if note.parentBookID != nil { XCTAssertEqual(restored.expandedBookIDs, [book.id]) }
    }
  }

  func testMovedAndTrashedBooksDoNotRemainSelectedInCollection() {
    let collection = BookCollection(name: "文件夹"), other = BookCollection(name: "其他文件夹")
    let kept = Book(title: "范围内"), moved = Book(title: "已移走"), trashed = Book(title: "已删除")
    kept.collectionItems = [CollectionItem(collection: collection, book: kept)]
    moved.collectionItems = [CollectionItem(collection: other, book: moved)]
    trashed.collectionItems = [CollectionItem(collection: collection, book: trashed)]; trashed.deletedAt = Date()
    let state = LibraryWorkspaceState(selection: .collection(collection.id), bookIDs: [kept.id, moved.id, trashed.id])
    let restored = state.validated(books: [kept, moved, trashed], collections: [collection, other], notes: [], includeSubcollections: false)
    XCTAssertEqual(restored.bookIDs, [kept.id])
  }

  func testChildNoteRestoresItsParentExpansionAndSingleSelection() {
    let book = Book(title: "书"), note = LibraryNote(title: "笔记", body: "正文")
    note.parentBookID = book.id
    let state = LibraryWorkspaceState(bookIDs: [book.id], noteID: note.id)
    let restored = state.validated(books: [book], collections: [], notes: [NoteRecord(note)], includeSubcollections: false)
    XCTAssertEqual(restored.noteID, note.id)
    XCTAssertEqual(restored.expandedBookIDs, [book.id])
    XCTAssertTrue(restored.bookIDs.isEmpty)
    note.deletedAt = Date()
    XCTAssertNil(state.validated(books: [book], collections: [], notes: [NoteRecord(note)], includeSubcollections: false).noteID)
  }

  func testStandaloneNoteAndMixedTrashSelectionRestore() {
    let note = LibraryNote(title: "独立笔记", body: "正文"), book = Book(title: "书")
    let state = LibraryWorkspaceState(noteID: note.id)
    XCTAssertEqual(state.validated(books: [book], collections: [], notes: [NoteRecord(note)], includeSubcollections: false).noteID, note.id)
    book.deletedAt = Date(); note.deletedAt = Date()
    let trash = LibraryWorkspaceState(selection: .trash, trashBookIDs: [book.id, UUID()], trashNoteIDs: [note.id, UUID()])
    let restored = trash.validated(books: [book], collections: [], notes: [NoteRecord(note)], includeSubcollections: false)
    XCTAssertEqual(restored.trashBookIDs, [book.id])
    XCTAssertEqual(restored.trashNoteIDs, [note.id])
  }

  func testNestedAndSmartCollectionScopesReevaluateCurrentContents() throws {
    let root = BookCollection(name: "父文件夹"), child = BookCollection(name: "子文件夹")
    child.parentID = root.id
    let book = Book(title: "阅读"), other = Book(title: "其他")
    book.collectionItems = [CollectionItem(collection: child, book: book)]
    let state = LibraryWorkspaceState(selection: .collection(root.id), bookIDs: [book.id])
    XCTAssertTrue(state.validated(books: [book], collections: [root, child], notes: [], includeSubcollections: false).bookIDs.isEmpty)
    XCTAssertEqual(state.validated(books: [book], collections: [root, child], notes: [], includeSubcollections: true).bookIDs, [book.id])
    let smart = BookCollection(name: "阅读")
    smart.smartRulesJSON = try AdvancedBookQuery.savingSearch(scope: .title, text: "阅读").encoded()
    let saved = LibraryWorkspaceState(selection: .smart(smart.id), bookIDs: [book.id, other.id])
    XCTAssertEqual(saved.validated(books: [book, other], collections: [smart], notes: [], includeSubcollections: false).bookIDs, [book.id])
  }
}
