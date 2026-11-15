import Foundation
import SwiftData

/// Local references only: a drag never copies metadata or creates another book.
struct BookDragPayload: Codable, Equatable, Sendable {
  var version = 1
  let libraryID: UUID
  let bookIDs: Set<UUID>

  /// Native Table may request a provider only for the row that starts the drag.
  /// Carry the selection explicitly, while excluding rows outside this view.
  static func selection(libraryID: UUID, dragging bookID: UUID,
    selected: Set<UUID>, available: Set<UUID>) -> BookDragPayload? {
    guard available.contains(bookID) else { return nil }
    let ids = selected.contains(bookID) ? selected.intersection(available) : [bookID]
    return BookDragPayload(libraryID: libraryID, bookIDs: ids)
  }
}

extension LibraryCommands {
  @discardableResult
  func addDroppedBooks(_ payloads: [BookDragPayload], to collectionID: UUID) throws -> Int {
    let scope = LibraryServices.forContext(context).dragScopeID
    guard !payloads.isEmpty,
      payloads.allSatisfy({ $0.version == 1 && $0.libraryID == scope && !$0.bookIDs.isEmpty }) else {
      throw LibraryOperationError.invalidSelection
    }
    let ids = payloads.reduce(into: Set<UUID>()) { $0.formUnion($1.bookIDs) }
    let collections = try context.fetch(FetchDescriptor<BookCollection>())
    guard let collection = collections.first(where: { $0.id == collectionID && !$0.isSmart }) else {
      throw LibraryOperationError.invalidSelection
    }
    let books = try context.fetch(FetchDescriptor<Book>()).filter { ids.contains($0.id) }
    // Revalidate the entire batch after asynchronous drag data loading. Never
    // silently add only part of a stale selection or accept a note's identifier.
    guard books.count == ids.count, books.allSatisfy({ $0.deletedAt == nil }) else {
      throw LibraryOperationError.changedSincePreview
    }
    let additions = books.filter { book in
      !book.collectionItems.contains { $0.collection?.id == collectionID }
    }
    guard !additions.isEmpty else { return 0 }
    try setMembership(additions, collection: collection, included: true)
    return additions.count
  }
}
