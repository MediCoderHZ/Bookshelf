import Foundation
import SwiftData

/// Immutable confirmation contents, including children that will be deleted with a book.
struct TrashPlan: Equatable {
  let selectedIDs: Set<LibraryItemID>
  let books: [UUID: BookArchive]
  let notes: [UUID: NoteRecord]
  let parents: [UUID: BookArchive]
  let emptiesTrash: Bool

  var summary: String {
    [books.isEmpty ? nil : L10n.tr("\(books.count) 本书"), notes.isEmpty ? nil : L10n.tr("\(notes.count) 条笔记")]
      .compactMap { $0 }.joined(separator: "、")
  }
  var confirmationTitle: String { emptiesTrash ? L10n.tr("清空回收站？") : L10n.tr("永久删除\(summary)？") }
  var confirmationMessage: String {
    let scope = emptiesTrash ? L10n.tr("将删除回收站中的全部 \(summary)，包括当前搜索或筛选未显示的条目。") : L10n.tr("将删除\(summary)。")
    let children = books.isEmpty ? "" : L10n.tr("笔记数量包含所选书籍下的全部子笔记；书籍元信息也会删除。")
    return scope + children + L10n.tr("此操作无法撤销，删除后无法从回收站恢复。")
  }
  var canRestore: Bool { !parents.values.contains { $0.deletedAt != nil } }
}

@MainActor
struct TrashCommands {
  let context: ModelContext
  let undoManager: UndoManager?

  func preview(_ ids: Set<LibraryItemID>) throws -> TrashPlan {
    try makePlan(ids: ids, emptiesTrash: false)
  }

  /// Deliberately independent of the UI's search, tag filters and selection.
  func previewEmptyTrash() throws -> TrashPlan {
    try makePlan(ids: [], emptiesTrash: true)
  }

  func restore(_ plan: TrashPlan) throws {
    try validate(plan)
    guard plan.canRestore else { throw OrganizationError.noteInTrash }
    let now = Date()
    let restoredBooks = plan.books.values.map { original in
      var record = original
      record.deletedAt = nil; record.mergedIntoID = nil; record.updatedAt = now
      return record
    }
    // Restoring a book revives inherited children. Explicitly deleted children
    // stay in trash unless they too were selected for restoration.
    let selectedNotes = plan.notes.filter { plan.selectedIDs.contains(.note($0.key)) && $0.value.deletedAt != nil }
    let restoredNotes = selectedNotes.values.map { original in
      var record = original; record.deletedAt = nil; record.updatedAt = now; return record
    }
    try LibraryRepository.apply(restoredBooks, notes: restoredNotes, into: context)
    LibraryServices.forContext(context).history.register(L10n.tr("恢复回收站条目"), before: plan.books,
      after: try LibraryRepository.snapshots(in: context, ids: Set(plan.books.keys)),
      beforeNotes: selectedNotes, afterNotes: try OrganizationStore.notes(in: context, ids: Set(selectedNotes.keys)),
      context: context, undoManager: undoManager)
  }

  func purge(_ plan: TrashPlan) throws {
    try validate(plan)
    try LibraryRepository.apply([], removing: Set(plan.books.keys), removingNoteIDs: Set(plan.notes.keys), into: context)
    // Older undo entries must not resurrect permanently deleted records.
    undoManager?.removeAllActions(withTarget: LibraryServices.forContext(context).history)
  }

  private func validate(_ plan: TrashPlan) throws {
    guard let current = try? makePlan(ids: plan.selectedIDs, emptiesTrash: plan.emptiesTrash), current == plan
    else { throw LibraryOperationError.changedSincePreview }
  }

  private func makePlan(ids requested: Set<LibraryItemID>, emptiesTrash: Bool) throws -> TrashPlan {
    let allBooks = try LibraryRepository.snapshots(in: context)
    let allNotes = try OrganizationStore.notes(in: context)
    let deletedBookIDs = Set(allBooks.values.filter { $0.deletedAt != nil }.map(\.id))
    let deletedNoteIDs = Set(allNotes.values.filter {
      $0.deletedAt != nil || $0.parentBookID.map(deletedBookIDs.contains) == true
    }.map(\.id))
    let ids = emptiesTrash
      ? Set(deletedBookIDs.map(LibraryItemID.book)).union(deletedNoteIDs.map(LibraryItemID.note)) : requested
    let bookIDs = Set(ids.compactMap(\.bookID)), selectedNoteIDs = Set(ids.compactMap(\.noteID))
    guard !ids.isEmpty, bookIDs.isSubset(of: deletedBookIDs), selectedNoteIDs.isSubset(of: deletedNoteIDs)
    else { throw LibraryOperationError.invalidSelection }
    let notes = allNotes.filter { selectedNoteIDs.contains($0.key) || $0.value.parentBookID.map(bookIDs.contains) == true }
    let parentIDs = Set(notes.values.compactMap(\.parentBookID)).subtracting(bookIDs)
    return TrashPlan(selectedIDs: ids, books: allBooks.filter { bookIDs.contains($0.key) }, notes: notes,
      parents: allBooks.filter { parentIDs.contains($0.key) }, emptiesTrash: emptiesTrash)
  }
}
