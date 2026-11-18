import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class PluginSystemTests: XCTestCase {
  private func exampleURL() throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: "reading-notes-v1", withExtension: "json", subdirectory: "Fixtures"))
  }

  private func packageURL() throws -> URL {
    try XCTUnwrap(L10n.resourceBundle.url(forResource: "reading-notes", withExtension: "bookshelfplugin"))
  }

  func testBundledPackageReplacesLegacyPluginAndContributesOnlyWhileEnabled() throws {
    try withStore { store, root, defaults in
      let id = NoteTemplatePlugin.readingNotesID
      store.setEnabled(false, for: id)
      let source = root.appendingPathComponent("download.bookshelfplugin")
      try FileManager.default.copyItem(at: packageURL(), to: source)
      let preview = try NoteTemplatePlugin.read(from: source)
      XCTAssertEqual(preview.id, id)
      XCTAssertEqual(preview.icon, "book.closed")
      XCTAssertEqual(preview.localized(for: .english).name, "Reading Notes")
      XCTAssertTrue(try XCTUnwrap(preview.localized(for: .chinese).description).contains("摘录"))
      try store.install(preview)
      try FileManager.default.removeItem(at: source)
      let reopened = PluginStore(directory: root, defaults: defaults)
      XCTAssertTrue(reopened.enabledTemplates.isEmpty)
      XCTAssertEqual(reopened.noteTemplates.map(\.version), ["1.1.0"])
      reopened.setEnabled(true, for: id)
      let active = try XCTUnwrap(reopened.enabledTemplates.first)
      XCTAssertEqual(active.draft(for: Book(title: "Example"), language: .english).title, "Reading Notes — Example")
      try reopened.remove(id)
      XCTAssertTrue(PluginStore(directory: root, defaults: defaults, exampleURL: try packageURL()).noteTemplates.isEmpty)
    }
  }

  func testInvalidPackageIsRejectedBeforeReplacement() throws {
    try withStore { store, root, _ in
      let source = root.appendingPathComponent("invalid.bookshelfplugin")
      let manager = FileManager.default
      try manager.copyItem(at: packageURL(), to: source)
      let file = source.appendingPathComponent("manifest.json")
      let original = try Data(contentsOf: file)
      let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      for change: [String: Any] in [
        ["manifest_version": 2], ["contributes": ["note_template": "../template.json"]],
        ["contributes": ["note_template": "absent.json"]], ["locales": [:]], ["id": "../other"]
      ] {
        try JSONSerialization.data(withJSONObject: manifest.merging(change) { _, new in new }).write(to: file)
        XCTAssertThrowsError(try store.install(NoteTemplatePlugin.read(from: source)))
      }
      try original.write(to: file)
      let template = source.appendingPathComponent("template.json")
      try Data(repeating: 32, count: ExtensionFile.sizeLimit).write(to: template)
      XCTAssertThrowsError(try NoteTemplatePlugin.read(from: source))
      try manager.removeItem(at: template)
      try manager.createSymbolicLink(at: template, withDestinationURL: packageURL().appendingPathComponent("template.json"))
      XCTAssertThrowsError(try NoteTemplatePlugin.read(from: source))
      XCTAssertEqual(store.enabledTemplates.map(\.version), ["1.0.0"])
    }
  }

  func testFirstLaunchInstallsPackagedExampleOnlyOnce() throws {
    let source = try packageURL()
    try withStore(bundled: source) { store, directory, defaults in
      let plugin = try XCTUnwrap(store.enabledTemplates.first)
      XCTAssertEqual(plugin.version, "1.1.0")
      XCTAssertTrue(store.diagnostics.isEmpty)
      try store.remove(plugin.id)
      XCTAssertTrue(PluginStore(directory: directory, defaults: defaults, exampleURL: source).noteTemplates.isEmpty)
    }
  }

  private func withStore(bundled: URL? = nil, _ body: (PluginStore, URL, UserDefaults) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "plugin-tests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      try? FileManager.default.removeItem(at: directory)
      defaults.removePersistentDomain(forName: suite)
    }
    try body(PluginStore(directory: directory, defaults: defaults, exampleURL: bundled ?? exampleURL()), directory, defaults)
  }

  func testSeparateCatalogsMigrateLegacyTemplatesOnceAndKeepSettings() throws {
    try withStore { _, root, defaults in
      let legacy = root.appendingPathComponent("Translators"), plugins = root.appendingPathComponent("Plugins")
      try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
      let rule = TranslatorRule.example
      let ruleFile = legacy.appendingPathComponent(rule.id + ".json"), templateID = NoteTemplatePlugin.readingNotesID
      let original = try rule.encoded()
      try original.write(to: ruleFile)
      let legacyTemplate = legacy.appendingPathComponent(templateID + ".json")
      let sample = try Data(contentsOf: exampleURL())
      try sample.write(to: legacyTemplate)
      defaults.set(false, forKey: "translator.enabled." + templateID)
      defaults.set(false, forKey: "translator.enabled." + rule.id)

      let pluginStore = PluginStore(directory: plugins, defaults: defaults, legacyDirectory: legacy)
      let translators = TranslatorStore(directory: legacy, defaults: defaults)
      XCTAssertEqual(pluginStore.noteTemplates.map(\.id), [templateID])
      XCTAssertEqual(translators.rules.map(\.id), [rule.id])
      XCTAssertTrue(pluginStore.enabledTemplates.isEmpty)
      XCTAssertFalse(translators.isEnabled(rule.id))
      XCTAssertTrue(translators.diagnostics.isEmpty)
      XCTAssertFalse(FileManager.default.fileExists(atPath: legacyTemplate.path))
      XCTAssertEqual(try Data(contentsOf: plugins.appendingPathComponent(templateID + ".json")), sample)
      XCTAssertEqual(try Data(contentsOf: ruleFile), original)
      try pluginStore.remove(templateID)
      let next = PluginStore(directory: plugins, defaults: defaults, legacyDirectory: legacy, exampleURL: try exampleURL())
      XCTAssertTrue(next.noteTemplates.isEmpty)
      XCTAssertEqual(try Data(contentsOf: ruleFile), original)
    }
  }

  func testMigrationPreservesBothTemplatesIfNewLocationIsAlreadyOccupied() throws {
    try withStore { _, root, defaults in
      let legacy = root.appendingPathComponent("Translators"), plugins = root.appendingPathComponent("Plugins")
      for url in [legacy, plugins] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
      let filename = NoteTemplatePlugin.readingNotesID + ".json"
      let old = try Data(contentsOf: exampleURL())
      try old.write(to: legacy.appendingPathComponent(filename))
      let current = Data(String(decoding: old, as: UTF8.self).replacingOccurrences(of: "1.0.0", with: "2.0.0").utf8)
      try current.write(to: plugins.appendingPathComponent(filename))
      let migrated = PluginStore(directory: plugins, defaults: defaults, legacyDirectory: legacy)
      XCTAssertEqual(migrated.noteTemplates.first?.version, "2.0.0")
      let previous = plugins.appendingPathComponent("Previous")
      let directories = try FileManager.default.contentsOfDirectory(at: previous, includingPropertiesForKeys: nil)
      XCTAssertEqual(directories.count, 1)
      XCTAssertEqual(try Data(contentsOf: XCTUnwrap(directories.first).appendingPathComponent(filename)), old)
    }
  }

  func testUninstallingBundledTemplatePersists() throws {
    try withStore { store, directory, defaults in
      let url = try exampleURL()
      let template = try XCTUnwrap(store.enabledTemplates.first)
      XCTAssertEqual(template.id, NoteTemplatePlugin.readingNotesID)
      store.setEnabled(false, for: template.id)
      try store.install(try NoteTemplatePlugin.read(from: url))
      let next = PluginStore(directory: directory, defaults: defaults, exampleURL: url)
      XCTAssertTrue(next.enabledTemplates.isEmpty)
      try next.remove(template.id)
      let reopened = PluginStore(directory: directory, defaults: defaults, exampleURL: url)
      XCTAssertTrue(reopened.noteTemplates.isEmpty)
      try reopened.install(NoteTemplatePlugin.read(from: url))
      XCTAssertEqual(reopened.enabledTemplates.map(\.id), [template.id])
    }
  }

  func testRejectsInvalidPackagesAndTranslatorFilesWithoutReplacingAWorkingPlugin() throws {
    try withStore { store, directory, _ in
      let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exampleURL())) as? [String: Any])
      let url = directory.appendingPathComponent("candidate.tmp")
      let invalid: [[String: Any]] = [
        ["id": "../outside"], ["schemaVersion": 2], ["type": "unknown"],
        ["content": [:]], ["content": ["en": ["name": "test", "title": "test", "body": "{{privateNotes}}"]]]
      ]
      for change in invalid {
        try JSONSerialization.data(withJSONObject: manifest.merging(change) { _, new in new }).write(to: url)
        XCTAssertThrowsError(try NoteTemplatePlugin.read(from: url))
      }
      try Data(repeating: 0, count: 256 * 1024 + 1).write(to: url)
      XCTAssertThrowsError(try NoteTemplatePlugin.read(from: url))
      try TranslatorRule.example.encoded().write(to: url)
      XCTAssertThrowsError(try NoteTemplatePlugin.read(from: url))
      XCTAssertEqual(store.noteTemplates.map(\.id), [NoteTemplatePlugin.readingNotesID])
    }
  }

  func testThirdPartyTemplateInstallsFromFileAndKeepsDisabledStateWhenReplaced() throws {
    try withStore { store, directory, defaults in
      let source = directory.appendingPathComponent("download.tmp")
      let content = ["en": ["name": "Publisher Notes", "title": "{{title}}", "body": "{{publisher}} / {{isbn}}"]]
      var manifest: [String: Any] = ["id": "publisher.notes", "author": "Example", "version": "1.0.0",
        "type": "note-template", "schemaVersion": 1, "content": content]
      @MainActor func installFile() throws {
        try JSONSerialization.data(withJSONObject: manifest).write(to: source)
        try store.install(NoteTemplatePlugin.read(from: source))
      }
      try installFile()
      let book = Book(title: "Test")
      book.publisher = "Example"
      let installed = try XCTUnwrap(store.enabledTemplates.first { $0.id == "publisher.notes" })
      XCTAssertEqual(installed.draft(for: book, language: .chinese).body, "Example / ")
      store.setEnabled(false, for: installed.id)
      manifest["version"] = "1.1.0"
      try installFile()
      let next = PluginStore(directory: directory, defaults: defaults)
      XCTAssertEqual(next.noteTemplates.first { $0.id == installed.id }?.version, "1.1.0")
      XCTAssertFalse(next.enabledTemplates.contains { $0.id == installed.id })
      XCTAssertEqual(next.enabledTemplates.map(\.id), [NoteTemplatePlugin.readingNotesID])
    }
  }

  func testTemplateCreatesIndependentEditableChildWithUndoAndBackup() throws {
    try withStore { store, _, _ in
      let template = try XCTUnwrap(store.enabledTemplates.first)
      let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
      let title = "A Book {{authors}}"
      try LibraryCommands(context: context, undoManager: nil).save(BookArchive(book: Book(title: title)), expected: nil)
      let book = try XCTUnwrap(context.fetch(FetchDescriptor<Book>()).first)
      let draft = template.draft(for: book, language: .english)
      XCTAssertEqual(draft.title, "Reading Notes — " + title)
      XCTAssertTrue(draft.body.contains("Questions to Explore"))
      XCTAssertTrue(template.draft(for: book, language: .chinese).body.contains("## 摘录"))
      let undo = UndoManager()
      undo.groupsByEvent = false
      let commands = NoteCommands(context: context, undoManager: undo)
      undo.beginUndoGrouping()
      let saved = try commands.save(draft, expected: nil)
      undo.endUndoGrouping()
      XCTAssertEqual(saved.parentBookID, book.id)
      undo.undo()
      XCTAssertNil(try OrganizationStore.notes(in: context)[saved.id])
      undo.redo()
      try store.remove(template.id)
      var edited = try XCTUnwrap(OrganizationStore.notes(in: context)[saved.id])
      let previous = edited
      edited.body += "My reflections"
      _ = try NoteCommands(context: context, undoManager: nil).save(edited, expected: previous)
      let backup = try LibraryBackupService.decode(LibraryBackupService.exportData(from: context))
      XCTAssertEqual(backup.libraryNotes?.first?.body, edited.body)
      XCTAssertEqual(backup.libraryNotes?.first?.parentBookID, book.id)
      try LibraryOperations.setTrashed(true, books: [book], context: context, undoManager: nil)
      XCTAssertThrowsError(try commands.save(template.draft(for: book, language: .english), expected: nil))
    }
  }
}
