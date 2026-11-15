import Foundation

/// Versioned, declarative rule package. XPath is evaluated against an inert local DOM.
/// No JavaScript, shell commands, arbitrary HTTP requests, or file access are available to rules.
struct TranslatorRule: Codable, Sendable, Identifiable {
  let schemaVersion: Int
  let id: String
  let name: String
  let version: String
  let author: String
  let priority: Int
  let targets: [TranslatorURLTarget]
  let book: BookExtractionRule
  let list: ListExtractionRule?

  var descriptor: TranslatorDescriptor {
    TranslatorDescriptor(id: id, name: name, version: version, author: author,
      targetDescription: targets.map { $0.host + $0.pathPrefix }.joined(separator: "、"),
      priority: priority)
  }

  static func decode(_ data: Data) throws -> TranslatorRule {
    guard data.count <= 256 * 1_024 else { throw WebMetadataError.invalidConfiguration("规则文件不能超过 256 KB") }
    let rule: TranslatorRule
    do {
      // Old rule packages may contain image mappings. Discard them before decoding
      // so unrelated metadata rules still work, even if the retired mapping is invalid.
      guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw WebMetadataError.invalidConfiguration("规则须为 JSON 对象")
      }
      object.removeValue(forKey: "coverHosts")
      if var book = object["book"] as? [String: Any], var fields = book["fields"] as? [String: Any] {
        fields.removeValue(forKey: "coverURL"); book["fields"] = fields; object["book"] = book
      }
      rule = try JSONDecoder().decode(TranslatorRule.self, from: JSONSerialization.data(withJSONObject: object))
    }
    catch { throw WebMetadataError.invalidConfiguration("JSON 格式或字段类型不正确：\(error.localizedDescription)") }
    try rule.validate()
    return rule
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  static var example: TranslatorRule {
    TranslatorRule(schemaVersion: 1, id: "example.publisher", name: "示例出版社", version: "1.0.0",
      author: "请替换为规则作者", priority: 100,
      targets: [TranslatorURLTarget(host: "books.example.org", pathPrefix: "/book/"),
        TranslatorURLTarget(host: "books.example.org", pathPrefix: "/catalog")],
      book: BookExtractionRule(detect: "//*[@class='book-detail']", fields: [
        "title": FieldExtractionRule(xpath: "//h1"),
        "authors": FieldExtractionRule(xpath: "//*[@class='author']", splitBy: ["、"]),
        "translators": FieldExtractionRule(xpath: "//*[@class='translator']"),
        "publisher": FieldExtractionRule(xpath: "//*[@class='publisher']"),
        "publicationDate": FieldExtractionRule(xpath: "//*[@class='publication-date']"),
        "isbn": FieldExtractionRule(xpath: "//meta[@name='isbn']/@content"),
        "pageCount": FieldExtractionRule(xpath: "//*[@class='pages']"),
        "description": FieldExtractionRule(xpath: "//*[@class='description']/p")]),
      list: ListExtractionRule(detect: "//*[@class='catalog']", items: "//*[@class='catalog']/a",
        title: ".", url: "@href"))
  }

  func validate() throws {
    func require(_ condition: Bool, _ message: String) throws {
      if !condition { throw WebMetadataError.invalidConfiguration(message) }
    }
    try require(schemaVersion == 1, "不支持规则格式版本 \(schemaVersion)")
    try require(id.range(of: #"^[a-z][a-z0-9.-]{2,63}$"#, options: .regularExpression) != nil, "ID 须为 3–64 位小写字母、数字、点或连字符，并以字母开头")
    try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 100, "名称不能为空或超过 100 字")
    try require(version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil && version.count <= 30, "版本须采用 1.0.0 格式")
    try require(!author.isEmpty && author.count <= 100, "请填写作者，最多 100 字")
    try require((1...10_000).contains(priority), "优先级须为 1–10000，数字越小越优先")
    try require(!targets.isEmpty && targets.count <= 20, "请声明 1–20 个目标网址规则")
    for target in targets {
      try require(WebURLPolicy.validHost(target.host), "目标域名必须为小写 DNS 域名：\(target.host)")
      try require(target.pathPrefix.hasPrefix("/") && target.pathPrefix.count <= 256
        && !target.pathPrefix.contains("?") && !target.pathPrefix.contains("#"), "路径前缀必须以 / 开头，不含查询或片段")
    }
    let fieldNames: Set<String> = ["title", "subtitle", "originalTitle", "authors", "translators", "publisher", "publicationDate", "isbn", "pageCount", "languageCode", "description"]
    try require(book.fields["title"] != nil, "必须声明 title 提取规则")
    try require(Set(book.fields.keys).isSubset(of: fieldNames), "存在未知的书籍字段")
    var expressions = [book.detect]
    for field in book.fields.values {
      expressions.append(field.xpath)
      try require((field.splitBy?.count ?? 0) <= 8
        && (field.splitBy ?? []).allSatisfy { !$0.isEmpty && $0.count <= 16 }, "splitBy 分隔符无效")
    }
    if let list { expressions += [list.detect, list.items, list.title, list.url] }
    try require(expressions.allSatisfy(HTMLMetadataDocument.validateXPath), "XPath 表达式无效或超过 2048 字符")
  }
}

struct TranslatorURLTarget: Codable, Sendable {
  let host: String
  let pathPrefix: String
  var exactPath: Bool? = nil

