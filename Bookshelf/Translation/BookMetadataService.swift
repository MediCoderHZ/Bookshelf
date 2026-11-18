import Foundation

struct BookMetadataSearchResult: Identifiable, Sendable, Decodable {
  let id: String
  let title: String
  let subtitle: String?
  let authors: [String]
  let publisher: String?
  let publicationDate: String?
  let isbn10: String?
  let isbn13: String?
  let pageCount: Int?
  let languageCode: String?
  var sourceName: String
  var translators: [String] = []
  var originalTitle: String? = nil
  var bookDescription: String? = nil
  var sourceURL: URL? = nil

  var preferredISBN: String? {
    isbn13 ?? isbn10
  }
}

enum BookMetadataQuery: Equatable, Sendable {
  case isbn(String)
  case title(String)

  var text: String {
    switch self { case .isbn(let value), .title(let value): value }
  }

  var scriptValue: [String: String] {
    switch self {
    case .isbn(let value): ["kind": "isbn", "text": value]
    case .title(let value): ["kind": "title", "text": value]
    }
  }

  init?(_ rawValue: String) {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    if let normalizedISBN = ISBN.normalized(value),
      normalizedISBN.count == 10 || normalizedISBN.count == 13
    {
      self = .isbn(normalizedISBN)
    } else {
      self = .title(value)
    }
  }
}

protocol BookMetadataProvider: Sendable {
  var displayName: String { get }

  func search(_ query: BookMetadataQuery, script: TranslatorScript) async throws -> [BookMetadataSearchResult]
}

struct OpenLibraryBookMetadataProvider: BookMetadataProvider {
  let displayName = "Open Library"

  private let session: URLSession

  init(session: URLSession? = nil) {
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 15
      configuration.timeoutIntervalForResource = 25
      configuration.waitsForConnectivity = false
      configuration.httpShouldSetCookies = false
      configuration.httpCookieStorage = nil
      configuration.urlCache = URLCache(memoryCapacity: 4 * 1_024 * 1_024, diskCapacity: 0)
      configuration.httpAdditionalHeaders = [
        "Accept": "application/json",
        "User-Agent": AppReleaseInfo.metadataUserAgent,
      ]
      self.session = URLSession(configuration: configuration)
    }
  }

  func search(_ query: BookMetadataQuery, script: TranslatorScript) async throws -> [BookMetadataSearchResult] {
    let value: String = try script.call("requestURL", [query.scriptValue])
    guard let url = URL(string: value), url.host == "openlibrary.org", WebURLPolicy.normalized(url) == url
    else { throw BookMetadataError.invalidURL }
    let (data, response) = try await session.data(for: URLRequest(url: url), delegate: NoWebRedirects())
    try Self.validate(response: response)
    return try Self.decode(data, query: query, script: script)
  }

  static func decode(_ data: Data, query: BookMetadataQuery, script: TranslatorScript) throws -> [BookMetadataSearchResult] {
    guard let json = String(data: data, encoding: .utf8) else { throw BookMetadataError.invalidResponse }
    var books: [BookMetadataSearchResult] = try script.call("doSearch", [query.scriptValue, json])
    for index in books.indices { books[index].sourceName = script.descriptor.name }
    return books
  }

  private static func validate(response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse else {
      throw BookMetadataError.invalidResponse
    }
    guard (200...299).contains(response.statusCode) else {
      throw BookMetadataError.httpStatus(response.statusCode)
    }
  }

}

enum BookMetadataError: LocalizedError {
  case invalidURL
  case invalidResponse
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      L10n.tr("无法创建检索地址。")
    case .invalidResponse:
      L10n.tr("书籍数据服务返回了无效响应。")
    case .httpStatus(let statusCode):
      statusCode == 429 ? L10n.tr("搜索过于频繁，请稍后再试。你仍可手动添加书籍。") : L10n.tr("书籍数据服务暂时不可用（HTTP \(statusCode)）。")
    }
  }
}
