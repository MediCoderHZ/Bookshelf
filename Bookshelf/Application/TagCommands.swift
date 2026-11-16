import Foundation
import SwiftData

@MainActor
struct TagCommands {
  let context: ModelContext
  let undoManager: UndoManager?

  func record(_ id: UUID) throws -> TagRecord {
    guard let record = try TagStore.snapshots(in: context, ids: [id])[id]
    else { throw LibraryOperationError.changedSincePreview }
    return record
  }

  @discardableResult
  func rename(_ expected: TagRecord, to input: String, merging expectedTarget: TagRecord? = nil) throws -> UUID {
    let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = MetadataNormalizer.normalizedName(name)
    guard !key.isEmpty else { throw TagCommandError.invalidName }
    let all = try TagStore.snapshots(in: context)
    guard all[expected.id] == expected else { throw LibraryOperationError.changedSincePreview }
    let target = all.values.first { $0.id != expected.id && MetadataNormalizer.normalizedName($0.name) == key }
    guard target == expectedTarget else {
      if target != nil && expectedTarget == nil { throw TagCommandError.mergeRequired }
      throw LibraryOperationError.changedSincePreview
    }
    if let target {
      try commit(L10n.tr("合并标签"), source: expected, destination: target.name,
        beforeTags: [expected.id: expected, target.id: target], afterTags: [target], removing: [expected.id])
      return target.id
    }
    guard name != expected.name else { return expected.id }
    var renamed = expected; renamed.name = name
    // Notes can have a label before it is used by any book and has its own Tag entity.
    let existingNotes = try OrganizationStore.notes(in: context).values
      .filter { $0.tags.contains { MetadataNormalizer.normalizedName($0) == key } }
    renamed.noteIDs.formUnion(existingNotes.map(\.id))
    try commit(L10n.tr("重命名标签"), source: expected, destination: name,
      beforeTags: [expected.id: expected], afterTags: [renamed], removing: [])
    return expected.id
  }

  func remove(_ expected: TagRecord) throws {
    guard try record(expected.id) == expected else { throw LibraryOperationError.changedSincePreview }
    try commit(L10n.tr("删除标签"), source: expected, destination: nil,
      beforeTags: [expected.id: expected], afterTags: [], removing: [expected.id])
  }

  private func commit(_ action: String, source: TagRecord, destination: String?,
    beforeTags: [UUID: TagRecord], afterTags: [TagRecord], removing: Set<UUID>) throws {
    let beforeBooks = try LibraryRepository.snapshots(in: context, ids: source.bookIDs)
    let beforeNotes = try OrganizationStore.notes(in: context, ids: source.noteIDs)
    let now = Date()
    let books = beforeBooks.values.map { original in
      var record = original
      record.tags = TagRecord.replacing(record.tags, source: source.name, destination: destination).sorted()
      record.updatedAt = now
      return record
    }
    let notes = beforeNotes.values.map { original in
      var record = original
      record.tags = TagRecord.replacing(record.tags, source: source.name, destination: destination)
      record.updatedAt = now
      return record
    }
    try LibraryRepository.apply(books, notes: notes, tags: afterTags, removingTagIDs: removing, into: context)
    LibraryServices.forContext(context).history.register(action, before: beforeBooks,
      after: try LibraryRepository.snapshots(in: context, ids: source.bookIDs),
      beforeNotes: beforeNotes, afterNotes: try OrganizationStore.notes(in: context, ids: source.noteIDs),
      beforeTags: beforeTags, afterTags: try TagStore.snapshots(in: context, ids: Set(beforeTags.keys)),
      context: context, undoManager: undoManager)
  }
}
