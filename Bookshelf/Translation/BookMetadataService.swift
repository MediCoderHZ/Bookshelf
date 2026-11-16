import Foundation

struct BookMetadataSearchResult: Identifiable, Sendable {
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

  func search(_ query: BookMetadataQuery) async throws -> [BookMetadataSearchResult]
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

  func search(_ query: BookMetadataQuery) async throws -> [BookMetadataSearchResult] {
    switch query {
    case .isbn(let isbn):
      return try await searchISBN(isbn)
    case .title(let title):
      return try await searchTitle(title)
    }
  }

  private func searchTitle(_ title: String) async throws -> [BookMetadataSearchResult] {
    var components = URLComponents(string: "https://openlibrary.org/search.json")
    components?.queryItems = [
      URLQueryItem(name: "title", value: title),
      URLQueryItem(
        name: "fields",
        value:
          "key,title,subtitle,author_name,first_publish_year,publisher,publish_date,isbn,number_of_pages_median,language"
      ),
      URLQueryItem(name: "lang", value: "zh"),
      URLQueryItem(name: "limit", value: "15"),
    ]
    guard let url = components?.url else { throw BookMetadataError.invalidURL }

    let (data, response) = try await session.data(from: url)
    try Self.validate(response: response)
    return try Self.decodeSearchResponse(data)
  }

  private func searchISBN(_ isbn: String) async throws -> [BookMetadataSearchResult] {
    var components = URLComponents(string: "https://openlibrary.org/api/books")
    components?.queryItems = [
      URLQueryItem(name: "bibkeys", value: "ISBN:\(isbn)"),
      URLQueryItem(name: "jscmd", value: "data"),
      URLQueryItem(name: "format", value: "json"),
    ]
    guard let url = components?.url else { throw BookMetadataError.invalidURL }

    let (data, response) = try await session.data(from: url)
    try Self.validate(response: response)
    return try Self.decodeISBNResponse(data, requestedISBN: isbn)
  }

  static func decodeSearchResponse(_ data: Data) throws -> [BookMetadataSearchResult] {
    let response = try JSONDecoder().decode(OpenLibrarySearchResponse.self, from: data)
    return response.docs.compactMap { document in
      let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { return nil }

      let isbn10 = document.isbn?.first { ISBN.normalized($0)?.count == 10 }
      let isbn13 = document.isbn?.first { ISBN.normalized($0)?.count == 13 }

      return BookMetadataSearchResult(
        id: document.key ?? "\(title)-\(document.authorName?.first ?? "")",
        title: title,
        subtitle: document.subtitle?.nilIfBlank,
        authors: document.authorName ?? [],
        publisher: document.publisher?.first?.nilIfBlank,
        publicationDate: document.publishDate?.first?.nilIfBlank
          ?? document.firstPublishYear.map(String.init),
        isbn10: isbn10.flatMap(ISBN.normalized),
        isbn13: isbn13.flatMap(ISBN.normalized),
        pageCount: document.numberOfPagesMedian,
        languageCode: document.language?.first.flatMap(Self.languageCode),
        sourceName: "Open Library"
      )
    }
  }

  static func decodeISBNResponse(
    _ data: Data,
    requestedISBN: String
  ) throws -> [BookMetadataSearchResult] {
    let records = try JSONDecoder().decode([String: OpenLibraryISBNRecord].self, from: data)
    return records.sorted(by: { $0.key < $1.key }).compactMap { key, record in
      let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { return nil }

      let allISBN10 = record.identifiers?.isbn10 ?? []
      let allISBN13 = record.identifiers?.isbn13 ?? []
      let fallbackISBN = ISBN.normalized(requestedISBN)

      return BookMetadataSearchResult(
        id: key,
        title: title,
        subtitle: record.subtitle?.nilIfBlank,
        authors: record.authors?.map(\.name) ?? [],
        publisher: record.publishers?.first?.name.nilIfBlank,
        publicationDate: record.publishDate?.nilIfBlank,
        isbn10: allISBN10.first.flatMap(ISBN.normalized)
          ?? (fallbackISBN?.count == 10 ? fallbackISBN : nil),
        isbn13: allISBN13.first.flatMap(ISBN.normalized)
          ?? (fallbackISBN?.count == 13 ? fallbackISBN : nil),
        pageCount: record.numberOfPages,
        languageCode: nil,
        sourceName: "Open Library"
      )
    }
  }

  private static func validate(response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse else {
      throw BookMetadataError.invalidResponse
    }
    guard (200...299).contains(response.statusCode) else {
      throw BookMetadataError.httpStatus(response.statusCode)
    }
  }

  private static func languageCode(_ value: String) -> String? {
    switch value.lowercased() {
    case "chi", "zho": "zh-Hans"
    case "eng": "en"
    case "jpn": "ja"
    case "kor": "ko"
    case "fre", "fra": "fr"
    case "ger", "deu": "de"
    case "spa": "es"
    default: value.nilIfBlank
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

private struct OpenLibrarySearchResponse: Decodable {
  let docs: [OpenLibrarySearchDocument]
}

private struct OpenLibrarySearchDocument: Decodable {
  let key: String?
  let title: String
  let subtitle: String?
  let authorName: [String]?
  let firstPublishYear: Int?
  let publisher: [String]?
  let publishDate: [String]?
  let isbn: [String]?
  let numberOfPagesMedian: Int?
  let language: [String]?

  enum CodingKeys: String, CodingKey {
    case key, title, subtitle, publisher, isbn, language
    case authorName = "author_name"
    case firstPublishYear = "first_publish_year"
    case publishDate = "publish_date"
    case numberOfPagesMedian = "number_of_pages_median"
  }
}

private struct OpenLibraryISBNRecord: Decodable {
  struct NamedValue: Decodable {
    let name: String
  }

  struct Identifiers: Decodable {
    let isbn10: [String]?
    let isbn13: [String]?

    enum CodingKeys: String, CodingKey {
      case isbn10 = "isbn_10"
      case isbn13 = "isbn_13"
    }
  }

  let title: String
  let subtitle: String?
  let authors: [NamedValue]?
  let publishers: [NamedValue]?
  let publishDate: String?
  let numberOfPages: Int?
  let identifiers: Identifiers?

  enum CodingKeys: String, CodingKey {
    case title, subtitle, authors, publishers, identifiers
    case publishDate = "publish_date"
    case numberOfPages = "number_of_pages"
  }
}

extension String {
  fileprivate var nilIfBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