  func matches(_ url: URL) -> Bool {
    url.host == host && (exactPath == true ? url.path == pathPrefix : url.path.hasPrefix(pathPrefix))
  }
}

struct BookExtractionRule: Codable, Sendable {
  let detect: String
  let fields: [String: FieldExtractionRule]
}

struct FieldExtractionRule: Codable, Sendable {
  let xpath: String
  var splitBy: [String]? = nil
}

struct ListExtractionRule: Codable, Sendable {
  let detect: String
  let items: String
  let title: String
  let url: String
}

struct RuleBasedWebTranslator: WebMetadataTranslator {
  let rule: TranslatorRule
  var descriptor: TranslatorDescriptor { rule.descriptor }

  init(rule: TranslatorRule) throws { try rule.validate(); self.rule = rule }

  func canonicalURL(for url: URL) -> URL? {
    guard let url = WebURLPolicy.normalized(url), rule.targets.contains(where: { $0.matches(url) }) else { return nil }
    return url
  }

  func detectWeb(in document: HTMLMetadataDocument, url: URL) throws -> WebPageKind? {
    if document.first(rule.book.detect) != nil,
      let titleRule = rule.book.fields["title"], document.text(titleRule.xpath) != nil { return .book }
    if let list = rule.list, document.first(list.detect) != nil,
      document.first(list.items) != nil { return .multiple }
    return nil
  }

  func doWeb(in document: HTMLMetadataDocument, url: URL, kind: WebPageKind) throws -> TranslatedWebPage {
    if kind == .multiple, let list = rule.list {
      let items = document.nodes(list.items).compactMap { node -> WebBookCandidate? in
        guard let titleNode = document.first(list.title, from: node),
          let linkNode = document.first(list.url, from: node) else { return nil }
        let title = document.text(of: titleNode)
        guard !title.isEmpty,
          let linked = URL(string: document.text(of: linkNode), relativeTo: url)?.absoluteURL,
          let target = canonicalURL(for: linked) else { return nil }
        return WebBookCandidate(title: title, url: target)
      }
      return .choices(items)
    }
    func values(_ field: String) -> [String] {
      guard let mapping = rule.book.fields[field] else { return [] }
      let values = document.nodes(mapping.xpath).map { document.text(of: $0) }
      return (mapping.splitBy ?? []).reduce(values) { values, separator in
        values.flatMap { $0.components(separatedBy: separator) }
      }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    func value(_ field: String) -> String? { values(field).first }
    guard let title = value("title") else { throw WebMetadataError.noBook }
    let isbn = ISBN.normalized(value("isbn"))
    let pages = value("pageCount").flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
    let paragraphs = values("description")
    return .book(BookMetadataSearchResult(
      id: "\(rule.id):\(url.absoluteString)", title: title, subtitle: value("subtitle"),
      authors: values("authors"), publisher: value("publisher"), publicationDate: value("publicationDate"),
      isbn10: isbn?.count == 10 ? isbn : nil, isbn13: isbn?.count == 13 ? isbn : nil,
      pageCount: pages, languageCode: value("languageCode"), sourceName: rule.name,
      translators: values("translators"), originalTitle: value("originalTitle"),
      bookDescription: paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n"), sourceURL: url))
  }
}
