import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class BookAttachmentTests: XCTestCase {
  private func directory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }
  private func database(in dir: URL) throws -> ModelContainer { try LibraryDatabase.open(at: dir.appendingPathComponent("default.store")) }

  func testStoredAttachmentsBackupRestoreRenameAndRemove() throws {
    let dir = try directory(), db = try database(in: dir)
    let context = db.mainContext, original = dir.appendingPathComponent("scan.epub"), bytes = Data("example".utf8)
    try bytes.write(to: original)
    let book = Book(title: "My Book")
    context.insert(book); try context.save()
    let commands = BookAttachmentCommands(book: book, context: context)
    try commands.add([original, original], linked: false, rule: .init(pattern: AttachmentNaming.defaultPattern))
    let ids = try XCTUnwrap(book.attachmentIDs)
    let store = try BookAttachmentStore(context: context)
    XCTAssertEqual(try ids.map { try store.item($0).name }, ["My Book.epub", "My Book (2).epub"])
    try store.rename(ids[0], stem: "Reading")
    XCTAssertEqual(try store.item(ids[0]).name, "Reading.epub")
    try store.rename(ids[0], stem: "reading")
    XCTAssertEqual(try store.item(ids[0]).name, "reading.epub")
    XCTAssertThrowsError(try store.rename(ids[0], stem: "../other"))
    try store.withFile(ids[0]) { try Data("annotations".utf8).write(to: $0) }
    XCTAssertEqual(try Data(contentsOf: original), bytes)
    let data = try LibraryBackupService.exportData(from: context)
    let target = try database(in: directory())
    let plan = try LibraryImportPlanner.prepare(data, context: target.mainContext)
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: target.mainContext, undoManager: nil)
    let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<Book>()).first)
    XCTAssertEqual(restored.attachmentIDs, ids)
    let copied = try BookAttachmentStore(context: target.mainContext)
    XCTAssertEqual(try copied.portable(ids[0]).contents, Data("annotations".utf8))
    try commands.detach(ids[0])
    XCTAssertEqual(book.attachmentIDs, [ids[1]])
    XCTAssertThrowsError(try store.item(ids[0]))
    XCTAssertEqual(try Data(contentsOf: original), bytes)
  }

  func testLinkedRenameCollisionRelinkAndPortablePrivacy() throws {
    let dir = try directory(), db = try database(in: dir), ctx = db.mainContext
    let original = dir.appendingPathComponent("source.pdf"), collision = dir.appendingPathComponent("other.pdf")
    let bytes = Data("personal file".utf8)
    try bytes.write(to: original); try Data().write(to: collision)
    let book = Book(title: "Linked")
    ctx.insert(book); try ctx.save()
    let commands = BookAttachmentCommands(book: book, context: ctx)
    try commands.add([original], linked: true, rule: .init(pattern: AttachmentNaming.defaultPattern))
    let id = try XCTUnwrap(book.attachmentIDs?.first), store = try BookAttachmentStore(context: ctx)
    XCTAssertThrowsError(try store.rename(id, stem: "other", grantedParent: dir))
    try store.rename(id, stem: "new", grantedParent: dir)
    let renamed = dir.appendingPathComponent("new.pdf")
    XCTAssertEqual(try Data(contentsOf: renamed), bytes)
    let data = try LibraryBackupService.exportData(from: ctx)
    XCTAssertEqual(try LibraryBackupService.decode(data).schemaVersion, 10)
    XCTAssertNil(try LibraryBackupService.decode(data).attachmentFiles?.first?.contents)
    let newDB = try database(in: directory())
    _ = try LibraryBackupService.importData(data, into: newDB.mainContext)
    let newStore = try BookAttachmentStore(context: newDB.mainContext)
    XCTAssertThrowsError(try newStore.withFile(id) { _ in })
    try newStore.relink(id, to: renamed)
    XCTAssertEqual(try newStore.withFile(id) { try Data(contentsOf: $0) }, bytes)
    try commands.detach(id)
    XCTAssertEqual(try Data(contentsOf: renamed), bytes)
  }

  func testFailureRollsBackBatchAndUnsafeArchiveIsRejected() throws {
    let dir = try directory(), db = try database(in: dir), ctx = db.mainContext
    let book = Book(title: "Book"), file = dir.appendingPathComponent("first.pdf")
    ctx.insert(book); try ctx.save(); try Data().write(to: file)
    XCTAssertThrowsError(try BookAttachmentCommands(book: book, context: ctx).add([file, dir], linked: false, rule: .init(pattern: "{title}")))
    XCTAssertTrue((book.attachmentIDs ?? []).isEmpty)
    let store = try BookAttachmentStore(context: ctx)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), [])
    var created: [UUID] = []
    XCTAssertThrowsError(try store.importFile(PortableAttachment(id: UUID(), name: "../x", contents: Data()), created: &created))
    XCTAssertThrowsError(try store.requireOutside(store.root.appendingPathComponent("new")))
  }

  func testRestoringConflictingFileTwiceKeepsBothVersionsOnce() throws {
    let dir = try directory(), db = try database(in: dir), ctx = db.mainContext
    let original = dir.appendingPathComponent("document.pdf"), book = Book(title: "Title")
    try Data("old".utf8).write(to: original)
    ctx.insert(book); try ctx.save()
    try BookAttachmentCommands(book: book, context: ctx).add([original], linked: false, rule: .init(pattern: "{title}"))
    let store = try BookAttachmentStore(context: ctx)
    let id = try XCTUnwrap(book.attachmentIDs?.first), archive = try LibraryBackupService.exportData(from: ctx)
    try store.withFile(id) { try Data("new".utf8).write(to: $0) }
    for _ in 0..<2 {
      let plan = try LibraryImportPlanner.prepare(archive, context: ctx)
      _ = try LibraryImportPlanner.apply(plan, choices: [book.id: ImportChoice(action: .fill, targetID: book.id)], context: ctx, undoManager: nil)
    }
    let ids = try XCTUnwrap(book.attachmentIDs)
    XCTAssertEqual(ids.count, 2)
    XCTAssertEqual(try ids.map { try store.portable($0).contents }, [Data("new".utf8), Data("old".utf8)])
  }

  func testNamingUsesFirstAuthorYearAndLiteralTokensInTitle() throws {
    var book = BookArchive(book: Book(title: "A/B {isbn}"))
    book.publicationDate = "2026-01"
    book.contributors = [ContributorArchive(name: "Author", roleRaw: "author", displayOrder: 0)]
    XCTAssertEqual(try AttachmentNaming.stem(book: book, pattern: AttachmentNaming.defaultPattern), "Author - 2026 - A-B {isbn}")
    XCTAssertEqual(try AttachmentNaming.stem(book: book, pattern: "{year}_{title}"), "2026_A-B {isbn}")
    XCTAssertFalse(AttachmentNaming.valid("{authors}"))
  }

  func testRenameRulesIgnoreLegacyTypeSelectionsAndPreserveOtherPreferences() throws {
    let suite = UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("{year}_{title}", forKey: AttachmentNaming.preference)
    var rule = AttachmentRenameRule(pattern: "{year}_{title}")
    for selection in [[], ["pdf"], ["image", "audio", "video"]] {
      defaults.set(selection, forKey: "attachments.renameTypes")
      XCTAssertEqual(AttachmentRenameRule.load(from: defaults), rule)
    }
    rule.automatic = false
    rule.linked = true
    rule.save(to: defaults)
    XCTAssertEqual(AttachmentRenameRule.load(from: defaults), rule)
  }

  func testAutomaticAndBatchRenamingIncludeEveryFileFormat() throws {
    let dir = try directory(), db = try database(in: dir), ctx = db.mainContext
    let book = Book(title: "New Edition")
    ctx.insert(book); try ctx.save()
    let commands = BookAttachmentCommands(book: book, context: ctx)
    let store = try BookAttachmentStore(context: ctx)
    let originals = ["source.PDF", "art.png", "audio.mp3", "talk.mkv", "edition.epub", "index.custom", "README"]
    let urls = originals.map { dir.appendingPathComponent($0) }
    for url in urls { try Data(url.lastPathComponent.utf8).write(to: url) }
    let rule = AttachmentRenameRule()
    try commands.add(urls, linked: false, rule: rule)
    let names = ["New Edition.PDF", "New Edition.png", "New Edition.mp3", "New Edition.mkv", "New Edition.epub", "New Edition.custom", "New Edition"]
    XCTAssertEqual(try (book.attachmentIDs ?? []).map { try store.item($0).name }, names)

    var manual = rule
    manual.automatic = false
    try commands.add(urls, linked: false, rule: manual)
    try commands.addWebLink(address: "https://example.org/", title: "Web edition")
    let plan = try AttachmentRenamePlan.changes(for: [book], rule: manual, store: store)
    XCTAssertEqual(plan.map(\.item.name), originals)
    XCTAssertEqual(plan.map(\.filename), names.map { $0.replacingOccurrences(of: "New Edition", with: "New Edition (2)") })
    XCTAssertEqual(AttachmentRenamePlan.apply(plan, store: store) { _ in XCTFail(); return nil }.renamed, urls.count)
    XCTAssertTrue(try AttachmentRenamePlan.changes(for: [book], rule: rule, store: store).isEmpty)
    for change in plan {
      XCTAssertEqual(try store.item(change.id).name, change.filename)
      XCTAssertEqual(try store.portable(change.id).contents, Data(change.item.name.utf8))
    }
  }

  func testLinkedRenameRequiresOptInAndPermissionAndNeverOverwritesExistingFile() throws {
    let dir = try directory(), db = try database(in: dir), ctx = db.mainContext
    let book = Book(title: "Title")
    ctx.insert(book); try ctx.save()
    let commands = BookAttachmentCommands(book: book, context: ctx)
    let store = try BookAttachmentStore(context: ctx)
    let original = dir.appendingPathComponent("from.pdf")
    try Data("original".utf8).write(to: original)
    try commands.add([original], linked: true, rule: .init()) { _ in XCTFail(); return nil }
    let rule = AttachmentRenameRule(linked: true)
    let plan = try AttachmentRenamePlan.changes(for: [book], rule: rule, store: store)
    XCTAssertEqual(plan.map(\.filename), ["Title.pdf"])
    XCTAssertEqual(AttachmentRenamePlan.apply(plan, store: store) { _ in nil }.skipped, 1)
    let collision = dir.appendingPathComponent("Title.pdf")
    try Data("existing".utf8).write(to: collision)
    let failed = AttachmentRenamePlan.apply(plan, store: store) { _ in dir }
    XCTAssertEqual(failed.failures.count, 1)
    XCTAssertEqual(try Data(contentsOf: collision), Data("existing".utf8))
    XCTAssertEqual(try store.withFile(plan[0].id) { try Data(contentsOf: $0) }, Data("original".utf8))
    try FileManager.default.removeItem(at: collision)
    XCTAssertEqual(AttachmentRenamePlan.apply(plan, store: store) { _ in dir }.renamed, 1)
    let second = dir.appendingPathComponent("again.pdf")
    try Data("second".utf8).write(to: second)
    let added = try commands.add([second], linked: true, rule: rule) { _ in dir }
    XCTAssertEqual(added.renamed, 1)
    XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Title (2).pdf")), Data("second".utf8))
  }

  func testWebLinkMenuCommandsPersistAcrossBackupAndDirectoryCopy() throws {
    let dir = try directory(), db = try database(in: dir), ctx = db.mainContext
    let book = Book(title: "References")
    ctx.insert(book); try ctx.save()
    let commands = BookAttachmentCommands(book: book, context: ctx)
    let address = "https://example.org/edition?lang=en#page-5"
    try commands.addWebLink(address: "  " + address, title: "")
    let id = try XCTUnwrap(book.attachmentIDs?.first), store = try BookAttachmentStore(context: ctx)
    XCTAssertEqual(try store.item(id).name, address)
    XCTAssertThrowsError(try store.withFile(id) { _ in })
    XCTAssertThrowsError(try store.rename(id, stem: "file"))
    let localFile = dir.appendingPathComponent("notes.pdf")
    try Data("notes".utf8).write(to: localFile)
    XCTAssertThrowsError(try store.relink(id, to: localFile))
    try store.updateWebLink(id, address: address, title: "Publisher / Edition")
    let expected = AttachmentItem(id: id, name: "Publisher / Edition", kind: .web(try XCTUnwrap(URL(string: address))))
    XCTAssertEqual(try store.item(id), expected)
    let snapshot = BookAttachmentStore(database: try directory().appendingPathComponent("default.store"))
    XCTAssertEqual(try store.snapshot(to: snapshot.root), [id.uuidString + "/link.json"])
    XCTAssertEqual(try snapshot.item(id), expected)

    try commands.add([localFile], linked: true, rule: .init(pattern: "{title}"))
    try commands.add([localFile], linked: false, rule: .init(pattern: "{title}"))
    let data = try LibraryBackupService.exportData(from: ctx)
    XCTAssertEqual(try LibraryBackupService.decode(data).schemaVersion, 11)
    let target = try database(in: directory()), newContext = target.mainContext
    let plan = try LibraryImportPlanner.prepare(data, context: newContext)
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: newContext, undoManager: nil)
    let restored = try XCTUnwrap(newContext.fetch(FetchDescriptor<Book>()).first)
    let restoredStore = try BookAttachmentStore(context: newContext)
    XCTAssertEqual(restored.attachmentIDs, book.attachmentIDs)
    XCTAssertEqual(try restoredStore.item(id), expected)
    XCTAssertEqual(try restoredStore.portable(id), try store.portable(id))
    try commands.detach(id)
    XCTAssertEqual(book.attachmentIDs?.count, 2)
    XCTAssertThrowsError(try store.item(id))
  }

  func testInvalidAndConflictingWebLinks() throws {
    let db = try database(in: directory()), ctx = db.mainContext, book = Book(title: "Links")
    ctx.insert(book); try ctx.save()
    let commands = BookAttachmentCommands(book: book, context: ctx)
    let store = try BookAttachmentStore(context: ctx)
    for invalid in ["", "example.org", "file:///tmp/data", "mailto:a@example.org", "javascript:void(0)", "https://", "http://bad host"] {
      XCTAssertThrowsError(try commands.addWebLink(address: invalid, title: "Invalid"))
    }
    XCTAssertNil(book.attachmentIDs)
    try commands.addWebLink(address: "https://example.org/first", title: "Reader")
    let id = try XCTUnwrap(book.attachmentIDs?.first)
    var other = try store.portable(id), created: [UUID] = []
    other.webURL = "https://example.org/second"
    let secondID = try store.importFile(other, created: &created)
    XCTAssertNotEqual(secondID, id)
    XCTAssertEqual(try store.importFile(other, created: &created), secondID)
    XCTAssertEqual(created, [secondID])
    other.contents = Data()
    XCTAssertThrowsError(try store.importFile(other, created: &created))
    let data = try LibraryBackupService.exportData(from: ctx)
    var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    archive["schemaVersion"] = 10
    XCTAssertThrowsError(try LibraryBackupService.decode(JSONSerialization.data(withJSONObject: archive)))
    archive["schemaVersion"] = 11
    var files = try XCTUnwrap(archive["attachmentFiles"] as? [[String: Any]])
    files[0]["webURL"] = "file:///tmp/data"
    archive["attachmentFiles"] = files
    XCTAssertThrowsError(try LibraryBackupService.decode(JSONSerialization.data(withJSONObject: archive)))
  }
}
