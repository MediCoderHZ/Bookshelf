import Foundation

protocol BookTranslator: Sendable { var descriptor: TranslatorDescriptor { get } }

/// The same four capability bits used by Zotero; a translator may implement several.
struct TranslatorCapabilities: OptionSet, Sendable {
  let rawValue: Int
  static let fileImport = Self(rawValue: 1)
  static let fileExport = Self(rawValue: 2)
  static let web = Self(rawValue: 4)
  static let search = Self(rawValue: 8)
  var title: String {
    [(Self.web, "网页"), (.search, "搜索"), (.fileImport, "导入"), (.fileExport, "导出")]
      .filter { contains($0.0) }.map(\.1).joined(separator: " · ")
  }
}

protocol FileImportTranslator: BookTranslator {
  var fileExtensions: [String] { get }
  @MainActor func detectImport(_ data: Data) -> Bool
  @MainActor func doImport(_ data: Data) throws -> BibliographicImportResult
}

protocol FileExportTranslator: BookTranslator {
  var fileExtension: String { get }
  var exportSummary: String { get }
  @MainActor func doExport(_ records: [BookArchive], includeNotes: Bool) throws -> Data
}

protocol SearchMetadataTranslator: BookTranslator {
  func searchURL(for query: BookMetadataQuery) -> URL
  func doSearch(_ query: BookMetadataQuery, host: TranslationHost) async throws -> [MetadataSearchHit]
  func resolve(_ hit: MetadataSearchHit, host: TranslationHost) async throws -> BookMetadataSearchResult
}

/// Host-provided I/O. Translators never receive a ModelContext or write the library.
struct TranslationHost: Sendable {
  var web: any WebMetadataLoading = WebMetadataClient()
  var openLibrary: any BookMetadataProvider = OpenLibraryBookMetadataProvider()
}

struct TranslatorRegistry: Sendable {
  let translators: [any BookTranslator]
  let disabledIDs: Set<String>

  init(translators: [any BookTranslator] = BuiltinTranslators.catalog, disabledIDs: Set<String> = []) {
    self.translators = translators; self.disabledIDs = disabledIDs
  }

  func validate() throws {
    guard Set(translators.map(\.descriptor.id)).count == translators.count else {
      throw WebMetadataError.invalidConfiguration("解析器 ID 重复")
    }
  }
  var ordered: [any BookTranslator] {
    translators.sorted { ($0.descriptor.priority, $0.descriptor.id) < ($1.descriptor.priority, $1.descriptor.id) }
  }
  func capabilities(for id: String) -> TranslatorCapabilities {
    guard let translator = translators.first(where: { $0.descriptor.id == id }) else { return [] }
    var types: TranslatorCapabilities = []
    if translator is any WebMetadataTranslator { types.insert(.web) }
    if translator is any SearchMetadataTranslator { types.insert(.search) }
    if translator is any FileImportTranslator { types.insert(.fileImport) }
    if translator is any FileExportTranslator { types.insert(.fileExport) }
    return types
  }
  func translator(_ id: String) throws -> any BookTranslator {
    try validate()
    guard !disabledIDs.contains(id) else { throw WebMetadataError.disabled }
    guard let result = translators.first(where: { $0.descriptor.id == id }) else {
      throw WebMetadataError.invalidConfiguration("找不到解析器：\(id)")
    }
    return result
  }
  var webRegistry: WebTranslatorRegistry {
    WebTranslatorRegistry(translators: translators.compactMap { $0 as? any WebMetadataTranslator }, disabledIDs: disabledIDs)
  }
  var searchSources: [MetadataSearchSource] {
    ordered.filter { $0 is any SearchMetadataTranslator && !disabledIDs.contains($0.descriptor.id) }
      .map { MetadataSearchSource(id: $0.descriptor.id, name: $0.descriptor.name) }
  }
}

extension BuiltinTranslators {
  static var catalog: [any BookTranslator] {
    all.map { $0 as any BookTranslator } + [OpenLibraryTranslator(), RISTranslator(), CSVTranslator()]
  }
}

struct TranslationEngine: Sendable {
  let registry: TranslatorRegistry
  var host = TranslationHost()

  func extractWeb(_ input: String) async throws -> WebTranslationResult {
    try registry.validate(); try Task.checkCancellation()
    let result = try await host.web.extract(input, registry: registry.webRegistry)
    try Task.checkCancellation(); return result
  }
  func extractHTML(_ data: Data, sourceURL: String) throws -> WebTranslationResult {
    try registry.validate()
    return try registry.webRegistry.translate(html: data, sourceURL: sourceURL)
  }

  func search(_ query: BookMetadataQuery, source: MetadataSearchSource) async throws -> [MetadataSearchHit] {
    try Task.checkCancellation()
    let results = try await searchTranslator(source.id).doSearch(query, host: host)
    try Task.checkCancellation()
    return results
  }
  func resolve(_ hit: MetadataSearchHit) async throws -> BookMetadataSearchResult {
    try Task.checkCancellation()
    let result = try await searchTranslator(hit.source.id).resolve(hit, host: host)
    try Task.checkCancellation()
    return result
  }
  func searchTranslator(_ id: String) throws -> any SearchMetadataTranslator {
    guard let translator = try registry.translator(id) as? any SearchMetadataTranslator else {
      throw WebMetadataError.invalidConfiguration("该解析器不支持搜索")
    }
    return translator
  }
  @MainActor
  func importFile(_ data: Data, fileExtension: String = "ris") throws -> BibliographicImportResult {
    try registry.validate()
    let candidates = registry.ordered.compactMap { $0 as? any FileImportTranslator }
      .filter { $0.fileExtensions.contains(fileExtension.lowercased()) }
    for translator in candidates where !registry.disabledIDs.contains(translator.descriptor.id) {
      if translator.detectImport(data) { return try translator.doImport(data) }
    }
    if !candidates.isEmpty && candidates.allSatisfy({ registry.disabledIDs.contains($0.descriptor.id) }) {
      throw WebMetadataError.disabled
    }
    throw BibliographicExchangeError.invalid("没有可读取此文件的导入解析器，请核对格式和文件编码。")
  }
  @MainActor
  func exportFile(_ records: [BookArchive], translatorID: String, includeNotes: Bool = false) throws -> Data {
    guard let translator = try registry.translator(translatorID) as? any FileExportTranslator else {
      throw WebMetadataError.invalidConfiguration("该解析器不支持导出")
    }
    return try translator.doExport(records.filter { $0.deletedAt == nil }, includeNotes: includeNotes)
  }
}
