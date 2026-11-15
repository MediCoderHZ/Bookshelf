import Foundation

struct RISTranslator: FileImportTranslator, FileExportTranslator {
  let descriptor = TranslatorDescriptor(id: "ris", name: "RIS 书目", version: "1.0.0", author: "Bookshelf",
    targetDescription: "本地 RIS 图书元信息", priority: 100, coverHosts: [])
  let fileExtensions = ["ris"]
  let fileExtension = "ris"
  let exportSummary = "用于交换整本图书的出版信息、作者、译者、编辑、标签、简介及首个丛书。条目类型和原作语言供本应用往返保存，其他工具可能不保留；副标题合并到书名；收藏、普通书单、原书名和其他贡献者不会导出。"
  @MainActor func detectImport(_ data: Data) -> Bool {
    let prefix = data.prefix(4096)
    let encoding: String.Encoding = prefix.starts(with: [0xFF, 0xFE]) || prefix.starts(with: [0xFE, 0xFF]) ? .utf16 : .utf8
    let text = encoding == .utf8 ? String(decoding: prefix, as: UTF8.self)
      : (String(data: prefix, encoding: .utf16) ?? String(data: prefix.dropLast(2), encoding: .utf16) ?? "")
    return text.replacingOccurrences(of: "\u{FEFF}", with: "")
      .range(of: "(?im)^TY[ \\t]{1,2}-[ \\t]", options: .regularExpression) != nil
  }
  @MainActor func doImport(_ data: Data) throws -> RISImportResult { try BibliographicExchange.decodeRIS(data) }
  @MainActor func doExport(_ records: [BookArchive], includeNotes: Bool) throws -> Data {
    BibliographicExchange.export(records, format: .ris, includeNotes: includeNotes)
  }
}

struct CSVTranslator: FileExportTranslator {
  let descriptor = TranslatorDescriptor(id: "csv", name: "CSV 清单", version: "1.0.0", author: "Bookshelf",
    targetDescription: "本地 CSV 书籍清单（仅导出）", priority: 100, coverHosts: [])
  let fileExtension = "csv"
  let exportSummary = "用于表格查看书籍清单，包含条目类型、原作语言、出版信息、作者、译者、标签、普通书单、收藏和来源网址。CSV 使用 UTF-8；ISBN 和可能被识别为公式的文本带文本前缀。"
  @MainActor func doExport(_ records: [BookArchive], includeNotes: Bool) throws -> Data {
    BibliographicExchange.export(records, format: .csv, includeNotes: includeNotes)
  }
}

struct OpenLibraryTranslator: SearchMetadataTranslator {
  let descriptor = TranslatorDescriptor(id: "open-library", name: "Open Library", version: "1.0.0", author: "Bookshelf",
    targetDescription: "书名或 ISBN 检索 · openlibrary.org", priority: 200, coverHosts: ["covers.openlibrary.org"])
  func searchURL(for query: BookMetadataQuery) -> URL {
    var parts = URLComponents(string: "https://openlibrary.org/search")!
    parts.queryItems = [URLQueryItem(name: "q", value: query.text)]
    return parts.url!
  }
  func doSearch(_ query: BookMetadataQuery, host: TranslationHost) async throws -> [MetadataSearchHit] {
    try await host.openLibrary.search(query).map { MetadataSearchHit(source: .openLibrary, candidate: nil, metadata: $0) }
  }
  func resolve(_ hit: MetadataSearchHit, host: TranslationHost) async throws -> BookMetadataSearchResult {
    guard let metadata = hit.metadata else { throw WebMetadataError.noBook }
    return metadata
  }
  func downloadCover(_ book: BookMetadataSearchResult, host: TranslationHost) async throws -> Data? {
    guard let url = book.coverURL else { return nil }
    guard descriptor.allowsCover(url) else { throw WebMetadataError.unsupportedURL }
    return try await host.openLibrary.downloadCover(from: url)
  }
}

extension BookSearchTranslator {
  private var searchSource: MetadataSearchSource { MetadataSearchSource(id: descriptor.id, name: descriptor.name) }
  private var detailRegistry: WebTranslatorRegistry { WebTranslatorRegistry(translators: [self]) }
  func doSearch(_ query: BookMetadataQuery, host: TranslationHost) async throws -> [MetadataSearchHit] {
    let page = try await host.web.searchPage(searchURL(for: query), translator: self)
    try Task.checkCancellation()
    guard canonicalURL(for: page.url) != nil else { throw WebMetadataError.unsupportedURL }
    let document = try HTMLMetadataDocument(data: page.data)
    if try detectWeb(in: document, url: page.url) == .book {
      let result = try detailRegistry.translate(html: page.data, sourceURL: page.url.absoluteString)
      guard case .book(let book) = result.page else { throw WebMetadataError.noBook }
      return [MetadataSearchHit(source: searchSource, candidate: nil, metadata: book)]
    }
    return try searchResults(in: document, url: page.url).map { MetadataSearchHit(source: searchSource, candidate: $0, metadata: nil) }
  }
  func resolve(_ hit: MetadataSearchHit, host: TranslationHost) async throws -> BookMetadataSearchResult {
    if let metadata = hit.metadata { return metadata }
    guard let candidate = hit.candidate else { throw WebMetadataError.noBook }
    let result = try await host.web.extract(candidate.url.absoluteString, registry: detailRegistry)
    guard case .book(let book) = result.page else { throw WebMetadataError.noBook }
    return book
  }
  func downloadCover(_ book: BookMetadataSearchResult, host: TranslationHost) async throws -> Data? {
    guard let url = book.coverURL else { return nil }
    return try await host.web.downloadCover(url, translatorID: descriptor.id, registry: detailRegistry)
  }
}
