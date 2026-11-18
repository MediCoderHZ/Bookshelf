import Foundation
import XCTest
@testable import Bookshelf

final class MetadataSearchTests: XCTestCase {
  private let douban = MetadataSearchSource(id: "douban-books", name: "豆瓣图书")
  private let goodreads = MetadataSearchSource(id: "goodreads-books", name: "Goodreads")

  func testQueriesAreEncodedWithoutAddingParameters() throws {
    for translator in [ScriptWebTranslator(script: .douban), ScriptWebTranslator(script: .goodreads)] {
      let url = try translator.searchURL(for: .title("C++ & q=other # 第2版"))
      let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
      XCTAssertEqual(query.first(where: { $0.name == "q" })?.value, "C++ & q=other # 第2版")
      XCTAssertNotNil(translator.canonicalURL(for: url))
      XCTAssertEqual(query.count, 2)
      XCTAssertTrue(url.absoluteString.contains("C%2B%2B"))
    }
    XCTAssertNil(ScriptWebTranslator(script: .douban).canonicalURL(for: URL(string: "https://www.douban.com/search?cat=1002&q=test")!))
    XCTAssertNil(ScriptWebTranslator(script: .douban).canonicalURL(for: URL(string: "https://evil.test/search?cat=1001&q=test")!))
  }

