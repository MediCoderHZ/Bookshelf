import AppKit
import SwiftUI
import XCTest
import SwiftData

@testable import Bookshelf

final class TagSuggestionTests: XCTestCase {
  func testExactThenPrefixThenSubstringMatches() {
    let matches = TagSuggestions.matches("个人", names: ["关于个人成长", "个人理财", "个人", "个人成长", "历史"], assignedNames: [])
    XCTAssertEqual(matches.first?.name, "个人")
    XCTAssertEqual(Set(matches.dropFirst().prefix(2).map(\.name)), ["个人成长", "个人理财"])
    XCTAssertEqual(matches.last?.name, "关于个人成长")
  }

  func testMatchesExistingAssignedTagsWithoutOfferingAnotherAddition() {
    let matches = TagSuggestions.matches("个人", names: ["个人成长", "有参考价值"], assignedNames: ["个人成长", "有参考价值"])
    XCTAssertEqual(matches, [TagSuggestion(name: "个人成长", isAssigned: true)])
  }

  func testNormalizationDeduplicatesAliasesAndPreservesExistingSpelling() {
    let matches = TagSuggestions.matches(" ＣＡＦＥ ", names: ["Café", "cafe", "读书"], assignedNames: ["Ｃａｆé"])
    XCTAssertEqual(matches, [TagSuggestion(name: "Café", isAssigned: true)])
    XCTAssertEqual(TagSuggestions.matches("成长", names: ["个人成长", "历史"], assignedNames: []).map(\.name), ["个人成长"])
  }

  func testEmptyAndUnmatchedInputHaveNoSuggestions() {
    XCTAssertTrue(TagSuggestions.matches(" \n\t", names: ["个人成长"], assignedNames: []).isEmpty)
    XCTAssertTrue(TagSuggestions.matches("艺术", names: ["个人成长"], assignedNames: []).isEmpty)
  }

  func testArrowNavigationSkipsAssignedTagsAndStopsAtEdges() {
    let suggestions = [TagSuggestion(name: "个人成长", isAssigned: false),
      TagSuggestion(name: "个人理财", isAssigned: true), TagSuggestion(name: "个人阅读", isAssigned: false)]
    var selection = TagSuggestionSelection()
    XCTAssertNil(selection.selected(in: suggestions))
    XCTAssertTrue(selection.move(.down, in: suggestions))
    XCTAssertEqual(selection.selected(in: suggestions)?.name, "个人成长")
    selection.move(.down, in: suggestions)
    XCTAssertEqual(selection.selected(in: suggestions)?.name, "个人阅读")
    selection.move(.down, in: suggestions)
    XCTAssertEqual(selection.selected(in: suggestions)?.name, "个人阅读")
    selection.move(.up, in: suggestions)
    XCTAssertEqual(selection.selected(in: suggestions)?.name, "个人成长")
    selection.move(.up, in: suggestions)
    XCTAssertEqual(selection.selected(in: suggestions)?.name, "个人成长")
    selection.reset()
    selection.move(.up, in: suggestions)
    XCTAssertEqual(selection.selected(in: suggestions)?.name, "个人阅读")
  }

  func testEscapeAndQueryChangesClearSelectionAndAllowReopening() {
    let suggestions = [TagSuggestion(name: "个人成长", isAssigned: false)]
    var selection = TagSuggestionSelection()
    selection.move(.down, in: suggestions)
    selection.dismiss()
    XCTAssertTrue(selection.isDismissed)
    XCTAssertNil(selection.selected(in: suggestions))
    selection.move(.up, in: suggestions)
    XCTAssertFalse(selection.isDismissed)
    XCTAssertEqual(selection.selected(in: suggestions)?.name, "个人成长")
    selection.dismiss()
    selection.reset()
    XCTAssertFalse(selection.isDismissed)
    XCTAssertNil(selection.selected(in: suggestions))
  }

  func testMissingOrNewlyAssignedCandidatesCannotBeSubmitted() {
    var selection = TagSuggestionSelection()
    XCTAssertFalse(selection.move(.down, in: []))
    selection.move(.down, in: [TagSuggestion(name: "个人成长", isAssigned: false)])
    XCTAssertNil(selection.selected(in: []))
    let assigned = [TagSuggestion(name: "个人成长", isAssigned: true)]
    XCTAssertNil(selection.selected(in: assigned))
    XCTAssertTrue(selection.move(.down, in: assigned))
    XCTAssertNil(selection.selectedID)
  }

  @MainActor
  func testFieldEditorRoutesKeysAndPreservesInputMethodCommands() {
    var text = "个人", selection = TagSuggestionSelection(), added = [String]()
    let suggestions = [TagSuggestion(name: "个人成长", isAssigned: false),
      TagSuggestion(name: "个人阅读", isAssigned: false)]
    let field = NativeTagTextField(text: Binding(get: { text }, set: { text = $0 }),
      onMove: { selection.move($0, in: suggestions) },
      onSubmit: { added.append(selection.selected(in: suggestions)?.name ?? text) },
      onDismiss: { selection.dismiss(); return true }, onFocusChange: { _ in })
    let coordinator = field.makeCoordinator(), control = NSTextField(), editor = NSTextView()
    let down = #selector(NSResponder.moveDown(_:)), up = #selector(NSResponder.moveUp(_:))
    let enter = #selector(NSResponder.insertNewline(_:)), escape = #selector(NSResponder.cancelOperation(_:))
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: down))
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: down))
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: up))
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: enter))
    XCTAssertEqual(added, ["个人成长"])
    XCTAssertEqual(text, "个人")
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: escape))
    XCTAssertNil(selection.selectedID)
    XCTAssertEqual(text, "个人")
    text = "新标签"
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: enter))
    XCTAssertEqual(added, ["个人成长", "新标签"])
    XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    editor.setMarkedText("ge", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText())
    for command in [up, down, enter, escape] {
      XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: command))
    }
    XCTAssertEqual(added, ["个人成长", "新标签"])
    XCTAssertTrue(editor.hasMarkedText())
  }

  @MainActor
  func testAcceptingSuggestionReusesTagAndSupportsUndo() throws {
    let container = try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    context.autosaveEnabled = false
    let source = Book(title: "已有标签的书"), target = Book(title: "待整理的书")
    let existing = Tag(name: "个人成长")
    context.insert(source); context.insert(target); context.insert(existing)
    context.insert(BookTag(book: source, tag: existing))
    try context.save()
    let original = BookArchive(book: target)
    let suggestion = try XCTUnwrap(TagSuggestions.matches("个人", names: [existing.name], assignedNames: []).first)
    let manager = UndoManager(); manager.groupsByEvent = false
    manager.beginUndoGrouping()
    try LibraryCommands(context: context, undoManager: manager).setTag(suggestion.name, included: true, book: target)
    manager.endUndoGrouping()
    XCTAssertEqual(target.tagLinks.first?.tag?.id, existing.id)
    XCTAssertEqual(try context.fetch(FetchDescriptor<Tag>()).count, 1)
    manager.undo()
    XCTAssertEqual(BookArchive(book: target), original)
    XCTAssertEqual(source.tagLinks.first?.tag?.id, existing.id)
    manager.redo()
    XCTAssertEqual(target.tagLinks.first?.tag?.id, existing.id)
    XCTAssertEqual(try context.fetch(FetchDescriptor<Tag>()).count, 1)
  }
}
