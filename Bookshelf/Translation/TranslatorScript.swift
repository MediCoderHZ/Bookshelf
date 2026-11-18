import CryptoKit
import Foundation
import JavaScriptCore
@preconcurrency import libxml2

/// An immutable snapshot. Reloading a file never changes an in-flight translation.
struct TranslatorScript: Sendable {
  static let douban = Self("douban-books")
  static let goodreads = Self("goodreads-books")
  static let openLibrary = Self("open-library")
  static let bundled = [douban, goodreads, openLibrary]

  struct Header: Decodable {
    let translatorID, label, creator, version, targetDescription, search: String
    let priority: Int
    let targets: [Target]
  }
  struct Target: Decodable {
    let hosts: [String]
    let path: String
    let keepQuery: [String]?
    let requireQuery: [String: String]?
    let trailingSlash: Bool?
  }

  let id: String
  let file: URL?
  private struct Contents: Sendable {
    let header: Header
    let source: String
    let digest: String
  }
  private let contents: Result<Contents, Error>
  var fingerprint: String? { try? contents.get().digest }

  private init(_ id: String) {
    self.init(id: id, file: L10n.resourceBundle.url(forResource: id, withExtension: "js", subdirectory: "Translators"))
  }

  init(id: String, file: URL?) {
    self.id = id
    self.file = file
    contents = Result {
      guard let file else { throw CocoaError(.fileNoSuchFile) }
      return try Self.parse(Self.readFile(file), id: id)
    }
  }

  private init(id: String, file: URL, contents: Contents) {
    self.id = id
    self.file = file
    self.contents = .success(contents)
  }

