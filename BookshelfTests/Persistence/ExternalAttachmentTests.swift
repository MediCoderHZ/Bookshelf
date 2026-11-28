import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class ExternalAttachmentTests: XCTestCase {
  private func folder() throws -> URL {
    let fm = FileManager.default
    let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock { try? fm.removeItem(at: url) }
    return url
  }

  func testMoveAndRenameKeepBookReferenceAndExternalContents() throws {
    let library = try folder(), first = try folder(), second = try folder(), inputs = try folder()
    let database = library.appendingPathComponent("default.store")
    let container = try LibraryDatabase.open(at: database)
    let book = Book(title: "Atlas")
    container.mainContext.insert(book)
    try container.mainContext.save()
    let store = BookAttachmentStore(database: database)
    let commands = BookAttachmentCommands(book: book, context: container.mainContext)
    let original = inputs.appendingPathComponent("notes.pdf"), bytes = Data("notes".utf8)
    try bytes.write(to: original)
    var rule = AttachmentRenameRule()
    rule.automatic = false
    try commands.add([original], linked: false, rule: rule)
    try commands.addWebLink(address: "https://example.org", title: "Website")
    let ids = try XCTUnwrap(book.attachmentIDs)
    let id = ids[0], initial = try store.item(id)
    let firstFolder = try store.folderPreferences.reference(for: first)
    try commands.organize(initial, stem: nil, destination: firstFolder, grantedParent: nil)
    let firstURL = first.appendingPathComponent("notes.pdf")
    XCTAssertEqual(try Data(contentsOf: firstURL), bytes)
    let external = try store.item(id)
    XCTAssertEqual(external.kind, .externalFile)
    let links = store.root.appendingPathComponent(id.uuidString + "/file")
    let firstLink = try FileManager.default.destinationOfSymbolicLink(atPath: links.appendingPathComponent("notes.pdf").path)
    XCTAssertEqual(URL(fileURLWithPath: firstLink).resolvingSymlinksInPath(), firstURL.resolvingSymlinksInPath())
    try commands.organize(external, stem: nil, destination: firstFolder, grantedParent: nil)
    let secondFolder = try store.folderPreferences.reference(for: second)
    let occupied = second.appendingPathComponent("Taken.pdf")
    try Data("other".utf8).write(to: occupied)
    XCTAssertThrowsError(try commands.organize(external, stem: "Taken", destination: secondFolder, grantedParent: nil))
    XCTAssertEqual(try Data(contentsOf: occupied), Data("other".utf8))
    XCTAssertEqual(try store.portable(id).contents, bytes)
    try commands.organize(external, stem: "Atlas", destination: secondFolder, grantedParent: nil)
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
    let moved = second.appendingPathComponent("Atlas.pdf")
    XCTAssertEqual(try Data(contentsOf: moved), bytes)
    let movedLink = try FileManager.default.destinationOfSymbolicLink(atPath: links.appendingPathComponent("Atlas.pdf").path)
    XCTAssertEqual(URL(fileURLWithPath: movedLink).resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
    try commands.organize(store.item(id), stem: "Appendix", destination: nil, grantedParent: nil)
    XCTAssertEqual(try store.item(id).name, "Appendix.pdf")
    XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent("Appendix.pdf")), bytes)
    XCTAssertEqual(try Data(contentsOf: original), bytes)
    XCTAssertEqual(book.attachmentIDs, ids)
    XCTAssertNil(try store.folderPreferences.reference())
    XCTAssertThrowsError(try commands.organize(store.item(ids[1]), stem: nil, destination: firstFolder, grantedParent: nil))
  }

  func testMovingLinkedOriginalRequiresCorrectGrantAndProtectsOtherLinks() throws {
    let library = try folder(), inputs = try folder(), destination = try folder()
    let database = library.appendingPathComponent("default.store")
    let container = try LibraryDatabase.open(at: database)
    let context = container.mainContext, store = BookAttachmentStore(database: database)
    let a = Book(title: "A"), b = Book(title: "B")
    context.insert(a); context.insert(b); try context.save()
    let commands = BookAttachmentCommands(book: a, context: context)
    let other = BookAttachmentCommands(book: b, context: context)
    let original = inputs.appendingPathComponent("first.epub"), bytes = Data("first".utf8)
    try bytes.write(to: original)
    try commands.add([original], linked: true, rule: .init())
    let id = try XCTUnwrap(a.attachmentIDs?.first), item = try store.item(id)
    let to = try store.folderPreferences.reference(for: destination)
    XCTAssertThrowsError(try commands.organize(item, stem: nil, destination: to, grantedParent: nil))
    XCTAssertThrowsError(try commands.organize(item, stem: nil, destination: to, grantedParent: library))
    XCTAssertThrowsError(try other.organize(item, stem: nil, destination: to, grantedParent: inputs))
    try other.add([original], linked: true, rule: .init())
    XCTAssertThrowsError(try commands.organize(item, stem: nil, destination: to, grantedParent: inputs))
    XCTAssertEqual(try Data(contentsOf: original), bytes)
    try other.detach(XCTUnwrap(b.attachmentIDs?.first))
    try commands.organize(item, stem: "Book A", destination: to, grantedParent: inputs)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Book A.epub")), bytes)
    XCTAssertEqual(try store.portable(id).contents, bytes)
  }

  func testDropsCreateNamedFilesAndRealSymlinksAndProtectOtherBooks() throws {
    let library = try folder(), external = try folder(), inputs = try folder()
    let database = library.appendingPathComponent("default.store")
    let container = try LibraryDatabase.open(at: database), context = container.mainContext
    let store = BookAttachmentStore(database: database)
    let first = Book(title: "Atlas"), second = Book(title: "Atlas")
    context.insert(first); context.insert(second); try context.save()
    let preferences = AttachmentFolderPreferences(database: database)
    try preferences.set(external)
    let original = inputs.appendingPathComponent("notes.pdf")
    let bytes = Data("an attachment".utf8)
    try bytes.write(to: original)
    let prior = external.appendingPathComponent("Atlas.pdf")
    try Data("preexisting".utf8).write(to: prior)
    let rule = AttachmentRenameRule(pattern: "{title}")
    let commands = BookAttachmentCommands(book: first, context: context)
    try commands.add([original], linked: false, rule: rule)
    try BookAttachmentCommands(book: second, context: context).add([original], linked: false, rule: rule)
    let id = try XCTUnwrap(first.attachmentIDs?.first)
    let item = try store.item(id)
    XCTAssertEqual(item.kind, .externalFile)
    XCTAssertEqual(item.name, "Atlas (2).pdf")
    XCTAssertEqual(try store.item(XCTUnwrap(second.attachmentIDs?.first)).name, "Atlas (3).pdf")
    let target = external.appendingPathComponent(item.name)
    let localDirectory = store.root.appendingPathComponent(id.uuidString + "/file")
    let local = localDirectory.appendingPathComponent(item.name)
    XCTAssertEqual(try URL(fileURLWithPath: FileManager.default.destinationOfSymbolicLink(atPath: local.path)).standardizedFileURL,
      target.standardizedFileURL)
    XCTAssertEqual(try store.withFile(id) { $0.standardizedFileURL }, target.standardizedFileURL)
    XCTAssertEqual(try Data(contentsOf: local), bytes)
    XCTAssertThrowsError(try store.rename(id, stem: "Atlas"))
    try store.rename(id, stem: "Appendix")
    let renamed = external.appendingPathComponent("Appendix.pdf")
    XCTAssertEqual(try store.item(id).name, "Appendix.pdf")
    XCTAssertEqual(try Data(contentsOf: localDirectory.appendingPathComponent("Appendix.pdf")), bytes)
    try commands.detach(id)
    XCTAssertEqual(try Data(contentsOf: renamed), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: localDirectory.path))
    XCTAssertEqual(try Data(contentsOf: prior), Data("preexisting".utf8))
    XCTAssertEqual(try Data(contentsOf: original), bytes)
  }

  func testFolderChangesAffectOnlyNewCopiesAndFailedBatchCleansUp() throws {
    let library = try folder(), first = try folder(), second = try folder(), inputs = try folder()
    let database = library.appendingPathComponent("default.store")
    let container = try LibraryDatabase.open(at: database), context = container.mainContext
    let book = Book(title: "Book")
    context.insert(book); try context.save()
    let preferences = AttachmentFolderPreferences(database: database), store = BookAttachmentStore(database: database)
    let original = inputs.appendingPathComponent("original.txt")
    try Data("text".utf8).write(to: original)
    let commands = BookAttachmentCommands(book: book, context: context)
    var rule = AttachmentRenameRule(); rule.automatic = false
    try preferences.set(first)
    try commands.add([original], linked: false, rule: rule)
    let firstID = try XCTUnwrap(book.attachmentIDs?.last)
    try preferences.set(second)
    XCTAssertThrowsError(try commands.add([original, inputs.appendingPathComponent("missing")], linked: false, rule: rule))
    XCTAssertEqual(book.attachmentIDs, [firstID])
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: second.path).isEmpty)
    try commands.add([original], linked: false, rule: rule)
    let secondID = try XCTUnwrap(book.attachmentIDs?.last)
    try commands.add([original], linked: true, rule: rule)
    let linkedID = try XCTUnwrap(book.attachmentIDs?.last)
    try preferences.reset()
    XCTAssertNil(try preferences.reference())
    try commands.add([original], linked: false, rule: rule)
    let storedID = try XCTUnwrap(book.attachmentIDs?.last)
    XCTAssertEqual(try store.withFile(firstID) { $0.deletingLastPathComponent().standardizedFileURL.path }, first.standardizedFileURL.path)
    XCTAssertEqual(try store.withFile(secondID) { $0.deletingLastPathComponent().standardizedFileURL.path }, second.standardizedFileURL.path)
    XCTAssertEqual(try store.item(linkedID).kind, .linkedFile)
    XCTAssertEqual(try store.withFile(linkedID) { $0.standardizedFileURL }, original.standardizedFileURL)
    XCTAssertEqual(try store.item(storedID).kind, .stored)
  }

  func testTamperedSymlinkCannotExposeAnotherFile() throws {
    let library = try folder(), external = try folder(), inputs = try folder()
    let database = library.appendingPathComponent("default.store")
    let preferences = AttachmentFolderPreferences(database: database), store = BookAttachmentStore(database: database)
    try preferences.set(external)
    let original = inputs.appendingPathComponent("original.txt")
    try Data("original".utf8).write(to: original)
    let id = try store.add(original, linked: false, name: "copied.txt")
    let local = store.root.appendingPathComponent(id.uuidString + "/file/copied.txt")
    try FileManager.default.removeItem(at: local)
    try FileManager.default.createSymbolicLink(at: local, withDestinationURL: original)
    XCTAssertThrowsError(try store.withFile(id) { _ in XCTFail("Unexpected target") })
    XCTAssertThrowsError(try store.rename(id, stem: "changed"))
    XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
  }

  func testFolderPreferencesRejectManagedDirectoriesAndCorruptConfiguration() throws {
    let library = try folder(), db = library.appendingPathComponent("default.store")
    let preferences = AttachmentFolderPreferences(database: db)
    let nested = library.appendingPathComponent("attachments/object", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    XCTAssertThrowsError(try preferences.set(nested))
    XCTAssertThrowsError(try preferences.set(library))
    XCTAssertNil(try preferences.reference())
    try Data("truncated".utf8).write(to: library.appendingPathComponent("AttachmentFolder.json"))
    XCTAssertThrowsError(try preferences.reference())
    try preferences.reset()
    XCTAssertNil(try preferences.reference())
  }

  func testMovingExternalDirectoryRepairsTheLibrarySymlink() throws {
    let library = try folder(), parent = try folder(), inputs = try folder()
    let database = library.appendingPathComponent("default.store")
    let external = parent.appendingPathComponent("Before", isDirectory: true)
    let moved = parent.appendingPathComponent("After", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: external, withIntermediateDirectories: false)
    try AttachmentFolderPreferences(database: database).set(external)
    let source = inputs.appendingPathComponent("reading.pdf")
    let content = Data("Reading copy".utf8)
    try content.write(to: source)
    let store = BookAttachmentStore(database: database)
    let id = try store.add(source, linked: false, name: "reading.pdf")
    let local = store.root.appendingPathComponent(id.uuidString + "/file/reading.pdf")
    try fm.moveItem(at: external, to: moved)
    XCTAssertFalse(fm.fileExists(atPath: local.path))

    let expected = moved.appendingPathComponent("reading.pdf").resolvingSymlinksInPath().path
    XCTAssertEqual(try store.withFile(id) { $0.resolvingSymlinksInPath().path }, expected)
    let destination = try fm.destinationOfSymbolicLink(atPath: local.path)
    XCTAssertEqual(URL(fileURLWithPath: destination).resolvingSymlinksInPath().path, expected)
    XCTAssertEqual(try Data(contentsOf: local), content)
    XCTAssertEqual(try BookAttachmentStore(database: database).withFile(id) { try Data(contentsOf: $0) }, content)
  }

  func testBatchRenameReservesSharedExternalFolderNamesAcrossBooks() throws {
    let library = try folder(), external = try folder(), inputs = try folder()
    let database = library.appendingPathComponent("default.store")
    let container = try LibraryDatabase.open(at: database), context = container.mainContext
    let store = BookAttachmentStore(database: database)
    try AttachmentFolderPreferences(database: database).set(external)
    let occupied = external.appendingPathComponent("Atlas.pdf")
    let unrelated = Data("Existing file".utf8)
    try unrelated.write(to: occupied)
    let books = [Book(title: "Atlas"), Book(title: "Atlas")]
    for book in books { context.insert(book) }
    try context.save()
    let sources = ["chapter-one.pdf", "chapter-two.pdf"]
    let rule = AttachmentRenameRule(pattern: "{title}", automatic: false)
    for (book, name) in zip(books, sources) {
      let source = inputs.appendingPathComponent(name)
      try Data(name.utf8).write(to: source)
      try BookAttachmentCommands(book: book, context: context).add([source], linked: false, rule: rule)
    }

    let changes = try AttachmentRenamePlan.changes(for: books, rule: rule, store: store)
    XCTAssertEqual(changes.map(\.filename), ["Atlas (2).pdf", "Atlas (3).pdf"])
    let result = AttachmentRenamePlan.apply(changes, store: store) { _ in
      XCTFail("The external folder already has an access grant")
      return nil
    }
    XCTAssertEqual(result.renamed, 2)
    XCTAssertEqual(result.skipped, 0)
    XCTAssertEqual(try Data(contentsOf: occupied), unrelated)
    for (change, originalName) in zip(changes, sources) {
      let file = external.appendingPathComponent(change.filename)
      let link = store.root.appendingPathComponent(change.id.uuidString + "/file/" + change.filename)
      XCTAssertEqual(try Data(contentsOf: file), Data(originalName.utf8))
      let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
      XCTAssertEqual(URL(fileURLWithPath: destination).resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
      XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent(originalName).path))
    }
  }
}
