import Foundation
import SwiftData

/// Composition root for the native storage adapter. Entity names remain stable so
/// existing stores keep their identity; failed opens never create a replacement store.
@MainActor
enum LibraryDatabase {
  static var schema: Schema {
    Schema([Book.self, Person.self, Contribution.self, Tag.self, BookTag.self,
      BookCollection.self, CollectionItem.self, BookSeries.self, SeriesMembership.self, LibraryNote.self])
  }

  static func open(inMemory: Bool = false, at url: URL? = nil) throws -> ModelContainer {
    let configuration = url.map { ModelConfiguration(schema: schema, url: $0) }
      ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    // Commands explicitly commit. A partially edited form must never autosave.
    container.mainContext.autosaveEnabled = false
    try removeRetiredRules(in: container.mainContext)
    return container
  }

  /// The inferred schema migration removes the obsolete Book attributes. Clean
  /// stored query JSON before the UI or undo history can load those definitions.
  private static func removeRetiredRules(in context: ModelContext) throws {
    do {
      for collection in try context.fetch(FetchDescriptor<BookCollection>()) {
        guard let text = collection.smartRulesJSON,
          let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
        guard let cleaned = RetiredReadingData.cleanQuery(object) else {
          context.delete(collection)
          continue
        }
        if !NSDictionary(dictionary: object).isEqual(to: cleaned) {
          collection.smartRulesJSON = String(decoding: try JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]), as: UTF8.self)
        }
      }
      for book in try context.fetch(FetchDescriptor<Book>()) {
        let cleaned = RetiredReadingData.cleanFieldOrigins(book.metadataFieldSourcesJSON)
        if cleaned != book.metadataFieldSourcesJSON { book.metadataFieldSourcesJSON = cleaned }
      }
      if context.hasChanges { try context.save() }
    } catch {
      context.rollback()
      throw error
    }
  }
}
