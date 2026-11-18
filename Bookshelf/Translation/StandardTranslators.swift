import Foundation

struct OpenLibraryTranslator: ScriptedSearchSource {
  var script: TranslatorScript = .openLibrary
  func doSearch(_ query: BookMetadataQuery, host: TranslationHost) async throws -> [MetadataSearchHit] {
    let source = MetadataSearchSource(id: descriptor.id, name: descriptor.name)
    return try await host.openLibrary.search(query, script: script).map { MetadataSearchHit(source: source, candidate: nil, metadata: $0) }
  }
  func resolve(_ hit: MetadataSearchHit, host: TranslationHost) async throws -> BookMetadataSearchResult {
    guard let metadata = hit.metadata else { throw WebMetadataError.noBook }
    return metadata
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

}
