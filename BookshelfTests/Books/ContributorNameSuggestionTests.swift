import AppKit
import SwiftData
import XCTest
@testable import Bookshelf

final class ContributorNameSuggestionTests: XCTestCase {
  private func use(_ name: String, role: String = "author", bookID: UUID = UUID()) -> ContributorNameUsage {
    ContributorNameUsage(name: name, roleRaw: role, bookID: bookID)
  }
  private func suggestions(_ text: String, _ names: [String]) -> [NameSuggestion] {
    ContributorNameSuggestions.matches(text, usages: names.map { use($0) }, field: .authors)
  }

  func testExactPrefixAndSubstringRanking() {
    let result = suggestions("王", ["小王", "王维", "王", "李白", "王兴"])
    XCTAssertEqual(result.first?.name, "王")
    XCTAssertEqual(Set(result.dropFirst().prefix(2).map(\.name)), ["王维", "王兴"])
    XCTAssertEqual(result.last?.name, "小王")
  }

  func testCaseWidthAccentMatchingPreservesDistinctSpellingsAndPunctuation() {
    let result = suggestions("ＲＥＮＥ", ["René", "rene", "René", "王兴"])
    XCTAssertEqual(Set(result.map(\.name)), ["René", "rene"])
    XCTAssertEqual(suggestions("rene", ["René", "rene"]).first?.name, "rene")
    XCTAssertEqual(suggestions("Gerlach", ["Gerlach, Peter A.；研究、组"]).first?.name, "Gerlach, Peter A.；研究、组")
  }

  func testPreferredRoleThenDistinctBookFrequencyWithoutExcludingOtherRoles() {
    let sameBook = UUID()
    let usages = [use("王作者"), use("王译者", role: "translator"),
      use("王编者", role: "editor"), use("王常用"), use("王常用"),
      use("王作者", bookID: sameBook), use("王作者", bookID: sameBook)]
    let authors = ContributorNameSuggestions.matches("王", usages: usages, field: .authors)
    XCTAssertTrue(Set(authors.prefix(2).map(\.name)).contains("王常用"))
    XCTAssertEqual(ContributorNameSuggestions.matches("王", usages: usages, field: .translators).first?.name, "王译者")
    XCTAssertEqual(Set(authors.map(\.name)), ["王作者", "王译者", "王编者", "王常用"])
    XCTAssertEqual(authors.count, 4)
  }

  func testBlankNoMatchLimitsAndInvalidMultilineNames() {
    XCTAssertTrue(suggestions(" \n ", ["王兴"]).isEmpty)
    XCTAssertTrue(suggestions("不存在", ["王兴"]).isEmpty)
    XCTAssertTrue(suggestions("王", ["王\n兴"]).isEmpty)
    let uses = (0..<80).map { use("王\($0)") }
    XCTAssertEqual(ContributorNameSuggestions.matches("王", usages: uses, field: .authors).count, 50)
    XCTAssertEqual(ContributorNameSuggestions.matches("王", usages: uses, field: .authors, limit: 3).count, 3)
    XCTAssertTrue(ContributorNameSuggestions.matches("王", usages: uses, field: .authors, limit: 0).isEmpty)
  }

  func testSelectionEdgesDismissReopenAndStaleCandidate() {
    let options = suggestions("王", ["王甲", "王乙", "王丙"])
    var selection = NameSuggestionSelection()
    XCTAssertNil(selection.selected(in: options))
    XCTAssertTrue(selection.move(.down, in: options)); XCTAssertEqual(selection.selectedID, options[0].id)
    selection.move(.up, in: options); XCTAssertEqual(selection.selectedID, options[0].id)
    for _ in 0..<10 { selection.move(.down, in: options) }
    XCTAssertEqual(selection.selectedID, options.last?.id)
    selection.dismiss(); XCTAssertNil(selection.selected(in: options))
    selection.move(.up, in: options); XCTAssertEqual(selection.selectedID, options.last?.id)
    XCTAssertNil(selection.selected(in: Array(options.dropLast())))
    selection.reset(); XCTAssertNil(selection.selected(in: options)); XCTAssertFalse(selection.isDismissed)
    XCTAssertFalse(selection.move(.down, in: []))
  }

