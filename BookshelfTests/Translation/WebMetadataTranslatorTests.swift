import AppKit
import Foundation
import XCTest
@testable import Bookshelf

final class WebMetadataTranslatorTests: XCTestCase {
  private let url = URL(string: "https://book.douban.com/subject/123456/")!

  func testDetailWithNestedLabelsEntitiesContributorsAndExpandedDescription() throws {
    let html = """
      <!DOCTYPE html><html><head><title>测试图书 (豆瓣)</title></head><body>
      <h1><span property="v:itemreviewed">测试 &amp; 图书</span></h1>
      <div id="mainpic"><a href="https://img1.doubanio.com/view/subject/l/public/example.jpg"><img src="small.jpg"></a></div>
      <div id="info">
        <span><span class="pl">作者</span>: <a>甲作者</a> / <a>乙作者</a></span><br>
        <span><span class="pl">译者</span>: <a>丙译者</a> / 丁译者</span><br/>
        <span class="pl">出版社：</span><a>示例出版社</a><br>
        <span class="pl">出版年:</span> 2024-6<br>
        <span class="pl">页数:</span> 320页<br>
        <span class="pl">ISBN:</span> 978-7-0200-4249-4<br>
        <span class="pl">副标题:</span> 一个副标题<br>
        <span class="pl">原作名:</span> An Original Title<br>
      </div>
      <div id="link-report"><div class="intro">简短介绍…</div>
        <div class="hidden"><div class="intro"><p>完整的第一段简介。</p><p>第二段 &amp; 后续。</p></div></div>
      </div>
      <div class="intro">不应抓取的作者传记</div>
      </body></html>
      """
    let result = try book(html)
    XCTAssertEqual(result.title, "测试 & 图书")
    XCTAssertEqual(result.authors, ["甲作者", "乙作者"])
    XCTAssertEqual(result.translators, ["丙译者", "丁译者"])
    XCTAssertEqual(result.publisher, "示例出版社")
    XCTAssertEqual(result.publicationDate, "2024-6")
    XCTAssertEqual(result.pageCount, 320)
    XCTAssertEqual(result.isbn13, "9787020042494")
    XCTAssertEqual(result.subtitle, "一个副标题")
    XCTAssertEqual(result.originalTitle, "An Original Title")
    XCTAssertEqual(result.bookDescription, "完整的第一段简介。\n\n第二段 & 后续。")
    XCTAssertEqual(result.sourceURL, url)
    XCTAssertNil(result.languageCode) // Do not infer a book's language from the site's language.
  }

  func testSparsePageRetainsOnlyAvailableInformation() throws {
    let result = try book("<h1>简版</h1><div id='info'><span>出版社:</span> 某出版社<br></div>")
    XCTAssertEqual(result.publisher, "某出版社")
    XCTAssertTrue(result.authors.isEmpty)
    XCTAssertNil(result.isbn13)
    XCTAssertNil(result.pageCount)
  }

  func testHomepageDeduplicatesBookLinksAndRejectsOtherSites() throws {
    let html = """
      <a href='/subject/123456/?from=home'><img alt='示例书'></a>
      <a href='https://book.douban.com/subject/123456/'>示例书</a>
      <a href='/subject/234567/' title='第二本'>查看</a>
      <a href='https://book.douban.com.evil.test/subject/999/'>外站</a>
      <a href='/review/123/'>书评</a>
      """
    let page = try ScriptWebTranslator(script: .douban).translate(html: Data(html.utf8), url: URL(string: "https://book.douban.com/")!)
    guard case .choices(let choices) = page else { return XCTFail("Expected choices") }
    XCTAssertEqual(choices.map(\.title), ["示例书", "第二本"])
    XCTAssertEqual(choices.first?.url, url)
  }

  func testRegistryNormalizesURLsAndHonorsDisabledTranslator() throws {
    let registry = WebTranslatorRegistry()
    XCTAssertEqual(try registry.resolve(" http://book.douban.com/subject/123456?from=tracking#x ").1, url)
    for input in ["file:///tmp/book.html", "https://evil.test/subject/123/",
      "https://book.douban.com.evil.test/subject/123/", "https://user@book.douban.com/subject/123/",
      "https://book.douban.com:1234/subject/123/", "https://book.douban.com/subject/123/reviews/",
      "https://book.douban.com/subject/not-a-number/", "https://movie.douban.com/subject/123/"] {
      XCTAssertThrowsError(try registry.resolve(input), input)
    }
    XCTAssertThrowsError(try WebTranslatorRegistry(disabledIDs: ["douban-books"]).resolve(url.absoluteString)) {
      guard case WebMetadataError.disabled = $0 else { return XCTFail("Expected disabled") }
    }
  }