  private static func readFile(_ url: URL) throws -> Data {
    let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let limit = 256 * 1024
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw WebMetadataError.invalidConfiguration(L10n.tr("文件超过 256 KB")) }
    return data
  }

  private static func digest(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).base64EncodedString()
  }

  private static func parse(_ data: Data, id: String) throws -> Contents {
    guard let source = String(data: data, encoding: .utf8), source.hasPrefix("/*"),
      let end = source.range(of: "*/") else { throw WebMetadataError.unexpectedContent }
    let header = try JSONDecoder().decode(Header.self, from: Data(source.dropFirst(2)[..<end.lowerBound].utf8))
    guard header.translatorID == id else { throw WebMetadataError.invalidConfiguration(L10n.tr("文件名与 ID 不一致或 ID 已占用")) }
    // Validate edits without evaluating top-level user code during reload.
    guard let context = JSContext(), let script = JSStringCreateWithCFString(source as CFString) else {
      throw WebMetadataError.unexpectedContent
    }
    defer { JSStringRelease(script) }
    var exception: JSValueRef?
    guard JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, &exception) else {
      let details = exception.flatMap { JSValue(jsValueRef: $0, in: context)?.toString() }
      throw WebMetadataError.invalidConfiguration(details ?? "JavaScript")
    }
    return Contents(header: header, source: source, digest: digest(data))
  }

  /// Install missing factory files and update only copies matching the previous installed factory hash.
  func installed(in directory: URL, defaults: UserDefaults) throws -> Self {
    let factory = try contents.get()
    let destination = directory.appendingPathComponent(id + ".js")
    let key = "translator.shippedHash." + id
    var coordinationError: NSError?
    var result: Result<Self, Error>?
    NSFileCoordinator().coordinate(writingItemAt: destination, options: [], error: &coordinationError) { url in
      result = Result {
        let local: Data?
        do { local = try Self.readFile(url) }
        catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) { local = nil }
        let shipped = Data(factory.source.utf8)
        let previous = defaults.string(forKey: key)
        if let local, local != shipped, Self.digest(local) != previous {
          return Self(id: id, file: url, contents: try Self.parse(local, id: id))
        }
        if local != shipped { try shipped.write(to: url, options: .atomic) }
        if previous != factory.digest { defaults.set(factory.digest, forKey: key) }
        // The byte comparison above also covers an existing copy on first install.
        return Self(id: id, file: url, contents: factory)
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw CocoaError(.fileReadUnknown) }
    return try result.get()
  }

  var descriptor: TranslatorDescriptor {
    let header = try? contents.get().header
    return TranslatorDescriptor(id: id, name: L10n.tr(InterfaceText(stringLiteral: header?.label ?? id)),
      version: header?.version ?? "—", author: header?.creator ?? "—",
      targetDescription: L10n.tr(InterfaceText(stringLiteral: header?.targetDescription ?? "")), priority: header?.priority ?? 10000)
  }

  func searchURL(for query: BookMetadataQuery) throws -> URL {
    let header = try contents.get().header
    guard var parts = URLComponents(string: header.search) else { throw BookMetadataError.invalidURL }
    parts.queryItems = parts.queryItems?.map { item in
      URLQueryItem(name: item.name, value: item.value == "{query}" ? query.text : item.value)
    }
    // A literal plus in a title must survive servers which decode '+' as a space.
    parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let url = parts.url.flatMap(WebURLPolicy.normalized) else { throw BookMetadataError.invalidURL }
    return url
  }

  func canonicalURL(for url: URL) -> URL? {
    guard let targets = try? contents.get().header.targets, let safe = WebURLPolicy.normalized(url),
      let host = safe.host, var parts = URLComponents(url: safe, resolvingAgainstBaseURL: false) else { return nil }
    for target in targets where target.hosts.contains(host) {
      guard parts.path.range(of: target.path, options: .regularExpression) != nil,
        (target.requireQuery ?? [:]).allSatisfy({ name, value in
          parts.queryItems?.first(where: { $0.name == name })?.value == value
        }) else { continue }
      parts.host = target.hosts.first
      if target.trailingSlash == true && !parts.path.hasSuffix("/") { parts.path += "/" }
      let keep = target.keepQuery ?? []
      let query = parts.percentEncodedQueryItems?.filter { keep.contains($0.name.removingPercentEncoding ?? $0.name) }
      parts.percentEncodedQueryItems = query?.isEmpty == false ? query : nil
      return parts.url
    }
    return nil
  }

  static func urlInfo(_ url: URL) -> [String: Any] {
    var query: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where query[item.name] == nil {
      query[item.name] = item.value
    }
    return ["href": url.absoluteString, "path": url.path, "host": url.host ?? "", "query": query]
  }

  func call<Value: Decodable>(_ function: String, _ arguments: [Any], document: HTMLMetadataDocument? = nil,
    as type: Value.Type = Value.self) throws -> Value {
    let source = try contents.get().source
    guard let context = JSContext() else { throw WebMetadataError.unexpectedContent }
    let resolve: @convention(block) (String, String, Bool) -> [String: Any]? = { href, base, canonical in
      guard !href.isEmpty, let url = URL(string: href, relativeTo: URL(string: base))?.absoluteURL,
        let safe = canonical ? canonicalURL(for: url) : WebURLPolicy.normalized(url) else { return nil }
      return Self.urlInfo(safe)
    }
    let isbn: @convention(block) (String) -> String? = { ISBN.normalized($0) }
    let plain: @convention(block) (String) -> String? = { html in
      guard !html.isEmpty, let fragment = try? HTMLMetadataDocument(data: Data(("<html><body>" + html + "</body></html>").utf8)),
        let body = fragment.first("//body") else { return nil }
      return fragment.lines(of: body).joined(separator: "\n\n")
    }
    let credit: @convention(block) (String) -> String = { L10n.tr("页面署名：\($0)") }
    context.setObject(resolve, forKeyedSubscript: "_resolve" as NSString)
    context.setObject(isbn, forKeyedSubscript: "_isbn" as NSString)
    context.setObject(plain, forKeyedSubscript: "plainHTML" as NSString)
    context.setObject(credit, forKeyedSubscript: "creditLine" as NSString)
    if let document { ScriptDocument(document).install(in: context) }
    context.evaluateScript(Self.helpers)
    context.evaluateScript(source, withSourceURL: file)
    try check(context)
    var inputs = arguments
    if document != nil, let doc = context.objectForKeyedSubscript("doc") { inputs.insert(doc, at: 0) }
    guard let result = context.objectForKeyedSubscript(function)?.call(withArguments: inputs) else {
      throw WebMetadataError.unexpectedContent
    }
    try check(context)
    let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [result])
    try check(context)
    guard let json, !json.isUndefined, let text = json.toString() else { throw WebMetadataError.unexpectedContent }
    return try JSONDecoder().decode(type, from: Data(text.utf8))
  }

  private func check(_ context: JSContext) throws {
    guard let exception = context.exception else { return }
    switch exception.toString() {
    case "accessRestricted": throw WebMetadataError.accessRestricted
    case "noBook": throw WebMetadataError.noBook
    case "noBooks": throw WebMetadataError.noBooks
    case "editionMismatch": throw WebMetadataError.editionMismatch
    case "invalidResponse": throw BookMetadataError.invalidResponse
    default: throw WebMetadataError.unexpectedContent
    }
  }

  private static let helpers = """
    function clean(value) { return typeof value === "string" && value.trim() || null; }
    function normalizeISBN(value) { return typeof value === "string" ? _isbn(value) : null; }
    function parseJSON(text) { try { return JSON.parse(text); } catch { return null; } }
    function record(fields) { return {authors: [], translators: [], sourceName: "", ...fields}; }
    function resolveURL(href, base) { return typeof href === "string" ? _resolve(href, base, false) : null; }
    function canonicalLink(href, base) { return typeof href === "string" ? _resolve(href, base, true) : null; }
    var doc = {
      nodes: (path, root = -1) => _nodes(path, root),
      first: (path, root = -1) => _nodes(path, root)[0] || 0,
      text: (path, root = -1) => _value(_nodes(path, root)[0] || 0) || null,
      value: node => _value(node), raw: node => _raw(node), lines: node => _lines(node),
      attr: (node, name) => _attr(node, name)
    };
    function bookLinks(doc, url, path, keyForLink) {
      const results = [], seen = new Set();
      for (const node of doc.nodes(path)) {
        const link = canonicalLink(doc.attr(node, "href"), url.href);
        const key = link && keyForLink(link);
        if (!key || seen.has(key)) continue;
        const title = doc.attr(node, "title") || doc.value(node) || doc.attr(doc.first(".//img", node), "alt");
        if (!title) continue;
        seen.add(key);
        results.push({title, url: link.href});
        if (results.length === 60) break;
      }
      return results;
    }
    """
}

