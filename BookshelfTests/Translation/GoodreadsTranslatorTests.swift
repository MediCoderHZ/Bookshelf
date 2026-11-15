import AppKit
import Foundation
import XCTest
@testable import Bookshelf

final class GoodreadsTranslatorTests: XCTestCase {
  private let url = URL(string: "https://www.goodreads.com/book/show/123-example-book")!

  func testSelectedEditionAndContributorRolesAreIsolated() throws {
    let cache: [String: Any] = [
      "Book:recommendation": ["legacyId": 999, "title": "Wrong book", "details": ["isbn13": "9789999999999"]],
      "Book:current": ["legacyId": 123, "title": "A  Title & Book",
        "description": "<p>First &amp; second.</p><p>New paragraph.</p>",
        "details": ["publisher": "Example Press", "publicationTime": 1072944000000,
          "isbn": "0-7432-7356-7", "isbn13": "978-0-7432-7356-5", "numPages": 180,
          "language": ["name": "English"]],
        "primaryContributorEdge": ["node": ["__ref": "Contributor:author"], "role": "Author"],
        "secondaryContributorEdges": [
          ["node": ["__ref": "Contributor:translator"], "role": "Translator"],
          ["node": ["__ref": "Contributor:editor"], "role": "Editor"],
          ["node": ["__ref": "Contributor:author"], "role": "Author"]],
        "work": ["__ref": "Work:current"],
        "imageUrl": "https://m.media-amazon.com/images/example.jpg"],
      "Contributor:author": ["name": "Writer A"], "Contributor:translator": ["name": "Translator B"],
      "Contributor:editor": ["name": "Editor C"],
      "Work:current": ["details": ["originalTitle": "Original Title", "publicationTime": -1411488000000]]
    ]
    let result = try book(embedded(cache))
    XCTAssertEqual(result.title, "A  Title & Book") // JSON text is not whitespace-collapsed before decoding.
    XCTAssertEqual(result.authors, ["Writer A"])
    XCTAssertEqual(result.translators, ["Translator B"])
    XCTAssertEqual(result.publisher, "Example Press")
    XCTAssertEqual(result.publicationDate, "2004-01-01")
    XCTAssertEqual(result.isbn10, "0743273567")
    XCTAssertEqual(result.isbn13, "9780743273565")
    XCTAssertEqual(result.pageCount, 180)
    XCTAssertEqual(result.languageCode, "en")
    XCTAssertEqual(result.originalTitle, "Original Title")
    XCTAssertEqual(result.bookDescription, "First & second.\n\nNew paragraph.")
  }

  func testMissingEditionFieldsDoNotUseWorkDateOrDifferentSchemaEdition() throws {
    let cache: [String: Any] = [
      "Book:current": ["legacyId": 123, "title": "Sparse", "work": ["__ref": "Work:current"],
        "details": ["numPages": NSNull(), "isbn13": NSNull(), "language": ["name": NSNull()]]],
      "Work:current": ["details": ["publicationTime": -1411488000000]]
    ]
    let result = try book(embedded(cache) + """
      <script type="application/ld+json">{"@type":"Book","name":"Sparse","isbn":"9780743273565","datePublished":"1925-04-10","publisher":"Wrong edition"}</script>
      <p data-testid="publicationInfo">First published April 10, 1925</p>
      """)
    XCTAssertNil(result.publisher)
    XCTAssertNil(result.publicationDate)
    XCTAssertNil(result.isbn13)
    XCTAssertNil(result.pageCount)
    XCTAssertNil(result.languageCode)
  }

  func testJSONLDGraphFallbackSelectsMatchingBook() throws {
    let result = try book("""
      <script id="__NEXT_DATA__">invalid</script>
      <script type="application/ld+json">{"@graph":[
        {"@type":"Book","name":"Wrong","url":"https://www.goodreads.com/book/show/999-wrong"},
        {"@type":["Thing","Book"],"name":"Fallback Book","url":"https://www.goodreads.com/book/show/123-example-book",
         "author":[{"name":"Author A"},{"name":"Author B"}],"translator":{"name":"Translator C"},
         "publisher":{"name":"Publisher"},"isbn":"9780743273565","datePublished":"2024-05",
         "numberOfPages":"320","inLanguage":"French","description":"First &amp; more.",
         "image":{"url":"https://unapproved.example.org/cover.jpg"}}
      ]}</script>
      """)
    XCTAssertEqual(result.title, "Fallback Book")
    XCTAssertEqual(result.authors, ["Author A", "Author B"])
    XCTAssertEqual(result.translators, ["Translator C"])
    XCTAssertEqual(result.publisher, "Publisher")
    XCTAssertEqual(result.isbn13, "9780743273565")
    XCTAssertEqual(result.publicationDate, "2024-05")
    XCTAssertEqual(result.pageCount, 320)
    XCTAssertEqual(result.languageCode, "fr")
  }

  func testURLScopeNormalizationAndEnabledState() throws {
    let registry = WebTranslatorRegistry()
    XCTAssertEqual(try registry.resolve("http://goodreads.com/book/show/123.Example?from_search=true#reviews").1.absoluteString,
      "https://www.goodreads.com/book/show/123.Example")
    XCTAssertEqual(try registry.resolve("https://www.goodreads.com/search?q=swift&search_type=books&tracking=1").1.query,
      "q=swift&search_type=books")
    for input in ["https://www.goodreads.com/", "https://www.goodreads.com/list/show/10.Example",
      "https://www.goodreads.com/shelf/show/science-fiction", "https://www.goodreads.com/search/index?q=fiction"] {
      XCTAssertEqual(try registry.resolve(input).0.descriptor.id, "goodreads-books")
    }
    for input in ["https://www.goodreads.com.evil.test/book/show/123", "https://www.goodreads.com/user/show/123",
      "https://www.goodreads.com/book/show/123/reviews", "https://www.goodreads.com/book/show/not-a-number",
      "https://user@www.goodreads.com/book/show/123", "https://www.goodreads.com:8080/book/show/123"] {
      XCTAssertThrowsError(try registry.resolve(input), input)
    }
    XCTAssertThrowsError(try WebTranslatorRegistry(disabledIDs: ["goodreads-books"]).resolve(url.absoluteString))
  }

