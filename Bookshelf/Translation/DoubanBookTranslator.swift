import Foundation

struct DoubanBookTranslator: BookSearchTranslator {
  var descriptor: TranslatorDescriptor { TranslatorDescriptor(
    id: "douban-books", name: L10n.tr("豆瓣图书"), version: "1.2.0", author: "Bookshelf",
    targetDescription: L10n.tr("book.douban.com 图书页面与 www.douban.com/search 图书搜索"), priority: 100) }

  func canonicalURL(for url: URL) -> URL? {
    if let safe = WebURLPolicy.normalized(url), safe.host == "www.douban.com", safe.path == "/search",
      var components = URLComponents(url: safe, resolvingAgainstBaseURL: false),
      components.queryItems?.first(where: { $0.name == "cat" })?.value == "1001" {
      components.queryItems = components.queryItems?.filter { ["q", "cat"].contains($0.name) }
      return components.url
    }
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host?.lowercased() == "book.douban.com", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443,
      url.path.isEmpty || url.path == "/" || url.path.range(
        of: #"^/subject/[0-9]+/?$"#, options: .regularExpression) != nil
    else { return nil }
    let path = url.path.isEmpty || url.path == "/" ? "/" : url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return URL(string: path == "/" ? "https://book.douban.com/" : "https://book.douban.com/\(path)/")
  }

  func detectWeb(in document: HTMLMetadataDocument, url: URL) throws -> WebPageKind? {
    let pageTitle = document.text("//title") ?? ""
    if ["安全验证", "异常请求", "访问受限", "禁止访问", "登录豆瓣", "验证码"].contains(where: pageTitle.contains)
      || document.first("//*[@id='captcha_image' or @id='captcha' or @name='captcha-solution']") != nil
    {
      throw WebMetadataError.accessRestricted
    }
    if url.host == "www.douban.com" {
      return document.first("//*[contains(concat(' ', normalize-space(@class), ' '), ' search-result ')]") != nil ? .multiple : nil
    }
    if url.path == "/" {
      return document.first("//a[contains(@href, '/subject/')]") == nil ? nil : .multiple
    }
    return document.first("//*[@id='info']") != nil && document.first("//h1") != nil ? .book : nil
  }

  func doWeb(in document: HTMLMetadataDocument, url sourceURL: URL, kind: WebPageKind) throws -> TranslatedWebPage {
    if sourceURL.host == "www.douban.com" { return .choices(try searchResults(in: document, url: sourceURL)) }
    if sourceURL.path == "/" {
      var seen = Set<URL>()
      let candidates = document.nodes("//a[@href]").compactMap { node -> WebBookCandidate? in
        guard let href = document.attribute("href", of: node),
          let linkedURL = URL(string: href, relativeTo: sourceURL)?.absoluteURL,
          let canonical = canonicalURL(for: linkedURL), canonical.path != "/",
          let title = document.attribute("title", of: node)?.nilIfBlank
            ?? document.text(of: node).nilIfBlank
            ?? document.attribute("alt", of: document.first(".//img", from: node))?.nilIfBlank,
          seen.insert(canonical).inserted
        else { return nil }
        return WebBookCandidate(title: title, url: canonical)
      }
      guard !candidates.isEmpty else { throw WebMetadataError.noBooks }
      return .choices(Array(candidates.prefix(60)))
    }

    guard let info = document.first("//*[@id='info']"),
      let title = document.text("//h1//*[@property='v:itemreviewed']") ?? document.text("//h1")
    else { throw WebMetadataError.noBook }
    // Traverse the DOM with <br> boundaries; labels may be nested in spans or links.
    let fields = document.lines(of: info).reduce(into: [String: String]()) { result, line in
      guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return }
      let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { result[key] = value }
    }
    guard fields["作者"] != nil || fields["出版社"] != nil || fields["ISBN"] != nil else {
      throw WebMetadataError.noBook
    }
    let isbn = ISBN.normalized(fields["ISBN"] ?? document.text("//meta[@property='book:isbn']/@content"))
    let intros = document.nodes("//*[@id='link-report']//*[contains(concat(' ', normalize-space(@class), ' '), ' intro ')]")
    let description = intros.map { document.lines(of: $0).joined(separator: "\n\n") }
      .max(by: { $0.count < $1.count })?.nilIfBlank
    let pages = fields["页数"].flatMap { value -> Int? in
      guard let range = value.range(of: #"^[0-9]+"#, options: .regularExpression) else { return nil }
      return Int(value[range]).flatMap { $0 > 0 ? $0 : nil }
    }
    return .book(BookMetadataSearchResult(
      id: "douban:\(sourceURL.path)", title: title, subtitle: fields["副标题"],
      authors: contributors(fields["作者"]), publisher: fields["出版社"],
      publicationDate: fields["出版年"] ?? fields["出版日期"],
      isbn10: isbn?.count == 10 ? isbn : nil, isbn13: isbn?.count == 13 ? isbn : nil,
      pageCount: pages, languageCode: nil, sourceName: descriptor.name,
      translators: contributors(fields["译者"]), originalTitle: fields["原作名"],
      bookDescription: description, sourceURL: sourceURL))
  }

  func searchURL(for query: BookMetadataQuery) -> URL {
    var url = URLComponents(string: "https://www.douban.com/search")!
    url.queryItems = [URLQueryItem(name: "cat", value: "1001"), URLQueryItem(name: "q", value: query.text)]
    return url.url!
  }

  func searchResults(in document: HTMLMetadataDocument, url: URL) throws -> [WebBookCandidate] {
    guard try detectWeb(in: document, url: url) == .multiple else { throw WebMetadataError.noBook }
    var seen = Set<URL>()
    return Array(document.nodes("//*[contains(concat(' ', normalize-space(@class), ' '), ' result ')]").compactMap { row in
      guard let anchor = document.first(".//h3/a[@href]", from: row),
        let href = document.attribute("href", of: anchor),
        let linked = URL(string: href, relativeTo: url)?.absoluteURL else { return nil }
      // Decode the public search wrapper locally. Never request its arbitrary URL.
      var destination = linked
      if linked.host == "www.douban.com", ["/link2", "/link2/"].contains(linked.path),
        let target = URLComponents(url: linked, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
        let unwrapped = URL(string: target) { destination = unwrapped }
      guard let canonical = canonicalURL(for: destination), canonical.host == "book.douban.com",
        canonical.path.hasPrefix("/subject/"), seen.insert(canonical).inserted,
        let title = document.text(of: anchor).nilIfBlank else { return nil }
      let summary = document.first(".//*[contains(concat(' ', normalize-space(@class), ' '), ' subject-cast ')]", from: row)
        .map { document.text(of: $0) }
      return WebBookCandidate(title: title, url: canonical, summary: summary)
    }.prefix(20))
  }

  private func contributors(_ value: String?) -> [String] {
    (value ?? "").components(separatedBy: CharacterSet(charactersIn: "/／、"))
      .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
  }
}

private extension String {
  var nilIfBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
