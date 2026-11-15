import Foundation

struct MetadataSearchSource: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  static let openLibrary = Self(id: "open-library", name: "Open Library")
}

struct MetadataSearchHit: Identifiable, Sendable {
  let source: MetadataSearchSource
  let candidate: WebBookCandidate?
  let metadata: BookMetadataSearchResult?
  var title: String { metadata?.title ?? candidate?.title ?? "" }
  var subtitle: String? { candidate?.summary ?? metadata?.authors.joined(separator: "、") }
  var id: String { source.id + ":" + (candidate?.id ?? metadata?.id ?? "") }
}

struct MetadataSearchBatch: Identifiable, Sendable {
  let source: MetadataSearchSource
  var hits: [MetadataSearchHit] = []
  var isLoading = true
  var error: String?
  var id: String { source.id }
}

struct MetadataSearchService: Sendable {
  private let engine: TranslationEngine
  var registry: WebTranslatorRegistry { engine.registry.webRegistry }

  init(registry: WebTranslatorRegistry, openLibrary: any BookMetadataProvider = OpenLibraryBookMetadataProvider(),
    web: any WebMetadataLoading = WebMetadataClient()) {
    self.init(catalog: TranslatorRegistry(translators: registry.translators.map { $0 as any BookTranslator } + [OpenLibraryTranslator()],
      disabledIDs: registry.disabledIDs), host: TranslationHost(web: web, openLibrary: openLibrary))
  }
  init(catalog: TranslatorRegistry, host: TranslationHost = TranslationHost()) {
    engine = TranslationEngine(registry: catalog, host: host)
  }
  var sources: [MetadataSearchSource] { engine.registry.searchSources }
  func searchURL(for query: BookMetadataQuery, source: MetadataSearchSource) -> URL? {
    (try? engine.searchTranslator(source.id))?.searchURL(for: query)
  }
  func search(_ query: BookMetadataQuery, source: MetadataSearchSource) async throws -> [MetadataSearchHit] {
    try await engine.search(query, source: source)
  }
  func batch(_ query: BookMetadataQuery, source: MetadataSearchSource) async -> MetadataSearchBatch {
    do { return MetadataSearchBatch(source: source, hits: try await search(query, source: source), isLoading: false) }
    catch { return MetadataSearchBatch(source: source, isLoading: false, error: error.localizedDescription) }
  }
  func resolve(_ hit: MetadataSearchHit) async throws -> BookMetadataSearchResult { try await engine.resolve(hit) }

  // ISBN-10/13 equivalents compare equal; a missing ISBN stays explicitly unverified.
  static func isbnNotice(query: BookMetadataQuery?, book: BookMetadataSearchResult) -> String? {
    guard case .isbn(let requested) = query else { return nil }
    let returned = [book.isbn10, book.isbn13].compactMap { $0 }.compactMap(comparisonISBN)
    guard !returned.isEmpty else { return "该页面未提供 ISBN，无法确认与查询号码一致，请核对版本。" }
    guard let wanted = comparisonISBN(requested), returned.contains(wanted) else {
      return "此版本的 ISBN 与查询号码不同，请核对后再填入。"
    }
    return nil
  }

  private static func comparisonISBN(_ value: String) -> String? {
    guard let isbn = ISBN.normalized(value) else { return nil }
    if isbn.count == 13 { return isbn }
    guard isbn.count == 10 else { return nil }
    let prefix = "978" + isbn.prefix(9)
    let digits = prefix.compactMap(\.wholeNumberValue)
    guard digits.count == 12 else { return nil }
    let sum = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 1 : 3) }
    return prefix + String((10 - sum % 10) % 10)
  }
}