  func testListDeduplicatesByBookIDEvenAcrossSlugsAndRetainsQueriesOnlyForSearch() throws {
    let html = """
      <a href='/book/show/123-example?from_search=true'><img alt='Example Book'></a>
      <a href='/book/show/123.Example'>Duplicate</a>
      <a href='https://www.goodreads.com/book/show/456-other' title='Other Book'>Read more</a>
      <a href='https://evil.test/book/show/999'>Not a Goodreads book</a>
      """
    let result = try WebTranslatorRegistry().translate(html: Data(html.utf8), sourceURL: "https://www.goodreads.com/")
    guard case .choices(let choices) = result.page else { return XCTFail("Expected list") }
    XCTAssertEqual(choices.map(\.title), ["Example Book", "Other Book"])
    XCTAssertNil(choices.first?.url.query)
  }

  func testWrongSavedEditionAndVerificationPagesDoNotProduceMetadata() throws {
    XCTAssertThrowsError(try book(embedded(["Book:wrong": ["legacyId": 999, "title": "Other edition"]])))
    for html in ["<title>JavaScript is disabled</title><h1>JavaScript is disabled</h1>",
      "<title>Just a moment...</title><form id='challenge-form'></form>",
      "<h1>Sign in</h1>",
      "<script type='application/ld+json'>{\"@type\":\"Book\",\"name\":\"Wrong\",\"url\":\"https://www.goodreads.com/book/show/999-wrong\"}</script>"] {
      XCTAssertThrowsError(try book(html))
    }
  }

  func testSavedRealGoodreadsPagesWhenProvided() throws {
    guard let paper = ProcessInfo.processInfo.environment["BOOKSHELF_GOODREADS_HTML"],
      let kindle = ProcessInfo.processInfo.environment["BOOKSHELF_GOODREADS_KINDLE_HTML"],
      let home = ProcessInfo.processInfo.environment["BOOKSHELF_GOODREADS_HOME_HTML"] else {
      throw XCTSkip("Set the three BOOKSHELF_GOODREADS_*_HTML paths for local real-page checks")
    }
    let registry = WebTranslatorRegistry()
    let paperResult = try registry.translate(html: Data(contentsOf: URL(fileURLWithPath: paper)),
      sourceURL: "https://www.goodreads.com/book/show/13634490-the-great-gatsby")
    guard case .book(let paperback) = paperResult.page else { return XCTFail("Expected paper edition") }
    XCTAssertEqual(paperback.title, "The Great Gatsby")
    XCTAssertEqual(paperback.authors, ["F. Scott Fitzgerald"])
    XCTAssertEqual(paperback.publisher, "Scribner")
    XCTAssertEqual(paperback.publicationDate, "2004-01-01")
    XCTAssertEqual(paperback.pageCount, 180)
    XCTAssertEqual(paperback.languageCode, "en")
    let kindleResult = try registry.translate(html: Data(contentsOf: URL(fileURLWithPath: kindle)),
      sourceURL: "https://www.goodreads.com/book/show/13336017-the-great-gatsby")
    guard case .book(let ebook) = kindleResult.page else { return XCTFail("Expected ebook edition") }
    XCTAssertEqual(ebook.publisher, "Foreign Language Teaching and Research Press")
    XCTAssertEqual(ebook.publicationDate, "2010-07-03")
    XCTAssertNil(ebook.pageCount)
    XCTAssertNil(ebook.isbn13)
    let list = try registry.translate(html: Data(contentsOf: URL(fileURLWithPath: home)), sourceURL: "https://www.goodreads.com/")
    guard case .choices(let choices) = list.page else { return XCTFail("Expected homepage choices") }
    XCTAssertFalse(choices.isEmpty)
  }

  func testLiveGoodreadsWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["BOOKSHELF_LIVE_GOODREADS"] == "1" else {
      throw XCTSkip("Set BOOKSHELF_LIVE_GOODREADS=1 to request public Goodreads pages")
    }
    let client = WebMetadataClient()
    let result = try await client.extract("https://www.goodreads.com/book/show/13634490-the-great-gatsby", registry: WebTranslatorRegistry())
    guard case .book(let book) = result.page else { return XCTFail("Expected book") }
    XCTAssertEqual(book.title, "The Great Gatsby")
    XCTAssertEqual(book.publisher, "Scribner")
    XCTAssertEqual(book.pageCount, 180)
    let list = try await client.extract("https://www.goodreads.com/", registry: WebTranslatorRegistry())
    guard case .choices(let choices) = list.page else { return XCTFail("Expected choices") }
    XCTAssertFalse(choices.isEmpty)
  }

  private func embedded(_ cache: [String: Any]) throws -> String {
    let json = try JSONSerialization.data(withJSONObject: ["props": ["pageProps": ["apolloState": cache]]])
    return "<script id='__NEXT_DATA__' type='application/json'>\(String(decoding: json, as: UTF8.self))</script>"
  }
  private func book(_ html: String) throws -> BookMetadataSearchResult {
    let result = try WebTranslatorRegistry().translate(html: Data(html.utf8), sourceURL: url.absoluteString)
    guard case .book(let book) = result.page else { throw WebMetadataError.noBook }
    return book
  }
}
