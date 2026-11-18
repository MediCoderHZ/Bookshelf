import Foundation
import XCTest
@testable import Bookshelf

final class TranslatorSystemTests: XCTestCase {
  private let url = "https://books.example.org/book/123?edition=2"

  func testDetectionFallsBackInPriorityOrderAndReportsActualTranslator() throws {
    let skipped = StubTranslator(id: "specific", priority: 1, detection: nil)
    let fallback = StubTranslator(id: "fallback", priority: 100, detection: .book)
    let registry = WebTranslatorRegistry(translators: [fallback, skipped])
    let result = try registry.translate(html: Data("<h1>Title</h1>".utf8), sourceURL: url)
    XCTAssertEqual(result.translator.id, "fallback")
    guard case .book(let book) = result.page else { return XCTFail("Expected book") }
    XCTAssertEqual(book.sourceName, "fallback")
    XCTAssertEqual(book.sourceURL?.absoluteString, url)
  }

  func testPriorityTieIsStableDisabledTranslatorIsSkippedAndDuplicateIDsFail() throws {
    let a = StubTranslator(id: "a", priority: 100, detection: .book)
    let b = StubTranslator(id: "b", priority: 100, detection: .book)
    XCTAssertEqual(try WebTranslatorRegistry(translators: [b, a]).resolve(url).0.descriptor.id, "a")
    XCTAssertEqual(try WebTranslatorRegistry(translators: [a, b], disabledIDs: ["a"]).resolve(url).0.descriptor.id, "b")
    XCTAssertThrowsError(try WebTranslatorRegistry(translators: [a, a]).resolve(url))
    XCTAssertThrowsError(try WebTranslatorRegistry(translators: [a], disabledIDs: ["a"]).resolve(url)) {
      guard case WebMetadataError.disabled = $0 else { return XCTFail("Expected disabled") }
    }
  }

  func testExtractionFailureIsNotSilentlyMaskedByFallback() throws {
    let first = StubTranslator(id: "first", priority: 1, detection: .book, fails: true)
    let next = StubTranslator(id: "next", priority: 100, detection: .book)
    XCTAssertThrowsError(try WebTranslatorRegistry(translators: [first, next])
      .translate(html: Data("<html></html>".utf8), sourceURL: url)) {
        guard case WebMetadataError.accessRestricted = $0 else { return XCTFail("Expected original error") }
      }
  }

  func testRulePackageExtractsAnotherSiteWithoutChangingHost() throws {
    let rule = try TranslatorRule.decode(fixture("publisher-example.json"))
    let translator = try RuleBasedWebTranslator(rule: rule)
    let registry = WebTranslatorRegistry(translators: [translator])
    let result = try registry.translate(html: fixture("detail.html"), sourceURL: url)
    guard case .book(let book) = result.page else { return XCTFail("Expected book") }
    XCTAssertEqual(result.translator.id, "example.publisher")
    XCTAssertEqual(book.title, "网页解析器示例书")
    XCTAssertEqual(book.authors, ["作者甲", "作者乙"])
    XCTAssertEqual(book.translators, ["译者丙"])
    XCTAssertEqual(book.publisher, "示例出版社")
    XCTAssertEqual(book.publicationDate, "2026-11")
    XCTAssertEqual(book.pageCount, 240)
    XCTAssertEqual(book.isbn13, "9787020042494")
    XCTAssertEqual(book.bookDescription, "这是第一段示例简介。\n\n这是第二段示例简介。")
    XCTAssertEqual(book.sourceURL?.query, "edition=2")
  }

  func testRuleListUsesRelativeSelectorsDeduplicatesAndRestrictsTargets() throws {
    let translator = try RuleBasedWebTranslator(rule: TranslatorRule.example)
    let result = try WebTranslatorRegistry(translators: [translator]).translate(
      html: fixture("list.html"), sourceURL: "https://books.example.org/catalog")
    guard case .choices(let choices) = result.page else { return XCTFail("Expected choices") }
    XCTAssertEqual(choices.map(\.title), ["网页解析器示例书", "另一本示例书"])
    XCTAssertEqual(choices.map(\.url.path), ["/book/123", "/book/456"])
  }

