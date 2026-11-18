import Foundation
import SwiftData

/// A local reference with an optimistic placement/version check; no note body
/// or book metadata is transferred through the drag pasteboard.
struct NoteDragPayload: Codable, Equatable, Sendable {
  var version = 1
  let libraryID: UUID
  let noteID: UUID
  let parentBookID: UUID?
  let updatedAt: Date

  init(libraryID: UUID, note: NoteRecord) {
    self.libraryID = libraryID; noteID = note.id
    parentBookID = note.parentBookID; updatedAt = note.updatedAt
  }
  func matches(_ note: NoteRecord) -> Bool {
    noteID == note.id && parentBookID == note.parentBookID && updatedAt == note.updatedAt && note.deletedAt == nil
  }
}

/// Each dragged row carries the entire visible note selection: AppKit may ask
/// only the initiating row for data. Repeated batches are deduplicated on drop.
struct NoteDragBatch: Codable, Equatable, Sendable {
  var version = 1
  let notes: [NoteDragPayload]

  static func selection(libraryID: UUID, dragging note: NoteRecord,
    selected: Set<UUID>, available: [NoteRecord]) -> Self {
    let ids = selected.contains(note.id) ? selected : [note.id]
    let notes = available.filter { ids.contains($0.id) && $0.deletedAt == nil }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    return Self(notes: notes.map { NoteDragPayload(libraryID: libraryID, note: $0) })
  }

  static func references(in batches: [Self]) throws -> [NoteDragPayload] {
    guard !batches.isEmpty, batches.allSatisfy({ $0.version == 1 && !$0.notes.isEmpty })
    else { throw NoteMoveError.invalidDrag }
    return try NoteDragPayload.unique(batches.flatMap(\.notes))
  }
}

extension NoteDragPayload {
  static func unique(_ payloads: [Self]) throws -> [Self] {
    guard !payloads.isEmpty else { throw NoteMoveError.invalidDrag }
    var seen: [UUID: Self] = [:]
    var result: [Self] = []
    for payload in payloads {
      if let existing = seen[payload.noteID] {
        guard existing == payload else { throw NoteMoveError.invalidDrag }
      } else {
        seen[payload.noteID] = payload; result.append(payload)
      }
    }
    return result
  }
}

enum NoteDropDestination: Equatable, Sendable {
  case book(UUID)
  case topLevel(collectionID: UUID?)
}

enum NoteMoveError: LocalizedError {
  case invalidDrag, unsavedDraft
  var errorDescription: String? {
    switch self {
    case .invalidDrag: L10n.tr("无法移动所选笔记，请在当前书库中重新拖动到有效的书籍或列表顶层。")
    case .unsavedDraft: L10n.tr("所选笔记中有未保存的修改，请先重试保存或另存为新笔记。")
    }
  }
}

/// A note selection is distinct from its parent book. Multiple selected books
/// never choose an arbitrary parent; the user must select one book first.
enum NoteCreationTarget: Equatable {
  case standalone, child(UUID), unavailable

  static func resolve(selectedBookIDs: Set<UUID>, hasSelectedNote: Bool, inTrash: Bool) -> Self {
    guard !inTrash else { return .unavailable }
    if hasSelectedNote || selectedBookIDs.isEmpty { return .standalone }
    guard selectedBookIDs.count == 1, let id = selectedBookIDs.first else { return .unavailable }
    return .child(id)
  }

  func draft(collectionID: UUID?) -> NoteRecord? {
    switch self {
    case .standalone:
      var note = NoteRecord()
      if let collectionID { note.collectionIDs = [collectionID] }
      return note
    case .child(let id): return NoteRecord(parentBookID: id)
    case .unavailable: return nil
    }
  }
}

extension NoteTemplatePlugin {
  @MainActor
  func draft(for book: Book, language: InterfaceLanguage) -> NoteRecord {
    let content = localized(for: language)
    let fields = ["title": book.title, "authors": book.authors.map(\.name).joined(separator: language == .chinese ? "、" : ", "),
      "publisher": book.publisher ?? "", "isbn": book.isbn13 ?? book.isbn10 ?? ""]
    var note = NoteRecord(title: render(content.title, fields: fields), parentBookID: book.id)
    note.body = render(content.body, fields: fields)
    return note
  }
}

