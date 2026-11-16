import Foundation
import SwiftData

/// Row identity belongs to the editing session, independent of name and position.
struct ContributorNameDraft: Codable, Identifiable, Equatable {
  let id: UUID
  var name: String
  var savedName: String?
  init(name: String, saved: Bool = true) {
    id = UUID(); self.name = name; savedName = saved ? name : nil
  }
  var isEmptyNewRow: Bool { savedName == nil && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum ContributorEditError: LocalizedError {
  case emptyName, multilineName
  var errorDescription: String? {
    switch self {
    case .emptyName: L10n.tr("姓名不能为空。如需删除此人，请使用减号按钮。")
    case .multilineName: L10n.tr("请在每行填写一位作者或译者的姓名，使用加号添加其他人。")
    }
  }
}

/// A sheet owns these rows until the whole book is saved. Never flatten names
/// into a delimited string: punctuation and repeated names are meaningful.
struct ContributorListDraft {
  private(set) var rows: [ContributorNameDraft]

  init(people: [ContributorArchive] = []) {
    rows = people.sorted { ($0.displayOrder, $0.name) < ($1.displayOrder, $1.name) }
      .map { ContributorNameDraft(name: $0.name) }
    ensureEmptyRow()
  }

  var names: [String] {
    rows.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }

  func contributors(role: String) -> [ContributorArchive] {
    names.enumerated().map { ContributorArchive(name: $0.element, roleRaw: role, displayOrder: $0.offset) }
  }

  func validate() throws {
    for row in rows { try validate(row) }
  }

  private func validate(_ row: ContributorNameDraft) throws {
    let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty && row.savedName != nil { throw ContributorEditError.emptyName }
    if name.rangeOfCharacter(from: .newlines) != nil { throw ContributorEditError.multilineName }
  }

  mutating func update(_ id: UUID, name: String) {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
    rows[index].name = name
  }

  mutating func commit(_ id: UUID) throws {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
    try validate(rows[index])
    let name = rows[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
    rows[index].name = name
    if !name.isEmpty { rows[index].savedName = name }
  }

  mutating func cancel(_ id: UUID) {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
    if let name = rows[index].savedName { rows[index].name = name }
    else { remove(id) }
  }

  @discardableResult mutating func add(after id: UUID) -> UUID {
    if let empty = rows.first(where: \.isEmptyNewRow) { return empty.id }
    let index = rows.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? rows.count
    let row = ContributorNameDraft(name: "", saved: false)
    rows.insert(row, at: index)
    return row.id
  }

  mutating func remove(_ id: UUID) {
    rows.removeAll { $0.id == id }
    ensureEmptyRow()
  }

  mutating func move(_ id: UUID, to destination: Int) {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
    let target = min(max(0, destination), rows.count - 1)
    rows.insert(rows.remove(at: index), at: target)
  }

  private mutating func ensureEmptyRow() {
    if rows.isEmpty { rows = [ContributorNameDraft(name: "", saved: false)] }
  }
}

extension BookMetadataCommands {
  /// Names are structured values, never parsed as a delimiter-separated string.
  @discardableResult
  func saveContributors(bookID: UUID, field: BookField, names: [String], expected: BookMetadataValue) throws -> BookMetadataValue {
    guard field == .authors || field == .translators else { throw BookMetadataEditError.unsupportedField }
    let id = bookID
    var fetch = FetchDescriptor<Book>(predicate: #Predicate { $0.id == id }); fetch.fetchLimit = 1
    guard let book = try context.fetch(fetch).first else { throw BookMetadataEditError.missingBook }
    guard book.deletedAt == nil else { throw BookMetadataEditError.readOnly }
    let current = BookArchive(book: book)
    guard BookMetadataValue.read(field, from: current) == expected else { throw BookMetadataEditError.conflict }
    let names = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard names.allSatisfy({ !$0.isEmpty }) else { throw ContributorEditError.emptyName }
    guard names.allSatisfy({ $0.rangeOfCharacter(from: .newlines) == nil }) else { throw ContributorEditError.multilineName }
    let role = field == .authors ? "author" : "translator"
    var changed = current
    changed.contributors.removeAll { $0.roleRaw == role }
    changed.contributors += names.enumerated().map { ContributorArchive(name: $0.element, roleRaw: role, displayOrder: $0.offset) }
    changed.contributors.sort { ($0.roleRaw, $0.displayOrder, $0.name) < ($1.roleRaw, $1.displayOrder, $1.name) }
    guard BookMetadataValue.read(field, from: changed) != expected else { return expected }
    changed = BookRecordMerge.markingManualChanges(changed, comparedTo: current)
    try LibraryCommands(context: context, undoManager: undoManager).update([book], name: L10n.tr("编辑") + field.label) { $0 = changed }
    return BookMetadataValue.read(field, from: BookArchive(book: book))
  }
}
