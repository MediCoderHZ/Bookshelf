import Foundation
import SwiftData

/// Application command boundary. Views pass drafts or intent, never commit models.
@MainActor
struct LibraryCommands {
  let context: ModelContext
  let undoManager: UndoManager?

  func save(_ draft: BookArchive, expected: BookArchive?) throws {
    var record = draft
    record.title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !record.title.isEmpty, record.deletedAt == nil else { throw LibraryOperationError.invalidSelection }
    if let expected {
      guard expected.id == record.id, expected.deletedAt == nil else { throw LibraryOperationError.invalidSelection }
    }
    record.updatedAt = Date()
    record.contributors.sort { ($0.roleRaw, $0.displayOrder, $0.name) < ($1.roleRaw, $1.displayOrder, $1.name) }
    try commit(expected == nil ? "添加书籍" : "编辑书籍", records: [record],
      expected: expected.map { [$0.id: $0] } ?? [:])
  }

  func update(_ books: [Book], name: String = "整理书籍", change: (inout BookArchive) -> Void) throws {
    guard books.allSatisfy({ $0.deletedAt == nil && $0.modelContext === context }) else {
      throw LibraryOperationError.invalidSelection
    }
    let before = LibraryHistory.snapshots(books)
    var records: [BookArchive] = []
    for original in before.values {
      var record = original; change(&record)
      guard record.id == original.id else { throw LibraryOperationError.invalidSelection }
      if record != original { record.updatedAt = Date(); records.append(record) }
    }
    guard !records.isEmpty else { return }
    let ids = Set(records.map(\.id))
    try commit(name, records: records, expected: before.filter { ids.contains($0.key) })
  }

  func setMembership(_ books: [Book], collection: BookCollection, included: Bool) throws {
    guard !collection.isSmart, collection.modelContext === context else { throw LibraryOperationError.invalidSelection }
    try update(books, name: included ? "加入文件夹" : "从文件夹移除") { record in
      record.collections.removeAll { $0 == collection.name }
      if included { record.collections.append(collection.name) }
      record.collections.sort()
    }
  }

  func setTag(_ name: String, included: Bool, book: Book) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let key = MetadataNormalizer.normalizedName(name)
    try update([book]) { record in
      let exists = record.tags.contains { MetadataNormalizer.normalizedName($0) == key }
      if included && !exists { record.tags.append(name) }
      if !included { record.tags.removeAll { MetadataNormalizer.normalizedName($0) == key } }
      record.tags.sort()
    }
  }

  func saveNote(_ text: String, expected: BookArchive) throws {
    guard expected.deletedAt == nil else { throw LibraryOperationError.invalidSelection }
    var record = expected; record.notes = text.isEmpty ? nil : text
    guard record != expected else { return }
    record.updatedAt = Date()
    try commit("编辑笔记", records: [record], expected: [expected.id: expected])
  }

  private func commit(_ name: String, records: [BookArchive], expected: [UUID: BookArchive]) throws {
    let ids = Set(records.map(\.id))
    let actual = try LibraryRepository.snapshots(in: context, ids: ids)
    guard actual == expected else { throw LibraryOperationError.changedSincePreview }
    try LibraryRepository.apply(records, into: context)
    LibraryServices.forContext(context).history.register(name, before: expected,
      after: try LibraryRepository.snapshots(in: context, ids: ids), context: context, undoManager: undoManager)
  }
}
