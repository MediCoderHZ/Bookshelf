import Foundation
import SwiftData

@MainActor
struct CollectionCommands {
  let context: ModelContext
  let undoManager: UndoManager?

  func save(name: String, replacing expected: ManualCollectionRecord?) throws -> UUID {
    try save(name: name, replacing: expected, parentID: expected?.parentID)
  }

  func save(name: String, replacing expected: ManualCollectionRecord?, parentID: UUID?) throws -> UUID {
    var record = expected ?? ManualCollectionRecord(name: name)
    record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if expected == nil || expected?.parentID != parentID {
      let items = try context.fetch(FetchDescriptor<BookCollection>()).filter { $0.id != record.id }.map(CollectionOrderingItem.init)
      record.sortOrder = CollectionOrdering.nextOrder(in: items, parentID: parentID)
    }
    record.parentID = parentID; record.updatedAt = Date()
    try LibraryRepository.writeCollection(record, expected: expected, id: record.id, context: context)
    LibraryServices.forContext(context).history.register(
      expected == nil ? L10n.tr("新建文件夹") : L10n.tr("编辑文件夹"), before: [:], after: [:],
      beforeCollections: expected.map { [$0.id: $0] } ?? [:],
      afterCollections: try OrganizationStore.collections(in: context, ids: [record.id]), context: context, undoManager: undoManager)
    return record.id
  }

  /// Removing a tree removes placements only; books and standalone notes remain.
  func remove(_ expected: ManualCollectionRecord) throws {
    let all = try OrganizationStore.collections(in: context)
    guard all[expected.id] == expected else { throw LibraryOperationError.changedSincePreview }
    let ids = CollectionTree.descendants(of: expected.id, in: Array(all.values))
    let removed = all.filter { ids.contains($0.key) }
    let names = Set(removed.values.map(\.name))
    let books = try context.fetch(FetchDescriptor<Book>()).filter { $0.collectionItems.contains { $0.collection.map { ids.contains($0.id) } ?? false } }
    let beforeBooks = LibraryHistory.snapshots(books)
    let updatedBooks = beforeBooks.values.map { original in
      var record = original; record.collections.removeAll { names.contains($0) }; return record
    }
    let beforeNotes = try OrganizationStore.notes(in: context).filter { !Set($0.value.collectionIDs).isDisjoint(with: ids) }
    let updatedNotes = beforeNotes.values.map { original in
      var record = original; record.collectionIDs.removeAll { ids.contains($0) }; return record
    }
    try LibraryRepository.apply(updatedBooks, removingCollectionIDs: ids, notes: updatedNotes, into: context)
    LibraryServices.forContext(context).history.register(L10n.tr("移除文件夹及子文件夹"), before: beforeBooks, after: LibraryHistory.snapshots(books),
      beforeCollections: removed, beforeNotes: beforeNotes,
      afterNotes: try OrganizationStore.notes(in: context, ids: Set(beforeNotes.keys)), context: context, undoManager: undoManager)
  }
}
