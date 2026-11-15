import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum BookDragTransfer {
  static let type = UTType(exportedAs: "org.bookshelf.book-drag", conformingTo: .data)

  static func provider(for payload: BookDragPayload, title: String) -> NSItemProvider? {
    guard let data = try? JSONEncoder().encode(payload) else { return nil }
    let provider = NSItemProvider()
    provider.suggestedName = title
    provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
      completion(data, nil)
      return nil
    }
    return provider
  }

  @MainActor
  static func load(_ provider: NSItemProvider) async throws -> BookDragPayload {
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
        if let error { continuation.resume(throwing: error) }
        else if let data { continuation.resume(returning: data) }
        else { continuation.resume(throwing: LibraryOperationError.invalidSelection) }
      }
    }
    return try JSONDecoder().decode(BookDragPayload.self, from: data)
  }

  @MainActor
  static func loadSelection(from providers: [NSItemProvider]) async throws -> BookDragPayload {
    // Every row carries the complete selection. macOS can leave subsequent
    // file-promise providers waiting indefinitely after the first has loaded.
    // Read that complete batch once instead of requesting redundant providers.
    guard let provider = providers.first else { throw LibraryOperationError.invalidSelection }
    return try await load(provider)
  }
}

