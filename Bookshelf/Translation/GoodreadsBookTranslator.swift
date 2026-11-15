import Foundation

struct GoodreadsBookTranslator: BookSearchTranslator {
  let descriptor = TranslatorDescriptor(
    id: "goodreads-books", name: "Goodreads", version: "1.1.0", author: "Bookshelf",
    targetDescription: "goodreads.com 图书详情、首页、搜索、公开图书列表与书架分类页", priority: 100)

  func canonicalURL(for url: URL) -> URL? {
    guard let safe = WebURLPolicy.normalized(url), ["www.goodreads.com", "goodreads.com"].contains(safe.host),
      var components = URLComponents(url: safe, resolvingAgainstBaseURL: false) else { return nil }
    let path = safe.path
    let detail = Self.bookID(safe) != nil
    let search = path == "/search" || path == "/search/index"
    let list = path.range(of: #"^/(list/show/[0-9]+([.\-][^/]+)?|shelf/show/[^/]+)/?$"#, options: .regularExpression) != nil
    guard path == "/" || detail || search || list else { return nil }
    components.host = "www.goodreads.com"
    if detail || path == "/" { components.query = nil }
    else {
      components.queryItems = components.queryItems?.filter { ["q", "search_type", "page"].contains($0.name) }
      if components.queryItems?.isEmpty == true { components.query = nil }
    }
    return components.url
  }

  static func bookID(_ url: URL) -> String? {
    guard ["www.goodreads.com", "goodreads.com"].contains(url.host),
      url.path.range(of: #"^/book/show/[0-9]+([.\-][^/]+)?/?$"#, options: .regularExpression) != nil else { return nil }
    let component = url.path.dropFirst("/book/show/".count)
    let id = String(component.prefix { $0.isASCII && $0.isNumber })
    return id.isEmpty ? nil : id
  }

  func searchURL(for query: BookMetadataQuery) -> URL {
    var url = URLComponents(string: "https://www.goodreads.com/search")!
    url.queryItems = [URLQueryItem(name: "q", value: query.text), URLQueryItem(name: "search_type", value: "books")]
    return url.url!
  }

  func searchResults(in document: HTMLMetadataDocument, url: URL) throws -> [WebBookCandidate] {
    _ = try detectWeb(in: document, url: url) // Includes access/verification detection.
    guard document.first("//input[@id='search_query'] | //form[@action='/search']") != nil else { throw WebMetadataError.noBook }
    var seen = Set<String>()
    return Array(document.nodes("//tr[.//a[contains(concat(' ', normalize-space(@class), ' '), ' bookTitle ')]]").compactMap { row in
      guard let anchor = document.first(".//a[contains(concat(' ', normalize-space(@class), ' '), ' bookTitle ')]", from: row),
        let href = document.attribute("href", of: anchor), let linked = URL(string: href, relativeTo: url)?.absoluteURL,
        let canonical = canonicalURL(for: linked), let id = Self.bookID(canonical), seen.insert(id).inserted,
        !document.text(of: anchor).isEmpty else { return nil }
      let names = document.nodes(".//a[contains(concat(' ', normalize-space(@class), ' '), ' authorName ')]", from: row)
        .map { document.text(of: $0) }.filter { !$0.isEmpty }
      return WebBookCandidate(title: document.text(of: anchor), url: canonical,
        summary: names.isEmpty ? nil : "页面署名：" + names.joined(separator: "、"))
    }.prefix(20))
  }

  func detectWeb(in document: HTMLMetadataDocument, url: URL) throws -> WebPageKind? {
    let title = document.text("//head/title")?.lowercased() ?? ""
    let heading = document.text("//h1")?.lowercased() ?? ""
    if ["javascript is disabled", "just a moment", "access denied", "robot check"].contains(where: title.contains)
      || heading.contains("javascript is disabled")
      || document.first("//*[@id='challenge-form' or @id='captcha' or @id='captcha-container']") != nil {
      throw WebMetadataError.accessRestricted
    }
    if let id = Self.bookID(url) {
      let state = pageState(document)
      if state.book(id: id) != nil { return .book }
      if state.books.contains(where: { $0.title != nil }) { throw GoodreadsError.editionMismatch }
      return structuredBook(document, id: id) != nil
        || document.first("//h1[@data-testid='bookTitle' or @id='bookTitle']") != nil ? .book : nil
    }
    return candidates(document, url: url).isEmpty ? nil : .multiple
  }

  func doWeb(in document: HTMLMetadataDocument, url: URL, kind: WebPageKind) throws -> TranslatedWebPage {
    if kind == .multiple { return .choices(candidates(document, url: url)) }
    guard let id = Self.bookID(url) else { throw WebMetadataError.noBook }
    let state = pageState(document)
    let book = state.book(id: id)
    if book == nil && state.books.contains(where: { $0.title != nil }) { throw GoodreadsError.editionMismatch }
    let ld = structuredBook(document, id: id) ?? [:]
    guard let title = nonblank(book?.title) ?? nonblank(ld["name"] as? String)
      ?? document.text("//h1[@data-testid='bookTitle' or @id='bookTitle']") else { throw WebMetadataError.noBook }

    var authors: [String] = []
    var translators: [String] = []
    if let book {
      let edges = [book.primaryContributorEdge].compactMap { $0 } + (book.secondaryContributorEdges ?? [])
      for edge in edges {
        guard let reference = edge.node?.reference, let name = nonblank(state.contributors[reference]?.name) else { continue }
        // Editors, narrators, illustrators and introduction writers are not authors.
        switch edge.role?.lowercased() {
        case "author": authors.append(name)
        case "translator", "translation": translators.append(name)
        default: break
        }
      }
    } else {
      authors = names(ld["author"])
      translators = names(ld["translator"])
    }
    if authors.isEmpty && book == nil && ld.isEmpty {
      // Legacy DOM fallback only accepts author-marked elements, not all contributors.
      authors = document.nodes("//*[@id='bookAuthors']//*[@itemprop='author']//*[@itemprop='name']")
        .map { document.text(of: $0) }
    }

    // Apollo Book.details describes this edition. Work.details and the visible
    // 'First published' text describe the work and must not fill edition fields.
    let details = book?.details
    let isbn10 = validISBN(details?.isbn ?? (book == nil ? ld["isbn"] as? String : nil), length: 10)
    let isbn13 = validISBN(details?.isbn13 ?? details?.isbn ?? (book == nil ? ld["isbn"] as? String : nil), length: 13)
    let publisher = book != nil ? nonblank(details?.publisher) : names(ld["publisher"]).first
    let date = book != nil ? details?.publicationTime.flatMap(Self.publicationDate) : nonblank(ld["datePublished"] as? String)
    let pageCount = (book != nil ? details?.numPages : integer(ld["numberOfPages"]))
      .flatMap { $0 > 0 ? $0 : nil }
    let language = book != nil ? details?.language?.name : (ld["inLanguage"] as? String)
    let originalTitle = book?.work?.reference.flatMap { state.works[$0]?.details?.originalTitle }
    var description = (book?.description ?? (ld["description"] as? String)).flatMap(plainHTML)
    if description == nil, let node = document.first("//*[@data-testid='description']//*[@data-testid='contentContainer']") {
      description = nonblank(document.lines(of: node).joined(separator: "\n\n"))
    }
    return .book(BookMetadataSearchResult(
      id: "goodreads:\(id)", title: title, subtitle: nil, authors: unique(authors),
      publisher: publisher, publicationDate: date, isbn10: isbn10, isbn13: isbn13,
      pageCount: pageCount, languageCode: languageCode(language), sourceName: descriptor.name,
      translators: unique(translators), originalTitle: nonblank(originalTitle), bookDescription: description, sourceURL: url))
  }

  private func candidates(_ document: HTMLMetadataDocument, url: URL) -> [WebBookCandidate] {
    var seen = Set<String>()
    return Array(document.nodes("//a[contains(@href, '/book/show/')]").compactMap { node -> WebBookCandidate? in
      guard let href = document.attribute("href", of: node),
        let linked = URL(string: href, relativeTo: url)?.absoluteURL,
        let canonical = canonicalURL(for: linked), let id = Self.bookID(canonical),
        let title = nonblank(document.attribute("title", of: node)) ?? nonblank(document.text(of: node))
          ?? nonblank(document.attribute("alt", of: document.first(".//img", from: node))),
        seen.insert(id).inserted else { return nil }
      return WebBookCandidate(title: title, url: canonical)
    }.prefix(60))
  }

  private func pageState(_ document: HTMLMetadataDocument) -> GoodreadsApolloState {
    guard let node = document.first("//script[@id='__NEXT_DATA__']"),
      let data = document.rawText(of: node).data(using: .utf8),
      let next = try? JSONDecoder().decode(GoodreadsNextData.self, from: data)
    else { return GoodreadsApolloState() }
    return next.props?.pageProps?.apolloState ?? GoodreadsApolloState()
  }

  private func structuredBook(_ document: HTMLMetadataDocument, id: String) -> [String: Any]? {
    var books: [[String: Any]] = []
    func collect(_ value: Any) {
      if let array = value as? [Any] { array.forEach(collect); return }
      guard let object = value as? [String: Any] else { return }
      let types = (object["@type"] as? [String]) ?? [object["@type"] as? String ?? ""]
      if types.contains(where: { $0 == "Book" || $0 == "https://schema.org/Book" || $0 == "http://schema.org/Book" }) { books.append(object) }
      if let graph = object["@graph"] { collect(graph) }
    }
    for node in document.nodes("//script[@type='application/ld+json']") {
      if let data = document.rawText(of: node).data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) { collect(json) }
    }
    let matching = books.first { object in
      [object["url"], object["@id"]].compactMap { $0 as? String }.contains { value in
        URL(string: value).flatMap(Self.bookID) == id
      }
    }
    if let matching { return matching }
    // An unlabelled singleton is the page's Book schema. Never pick a random
    // recommendation from multiple Book objects or an explicitly different ID.
    guard books.count == 1, books[0]["url"] == nil, books[0]["@id"] == nil else { return nil }
    return books[0]
  }

  private func plainHTML(_ html: String) -> String? {
    guard let document = try? HTMLMetadataDocument(data: Data(("<html><body>" + html + "</body></html>").utf8)),
      let body = document.first("//body") else { return nil }
    return nonblank(document.lines(of: body).joined(separator: "\n\n"))
  }

  private func names(_ value: Any?) -> [String] {
    if let array = value as? [Any] { return array.flatMap { names($0) } }
    if let object = value as? [String: Any] { return nonblank(object["name"] as? String).map { [$0] } ?? [] }
    return nonblank(value as? String).map { [$0] } ?? []
  }

  private func integer(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    return (value as? String).flatMap(Int.init)
  }
  private func nonblank(_ value: String?) -> String? {
    let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return text?.isEmpty == false ? text : nil
  }
  private func validISBN(_ value: String?, length: Int) -> String? {
    guard let isbn = ISBN.normalized(value), isbn.count == length else { return nil }
    return isbn
  }
  private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap(nonblank).filter { seen.insert($0).inserted }
  }
  private func languageCode(_ value: String?) -> String? {
    guard let value = nonblank(value) else { return nil }
    let known = ["english": "en", "chinese": "zh", "french": "fr", "german": "de", "spanish": "es",
      "japanese": "ja", "korean": "ko", "italian": "it", "portuguese": "pt", "russian": "ru"]
    return known[value.lowercased()] ?? (value.range(of: #"^[a-z]{2,3}(-[A-Za-z]{2,8})?$"#, options: .regularExpression) != nil ? value : nil)
  }
  private static func publicationDate(_ milliseconds: Double) -> String? {
    guard milliseconds.isFinite, abs(milliseconds) < 253_402_214_400_000 else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
  }
}

// Decode only bibliographic cache records. Page authentication/ad/user objects
// are ignored; no embedded token is retained, logged, or used for API calls.
private struct GoodreadsNextData: Decodable {
  let props: Props?
  struct Props: Decodable { let pageProps: PageProps? }
  struct PageProps: Decodable { let apolloState: GoodreadsApolloState? }
}
private struct GoodreadsApolloState: Decodable {
  var books: [BookRecord] = []
  var contributors: [String: Contributor] = [:]
  var works: [String: Work] = [:]
  init() {}
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    for key in container.allKeys {
      if key.stringValue.hasPrefix("Book:"), let book = try? container.decode(BookRecord.self, forKey: key) { books.append(book) }
      if key.stringValue.hasPrefix("Contributor:"), let person = try? container.decode(Contributor.self, forKey: key) { contributors[key.stringValue] = person }
      if key.stringValue.hasPrefix("Work:"), let work = try? container.decode(Work.self, forKey: key) { works[key.stringValue] = work }
    }
  }
  func book(id: String) -> BookRecord? { books.first { $0.legacyId.map(String.init) == id && $0.title != nil } }
  struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
  struct Reference: Decodable {
    let reference: String?
    enum CodingKeys: String, CodingKey { case reference = "__ref" }
  }
  struct Contributor: Decodable { let name: String? }
  struct Edge: Decodable { let node: Reference?; let role: String? }
  struct BookRecord: Decodable {
    let legacyId: Int64?
    let title: String?
    let description: String?
    let primaryContributorEdge: Edge?
    let secondaryContributorEdges: [Edge]?
    let details: Details?
    let work: Reference?
  }
  struct Details: Decodable {
    let publisher: String?
    let publicationTime: Double?
    let isbn: String?
    let isbn13: String?
    let numPages: Int?
    let language: Language?
  }
  struct Language: Decodable { let name: String? }
  struct Work: Decodable {
    let details: Details?
    struct Details: Decodable { let originalTitle: String? }
  }
}

private enum GoodreadsError: LocalizedError {
  case editionMismatch
  var errorDescription: String? {
    "Goodreads 页面数据与链接中的图书 ID 不一致。请核对版本，并使用该页面原始链接重新提取。"
  }
}
