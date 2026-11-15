import AppKit
import SwiftData
import XCTest
@testable import Bookshelf

final class PublisherSuggestionTests: XCTestCase {
  private func matches(_ query: String, _ names: [String]) -> [NameSuggestion] {
    PublisherSuggestions.matches(query, usages: names.map { PublisherUsage(name: $0, bookID: UUID()) })
  }

  func testExactPrefixAndSubstringRanking() {
    let names = matches("人民", ["上海人民出版社", "人民文学出版社", "人民", "商务印书馆", "人民出版社"])
    XCTAssertEqual(names.first?.name, "人民")
    XCTAssertEqual(Set(names.dropFirst().prefix(2).map(\.name)), ["人民出版社", "人民文学出版社"])
    XCTAssertEqual(names.last?.name, "上海人民出版社")
  }

  func testDeduplicationTrimmingAndDistinctBookFrequency() {
    let sameBook = UUID()
    let usages = [PublisherUsage(name: "人民甲", bookID: sameBook),
      PublisherUsage(name: " 人民甲 ", bookID: sameBook),
      PublisherUsage(name: "人民乙", bookID: UUID()), PublisherUsage(name: "人民乙", bookID: UUID())]
    XCTAssertEqual(PublisherSuggestions.matches("人民", usages: usages).map(\.name), ["人民乙", "人民甲"])
  }

  func testCaseWidthAccentMatchingPreservesCompleteSpelling() {
    XCTAssertEqual(Set(matches("ＥＤＩＴＩＯＮＳ", ["Éditions Gallimard", "editions Gallimard"]).map(\.name)),
      ["Éditions Gallimard", "editions Gallimard"])
    XCTAssertEqual(matches("editions", ["Éditions", "editions"]).first?.name, "editions")
    XCTAssertEqual(matches("thames", ["Thames & Hudson, Ltd."]).first?.name, "Thames & Hudson, Ltd.")
    XCTAssertEqual(matches("oxforduniversity", ["Oxford University Press"]).first?.name, "Oxford University Press")
  }

  func testEmptyUnmatchedMultilineAndLimits() {
    XCTAssertTrue(matches(" \n", ["人民出版社"]).isEmpty)
    XCTAssertTrue(matches("未知", ["人民出版社"]).isEmpty)
    XCTAssertTrue(matches("人民", ["人民\n出版社", ""]).isEmpty)
    let usages = (0..<70).map { PublisherUsage(name: "人民\($0)", bookID: UUID()) }
    XCTAssertEqual(PublisherSuggestions.matches("人民", usages: usages).count, 50)
    XCTAssertEqual(PublisherSuggestions.matches("人民", usages: usages, limit: 3).count, 3)
    XCTAssertTrue(PublisherSuggestions.matches("人民", usages: usages, limit: 0).isEmpty)
  }

  @MainActor
  func testCatalogExcludesTrashAndBlankAndReflectsRenameRestore() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let active = Book(title: "正常"), trashed = Book(title: "回收站"), blank = Book(title: "空值"), missing = Book(title: "无值")
    active.publisher = "人民出版社"; trashed.publisher = "人民已删除出版社"
    trashed.deletedAt = Date(); blank.publisher = " \n "
    for book in [active, trashed, blank, missing] { context.insert(book) }
    try context.save()
    func catalog() throws -> [String] {
      try context.fetch(FetchDescriptor<Book>()).compactMap(PublisherUsage.init).map(\.name).sorted()
    }
    XCTAssertEqual(try catalog(), ["人民出版社"])
    active.publisher = "新出版社"; trashed.deletedAt = nil; try context.save()
    XCTAssertEqual(Set(try catalog()), ["新出版社", "人民已删除出版社"])
  }

  @MainActor
  func testSelectedPublisherSavesOnlyTargetAndUndoesOnce() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let source = Book(title: "来源"), target = Book(title: "当前书籍")
    source.publisher = "人民文学出版社"; target.publisher = "原出版社"
    target.pageCount = 123; target.metadataSourceName = "原来源"
    context.insert(source); context.insert(target); try context.save()
    let sourceBefore = BookArchive(book: source), before = BookArchive(book: target)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = BookMetadataEditingSession(store: BookMetadataDraftStore(directory: directory))
    let undo = UndoManager(); undo.groupsByEvent = false
    session.begin(before, field: .publisher); session.update(target.id, field: .publisher, text: "人民")
    let candidates = matches("人民", [source.publisher!])
    var selection = NameSuggestionSelection()
    let native = NativeBookMetadataField(value: "人民", label: "出版社", multiline: false, focusToken: nil,
      onFocus: {}, onBegin: {}, onChange: { session.update(target.id, field: .publisher, text: $0) },
      onCommit: { session.commit(target.id, field: .publisher, context: context, undoManager: undo) },
      onCancel: { "原出版社" }, currentValue: { target.publisher ?? "" },
      onMoveSuggestion: { selection.move($0, in: candidates) }, selectedSuggestion: { selection.selected(in: candidates)?.name })
    let coordinator = native.makeCoordinator(), control = NSTextField(string: "人民"), editor = NSTextView()
    coordinator.field = control; editor.string = "人民"
    coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: control))
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    undo.beginUndoGrouping()
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    undo.endUndoGrouping()
    XCTAssertEqual(target.publisher, "人民文学出版社"); XCTAssertEqual(target.pageCount, 123)
    XCTAssertEqual(target.title, "当前书籍"); XCTAssertEqual(BookArchive(book: source), sourceBefore)
    XCTAssertEqual(BookRecordMerge.origins(BookArchive(book: target))["publisher"]?.name, "手动编辑")
    XCTAssertTrue(BookMetadataDraftStore(directory: directory).load().drafts.isEmpty)
    undo.undo(); XCTAssertEqual(BookArchive(book: target), before); XCTAssertFalse(undo.canUndo)
    undo.redo(); XCTAssertEqual(target.publisher, "人民文学出版社")
  }
}
