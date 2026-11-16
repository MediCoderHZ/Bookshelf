import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LibraryHistory {
  var errorMessage: String?
  private(set) var revision = 0
  func changed() { revision += 1 }

  static func snapshots(_ books: [Book]) -> [UUID: BookArchive] {
    Dictionary(uniqueKeysWithValues: books.map { ($0.id, BookArchive(book: $0)) })
  }

  func register(_ name: String, before: [UUID: BookArchive], after: [UUID: BookArchive],
    beforeSmart: [UUID: SmartCollectionArchive] = [:], afterSmart: [UUID: SmartCollectionArchive] = [:],
    beforeCollections: [UUID: ManualCollectionRecord] = [:], afterCollections: [UUID: ManualCollectionRecord] = [:],
    beforeNotes: [UUID: NoteRecord] = [:], afterNotes: [UUID: NoteRecord] = [:],
    beforeTags: [UUID: TagRecord] = [:], afterTags: [UUID: TagRecord] = [:],
    context: ModelContext, undoManager: UndoManager?) {
    guard let undoManager else { return }
    undoManager.registerUndo(withTarget: self) { history in
      MainActor.assumeIsolated {
        history.restore(name, desired: before, expected: after, desiredSmart: beforeSmart, expectedSmart: afterSmart,
          desiredCollections: beforeCollections, expectedCollections: afterCollections, desiredNotes: beforeNotes, expectedNotes: afterNotes,
          desiredTags: beforeTags, expectedTags: afterTags,
          context: context, undoManager: undoManager)
      }
    }
    undoManager.setActionName(name)
    revision += 1
  }

  private func restore(_ name: String, desired: [UUID: BookArchive], expected: [UUID: BookArchive],
    desiredSmart: [UUID: SmartCollectionArchive], expectedSmart: [UUID: SmartCollectionArchive],
    desiredCollections: [UUID: ManualCollectionRecord], expectedCollections: [UUID: ManualCollectionRecord],
    desiredNotes: [UUID: NoteRecord], expectedNotes: [UUID: NoteRecord],
    desiredTags: [UUID: TagRecord], expectedTags: [UUID: TagRecord],
    context: ModelContext, undoManager: UndoManager) {
    do {
      let ids = Set(desired.keys).union(expected.keys)
      let current = try context.fetch(FetchDescriptor<Book>()).filter { ids.contains($0.id) }
      let actual = Self.snapshots(current)
      let smartIDs = Set(desiredSmart.keys).union(expectedSmart.keys)
      let actualSmart = try SmartCollectionService.snapshots(in: context, ids: smartIDs)
      let collectionIDs = Set(desiredCollections.keys).union(expectedCollections.keys)
      let noteIDs = Set(desiredNotes.keys).union(expectedNotes.keys)
      let tagIDs = Set(desiredTags.keys).union(expectedTags.keys)
      guard actual == expected, actualSmart == expectedSmart,
        try OrganizationStore.collections(in: context, ids: collectionIDs) == expectedCollections,
        try OrganizationStore.notes(in: context, ids: noteIDs) == expectedNotes,
        try TagStore.snapshots(in: context, ids: tagIDs) == expectedTags
      else { throw LibraryOperationError.changedSincePreview }
      try LibraryRepository.apply(Array(desired.values), removing: ids.subtracting(desired.keys),
        smartCollections: Array(desiredSmart.values), removingSmartIDs: smartIDs.subtracting(desiredSmart.keys),
        manualCollections: Array(desiredCollections.values), removingCollectionIDs: collectionIDs.subtracting(desiredCollections.keys),
        notes: Array(desiredNotes.values), removingNoteIDs: noteIDs.subtracting(desiredNotes.keys),
        tags: Array(desiredTags.values), removingTagIDs: tagIDs.subtracting(desiredTags.keys), into: context)
      let restored = try context.fetch(FetchDescriptor<Book>()).filter { ids.contains($0.id) }
      register(name, before: expected, after: Self.snapshots(restored), beforeSmart: expectedSmart,
        afterSmart: try SmartCollectionService.snapshots(in: context, ids: smartIDs),
        beforeCollections: expectedCollections, afterCollections: try OrganizationStore.collections(in: context, ids: collectionIDs),
        beforeNotes: expectedNotes, afterNotes: try OrganizationStore.notes(in: context, ids: noteIDs),
        beforeTags: expectedTags, afterTags: try TagStore.snapshots(in: context, ids: tagIDs), context: context, undoManager: undoManager)
    } catch { errorMessage = error.localizedDescription; revision += 1 }
  }
}

