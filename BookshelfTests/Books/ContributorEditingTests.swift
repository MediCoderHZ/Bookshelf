import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class ContributorEditingTests: XCTestCase {
  private var containers: [ModelContainer] = []
  private func fixture() throws -> (ModelContext, Book, BookMetadataEditingSession, URL) {
    let db = try LibraryDatabase.open(inMemory: true); containers.append(db)
    let context = db.mainContext, book = Book(title: "逐人编辑测试")
    book.publisher = "保留的出版社"; context.insert(book); try context.save()
    var record = BookArchive(book: book)
    record.contributors = [person("甲", 0), person("乙", 1), person("丙", 2),
      person("译者甲", 0, role: "translator"), person("编辑甲", 0, role: "editor")]
    record.tags = ["保留的标签"]
    try LibraryRepository.apply([record], into: context)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let session = BookMetadataEditingSession(store: BookMetadataDraftStore(directory: dir))
    session.prepareContributors(BookArchive(book: book), field: .authors)
    session.prepareContributors(BookArchive(book: book), field: .translators)
    return (context, book, session, dir)
  }
  private func person(_ name: String, _ order: Int, role: String = "author") -> ContributorArchive {
    ContributorArchive(name: name, roleRaw: role, displayOrder: order)
  }
  private func rows(_ session: BookMetadataEditingSession, _ book: Book, _ field: BookField = .authors) -> [ContributorNameDraft] {
    session.draft(book.id, field)!.contributorRows!
  }
  private func names(_ book: Book, _ field: BookField = .authors) -> [String] {
    if case .contributors(let people) = BookMetadataValue.read(field, from: BookArchive(book: book)) { return people.map(\.name) }
    return []
  }
  private func save(_ session: BookMetadataEditingSession, _ book: Book, _ context: ModelContext, _ field: BookField = .authors) -> Bool {
    session.commit(book.id, field: field, context: context, undoManager: nil)
  }

  func testNameIsOnePersonAndPreservesPunctuationAndOtherRoles() throws {
    let (context, book, session, _) = try fixture()
    let id = rows(session, book)[1].id, exact = "Gerlach, Peter A.；研究、编写组"
    session.updateContributor(book.id, field: .authors, rowID: id, name: exact)
    XCTAssertEqual(names(book), ["甲", "乙", "丙"])
    XCTAssertTrue(save(session, book, context))
    XCTAssertEqual(names(book), ["甲", exact, "丙"])
    XCTAssertEqual(rows(session, book)[1].id, id)
    XCTAssertEqual(names(book, .translators), ["译者甲"])
    let record = BookArchive(book: book)
    XCTAssertEqual(record.contributors.filter { $0.roleRaw == "editor" }.map(\.name), ["编辑甲"])
    XCTAssertEqual(record.tags, ["保留的标签"]); XCTAssertEqual(book.publisher, "保留的出版社")
    XCTAssertEqual(BookRecordMerge.origins(record)["authors"]?.name, "手动编辑")
  }

  func testAddingEmptyRowDoesNotWriteAndCompletedNameKeepsIdentity() throws {
    let (context, book, session, _) = try fixture()
    let before = BookArchive(book: book), id = session.addContributor(before, field: .authors)
    XCTAssertEqual(session.addContributor(before, field: .authors), id)
    XCTAssertFalse(session.draft(book.id, .authors)!.isDirty)
    XCTAssertEqual(BookArchive(book: book), before)
    session.updateContributor(book.id, field: .authors, rowID: id, name: "  新作者  ")
    XCTAssertTrue(save(session, book, context))
    XCTAssertEqual(names(book), ["甲", "乙", "丙", "新作者"])
    XCTAssertEqual(rows(session, book).last?.id, id)
    XCTAssertEqual(rows(session, book).last?.savedName, "新作者")
  }

  func testDeleteLastTranslatorAndUndoRestoreCompleteRecord() throws {
    let (context, book, session, _) = try fixture()
    let before = BookArchive(book: book), id = rows(session, book, .translators)[0].id
    let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
    session.removeContributor(book.id, field: .translators, rowID: id, context: context, undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertTrue(names(book, .translators).isEmpty); XCTAssertEqual(names(book), ["甲", "乙", "丙"])
    undo.undo(); XCTAssertEqual(BookArchive(book: book), before)
    session.prepareContributors(BookArchive(book: book), field: .translators)
    XCTAssertEqual(rows(session, book, .translators).map(\.name), ["译者甲"])
    XCTAssertTrue(undo.canRedo); undo.redo(); XCTAssertTrue(names(book, .translators).isEmpty)
  }

  func testInsertBelowSelectedPersonPreservesOrderAndUndo() throws {
    let (context, book, session, _) = try fixture()
    let before = BookArchive(book: book), first = rows(session, book)[0].id
    let added = session.addContributor(before, field: .authors, after: first)
    XCTAssertEqual(rows(session, book).map(\.name), ["甲", "", "乙", "丙"])
    XCTAssertEqual(BookArchive(book: book), before)
    session.updateContributor(book.id, field: .authors, rowID: added, name: "新增作者")
    let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
    XCTAssertTrue(session.commit(book.id, field: .authors, context: context, undoManager: undo))
    undo.endUndoGrouping()
    XCTAssertEqual(names(book), ["甲", "新增作者", "乙", "丙"])
    XCTAssertEqual(names(book, .translators), ["译者甲"])
    undo.undo(); XCTAssertEqual(BookArchive(book: book), before)
    undo.redo(); XCTAssertEqual(names(book), ["甲", "新增作者", "乙", "丙"])
  }

  func testInsertReusesUnfinishedRowAndCancelLeavesSavedOrderIntact() throws {
    let (_, book, session, _) = try fixture()
    let before = BookArchive(book: book), list = rows(session, book)
    let added = session.addContributor(before, field: .authors, after: list[1].id)
    XCTAssertEqual(session.addContributor(before, field: .authors, after: list[0].id), added)
    XCTAssertEqual(rows(session, book).map(\.name), ["甲", "乙", "", "丙"])
    session.cancelContributor(book.id, field: .authors, rowID: added)
    XCTAssertEqual(rows(session, book).map(\.name), ["甲", "乙", "丙"])
    XCTAssertEqual(BookArchive(book: book), before)
  }

  func testReorderNormalizesOrderAndSupportsUndoRedo() throws {
    let (context, book, session, _) = try fixture()
    let before = BookArchive(book: book), ids = rows(session, book).map(\.id)
    let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
    session.moveContributor(book.id, field: .authors, rowID: ids[0], to: 2, context: context, undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertEqual(names(book), ["乙", "丙", "甲"])
    XCTAssertEqual(rows(session, book).map(\.id), [ids[1], ids[2], ids[0]])
    XCTAssertEqual(BookArchive(book: book).contributors.filter { $0.roleRaw == "author" }.map(\.displayOrder), [0, 1, 2])
    undo.undo(); XCTAssertEqual(BookArchive(book: book), before)
    undo.redo(); XCTAssertEqual(names(book), ["乙", "丙", "甲"])
    session.prepareContributors(BookArchive(book: book), field: .authors)
    session.updateContributor(book.id, field: .authors, rowID: rows(session, book)[2].id, name: "移动后改名")
    XCTAssertTrue(save(session, book, context)); XCTAssertEqual(names(book), ["乙", "丙", "移动后改名"])
  }

  func testCancelOnlyThisRowAndRemoveUnfinishedNewRow() throws {
    let (context, book, session, _) = try fixture()
    let list = rows(session, book)
    session.updateContributor(book.id, field: .authors, rowID: list[0].id, name: "修改甲")
    session.updateContributor(book.id, field: .authors, rowID: list[1].id, name: "修改乙")
    session.cancelContributor(book.id, field: .authors, rowID: list[0].id)
    let new = session.addContributor(BookArchive(book: book), field: .authors)
    session.updateContributor(book.id, field: .authors, rowID: new, name: "取消新增")
    session.cancelContributor(book.id, field: .authors, rowID: new)
    XCTAssertTrue(save(session, book, context)); XCTAssertEqual(names(book), ["甲", "修改乙", "丙"])
  }

  func testConflictRecoveryRetainsExactRowsAndOrder() throws {
    let (context, book, session, directory) = try fixture()
    let id = rows(session, book)[0].id
    session.updateContributor(book.id, field: .authors, rowID: id, name: "完整、姓名；含标点")
    try LibraryCommands(context: context, undoManager: nil).update([book]) { $0.contributors[0].name = "其他窗口" }
    XCTAssertFalse(save(session, book, context))
    let recovered = BookMetadataEditingSession(store: BookMetadataDraftStore(directory: directory))
    recovered.prepareContributors(BookArchive(book: book), field: .authors)
    XCTAssertEqual(rows(recovered, book)[0].id, id)
    XCTAssertEqual(rows(recovered, book).map(\.name), ["完整、姓名；含标点", "乙", "丙"])
    XCTAssertFalse(save(recovered, book, context)); XCTAssertEqual(names(book)[0], "其他窗口")
    recovered.discard(book.id, field: .authors)
    recovered.prepareContributors(BookArchive(book: book), field: .authors)
    XCTAssertEqual(rows(recovered, book)[0].name, "其他窗口")
  }

  func testLegacyRecoveryRemainsEditableWithoutNewSnapshotProperty() throws {
    let (_, book, _, directory) = try fixture()
    let snapshot = BookMetadataDraftSnapshot(bookID: book.id, bookTitle: book.title, fieldRaw: "authors",
      baseline: .read(.authors, from: BookArchive(book: book)), text: "旧草稿甲、旧草稿乙")
    try BookMetadataDraftStore(directory: directory).save(snapshot)
    let session = BookMetadataEditingSession(store: BookMetadataDraftStore(directory: directory))
    session.prepareContributors(BookArchive(book: book), field: .authors)
    XCTAssertEqual(rows(session, book).map(\.name), ["旧草稿甲", "旧草稿乙"])
    session.cancelContributor(book.id, field: .authors, rowID: rows(session, book)[0].id)
    XCTAssertEqual(rows(session, book).map(\.name), ["甲", "旧草稿乙"])
  }

  func testEmptyExistingNameIsRetainedAndCanBeDeletedExplicitly() throws {
    let (context, book, session, _) = try fixture()
    let id = rows(session, book)[0].id
    session.updateContributor(book.id, field: .authors, rowID: id, name: "  ")
    XCTAssertFalse(save(session, book, context)); XCTAssertEqual(names(book), ["甲", "乙", "丙"])
    XCTAssertEqual(rows(session, book)[0].name, "  ")
    session.removeContributor(book.id, field: .authors, rowID: id, context: context, undoManager: nil)
    XCTAssertEqual(names(book), ["乙", "丙"]); XCTAssertTrue(session.pendingDrafts.isEmpty)
  }

  func testTrashedAndMissingBooksRejectRowEdits() throws {
    let (context, book, session, _) = try fixture()
    let id = book.id, row = rows(session, book)[0].id
    session.updateContributor(id, field: .authors, rowID: row, name: "保留的姓名")
    try LibraryOperations.setTrashed(true, books: [book], context: context, undoManager: nil)
    XCTAssertFalse(save(session, book, context)); XCTAssertEqual(names(book)[0], "甲")
    try LibraryOperations.purge([book], context: context, undoManager: nil)
    XCTAssertFalse(session.commit(id, field: .authors, context: context, undoManager: nil))
    XCTAssertEqual(session.draft(id, .authors)?.contributorRows?.first?.name, "保留的姓名")
  }

  func testChangingSpellingDoesNotRenameSharedPersonInOtherBooks() throws {
    let (context, book, session, _) = try fixture()
    let other = Book(title: "其他书籍"); context.insert(other); try context.save()
    var first = BookArchive(book: book), second = BookArchive(book: other)
    first.contributors = [person("rene", 0)]; second.contributors = first.contributors
    try LibraryRepository.apply([first, second], into: context)
    session.prepareContributors(BookArchive(book: book), field: .authors)
    session.updateContributor(book.id, field: .authors, rowID: rows(session, book)[0].id, name: "René")
    let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
    XCTAssertTrue(session.commit(book.id, field: .authors, context: context, undoManager: undo)); undo.endUndoGrouping()
    XCTAssertEqual(names(book), ["René"]); XCTAssertEqual(names(other), ["rene"])
    undo.undo(); XCTAssertEqual(names(book), ["rene"]); XCTAssertEqual(names(other), ["rene"])
    undo.redo(); XCTAssertEqual(names(book), ["René"])
  }

  func testIndependentRoleEditAndUnrelatedMetadataArePreserved() throws {
    let (context, book, session, _) = try fixture()
    session.updateContributor(book.id, field: .authors, rowID: rows(session, book)[0].id, name: "新作者")
    let tid = rows(session, book, .translators)[0].id
    session.updateContributor(book.id, field: .translators, rowID: tid, name: "新译者")
    XCTAssertTrue(save(session, book, context, .translators))
    try LibraryCommands(context: context, undoManager: nil).update([book]) { $0.title = "另一操作修改书名" }
    XCTAssertTrue(save(session, book, context))
    XCTAssertEqual(names(book)[0], "新作者"); XCTAssertEqual(names(book, .translators), ["新译者"])
    XCTAssertEqual(book.title, "另一操作修改书名")
  }

  func testDuplicateNamesAndReorderedNamesSurviveReopeningDatabase() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("books.store")
    do {
      let db = try LibraryDatabase.open(at: url), context = db.mainContext
      let book = Book(title: "同名作者"); context.insert(book); try context.save()
      try BookMetadataCommands(context: context, undoManager: nil).saveContributors(bookID: book.id, field: .authors,
        names: ["乙", "甲", "甲"], expected: .read(.authors, from: BookArchive(book: book)))
    }
    let db = try LibraryDatabase.open(at: url), book = try XCTUnwrap(db.mainContext.fetch(FetchDescriptor<Book>()).first)
    XCTAssertEqual(names(book), ["乙", "甲", "甲"])
  }
}

@MainActor
final class BookEditorContributorDraftTests: XCTestCase {
  private func person(_ name: String, _ order: Int, role: String = "author") -> ContributorArchive {
    ContributorArchive(name: name, roleRaw: role, displayOrder: order)
  }

  func testStructuredNamesKeepPunctuationRepeatedPeopleAndOrder() throws {
    let people = [person("同名", 2), person("Gerlach, Peter A.；研究、编写组", 0), person("同名", 1)]
    let draft = ContributorListDraft(people: people)
    try draft.validate()
    XCTAssertEqual(draft.names, ["Gerlach, Peter A.；研究、编写组", "同名", "同名"])
    XCTAssertEqual(draft.contributors(role: "author"), [people[1], people[2], people[0]])
    let importedAgain = ContributorListDraft(people: draft.contributors(role: "author"))
    XCTAssertEqual(importedAgain.names, draft.names)
  }

  func testInsertReorderRemoveAndEscapeRetainRowIdentity() throws {
    var draft = ContributorListDraft(people: [person("甲", 0), person("乙", 1)])
    let first = draft.rows[0].id, second = draft.rows[1].id
    let added = draft.add(after: first)
    XCTAssertEqual(draft.add(after: second), added)
    draft.update(added, name: "  新姓名, 保留逗号  ")
    try draft.commit(added)
    XCTAssertEqual(draft.names, ["甲", "新姓名, 保留逗号", "乙"])
    draft.move(added, to: 0)
    XCTAssertEqual(draft.rows.map(\.id), [added, first, second])
    draft.update(first, name: "临时修改")
    draft.cancel(first)
    XCTAssertEqual(draft.names, ["新姓名, 保留逗号", "甲", "乙"])
    draft.remove(second)
    let cancelled = draft.add(after: first)
    draft.update(cancelled, name: "不保存的姓名")
    draft.cancel(cancelled)
    XCTAssertEqual(draft.names, ["新姓名, 保留逗号", "甲"])
    XCTAssertEqual(draft.contributors(role: "author").map(\.displayOrder), [0, 1])
  }

  func testEmptyPlaceholderIsOptionalButClearedExistingAndMultilineNamesAreRejected() throws {
    var draft = ContributorListDraft()
    try draft.validate()
    XCTAssertTrue(draft.contributors(role: "author").isEmpty)
    let id = draft.rows[0].id
    draft.update(id, name: "作者")
    try draft.commit(id)
    draft.update(id, name: "  ")
    XCTAssertThrowsError(try draft.validate())
    draft.update(id, name: "甲\n乙")
    XCTAssertThrowsError(try draft.commit(id))
    draft.cancel(id)
    XCTAssertEqual(draft.names, ["作者"])
    draft.remove(id)
    XCTAssertEqual(draft.rows.count, 1)
    XCTAssertTrue(draft.rows[0].isEmptyNewRow)
    try draft.validate()
    XCTAssertTrue(draft.names.isEmpty)
  }

  func testDraftOnlyWritesWithWholeBookSaveAndPreservesOtherMetadata() throws {
    let database = try LibraryDatabase.open(inMemory: true)
    let context = database.mainContext
    let book = Book(title: "表单草稿测试")
    context.insert(book); try context.save()
    var record = BookArchive(book: book)
    record.contributors = [person("原作者", 0), person("译者, 名字；含、标点", 0, role: "translator"),
      person("原编辑", 0, role: "editor")]
    record.tags = ["保留、标签"]; record.notes = "保留的笔记"
    record.bookDescription = "保留的简介"; record.collections = ["保留的文件夹"]
    try LibraryRepository.apply([record], into: context)
    let baseline = BookArchive(book: book)
    var authors = ContributorListDraft(people: baseline.contributors.filter { $0.roleRaw == "author" })
    let translators = ContributorListDraft(people: baseline.contributors.filter { $0.roleRaw == "translator" })
    authors.update(authors.rows[0].id, name: "新作者, 名字；含、标点")
    try authors.commit(authors.rows[0].id)
    let another = authors.add(after: authors.rows[0].id)
    authors.update(another, name: "新作者, 名字；含、标点")
    try authors.commit(another)
    XCTAssertEqual(BookArchive(book: book), baseline)
    record = baseline
    record.contributors.removeAll { ["author", "translator"].contains($0.roleRaw) }
    record.contributors += authors.contributors(role: "author") + translators.contributors(role: "translator")
    try LibraryCommands(context: context, undoManager: nil).save(record, expected: baseline)
    let saved = BookArchive(book: book)
    XCTAssertEqual(saved.contributors.filter { $0.roleRaw == "author" }.map(\.name), authors.names)
    XCTAssertEqual(saved.contributors.filter { $0.roleRaw == "translator" }.map(\.name), translators.names)
    XCTAssertEqual(saved.contributors.filter { $0.roleRaw == "editor" }.map(\.name), ["原编辑"])
    XCTAssertEqual(saved.tags, baseline.tags); XCTAssertEqual(saved.notes, baseline.notes)
    XCTAssertEqual(saved.collections, baseline.collections); XCTAssertEqual(saved.bookDescription, baseline.bookDescription)
  }
}
