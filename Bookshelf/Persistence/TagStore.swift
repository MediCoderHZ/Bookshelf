import Foundation
import SwiftData

@MainActor
enum TagStore {
  static func snapshots(in context: ModelContext, ids: Set<UUID>? = nil) throws -> [UUID: TagRecord] {
    if ids?.isEmpty == true { return [:] }
    let notes = try context.fetch(FetchDescriptor<LibraryNote>())
    let records = try context.fetch(FetchDescriptor<Tag>())
      .filter { ids == nil || ids!.contains($0.id) }.map { TagRecord($0, notes: notes) }
    return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
  }

  /// Stage identities before book memberships resolve their names in the same transaction.
  static func stage(_ records: [TagRecord], removing ids: Set<UUID>, changingNoteIDs: Set<UUID>, context: ModelContext) throws {
    guard !records.isEmpty || !ids.isEmpty else { return }
    let all = try context.fetch(FetchDescriptor<Tag>())
    let updated = Set(records.map(\.id))
    guard updated.count == records.count, ids.isDisjoint(with: updated) else { throw TagCommandError.invalidName }
    var names = Set(all.filter { !ids.contains($0.id) && !updated.contains($0.id) }.map(\.normalizedName))
    let notes = try context.fetch(FetchDescriptor<LibraryNote>())
    for record in records {
      let key = MetadataNormalizer.normalizedName(record.name)
      guard !key.isEmpty, names.insert(key).inserted else { throw TagCommandError.invalidName }
      let references = Set(notes.filter { $0.tags.contains { MetadataNormalizer.normalizedName($0) == key } }.map(\.id))
      guard references.isSubset(of: record.noteIDs.union(changingNoteIDs))
      else { throw LibraryOperationError.changedSincePreview }
    }
    for tag in all where ids.contains(tag.id) { context.delete(tag) }
    for record in records {
      let tag = all.first { $0.id == record.id } ?? Tag(name: record.name)
      if tag.modelContext == nil { context.insert(tag) }
      tag.id = record.id; tag.name = record.name
      tag.normalizedName = MetadataNormalizer.normalizedName(record.name)
      tag.createdAt = record.createdAt
    }
  }
}