  @MainActor
  func testCatalogExcludesTrashedBooksOrphanPeopleAndDetachedContributions() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let active = Book(title: "正常书籍"), trashed = Book(title: "已删除书籍")
    trashed.deletedAt = Date(); context.insert(active); context.insert(trashed)
    let a = Person(name: "王作者"), t = Person(name: "王译者"), deleted = Person(name: "王已删")
    let orphan = Person(name: "王孤立"), detached = Person(name: "王断开")
    for person in [a, t, deleted, orphan, detached] { context.insert(person) }
    for link in [Contribution(book: active, person: a, role: .author, displayOrder: 0),
      Contribution(book: active, person: t, role: .translator, displayOrder: 0),
      Contribution(book: trashed, person: deleted, role: .author, displayOrder: 0),
      Contribution(book: nil, person: detached, role: .author, displayOrder: 0)] { context.insert(link) }
    try context.save()
    let usages = try context.fetch(FetchDescriptor<Contribution>()).compactMap(ContributorNameUsage.init)
    XCTAssertEqual(Set(usages.map(\.name)), ["王作者", "王译者"])
  }

  @MainActor
  func testFieldEditorArrowsEnterAndEscapeRouteWithoutLosingTypedInput() {
    var text = "王", commits = [String](), cancels = 0, selection = NameSuggestionSelection()
    let options = suggestions(text, ["王甲", "王乙"])
    let native = NativeBookMetadataField(value: text, label: "作者姓名", multiline: false, focusToken: nil,
      onFocus: {}, onBegin: {}, onChange: { text = $0 }, onCommit: { commits.append(text); return true },
      onCancel: { cancels += 1; return "原姓名" }, currentValue: { text },
      onMoveSuggestion: { selection.move($0, in: options) },
      selectedSuggestion: { selection.selected(in: options)?.name },
      onDismissSuggestions: { guard !selection.isDismissed else { return false }; selection.dismiss(); return true })
    let coordinator = native.makeCoordinator(), control = NSTextField(string: text), editor = NSTextView()
    coordinator.field = control; editor.string = text
    coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: control))
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
    XCTAssertEqual(text, "王")
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertEqual(cancels, 0); XCTAssertEqual(text, "王"); XCTAssertTrue(commits.isEmpty)
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertEqual(commits, [options[0].name]); XCTAssertEqual(control.stringValue, options[0].name)
    selection.dismiss()
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertEqual(cancels, 1); XCTAssertEqual(control.stringValue, "原姓名")
  }

  @MainActor
  func testInputMethodRetainsArrowEnterAndEscapeAndPlainEnterSavesNewName() {
    var text = "新姓名", saved = [String](), moves = 0, cancels = 0
    let native = NativeBookMetadataField(value: text, label: "译者姓名", multiline: false, focusToken: nil,
      onFocus: {}, onBegin: {}, onChange: { text = $0 }, onCommit: { saved.append(text); return true },
      onCancel: { cancels += 1; return text }, currentValue: { text },
      onMoveSuggestion: { _ in moves += 1; return true })
    let coordinator = native.makeCoordinator(), control = NSTextField(), editor = NSTextView()
    coordinator.field = control; editor.string = text
    coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: control))
    XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertEqual(saved, ["新姓名"])
    editor.setMarkedText("wang", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    for command in [#selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
      #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
      XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: command))
    }
    XCTAssertEqual(saved.count, 1); XCTAssertEqual(moves, 0); XCTAssertEqual(cancels, 0)
    XCTAssertTrue(editor.hasMarkedText())
  }

  @MainActor
  func testAcceptingNameSavesOnlyTargetRowReusesPersonAndUndoesOnce() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let source = Book(title: "已有姓名"), target = Book(title: "需要补全")
    context.insert(source); context.insert(target)
    let person = Person(name: "王兴"); context.insert(person)
    context.insert(Contribution(book: source, person: person, role: .author, displayOrder: 0)); try context.save()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = BookMetadataEditingSession(store: BookMetadataDraftStore(directory: directory))
    let before = BookArchive(book: target)
    let rowID = session.addContributor(before, field: .translators), undo = UndoManager()
    undo.groupsByEvent = false
    session.updateContributor(target.id, field: .translators, rowID: rowID, name: "王")
    let native = NativeBookMetadataField(value: "王", label: "译者姓名", multiline: false, focusToken: nil,
      onFocus: {}, onBegin: { session.prepareContributors(BookArchive(book: target), field: .translators) },
      onChange: { session.updateContributor(target.id, field: .translators, rowID: rowID, name: $0) },
      onCommit: { session.commit(target.id, field: .translators, context: context, undoManager: undo) },
      onCancel: { "" }, currentValue: { session.draft(target.id, .translators)?.contributorRows?.first?.name ?? "" })
    let coordinator = native.makeCoordinator(), control = NSTextField(string: "王")
    coordinator.field = control
    undo.beginUndoGrouping(); coordinator.acceptSuggestion("王兴"); undo.endUndoGrouping()
    XCTAssertEqual(target.translators.map(\.name), ["王兴"])
    XCTAssertEqual(target.translators.first?.id, person.id)
    XCTAssertTrue(target.authors.isEmpty); XCTAssertEqual(source.authors.map(\.name), ["王兴"])
    XCTAssertEqual(try context.fetch(FetchDescriptor<Person>()).count, 1)
    undo.undo(); XCTAssertEqual(BookArchive(book: target), before); XCTAssertFalse(undo.canUndo)
    undo.redo(); XCTAssertEqual(target.translators.first?.id, person.id)
  }

  @MainActor
  func testFailedAcceptanceKeepsCompletedNameForRetry() {
    var text = "王", active = true
    let native = NativeBookMetadataField(value: text, label: "作者姓名", multiline: false, focusToken: nil,
      onFocus: {}, onBegin: {}, onChange: { text = $0 }, onCommit: { false }, onCancel: { text },
      currentValue: { text }, onEditingChange: { active = $0 })
    let coordinator = native.makeCoordinator(), control = NSTextField(string: text)
    coordinator.field = control
    coordinator.acceptSuggestion("王兴")
    XCTAssertEqual(text, "王兴"); XCTAssertEqual(control.stringValue, "王兴")
    XCTAssertTrue(coordinator.isEditing); XCTAssertTrue(active)
  }
}