enum LibraryOperationError: LocalizedError {
  case changedSincePreview, differentEditions, invalidSelection
  var errorDescription: String? {
    switch self {
    case .changedSincePreview: L10n.tr("记录在预览或操作后发生了变化，已停止以免覆盖新修改。请重新打开预览。")
    case .differentEditions: L10n.tr("所选记录的有效 ISBN 不同，属于不同版本，请分别保留。")
    case .invalidSelection: L10n.tr("请重新选择有效的书籍和处理方式。")
    }
  }
}

@MainActor
enum LibraryOperations {
  static func setTrashed(_ trashed: Bool, books: [Book], context: ModelContext, undoManager: UndoManager?) throws {
    guard books.allSatisfy({ $0.modelContext === context }) else { throw LibraryOperationError.invalidSelection }
    let before = LibraryHistory.snapshots(books)
    let records = before.values.map { original in
      var record = original
      record.deletedAt = trashed ? Date() : nil
      if !trashed { record.mergedIntoID = nil }
      record.updatedAt = Date()
      return record
    }
    try LibraryRepository.apply(records, into: context)
    LibraryServices.forContext(context).history.register(trashed ? L10n.tr("移入回收站") : L10n.tr("恢复书籍"), before: before,
      after: LibraryHistory.snapshots(books), context: context, undoManager: undoManager)
  }

  static func purge(_ books: [Book], context: ModelContext, undoManager: UndoManager?) throws {
    guard books.allSatisfy({ $0.deletedAt != nil && $0.modelContext === context }) else { throw LibraryOperationError.invalidSelection }
    guard !books.isEmpty else { return }
    let commands = TrashCommands(context: context, undoManager: undoManager)
    try commands.purge(commands.preview(Set(books.map { .book($0.id) })))
  }

  static func merge(_ snapshots: [BookArchive], primaryID: UUID, choices: [BookField: UUID],
    context: ModelContext, undoManager: UndoManager?) throws -> UUID {
    guard snapshots.count >= 2, Set(snapshots.map(\.id)).count == snapshots.count,
      let primary = snapshots.first(where: { $0.id == primaryID }),
      snapshots.allSatisfy({ $0.deletedAt == nil }) else { throw LibraryOperationError.invalidSelection }
    let knownISBNs = Set(snapshots.compactMap { ISBN.identity($0.isbn13) ?? ISBN.identity($0.isbn10) })
    guard knownISBNs.count <= 1 else { throw LibraryOperationError.differentEditions }
    let ids = Set(snapshots.map(\.id))
    let books = try context.fetch(FetchDescriptor<Book>()).filter { ids.contains($0.id) }
    let before = LibraryHistory.snapshots(books)
    guard before == Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) }) else { throw LibraryOperationError.changedSincePreview }
    var merged = BookRecordMerge.combine(primary: primary, others: snapshots.filter { $0.id != primaryID }, choices: choices)
    merged.deletedAt = nil
    merged.mergedIntoID = nil
    var records = [merged]
    for var original in snapshots where original.id != primaryID {
      original.deletedAt = Date()
      original.updatedAt = Date()
      original.mergedIntoID = primaryID
      records.append(original)
    }
    let attachedNotes = try OrganizationStore.notes(in: context).filter { $0.value.parentBookID.map { ids.contains($0) && $0 != primaryID } ?? false }
    let movedNotes = attachedNotes.values.map { note in
      var moved = note; moved.parentBookID = primaryID; moved.updatedAt = Date(); return moved
    }
    try LibraryRepository.apply(records, notes: movedNotes, into: context)
    LibraryServices.forContext(context).history.register(L10n.tr("合并书籍"), before: before, after: LibraryHistory.snapshots(books),
      beforeNotes: attachedNotes, afterNotes: try OrganizationStore.notes(in: context, ids: Set(attachedNotes.keys)),
      context: context, undoManager: undoManager)
    return primaryID
  }
}
