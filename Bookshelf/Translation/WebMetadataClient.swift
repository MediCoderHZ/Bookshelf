import Foundation

struct FetchedMetadataPage: Sendable {
  let data: Data
  let url: URL
}

protocol WebMetadataLoading: Sendable {
  func searchPage(_ url: URL, translator: any BookSearchTranslator) async throws -> FetchedMetadataPage
  func extract(_ input: String, registry: WebTranslatorRegistry) async throws -> WebTranslationResult
}

struct WebMetadataClient: WebMetadataLoading {
  static let htmlLimit = 3 * 1_024 * 1_024

  func extract(_ input: String, registry: WebTranslatorRegistry) async throws -> WebTranslationResult {
    let (_, url) = try registry.resolve(input)
    let page = try await fetch(url)
    try Task.checkCancellation()
    return try registry.translate(html: page.data, sourceURL: page.url.absoluteString)
  }

  func searchPage(_ url: URL, translator: any BookSearchTranslator) async throws -> FetchedMetadataPage {
    guard WebURLPolicy.normalized(url) == url, translator.canonicalURL(for: url) != nil else { throw WebMetadataError.unsupportedURL }
    return try await fetch(url, redirectTranslator: translator)
  }

  func extractSavedHTML(_ data: Data, sourceURL: String, registry: WebTranslatorRegistry) throws -> WebTranslationResult {
    try registry.translate(html: data, sourceURL: sourceURL)
  }

  // ISBN search can redirect to a detail page. Only known paths on the same HTTPS
  // host are followed, with an explicit bound. Login and off-site redirects fail.
  static func searchRedirect(_ destination: URL, from source: URL, translator: any BookSearchTranslator) -> URL? {
    guard destination.scheme?.lowercased() == "https", destination.host?.lowercased() == source.host?.lowercased(),
      let safe = WebURLPolicy.normalized(destination), let canonical = translator.canonicalURL(for: safe),
      WebURLPolicy.normalized(canonical) == canonical else { return nil }
    return canonical
  }

  private func fetch(_ url: URL, redirectTranslator: (any BookSearchTranslator)? = nil) async throws -> FetchedMetadataPage {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var currentURL = url
    for redirectCount in 0...3 {
      try Task.checkCancellation()
      var request = URLRequest(url: currentURL)
      request.setValue(AppReleaseInfo.metadataUserAgent, forHTTPHeaderField: "User-Agent")
      request.setValue("text/html", forHTTPHeaderField: "Accept")
      let (bytes, response) = try await session.bytes(for: request, delegate: NoWebRedirects())
      guard let http = response as? HTTPURLResponse else { throw WebMetadataError.noBook }
      if [301, 302, 303, 307, 308].contains(http.statusCode), let redirectTranslator, redirectCount < 3,
        let location = http.value(forHTTPHeaderField: "Location"),
        let destination = URL(string: location, relativeTo: currentURL)?.absoluteURL,
        let next = Self.searchRedirect(destination, from: currentURL, translator: redirectTranslator), next != currentURL {
        currentURL = next
        continue
      }
      guard (200...299).contains(http.statusCode) else {
        if [301, 302, 303, 307, 308, 401, 403, 418, 429].contains(http.statusCode) {
          throw WebMetadataError.accessRestricted
        }
        throw WebMetadataError.httpStatus(http.statusCode)
      }
      let mime = response.mimeType?.lowercased() ?? ""
      guard ["text/html", "application/xhtml+xml"].contains(mime)
      else { throw WebMetadataError.unexpectedContent }
      let limit = Self.htmlLimit
      guard response.expectedContentLength <= Int64(limit) else { throw WebMetadataError.tooLarge }
      var data = Data()
      for try await byte in bytes {
        if data.count >= limit { throw WebMetadataError.tooLarge }
        data.append(byte)
      }
      try Task.checkCancellation()
      return FetchedMetadataPage(data: data, url: currentURL)
    }
    throw WebMetadataError.accessRestricted
  }
}

final class NoWebRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