@MainActor
struct NoteCommands {
  let context: ModelContext
  let undoManager: UndoManager?

  @discardableResult
  func move(_ payload: NoteDragPayload, to destination: NoteDropDestination) throws -> NoteRecord {
    try move([payload], to: destination)[0]
  }

  /// Validate every reference before writing, then commit the entire batch and
  /// register one undo operation. A stale item cannot leave a partial move.
  @discardableResult
  func move(_ payloads: [NoteDragPayload], to destination: NoteDropDestination) throws -> [NoteRecord] {
    let payloads = try NoteDragPayload.unique(payloads)
    let scope = LibraryServices.forContext(context).dragScopeID
    guard payloads.allSatisfy({ $0.version == 1 && $0.libraryID == scope }) else {
      throw NoteMoveError.invalidDrag
    }
    let originals = try OrganizationStore.notes(in: context, ids: Set(payloads.map(\.noteID)))
    guard payloads.allSatisfy({ payload in originals[payload.noteID].map(payload.matches) == true })
    else { throw LibraryOperationError.changedSincePreview }
    let books = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Book>())
      .filter { $0.deletedAt == nil }.map { ($0.id, $0) })
    let manual = try OrganizationStore.collections(in: context)
    switch destination {
    case .book(let id):
      guard books[id] != nil else { throw NoteMoveError.invalidDrag }
    case .topLevel(let collectionID):
      if let collectionID, manual[collectionID] == nil { throw NoteMoveError.invalidDrag }
    }
    let now = Date()
    var before: [UUID: NoteRecord] = [:], after: [UUID: NoteRecord] = [:]
    var results: [NoteRecord] = []
    for payload in payloads {
      guard let original = originals[payload.noteID] else { throw LibraryOperationError.changedSincePreview }
      let parent = original.parentBookID.flatMap { books[$0] }
      guard original.parentBookID == nil || parent != nil else { throw OrganizationError.noteInTrash }
      var moved = original
      switch destination {
      case .book(let id):
        if original.parentBookID != id { moved.parentBookID = id; moved.collectionIDs = [] }
      case .topLevel(let collectionID):
        if let parent {
          // Retain each original parent's placements and the current manual
          // collection, so detaching notes from different books stays visible.
          var placements = Set(parent.collectionItems.compactMap(\.collection?.id).filter { manual[$0] != nil })
          if let collectionID { placements.insert(collectionID) }
          moved.parentBookID = nil; moved.collectionIDs = placements.sorted { $0.uuidString < $1.uuidString }
        }
      }
      if moved != original {
        moved.updatedAt = now; before[moved.id] = original; after[moved.id] = moved
      }
      results.append(moved)
    }
    if !after.isEmpty {
      try LibraryRepository.apply([], notes: Array(after.values), into: context)
      LibraryServices.forContext(context).history.register(after.count == 1 ? L10n.tr("移动笔记") : L10n.tr("移动 \(after.count) 条笔记"),
        before: [:], after: [:], beforeNotes: before, afterNotes: after, context: context, undoManager: undoManager)
    }
    return results
  }

  @discardableResult
  func save(_ draft: NoteRecord, expected: NoteRecord?) throws -> NoteRecord {
    guard draft.deletedAt == nil, expected?.deletedAt == nil else { throw OrganizationError.noteInTrash }
    if let parent = expected?.parentBookID,
      try context.fetch(FetchDescriptor<Book>()).first(where: { $0.id == parent })?.deletedAt != nil {
      throw OrganizationError.noteInTrash
    }
    if let parent = draft.parentBookID {
      guard let book = try context.fetch(FetchDescriptor<Book>()).first(where: { $0.id == parent }), book.deletedAt == nil
      else { throw OrganizationError.noteInTrash }
    }
    var record = draft
    record.title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
    record.tags = Array(Set(record.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    record.collectionIDs = record.parentBookID == nil ? Array(Set(record.collectionIDs)).sorted { $0.uuidString < $1.uuidString } : []
    guard try OrganizationStore.notes(in: context, ids: [record.id])[record.id] == expected
    else { throw LibraryOperationError.changedSincePreview }
    if record == expected { return record }
    record.updatedAt = Date()
    try commit(record, expected: expected, name: expected == nil ? L10n.tr("新建笔记") : L10n.tr("编辑笔记"))
    return record
  }

  func setTrashed(_ trashed: Bool, expected: NoteRecord) throws {
    if !trashed, let parent = expected.parentBookID,
      try context.fetch(FetchDescriptor<Book>()).first(where: { $0.id == parent })?.deletedAt != nil {
      throw OrganizationError.noteInTrash
    }
    var record = expected; record.deletedAt = trashed ? Date() : nil; record.updatedAt = Date()
    try commit(record, expected: expected, name: trashed ? L10n.tr("笔记移入回收站") : L10n.tr("恢复笔记"))
  }

  func purge(_ expected: NoteRecord) throws {
    let commands = TrashCommands(context: context, undoManager: undoManager)
    let plan = try commands.preview([.note(expected.id)])
    guard plan.notes[expected.id] == expected else { throw LibraryOperationError.changedSincePreview }
    try commands.purge(plan)
  }

  @discardableResult
  func convertLegacyNote(_ expected: BookArchive) throws -> NoteRecord {
    guard expected.deletedAt == nil, let body = expected.notes, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      try LibraryRepository.snapshots(in: context, ids: [expected.id])[expected.id] == expected
    else { throw LibraryOperationError.changedSincePreview }
    var book = expected; book.notes = nil; book.updatedAt = Date()
    var note = NoteRecord(title: L10n.tr("阅读笔记"), parentBookID: expected.id); note.body = body
    try LibraryRepository.apply([book], notes: [note], into: context)
    LibraryServices.forContext(context).history.register(L10n.tr("备注转为书籍笔记"), before: [expected.id: expected],
      after: try LibraryRepository.snapshots(in: context, ids: [expected.id]), afterNotes: [note.id: note],
      context: context, undoManager: undoManager)
    return note
  }

  private func commit(_ record: NoteRecord, expected: NoteRecord?, name: String) throws {
    guard expected == nil || expected?.id == record.id,
      try OrganizationStore.notes(in: context, ids: [record.id])[record.id] == expected
    else { throw LibraryOperationError.changedSincePreview }
    try LibraryRepository.apply([], notes: [record], into: context)
    LibraryServices.forContext(context).history.register(name, before: [:], after: [:],
      beforeNotes: expected.map { [$0.id: $0] } ?? [:], afterNotes: [record.id: record], context: context, undoManager: undoManager)
  }
}

enum NoteQueries {
  static func results(_ notes: [NoteRecord], books: [Book], collections: [ManualCollectionRecord],
    scope: LibrarySelection, text: String, searchScope: LibrarySearchScope = .allFields,
    includeSubcollections: Bool = false, smartQuery: AdvancedBookQuery? = nil) -> [NoteRecord] {
    var collectionIDs: Set<UUID>?
    if case .collection(let id) = scope {
      collectionIDs = includeSubcollections ? CollectionTree.descendants(of: id, in: collections) : [id]
    }
    return notes.filter { note in
      guard (scope == .trash || scope == .noteTrash) == isTrashed(note, books: books),
        matches(note, text: text, searchScope: searchScope) else { return false }
      if let smartQuery, !smartQuery.matches(note) { return false }
      switch scope {
      case .notes, .trash, .noteTrash: return true
      case .smart: return smartQuery != nil && note.parentBookID == nil
      case .all, .standaloneNotes: return note.parentBookID == nil
      case .collection: return note.parentBookID == nil && !Set(note.collectionIDs).isDisjoint(with: collectionIDs ?? [])
      default: return false
      }
    }
  }
  static func isTrashed(_ note: NoteRecord, books: [Book]) -> Bool {
    note.deletedAt != nil || note.parentBookID.map { id in books.first { $0.id == id }?.deletedAt != nil } == true
  }
  static func matches(_ note: NoteRecord, text: String, searchScope: LibrarySearchScope = .allFields) -> Bool {
    LibraryTextSearch.matches(note, query: text, scope: searchScope)
  }
}