  func testVerificationAndChangedPagesDoNotProduceBooks() {
    for html in ["<title>安全验证</title><h1>请验证</h1>",
      "<h1>登录</h1><input name='captcha-solution'>", "<h1>暂无数据</h1>",
      "<h1>评论</h1><div id='info'>没有出版信息</div>"] {
      XCTAssertThrowsError(try book(html))
    }
    XCTAssertThrowsError(try ScriptWebTranslator(script: .douban).translate(
      html: Data(repeating: 32, count: WebMetadataClient.htmlLimit + 1), url: url))
  }

  func testExternalResourcesAndScriptsStayInert() throws {
    let result = try book("""
      <h1>安全书名</h1><div id='info'>作者: 作者甲<br></div>
      <div id='mainpic'><img src='http://127.0.0.1/private'></div>
      <script>throw new Error('must never execute')</script>
      """)
    XCTAssertEqual(result.title, "安全书名")
    XCTAssertEqual(result.authors, ["作者甲"])
  }

  // Opt-in manual integration checks; ordinary test runs never contact Douban.
  func testSavedRealDoubanPageWhenProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["BOOKSHELF_DOUBAN_HTML"] else {
      throw XCTSkip("Set BOOKSHELF_DOUBAN_HTML to a locally saved Douban detail HTML file")
    }
    let page = try WebMetadataClient().extractSavedHTML(
      Data(contentsOf: URL(fileURLWithPath: path)),
      sourceURL: "https://book.douban.com/subject/1084336/", registry: WebTranslatorRegistry())
    guard case .book(let result) = page.page else { return XCTFail("Expected book") }
    XCTAssertEqual(result.title, "小王子")
    XCTAssertEqual(result.isbn13, "9787020042494")
    XCTAssertEqual(result.authors, ["[法] 安东尼·德·圣-埃克苏佩里"])
    XCTAssertEqual(result.translators, ["马振骋"])
    XCTAssertEqual(result.publisher, "人民文学出版社")
    XCTAssertEqual(result.publicationDate, "2003-8")
    XCTAssertEqual(result.pageCount, 97)
    XCTAssertEqual(result.originalTitle, "Le Petit Prince")
    XCTAssertNotNil(result.bookDescription)
  }

  func testSavedHTMLHonorsSourceValidationAndDisabledSetting() throws {
    let html = Data("<h1>示例书</h1><div id='info'>作者: 甲<br></div>".utf8)
    XCTAssertThrowsError(try WebMetadataClient().extractSavedHTML(html, sourceURL: url.absoluteString, registry: WebTranslatorRegistry(disabledIDs: ["douban-books"])))
    XCTAssertThrowsError(try WebMetadataClient().extractSavedHTML(html, sourceURL: "https://evil.test", registry: WebTranslatorRegistry()))
    guard case .book(let result) = try WebMetadataClient().extractSavedHTML(html, sourceURL: url.absoluteString, registry: WebTranslatorRegistry()).page else {
      return XCTFail("Expected book")
    }
    XCTAssertEqual(result.title, "示例书")
    XCTAssertEqual(result.sourceURL, url)
  }

  func testLiveDoubanPageWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["BOOKSHELF_LIVE_DOUBAN"] == "1" else {
      throw XCTSkip("Set BOOKSHELF_LIVE_DOUBAN=1 for the public page integration check")
    }
    let page = try await WebMetadataClient().extract(
      "https://book.douban.com/subject/1084336/", registry: WebTranslatorRegistry())
    guard case .book(let result) = page.page else { return XCTFail("Expected book") }
    XCTAssertEqual(result.title, "小王子")
    XCTAssertEqual(result.isbn13, "9787020042494")
    XCTAssertFalse(result.authors.isEmpty)
    XCTAssertEqual(result.publisher, "人民文学出版社")
    XCTAssertFalse(result.translators.isEmpty)
    let homepage = try await WebMetadataClient().extract("https://book.douban.com/", registry: WebTranslatorRegistry())
    guard case .choices(let books) = homepage.page else { return XCTFail("Expected homepage choices") }
    XCTAssertFalse(books.isEmpty)
    XCTAssertEqual(Set(books.map(\.id)).count, books.count)
  }

  private func book(_ html: String) throws -> BookMetadataSearchResult {
    let result = try ScriptWebTranslator(script: .douban).translate(html: Data(html.utf8), url: url)
    guard case .book(let book) = result else { throw WebMetadataError.noBook }
    return book
  }
}