/// libxml pointers remain private. Zero means no node, and -1 selects the document root.
private final class ScriptDocument {
  let document: HTMLMetadataDocument
  var handles: [xmlNodePtr] = []
  init(_ document: HTMLMetadataDocument) { self.document = document }
  func node(_ handle: Int) -> xmlNodePtr? { handle > 0 && handle <= handles.count ? handles[handle - 1] : nil }
  func install(in context: JSContext) {
    let nodes: @convention(block) (String, Int) -> [Int] = { [self] path, root in
      guard root == -1 || node(root) != nil else { return [] }
      let start = handles.count
      handles.append(contentsOf: document.nodes(path, from: node(root)))
      return (start..<handles.count).map { $0 + 1 }
    }
    let value: @convention(block) (Int) -> String = { [self] in node($0).map(document.text(of:)) ?? "" }
    let raw: @convention(block) (Int) -> String = { [self] in node($0).map(document.rawText(of:)) ?? "" }
    let lines: @convention(block) (Int) -> [String] = { [self] in node($0).map(document.lines(of:)) ?? [] }
    let attr: @convention(block) (Int, String) -> String? = { [self] in document.attribute($1, of: node($0)) }
    for (name, block) in [("_nodes", nodes as Any), ("_value", value as Any), ("_raw", raw as Any),
      ("_lines", lines as Any), ("_attr", attr as Any)] {
      context.setObject(block, forKeyedSubscript: name as NSString)
    }
  }
}