  func testLegacyImageRuleIsDiscardedWhileMetadataStillExtracts() throws {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: TranslatorRule.example.encoded()) as? [String: Any])
    object["coverHosts"] = ["obsolete.invalid"]
    var book = try XCTUnwrap(object["book"] as? [String: Any])
    var fields = try XCTUnwrap(book["fields"] as? [String: Any])
    fields["coverURL"] = ["xpath": "//*[", "unused": true]
    book["fields"] = fields; object["book"] = book
    let rule = try TranslatorRule.decode(JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(rule.book.fields["coverURL"])
    let encoded = String(decoding: try rule.encoded(), as: UTF8.self)
    XCTAssertFalse(encoded.contains("coverHosts")); XCTAssertFalse(encoded.contains("coverURL"))
    let translator = try RuleBasedWebTranslator(rule: rule)
    let result = try translator.translate(html: fixture("detail.html"), url: URL(string: "https://books.example.org/book/123")!)
    guard case .book(let metadata) = result else { return XCTFail("Expected book metadata") }
    XCTAssertEqual(metadata.title, "网页解析器示例书")
    XCTAssertEqual(metadata.isbn13, "9787020042494")
  }

  func testValidationRejectsBadSchemaFieldsHostsAndXPath() throws {
    let original = try XCTUnwrap(JSONSerialization.jsonObject(with: TranslatorRule.example.encoded()) as? [String: Any])
    let mutations: [(String, Any)] = [
      ("schemaVersion", 2), ("id", "../escape"), ("version", "latest"), ("priority", 0),
      ("targets", [["host": "127.0.0.1", "pathPrefix": "/"]]),
      ("targets", [["host": "books.example.org", "pathPrefix": "book"]]),
      ("book", ["detect": "//*[", "fields": ["title": ["xpath": "//h1"]]]),
      ("book", ["detect": "boolean(//h1)", "fields": ["title": ["xpath": "//h1"]]]),
      ("book", ["detect": "//h1", "fields": ["unknownField": ["xpath": "//h1"]]])
    ]
    for (key, value) in mutations {
      var object = original
      object[key] = value
      XCTAssertThrowsError(try TranslatorRule.decode(JSONSerialization.data(withJSONObject: object)), key)
    }
    XCTAssertThrowsError(try TranslatorRule.decode(Data(repeating: 32, count: 256 * 1_024 + 1)))
    XCTAssertThrowsError(try TranslatorRule.decode(Data("not-json".utf8)))
  }

  func testURLPolicyRejectsLocalSchemesCredentialsAndMisleadingHosts() {
    for raw in ["file:///tmp/page", "http://127.0.0.1/", "https://localhost/", "https://host.local/",
      "https://[::1]/", "https://user:pass@books.example.org/book/1", "https://books.example.org:8080/"] {
      XCTAssertNil(URL(string: raw).flatMap(WebURLPolicy.normalized), raw)
    }
    let rule = try! RuleBasedWebTranslator(rule: TranslatorRule.example)
    XCTAssertNil(rule.canonicalURL(for: URL(string: "https://books.example.org.evil.com/book/1")!))
    XCTAssertNil(rule.canonicalURL(for: URL(string: "https://books.example.org/account/")!))
    XCTAssertEqual(rule.canonicalURL(for: URL(string: "http://books.example.org/book/1#section")!)?.absoluteString,
      "https://books.example.org/book/1")
  }

  @MainActor
  func testDirectoryScriptsAreSeededReloadedAndIsolated() throws {
    let name = UUID().uuidString, folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: name) }
    let store = TranslatorStore(directory: folder, defaults: defaults)
    for seed in TranslatorScript.bundled {
      let active = try XCTUnwrap(store.scriptFile(for: seed.id))
      XCTAssertEqual(active.standardizedFileURL, folder.appendingPathComponent(seed.id + ".js").standardizedFileURL)
      XCTAssertEqual(try Data(contentsOf: active), try Data(contentsOf: XCTUnwrap(seed.file)))
    }
    let file = try XCTUnwrap(store.scriptFile(for: "douban-books"))
    let initial = try String(contentsOf: file, encoding: .utf8)
    let edit = initial + "\nfunction doWeb() { return record({id: 'local', title: 'Local script'}); }"
    try edit.write(to: file, atomically: true, encoding: .utf8)
    let revision = store.revision
    store.reload()
    XCTAssertGreaterThan(store.revision, revision)
    let active = TranslatorStore(directory: folder, defaults: defaults)
    let html = Data("<h1>Title</h1><div id='info'>ISBN: 9780743273565</div>".utf8)
    let result = try active.registry.translate(html: html, sourceURL: "https://book.douban.com/subject/123/")
    guard case .book(let book) = result.page else { return XCTFail("Expected local book") }
    XCTAssertEqual(book.title, "Local script")
    let broken = edit + "\nfunction ("
    try broken.write(to: file, atomically: true, encoding: .utf8)
    active.reload()
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), broken)
    XCTAssertFalse(active.descriptors.contains { $0.id == "douban-books" })
    XCTAssertTrue(active.diagnostics.contains { $0.contains(file.lastPathComponent) })
    XCTAssertEqual(Set(active.catalog.searchSources.map(\.id)), ["goodreads-books", "open-library"])
    try FileManager.default.removeItem(at: file)
    active.reload()
    XCTAssertTrue(active.diagnostics.isEmpty)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), initial)
  }

  func testFactoryUpgradeUpdatesUntouchedFilesAndPreservesEdits() throws {
    let name = UUID().uuidString, root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
    let folder = root.appendingPathComponent("Translators")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let id = "douban-books", factory = root.appendingPathComponent("factory.js"), local = folder.appendingPathComponent(id + ".js")
    let v1 = try String(contentsOf: XCTUnwrap(TranslatorScript.douban.file), encoding: .utf8)
    let v2 = v1 + "\n// Factory update"
    func install(_ source: String) throws {
      try source.write(to: factory, atomically: true, encoding: .utf8)
      _ = try TranslatorScript(id: id, file: factory).installed(in: folder, defaults: defaults)
    }
    try install(v1)
    try install(v2)
    XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), v2)
    let edit = v2 + "\n// Local edit"
    try edit.write(to: local, atomically: true, encoding: .utf8)
    try install(v2 + "\n// Newer update")
    XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), edit)
    defaults.removePersistentDomain(forName: name)
    try install(v1)
    XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), edit)
  }

  @MainActor
  func testInstallationReplacementPersistenceRemovalAndCorruptFileIsolation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "translator-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "translator.douban.enabled")
    let store = TranslatorStore(directory: directory, defaults: defaults)
    XCTAssertFalse(store.isEnabled("douban-books"))
    try store.install(TranslatorRule.example)
    store.setEnabled(false, for: "example.publisher")
    var replacement = try XCTUnwrap(JSONSerialization.jsonObject(with: TranslatorRule.example.encoded()) as? [String: Any])
    replacement["version"] = "2.0.0"
    try store.install(TranslatorRule.decode(JSONSerialization.data(withJSONObject: replacement)))
    XCTAssertEqual(store.rules.count, 1)
    XCTAssertEqual(store.rules.first?.version, "2.0.0")
    XCTAssertFalse(store.isEnabled("example.publisher"))
    try Data("broken".utf8).write(to: directory.appendingPathComponent("broken.json"))
    let reloaded = TranslatorStore(directory: directory, defaults: defaults)
    XCTAssertEqual(reloaded.rules.count, 1)
    XCTAssertFalse(reloaded.isEnabled("example.publisher"))
    XCTAssertEqual(reloaded.diagnostics.count, 1)
    XCTAssertEqual(try TranslatorRule.decode(XCTUnwrap(reloaded.rules.first).encoded()).version, "2.0.0")
    replacement["id"] = "douban-books"
    XCTAssertThrowsError(try reloaded.install(TranslatorRule.decode(JSONSerialization.data(withJSONObject: replacement))))
    try reloaded.remove("example.publisher")
    XCTAssertTrue(reloaded.rules.isEmpty)
    XCTAssertEqual(Set(reloaded.descriptors.map(\.id)), Set(BuiltinTranslators.catalog.map(\.descriptor.id)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("broken.json").path))
  }

  @MainActor
  func testFolderReloadUsesDeclaredIDAndIsolatesDuplicateFiles() throws {
    let name = UUID().uuidString, directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: name) }
    let store = TranslatorStore(directory: directory, defaults: defaults)
    try store.ensureDirectory()
    let rule = TranslatorRule.example, chosen = directory.appendingPathComponent("Publisher.JSON")
    try rule.encoded().write(to: chosen)
    store.reload()
    XCTAssertEqual(store.rules, [rule])
    let revision = store.revision
    store.reload()
    XCTAssertEqual(store.revision, revision)
    store.setEnabled(false, for: rule.id)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: rule.encoded()) as? [String: Any])
    object["version"] = "2.0.0"
    let updated = try TranslatorRule.decode(JSONSerialization.data(withJSONObject: object))
    try store.install(updated)
    XCTAssertEqual(try TranslatorRule.decode(Data(contentsOf: chosen)), updated)
    XCTAssertFalse(store.isEnabled(rule.id))
    let duplicate = directory.appendingPathComponent(rule.id + ".json")
    try rule.encoded().write(to: duplicate)
    store.reload()
    XCTAssertTrue(store.rules.isEmpty)
    XCTAssertFalse(store.diagnostics.isEmpty)
    XCTAssertThrowsError(try store.install(rule))
    XCTAssertThrowsError(try store.remove(rule.id))
    try FileManager.default.removeItem(at: duplicate)
    store.reload()
    XCTAssertEqual(store.rules, [updated])
    XCTAssertFalse(store.isEnabled(rule.id))
    try store.remove(rule.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: chosen.path))
  }

  private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("Examples/Translators/\(name)"))
  }
}

private struct StubTranslator: WebMetadataTranslator {
  let id: String
  let priority: Int
  let detection: WebPageKind?
  var fails = false
  var descriptor: TranslatorDescriptor {
    TranslatorDescriptor(id: id, name: id, version: "1.0.0", author: "Test", targetDescription: "Test",
      priority: priority)
  }
  func canonicalURL(for url: URL) -> URL? {
    guard url.host == "books.example.org" else { return nil }
    return WebURLPolicy.normalized(url)
  }
  func detectWeb(in document: HTMLMetadataDocument, url: URL) throws -> WebPageKind? { detection }
  func doWeb(in document: HTMLMetadataDocument, url: URL, kind: WebPageKind) throws -> TranslatedWebPage {
    if fails || detection == nil { throw WebMetadataError.accessRestricted }
    return .book(BookMetadataSearchResult(id: id, title: "Test", subtitle: nil, authors: [], publisher: nil,
      publicationDate: nil, isbn10: nil, isbn13: nil, pageCount: nil, languageCode: nil,
      sourceName: "untrusted label"))
  }
}
