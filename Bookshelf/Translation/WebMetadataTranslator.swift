import Foundation

struct TranslatorDescriptor: Identifiable, Sendable {
  let id: String
  let name: String
  let version: String
  let author: String
  let targetDescription: String
  let priority: Int

}

struct WebBookCandidate: Identifiable, Sendable, Decodable {
  let title: String
  let url: URL
  var summary: String? = nil
  var id: String { url.absoluteString }
}

enum WebPageKind: String, Sendable, Decodable { case book, multiple }
enum TranslatedWebPage: Sendable {
  case book(BookMetadataSearchResult)
  case choices([WebBookCandidate])
}
struct WebTranslationResult: Sendable {
  let translator: TranslatorDescriptor
  let sourceURL: URL
  let page: TranslatedWebPage
}

/// Matching and detection never make requests. The host owns networking and persistence.
/// Nil detection tries the next matching translator; extraction errors remain visible.
protocol WebMetadataTranslator: BookTranslator {
  func canonicalURL(for url: URL) -> URL?
  func detectWeb(in document: HTMLMetadataDocument, url: URL) throws -> WebPageKind?
  func doWeb(in document: HTMLMetadataDocument, url: URL, kind: WebPageKind) throws -> TranslatedWebPage
}

/// Optional capability for compiled translators. Search only discovers candidates;
/// the same translator reads a selected edition's detail page afterwards.
protocol BookSearchTranslator: WebMetadataTranslator, SearchMetadataTranslator {
  func searchResults(in document: HTMLMetadataDocument, url: URL) throws -> [WebBookCandidate]
}
extension WebMetadataTranslator {
  func translate(html: Data, url: URL) throws -> TranslatedWebPage {
    guard let canonical = canonicalURL(for: url) else { throw WebMetadataError.unsupportedURL }
    let document = try HTMLMetadataDocument(data: html)
    guard let kind = try detectWeb(in: document, url: canonical) else { throw WebMetadataError.noBook }
    return try doWeb(in: document, url: canonical, kind: kind)
  }
}

/// Factory catalog for isolated callers. The application uses the installed catalog from TranslatorStore.
enum BuiltinTranslators {
  static var all: [any WebMetadataTranslator] { catalog.compactMap { $0 as? any WebMetadataTranslator } }
}

struct WebTranslatorRegistry: Sendable {
  let translators: [any WebMetadataTranslator]
  let disabledIDs: Set<String>

  init(translators: [any WebMetadataTranslator] = BuiltinTranslators.all, disabledIDs: Set<String> = []) {
    self.translators = translators
    self.disabledIDs = disabledIDs
  }

  func matching(_ input: String, includingDisabled: Bool = false) throws -> [any WebMetadataTranslator] {
    guard Set(translators.map(\.descriptor.id)).count == translators.count else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("解析器 ID 重复"))
    }
    guard let raw = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
      let url = WebURLPolicy.normalized(raw) else { throw WebMetadataError.unsupportedURL }
    return translators.filter {
      (includingDisabled || !disabledIDs.contains($0.descriptor.id)) && $0.canonicalURL(for: url) != nil
    }.sorted {
      if $0.descriptor.priority == $1.descriptor.priority { return $0.descriptor.id < $1.descriptor.id }
      return $0.descriptor.priority < $1.descriptor.priority
    }
  }

  func resolve(_ input: String) throws -> (any WebMetadataTranslator, URL) {
    guard let translator = try matching(input).first else {
      if !(try matching(input, includingDisabled: true)).isEmpty { throw WebMetadataError.disabled }
      throw WebMetadataError.unsupportedURL
    }
    guard let raw = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
      let normalized = WebURLPolicy.normalized(raw),
      let canonical = translator.canonicalURL(for: normalized), let url = WebURLPolicy.normalized(canonical)
    else { throw WebMetadataError.unsupportedURL }
    return (translator, url)
  }

  func translate(html: Data, sourceURL input: String) throws -> WebTranslationResult {
    let (_, url) = try resolve(input)
    let document = try HTMLMetadataDocument(data: html)
    for translator in try matching(url.absoluteString) {
      guard let kind = try translator.detectWeb(in: document, url: url) else { continue }
      let page = try translator.doWeb(in: document, url: url, kind: kind)
      let checked: TranslatedWebPage
      switch page {
      case .book(var book):
        guard !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebMetadataError.noBook }
        book.sourceName = translator.descriptor.name
        book.sourceURL = url
        checked = .book(book)
      case .choices(let choices):
        var seen = Set<URL>()
        let valid = choices.compactMap { choice -> WebBookCandidate? in
          guard let canonical = translator.canonicalURL(for: choice.url),
            let safeURL = WebURLPolicy.normalized(canonical),
            !choice.title.isEmpty, seen.insert(safeURL).inserted else { return nil }
          return WebBookCandidate(title: choice.title, url: safeURL)
        }
        guard !valid.isEmpty else { throw WebMetadataError.noBooks }
        checked = .choices(Array(valid.prefix(60)))
      }
      return WebTranslationResult(translator: translator.descriptor, sourceURL: url, page: checked)
    }
    throw WebMetadataError.noBook
  }

}

enum WebURLPolicy {
  static func validHost(_ value: String) -> Bool {
    let labels = value.split(separator: ".", omittingEmptySubsequences: false)
    return value == value.lowercased() && value.count <= 253 && labels.count >= 2
      && !["localhost", "local", "internal", "lan", "home", "arpa"].contains(String(labels.last ?? ""))
      && labels.last?.contains(where: { $0.isASCII && $0.isLetter }) == true
      && labels.allSatisfy { label in
        !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
          && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
      }
  }

  static func normalized(_ url: URL) -> URL? {
    guard url.absoluteString.count <= 4_096,
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host?.lowercased(), validHost(host),
      url.user == nil, url.password == nil, url.port == nil || url.port == 443,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    components.scheme = "https"
    components.host = host
    components.port = nil
    components.fragment = nil
    if components.path.isEmpty { components.path = "/" }
    return components.url
  }
}

enum WebMetadataError: LocalizedError {
  case unsupportedURL, disabled, accessRestricted, noBook, noBooks, tooLarge, unexpectedContent
  case editionMismatch
  case httpStatus(Int)
  case invalidConfiguration(String)
  var errorDescription: String? {
    switch self {
    case .editionMismatch: L10n.tr("Goodreads 页面数据与链接中的图书 ID 不一致。请核对版本，并使用该页面原始链接重新提取。")
    case .unsupportedURL: L10n.tr("没有可用的解析器匹配此链接。请检查网址，或在元信息解析器窗口中安装对应网站的解析规则。")
    case .disabled: L10n.tr("此元信息解析器已停用，请在设置 → 文件与数据库 → 元信息解析器中启用。")
    case .accessRestricted: L10n.tr("网站返回了访问限制或验证页面。请尝试其他来源，或手动填写书籍信息。")
    case .noBook: L10n.tr("匹配的解析器没有识别到书籍。请核对页面、来源链接和解析规则；页面也可能需要验证。")
    case .noBooks: L10n.tr("没有识别到可用的图书链接，请使用图书详情页或检查列表解析规则。")
    case .tooLarge: L10n.tr("页面超出大小限制，已停止读取。")
    case .unexpectedContent: L10n.tr("网站返回的内容格式不符合预期，请在浏览器查看。")
    case .httpStatus(let status): L10n.tr("网站暂时无法返回页面（HTTP \(status)），请稍后再试。")
    case .invalidConfiguration(let reason): L10n.tr("解析规则无效：\(reason)")
    }
  }
}
