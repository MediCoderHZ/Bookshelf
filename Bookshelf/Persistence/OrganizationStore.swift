import Foundation
import SwiftData

@MainActor
enum OrganizationStore {
  static func collections(in context: ModelContext, ids: Set<UUID>? = nil) throws -> [UUID: ManualCollectionRecord] {
    let records = try context.fetch(FetchDescriptor<BookCollection>())
      .filter { !$0.isSmart && (ids == nil || ids!.contains($0.id)) }.map(ManualCollectionRecord.init)
    return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
  }
  static func notes(in context: ModelContext, ids: Set<UUID>? = nil) throws -> [UUID: NoteRecord] {
    let records = try context.fetch(FetchDescriptor<LibraryNote>())
      .filter { ids == nil || ids!.contains($0.id) }.map(NoteRecord.init)
    return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
  }

  static func stageCollections(_ records: [ManualCollectionRecord], removing ids: Set<UUID>, context: ModelContext) throws {
    let all = try context.fetch(FetchDescriptor<BookCollection>())
    let smartIDs = Set(all.filter(\.isSmart).map(\.id))
    guard Set(records.map(\.id)).count == records.count,
      ids.isDisjoint(with: records.map(\.id)), smartIDs.isDisjoint(with: ids.union(records.map(\.id)))
    else { throw OrganizationError.invalidHierarchy }
    let updatedIDs = Set(records.map(\.id))
    let graph = all.filter { !$0.isSmart && !ids.contains($0.id) && !updatedIDs.contains($0.id) }.map(ManualCollectionRecord.init) + records
    try CollectionTree.validate(graph)
    for collection in all where ids.contains(collection.id) { context.delete(collection) }
    for record in records {
      let collection = all.first { $0.id == record.id } ?? BookCollection(name: record.name)
      if collection.modelContext == nil { context.insert(collection) }
      collection.id = record.id; collection.name = record.name
      collection.normalizedName = MetadataNormalizer.normalizedName(record.name)
      collection.parentID = record.parentID
      collection.sortOrder = record.sortOrder
      collection.createdAt = record.createdAt; collection.updatedAt = record.updatedAt
    }
  }

  static func stageNotes(_ records: [NoteRecord], removing ids: Set<UUID>,
    removingBookIDs: Set<UUID>, removingCollectionIDs: Set<UUID>, context: ModelContext) throws {
    let all = try context.fetch(FetchDescriptor<LibraryNote>())
    guard Set(records.map(\.id)).count == records.count, ids.isDisjoint(with: records.map(\.id))
    else { throw LibraryBackupError.invalidDocument }
    let updatedIDs = Set(records.map(\.id))
    let final = all.filter { !ids.contains($0.id) && !updatedIDs.contains($0.id) }.map(NoteRecord.init) + records
    let bookIDs = Set(try context.fetch(FetchDescriptor<Book>()).map(\.id)).subtracting(removingBookIDs)
    let collectionIDs = Set(try context.fetch(FetchDescriptor<BookCollection>()).filter { !$0.isSmart }.map(\.id)).subtracting(removingCollectionIDs)
    for note in final {
      guard note.parentBookID.map({ bookIDs.contains($0) && note.collectionIDs.isEmpty }) ?? true,
        Set(note.collectionIDs).isSubset(of: collectionIDs)
      else { throw OrganizationError.missingParent }
    }
    for note in all where ids.contains(note.id) { context.delete(note) }
    for record in records {
      let note = all.first { $0.id == record.id } ?? LibraryNote(title: record.title)
      if note.modelContext == nil { context.insert(note) }
      note.id = record.id; note.title = record.title; note.body = record.body
      note.parentBookID = record.parentBookID; note.collectionIDs = record.collectionIDs; note.tags = record.tags
      note.createdAt = record.createdAt; note.updatedAt = record.updatedAt; note.deletedAt = record.deletedAt
    }
  }
}
