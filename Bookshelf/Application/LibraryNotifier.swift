import Foundation
import Observation
import SwiftData

struct LibraryChange: Equatable {
  let bookIDs: Set<UUID>
  let collectionIDs: Set<UUID>
  var noteIDs: Set<UUID> = []
  var tagIDs: Set<UUID> = []
}

/// Like Zotero.Notifier, changes are published only after a successful commit.
/// No metadata is carried in events; consumers re-read their query projection.
@MainActor
@Observable
final class LibraryNotifier {
  private static let scopes = NSMapTable<ModelContext, LibraryNotifier>(keyOptions: .weakMemory, valueOptions: .strongMemory)
  static func forContext(_ context: ModelContext) -> LibraryNotifier {
    if let notifier = scopes.object(forKey: context) { return notifier }
    let notifier = LibraryNotifier(); scopes.setObject(notifier, forKey: context); return notifier
  }
  private(set) var revision = 0
  private(set) var lastChange: LibraryChange?
  @ObservationIgnored private var observers: [UUID: (LibraryChange) -> Void] = [:]

  @discardableResult
  func observe(_ callback: @escaping (LibraryChange) -> Void) -> UUID {
    let token = UUID(); observers[token] = callback; return token
  }
  func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }
  func publish(books: Set<UUID> = [], collections: Set<UUID> = [], notes: Set<UUID> = [], tags: Set<UUID> = []) {
    guard !books.isEmpty || !collections.isEmpty || !notes.isEmpty || !tags.isEmpty else { return }
    let event = LibraryChange(bookIDs: books, collectionIDs: collections, noteIDs: notes, tagIDs: tags)
    lastChange = event; revision += 1
    for callback in Array(observers.values) { callback(event) }
  }
}

/// A context owns its notification/history scope, while each window owns its
/// UndoManager. Separate libraries and in-memory tests cannot share error state.
@MainActor
final class LibraryServices {
  private static let scopes = NSMapTable<ModelContext, LibraryServices>(keyOptions: .weakMemory, valueOptions: .strongMemory)
  let history = LibraryHistory()
  let dragScopeID = UUID()
  // Used only for immediate hover feedback. The dropped data is independently validated.
  var collectionDrag: CollectionDragPayload?
  static func forContext(_ context: ModelContext) -> LibraryServices {
    if let scope = scopes.object(forKey: context) { return scope }
    let scope = LibraryServices(); scopes.setObject(scope, forKey: context); return scope
  }
}