  @MainActor
  func testOpenLibraryISBNUsesInstalledScriptForRequestAndParsing() async throws {
    let name = UUID().uuidString, directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: name) }
    let store = TranslatorStore(directory: directory, defaults: defaults)
    let file = try XCTUnwrap(store.scriptFile(for: "open-library"))
    let source = try String(contentsOf: file, encoding: .utf8)
    let changes = """
      const originalRequest = requestURL, originalSearch = doSearch;
      requestURL = query => originalRequest(query) + "&installed=1";
      doSearch = (query, data) => originalSearch(query, data).map(book => ({...book, subtitle: "Local script"}));
      """
    try (source + "\n" + changes).write(to: file, atomically: true, encoding: .utf8)
    store.reload()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenLibraryFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let service = MetadataSearchService(catalog: store.catalog,
      host: TranslationHost(openLibrary: OpenLibraryBookMetadataProvider(session: session)))
    let hits = try await service.search(.isbn("9780743273565"), source: .openLibrary)
    let book = try await service.resolve(XCTUnwrap(hits.first))
    XCTAssertEqual(book.id, "ISBN:9780743273565")
    XCTAssertEqual(book.title, "Example Edition")
    XCTAssertEqual(book.subtitle, "Local script")
    XCTAssertEqual(book.authors, ["Writer"])
    XCTAssertEqual(book.publisher, "Edition Press")
    XCTAssertEqual(book.isbn10, "0743273567")
    XCTAssertEqual(book.isbn13, "9780743273565")
    XCTAssertEqual(book.sourceName, "Open Library")
  }

  func testDoubanSearchUnwrapsOnlyBookLinksAndDeduplicates() throws {
    let html = Self.doubanSearch + """
      <div class='result'><h3><a href='https://book.douban.com/subject/123/?from=duplicate'>Duplicate</a></h3></div>
      <div class='result'><h3><a href='https://www.douban.com/link2/?url=https%3A%2F%2Fevil.test%2Fsubject%2F456%2F'>External</a></h3></div>
      <div class='result'><h3><a href='https://movie.douban.com/subject/789/'>Movie</a></h3></div>
      <a href='https://book.douban.com/subject/999/'>Recommendation outside search rows</a>
      """
    let t = ScriptWebTranslator(script: .douban)
    let rows = try t.searchResults(in: HTMLMetadataDocument(data: Data(html.utf8)), url: t.searchURL(for: .title("Example")))
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.title, "Example Book")
    XCTAssertEqual(rows.first?.url.absoluteString, "https://book.douban.com/subject/123/")
    XCTAssertEqual(rows.first?.summary, "Writer / Press / 2024")
  }

  func testGoodreadsSearchUsesRankedRowsNotOtherBookLinks() throws {
    let t = ScriptWebTranslator(script: .goodreads)
    let rows = try t.searchResults(in: HTMLMetadataDocument(data: Data(Self.goodreadsSearch.utf8)), url: t.searchURL(for: .title("Example")))
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.url.absoluteString, "https://www.goodreads.com/book/show/123-example")
    XCTAssertEqual(rows.first?.summary, "页面署名：Writer")
  }

  func testEmptySearchIsDifferentFromChallengeOrChangedMarkup() throws {
    let d = ScriptWebTranslator(script: .douban)
    let g = ScriptWebTranslator(script: .goodreads)
    XCTAssertTrue(try d.searchResults(in: HTMLMetadataDocument(data: Data("<div class='search-result'></div>".utf8)),
      url: d.searchURL(for: .title("empty"))).isEmpty)
    XCTAssertTrue(try g.searchResults(in: HTMLMetadataDocument(data: Data("<form action='/search'></form>".utf8)),
      url: g.searchURL(for: .title("empty"))).isEmpty)
    for translator in [d, g] {
      XCTAssertThrowsError(try translator.searchResults(in: HTMLMetadataDocument(data: Data("<h1>Unknown page</h1>".utf8)),
        url: translator.searchURL(for: .title("test"))))
      XCTAssertThrowsError(try translator.searchResults(in: HTMLMetadataDocument(data: Data("<title>安全验证 Just a moment</title>".utf8)),
        url: translator.searchURL(for: .title("test"))))
    }
  }

  func testSearchFetchesOnlyChosenDetailAndRetainsProvenance() async throws {
    let web = SearchWebStub(html: Self.doubanSearch)
    let service = MetadataSearchService(registry: WebTranslatorRegistry(), web: web)
    let hits = try await service.search(.title("Example"), source: douban)
    let before = await web.counts()
    XCTAssertEqual(before.details, 0)
    XCTAssertEqual(hits.count, 1)
    let hit = try XCTUnwrap(hits.first)
    XCTAssertNil(hit.metadata)
    let result = try await service.resolve(hit)
    XCTAssertEqual(result.sourceName, "豆瓣图书")
    XCTAssertEqual(result.sourceURL?.absoluteString, "https://book.douban.com/subject/123/")
    XCTAssertEqual(result.publisher, "Example Press")
    let after = await web.counts()
    XCTAssertEqual(after.details, 1)
  }

  func testDirectISBNResultUsesFinalDetailURLWithoutFetchingAgain() async throws {
    let finalURL = URL(string: "https://www.goodreads.com/book/show/123-example")!
    let web = SearchWebStub(html: Self.goodreadsDetail, finalURL: finalURL)
    let service = MetadataSearchService(registry: WebTranslatorRegistry(), web: web)
    let hits = try await service.search(.isbn("9780743273565"), source: goodreads)
    let book = try await service.resolve(XCTUnwrap(hits.first))
    XCTAssertEqual(book.sourceURL, finalURL)
    XCTAssertEqual(book.publisher, "Example Press")
    XCTAssertNil(MetadataSearchService.isbnNotice(query: .isbn("0743273567"), book: book))
    let counts = await web.counts()
    XCTAssertEqual(counts.pages, 1)
    XCTAssertEqual(counts.details, 0)
  }

  func testDisabledSourcesCannotSearchOrResolve() async throws {
    let web = SearchWebStub(html: Self.doubanSearch)
    let registry = WebTranslatorRegistry(disabledIDs: ["douban-books", "goodreads-books"])
    let service = MetadataSearchService(registry: registry, web: web)
    XCTAssertEqual(service.sources.map(\.id), ["open-library"])
    let batch = await service.batch(.title("test"), source: douban)
    XCTAssertNotNil(batch.error)
    let book = Self.book()
    do {
      _ = try await service.resolve(MetadataSearchHit(source: douban, candidate: nil, metadata: book))
      XCTFail("Disabled cached result must not resolve")
    } catch {}
    let counts = await web.counts()
    XCTAssertEqual(counts.pages + counts.details, 0)
  }

  func testFailureInOneSourcePreservesOtherSourceResults() async {
    let web = SearchWebStub(html: Self.doubanSearch, failSearch: true)
    let service = MetadataSearchService(registry: WebTranslatorRegistry(), openLibrary: SearchOpenLibraryStub(), web: web)
    let source = douban
    async let failed = service.batch(.title("test"), source: source)
    async let success = service.batch(.title("test"), source: .openLibrary)
    let (a, b) = await (failed, success)
    XCTAssertNotNil(a.error)
    XCTAssertTrue(a.hits.isEmpty)
    XCTAssertNil(b.error)
    XCTAssertEqual(b.hits.count, 1)
  }

  func testCancellationDoesNotReturnLateResults() async {
    let web = SearchWebStub(html: Self.doubanSearch, cancelDuringSearch: true)
    let service = MetadataSearchService(registry: WebTranslatorRegistry(), web: web)
    let source = douban
    let task = Task { try await service.search(.title("test"), source: source) }
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled search returned data") } catch {}
  }

  func testSearchRedirectAllowsOnlyKnownHTTPSPathsOnSameHost() throws {
    let t = ScriptWebTranslator(script: .goodreads)
    let from = try t.searchURL(for: .isbn("9780743273565"))
    XCTAssertEqual(WebMetadataClient.searchRedirect(URL(string: "https://www.goodreads.com/book/show/4671.The_Great_Gatsby?tracking=1")!,
      from: from, translator: t)?.absoluteString, "https://www.goodreads.com/book/show/4671.The_Great_Gatsby")
    for target in ["http://www.goodreads.com/book/show/4671", "https://evil.test/book/show/4671",
      "https://www.goodreads.com/user/sign_in", "https://www.goodreads.com:8080/book/show/4671",
      "https://user@www.goodreads.com/book/show/4671", "https://127.0.0.1/book/show/4671"] {
      XCTAssertNil(WebMetadataClient.searchRedirect(URL(string: target)!, from: from, translator: t), target)
    }
  }

  func testISBNMismatchAndMissingFieldsAreNotSilentlyAcceptedAsMatches() {
    XCTAssertNil(MetadataSearchService.isbnNotice(query: .isbn("0743273567"), book: Self.book()))
    XCTAssertNotNil(MetadataSearchService.isbnNotice(query: .isbn("9787544270878"), book: Self.book()))
    let missing = BookMetadataSearchResult(id: "missing", title: "Missing", subtitle: nil, authors: [],
      publisher: nil, publicationDate: nil, isbn10: nil, isbn13: nil, pageCount: nil, languageCode: nil, sourceName: "Test")
    XCTAssertNotNil(MetadataSearchService.isbnNotice(query: .isbn("9780743273565"), book: missing))
    XCTAssertNil(MetadataSearchService.isbnNotice(query: .title("Title"), book: missing))
  }

  func testLiveDoubanTitleAndISBNWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["BOOKSHELF_LIVE_SEARCH"] == "1" else { throw XCTSkip("Set BOOKSHELF_LIVE_SEARCH=1") }
    let service = MetadataSearchService(registry: WebTranslatorRegistry())
    for query in [BookMetadataQuery.title("活着"), .isbn("9787544270878")] {
      print("Live Douban search: \(query.text)")
      let results = try await service.search(query, source: douban)
      print("Live Douban detail: \(results.first?.candidate?.url.absoluteString ?? "cached")")
      let book = try await service.resolve(XCTUnwrap(results.first))
      XCTAssertFalse(book.authors.isEmpty)
      XCTAssertNotNil(book.publisher)
      XCTAssertEqual(book.sourceName, "豆瓣图书")
      if case .isbn = query { XCTAssertEqual(book.isbn13, "9787544270878") }
    }
  }

  func testSavedRealSearchPagesWhenProvided() throws {
    guard let directory = ProcessInfo.processInfo.environment["BOOKSHELF_SEARCH_SAMPLES"] else { throw XCTSkip("Set BOOKSHELF_SEARCH_SAMPLES to the saved search sample directory") }
    let douban = ScriptWebTranslator(script: .douban)
    let d = try douban.searchResults(in: HTMLMetadataDocument(data: Data(contentsOf:
      URL(fileURLWithPath: directory).appendingPathComponent("bookshelf-search-douban-search-isbn.txt"))),
      url: douban.searchURL(for: .isbn("9787544270878")))
    XCTAssertEqual(d.first?.title, "解忧杂货店")
    XCTAssertEqual(d.first?.url.absoluteString, "https://book.douban.com/subject/25862578/")
    let goodreads = ScriptWebTranslator(script: .goodreads)
    let g = try goodreads.searchResults(in: HTMLMetadataDocument(data: Data(contentsOf:
      URL(fileURLWithPath: directory).appendingPathComponent("bookshelf-search-goodreads-title.txt"))),
      url: goodreads.searchURL(for: .title("The Great Gatsby")))
    XCTAssertEqual(g.count, 20)
    XCTAssertEqual(g.first?.title, "The Great Gatsby")
    XCTAssertEqual(g.first?.url.path, "/book/show/41733839-the-great-gatsby")
  }

  func testLiveGoodreadsTitleWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["BOOKSHELF_LIVE_SEARCH"] == "1" else { throw XCTSkip("Set BOOKSHELF_LIVE_SEARCH=1") }
    try await checkGoodreads(.title("The Great Gatsby"))
  }

  func testLiveGoodreadsISBNWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["BOOKSHELF_LIVE_SEARCH"] == "1" else { throw XCTSkip("Set BOOKSHELF_LIVE_SEARCH=1") }
    try await checkGoodreads(.isbn("9780743273565"))
  }

  private func checkGoodreads(_ query: BookMetadataQuery) async throws {
    let service = MetadataSearchService(registry: WebTranslatorRegistry())
      print("Live Goodreads search: \(query.text)")
      let results = try await service.search(query, source: goodreads)
      print("Live Goodreads detail: \(results.first?.candidate?.url.absoluteString ?? "cached")")
      let book = try await service.resolve(XCTUnwrap(results.first))
      XCTAssertEqual(book.title, "The Great Gatsby")
      XCTAssertTrue(book.authors.contains("F. Scott Fitzgerald"))
      XCTAssertNotNil(book.publisher)
      XCTAssertEqual(book.sourceName, "Goodreads")
      if case .isbn = query { XCTAssertEqual(book.sourceURL?.path, "/book/show/4671.The_Great_Gatsby") }
  }

  private static let doubanSearch = """
    <title>搜索: Example</title><div class='search-result'><div class='result'>
    <h3><a href='https://www.douban.com/link2/?url=https%3A%2F%2Fbook.douban.com%2Fsubject%2F123%2F&amp;query=Example'>Example Book</a></h3>
    <span class='subject-cast'>Writer / Press / 2024</span></div></div>
    """
  private static let goodreadsSearch = """
    <form action='/search'><input id='search_query'></form><table><tr>
    <td><a class='bookTitle' href='/book/show/123-example?from_search=true'>Example</a>
    <a class='authorName' href='/author/show/1'>Writer</a></td></tr></table>
    <a href='/book/show/999-other'>Recommended unrelated title</a>
    """
  fileprivate static let goodreadsDetail = """
    <script type='application/ld+json'>{"@type":"Book","name":"Example","author":{"name":"Writer"},
    "publisher":"Example Press","isbn":"9780743273565"}</script>
    """
  fileprivate static func book() -> BookMetadataSearchResult {
    BookMetadataSearchResult(id: "example", title: "Example", subtitle: nil, authors: ["Writer"], publisher: "Example Press",
      publicationDate: "2024", isbn10: nil, isbn13: "9780743273565", pageCount: 180, languageCode: "en",
      sourceName: "Test")
  }
}

