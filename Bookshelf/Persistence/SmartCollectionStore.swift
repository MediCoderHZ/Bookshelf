import Foundation
import SwiftData

@MainActor
enum SmartCollectionStore {
  // Participates in the same database transaction as book imports and undo.
  static func stage(_ records: [SmartCollectionArchive], removing ids: Set<UUID>, context: ModelContext) throws {
    guard !records.isEmpty || !ids.isEmpty else { return }
    let collections = try context.fetch(FetchDescriptor<BookCollection>())
    let updates = Set(records.map(\.id))
    guard updates.count == records.count, updates.isDisjoint(with: ids), records.allSatisfy(\.isValid),
      collections.filter({ ids.contains($0.id) || updates.contains($0.id) }).allSatisfy(\.isSmart) else { throw SmartCollectionError.invalidRules }
    var names = Set(collections.filter { $0.isSmart && !updates.contains($0.id) && !ids.contains($0.id) }.map(\.normalizedName))
    for record in records where !names.insert(MetadataNormalizer.normalizedName(record.name)).inserted { throw SmartCollectionError.duplicateName }
    for collection in collections where ids.contains(collection.id) { context.delete(collection) }
    for record in records {
      let collection = collections.first { $0.id == record.id } ?? BookCollection(name: record.name)
      if collection.modelContext == nil { context.insert(collection) }
      collection.id = record.id; collection.name = record.name
      collection.normalizedName = MetadataNormalizer.normalizedName(record.name)
      collection.smartRulesJSON = try record.query.encoded()
      collection.symbolName = "folder.badge.gearshape"
      collection.sortOrder = record.sortOrder
      collection.createdAt = record.createdAt; collection.updatedAt = record.updatedAt
    }
  }
}
