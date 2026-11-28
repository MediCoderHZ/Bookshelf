import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppState {
  var editorDestination: BookEditorDestination?

  func presentNewBook(type: BookType? = nil, collectionID: UUID? = nil, startWithSearch: Bool = false) {
    editorDestination = BookEditorDestination(
      book: nil, collectionID: collectionID, startWithSearch: startWithSearch, initialBookType: type)
  }

  func presentEditor(for book: Book) {
    editorDestination = BookEditorDestination(book: book)
  }
}

struct BookEditorDestination: Identifiable {
  let id = UUID()
  let book: Book?
  var collectionID: UUID? = nil
  var startWithSearch = false
  var initialBookType: BookType? = nil
}

enum AppReleaseInfo {
  static let displayName = "Bookshelf"
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
  }
  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
  }
  static var supportURL: URL? { configuredURL("BookshelfSupportURL") }
  static var privacyURL: URL? { configuredURL("BookshelfPrivacyURL") }
  static var metadataUserAgent: String {
    let contact =
      Bundle.main.object(forInfoDictionaryKey: "BookshelfMetadataContact") as? String ?? ""
    let suffix = contact.contains("@") && !contact.contains("REPLACE") ? "; \(contact)" : ""
    return "Bookshelf/\(version) (macOS\(suffix))"
  }
  private static func configuredURL(_ key: String) -> URL? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
      !value.contains("REPLACE"), let url = URL(string: value),
      url.scheme == "https", url.host != nil
    else { return nil }
    return url
  }
}