private actor SearchWebStub: WebMetadataLoading {
  let html: String
  let finalURL: URL?
  let failSearch: Bool
  let cancelDuringSearch: Bool
  var pages = 0
  var details = 0
  init(html: String, finalURL: URL? = nil, failSearch: Bool = false, cancelDuringSearch: Bool = false) {
    self.html = html; self.finalURL = finalURL; self.failSearch = failSearch; self.cancelDuringSearch = cancelDuringSearch
  }
  func searchPage(_ url: URL, translator: any BookSearchTranslator) async throws -> FetchedMetadataPage {
    pages += 1
    if failSearch { throw WebMetadataError.accessRestricted }
    if cancelDuringSearch { try await Task.sleep(for: .seconds(30)) }
    return FetchedMetadataPage(data: Data(html.utf8), url: finalURL ?? url)
  }
  func extract(_ input: String, registry: WebTranslatorRegistry) async throws -> WebTranslationResult {
    details += 1
    let html = "<h1>Example</h1><div id='info'>作者: Writer<br>出版社: Example Press<br>ISBN: 9780743273565</div>"
    return try registry.translate(html: Data(html.utf8), sourceURL: input)
  }

  func counts() -> (pages: Int, details: Int) { (pages, details) }
}

private struct SearchOpenLibraryStub: BookMetadataProvider {
  let displayName = "Open Library"
  func search(_ query: BookMetadataQuery, script: TranslatorScript) async throws -> [BookMetadataSearchResult] { [MetadataSearchTests.book()] }

}

private final class OpenLibraryFixtureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, url.host == "openlibrary.org", url.path == "/api/books",
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      items.contains(URLQueryItem(name: "bibkeys", value: "ISBN:9780743273565")),
      items.contains(URLQueryItem(name: "jscmd", value: "data")),
      items.contains(URLQueryItem(name: "installed", value: "1")),
      items.contains(URLQueryItem(name: "format", value: "json")),
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let json = """
      {"ISBN:9780743273565":{"title":"Example Edition","authors":[{"name":"Writer"}],
      "publishers":[{"name":"Edition Press"}],"identifiers":{"isbn_10":["0-7432-7356-7"]}}}
      """
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(json.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
