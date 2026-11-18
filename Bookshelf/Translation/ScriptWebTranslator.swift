import Foundation

protocol ScriptedSearchSource: SearchMetadataTranslator {
  var script: TranslatorScript { get }
}

extension ScriptedSearchSource {
  var descriptor: TranslatorDescriptor { script.descriptor }
  func searchURL(for query: BookMetadataQuery) throws -> URL { try script.searchURL(for: query) }
}

struct ScriptWebTranslator: ScriptedSearchSource, BookSearchTranslator {
  let script: TranslatorScript

  func canonicalURL(for url: URL) -> URL? { script.canonicalURL(for: url) }

  func detectWeb(in document: HTMLMetadataDocument, url: URL) throws -> WebPageKind? {
    try script.call("detectWeb", [TranslatorScript.urlInfo(url)], document: document)
  }

  func doWeb(in document: HTMLMetadataDocument, url: URL, kind: WebPageKind) throws -> TranslatedWebPage {
    let arguments: [Any] = [TranslatorScript.urlInfo(url), kind.rawValue]
    if kind == .multiple {
      let choices: [WebBookCandidate] = try script.call("doWeb", arguments, document: document)
      guard !choices.isEmpty else { throw WebMetadataError.noBooks }
      return .choices(choices)
    }
    var book: BookMetadataSearchResult = try script.call("doWeb", arguments, document: document)
    book.sourceName = descriptor.name
    book.sourceURL = url
    return .book(book)
  }

  func searchResults(in document: HTMLMetadataDocument, url: URL) throws -> [WebBookCandidate] {
    try script.call("doSearch", [TranslatorScript.urlInfo(url)], document: document)
  }
}
