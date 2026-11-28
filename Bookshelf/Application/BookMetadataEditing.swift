import Foundation
import Observation
import SwiftData

struct MetadataUpdateProposal: Identifiable {
  let id = UUID()
  let current: BookArchive
  let incoming: BookArchive
  private(set) var suppliedFields: [BookField] = []
  private(set) var changedFields: [BookField] = []
  private(set) var defaultSelection: Set<BookField> = []

  init(current: BookArchive, incoming: BookArchive) {
    self.current = current
    self.incoming = incoming
    for field in BookField.metadataUpdateFields {
      let replacement = Self.comparisonValue(for: field, in: incoming)
      guard !replacement.isEmpty else { continue }
      suppliedFields.append(field)
      let existing = Self.comparisonValue(for: field, in: current)
      if existing != replacement { changedFields.append(field) }
      if existing.isEmpty { defaultSelection.insert(field) }
    }
  }

  private static func comparisonValue(for field: BookField, in record: BookArchive) -> [String] {
    func trimmed(_ value: String?) -> String {
      value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    switch BookMetadataValue.read(field, from: record) {
    case .contributors(let contributors):
      return contributors.map { trimmed($0.name) }.filter { !$0.isEmpty }
    case .isbn(let ten, let thirteen):
      let pair = [trimmed(ten), trimmed(thirteen)]
      return pair.allSatisfy(\.isEmpty) ? [] : pair
    case .text(let value):
      let text = trimmed(value)
      return text.isEmpty ? [] : [text]
    case .pages(let count):
      return count.map { [String($0)] } ?? []
    }
  }
}

/// A field snapshot protects concurrent edits without locking unrelated metadata.
enum BookMetadataValue: Codable, Equatable {
  case text(String?)
  case contributors([ContributorArchive])
  case isbn(String?, String?)
  case pages(Int?)

  static func read(_ field: BookField, from record: BookArchive) -> Self {
    switch field {
    case .authors, .translators:
      let role = field == .authors ? "author" : "translator"
      return .contributors(record.contributors.filter { $0.roleRaw == role }
        .sorted { ($0.displayOrder, $0.name) < ($1.displayOrder, $1.name) })
    case .isbn: return .isbn(record.isbn10, record.isbn13)
    case .pageCount: return .pages(record.pageCount)
    default: return .text(field.value(in: record).isEmpty ? nil : field.value(in: record))
    }
  }

  var text: String {
    switch self {
    case .text(let value): value ?? ""
    case .contributors(let values): values.map(\.name).joined(separator: "、")
    case .isbn(let ten, let thirteen): thirteen ?? ten ?? ""
    case .pages(let value): value.map(String.init) ?? ""
    }
  }
}

enum BookMetadataEditError: LocalizedError {
  case emptyTitle, invalidISBN, invalidPageCount, conflict, readOnly, missingBook, unsupportedField, invalidBookType
  var errorDescription: String? {
    switch self {
    case .invalidBookType: L10n.tr("请选择中文原版书、英文原版书或中文译本。")
    case .emptyTitle: L10n.tr("标题不能为空。")
    case .invalidISBN: L10n.tr("请输入有效的 ISBN-10 或 ISBN-13，或清空此字段。")
    case .invalidPageCount: L10n.tr("页数应为大于 0 的整数，或留空。")
    case .conflict: L10n.tr("此字段已被其他操作修改，未覆盖新内容。可复制当前输入，或放弃修改后重新编辑。")
    case .readOnly: L10n.tr("书籍已在回收站中，请先恢复书籍。")
    case .missingBook: L10n.tr("书籍已不存在，当前输入仍保留，可复制后使用。")
    case .unsupportedField: L10n.tr("此字段不支持文本编辑。")
    }
  }
}

@MainActor
struct BookMetadataCommands {
  let context: ModelContext
  let undoManager: UndoManager?

  @discardableResult
  func save(bookID: UUID, field: BookField, text: String, expected: BookMetadataValue) throws -> BookMetadataValue {
    guard let book = try context.fetch(FetchDescriptor<Book>()).first(where: { $0.id == bookID })
    else { throw BookMetadataEditError.missingBook }
    guard book.deletedAt == nil else { throw BookMetadataEditError.readOnly }
    let current = BookArchive(book: book)
    guard BookMetadataValue.read(field, from: current) == expected else { throw BookMetadataEditError.conflict }
    var changed = current
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let optional = value.isEmpty ? nil : value
    switch field {
    case .bookType:
      guard let type = BookType(rawValue: value) ?? BookType.allCases.first(where: { $0.title == value })
      else { throw BookMetadataEditError.invalidBookType }
      changed.bookTypeRaw = type.rawValue
    case .originalLanguage: changed.originalLanguageCode = optional
    case .title:
      guard !value.isEmpty else { throw BookMetadataEditError.emptyTitle }
      changed.title = value
    case .subtitle: changed.subtitle = optional
    case .originalTitle: changed.originalTitle = optional
    case .publisher: changed.publisher = optional
    case .publicationDate: changed.publicationDate = optional
    case .edition: changed.edition = optional
    case .language: changed.languageCode = optional
    case .description: changed.bookDescription = optional
    case .authors, .translators:
      let role = field == .authors ? "author" : "translator"
      var seen = Set<String>()
      // A comma can be part of a person's name (e.g. "Gerlach, Peter A.").
      let names = value.components(separatedBy: CharacterSet(charactersIn: "、;；\n\r"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert(MetadataNormalizer.normalizedName($0)).inserted }
      changed.contributors.removeAll { $0.roleRaw == role }
      changed.contributors += names.enumerated().map { ContributorArchive(name: $0.element, roleRaw: role, displayOrder: $0.offset) }
      changed.contributors.sort { ($0.roleRaw, $0.displayOrder, $0.name) < ($1.roleRaw, $1.displayOrder, $1.name) }
    case .isbn:
      if value.isEmpty { changed.isbn10 = nil; changed.isbn13 = nil }
      else {
        let normalized = value.folding(options: .widthInsensitive, locale: .current).uppercased()
          .filter { !$0.isWhitespace && !"-‐‑–—".contains($0) }
        guard normalized.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "X") }), ISBN.identity(normalized) != nil
        else { throw BookMetadataEditError.invalidISBN }
        // Formatting-only edits retain an existing valid ISBN pair.
        if normalized != current.isbn10 && normalized != current.isbn13 {
          changed.isbn10 = normalized.count == 10 ? normalized : nil
          changed.isbn13 = normalized.count == 13 ? normalized : ISBN.identity(normalized)
        }
      }
    case .pageCount:
      if value.isEmpty { changed.pageCount = nil }
      else {
        let digits = value.folding(options: .widthInsensitive, locale: .current)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let pages = Int(digits), pages > 0
        else { throw BookMetadataEditError.invalidPageCount }
        changed.pageCount = pages
      }
    }
    guard BookMetadataValue.read(field, from: changed) != expected else { return expected }
    changed = BookRecordMerge.markingManualChanges(changed, comparedTo: current)
    try LibraryCommands(context: context, undoManager: undoManager).update([book], name: L10n.tr("编辑") + field.label) { $0 = changed }
    return BookMetadataValue.read(field, from: BookArchive(book: book))
  }
}

struct BookMetadataDraftSnapshot: Codable {
  let bookID: UUID
  let bookTitle: String
  let fieldRaw: String
  let baseline: BookMetadataValue
  let text: String
  var contributorRows: [ContributorNameDraft]? = nil
  var id: String { bookID.uuidString + "-" + fieldRaw }
}

@MainActor @Observable
final class BookMetadataDraft: Identifiable {
  let bookID: UUID
  let bookTitle: String
  let field: BookField
  var baseline: BookMetadataValue
  var text: String
  var errorMessage: String?
  var contributorRows: [ContributorNameDraft]?
  nonisolated let id: String
  var isDirty: Bool {
    if let contributorRows, case .contributors(let saved) = baseline {
      return contributorRows.filter { !$0.isEmptyNewRow }.map(\.name) != saved.map(\.name)
    }
    return text != baseline.text
  }
  static func key(_ bookID: UUID, _ field: BookField) -> String { bookID.uuidString + "-" + field.rawValue }
  init(bookID: UUID, bookTitle: String, field: BookField, baseline: BookMetadataValue, text: String? = nil) {
    self.bookID = bookID; self.bookTitle = bookTitle; self.field = field
    self.id = Self.key(bookID, field)
    self.baseline = baseline; self.text = text ?? baseline.text
  }
  var snapshot: BookMetadataDraftSnapshot {
    BookMetadataDraftSnapshot(bookID: bookID, bookTitle: bookTitle, fieldRaw: field.rawValue,
      baseline: baseline, text: text, contributorRows: contributorRows)
  }
}

struct BookMetadataFocusRequest {
  let bookID: UUID
  let field: BookField
  let token = UUID()
}

/// Drafts live at window scope, so changing rows cannot lose a failed field edit.
@MainActor @Observable
final class BookMetadataEditingSession {
  private(set) var drafts: [String: BookMetadataDraft] = [:]
  var focusRequest: BookMetadataFocusRequest?
  var recoveryIssue: String?
  private let store: BookMetadataDraftStore
  init(store: BookMetadataDraftStore = BookMetadataDraftStore()) {
    self.store = store
    let recovered = store.load()
    for snapshot in recovered.drafts {
      guard let field = BookField(rawValue: snapshot.fieldRaw) else { continue }
      let draft = BookMetadataDraft(bookID: snapshot.bookID, bookTitle: snapshot.bookTitle,
        field: field, baseline: snapshot.baseline, text: snapshot.text)
      if field == .authors || field == .translators { draft.contributorRows = snapshot.contributorRows }
      draft.errorMessage = L10n.tr("已恢复未保存的输入，请核对后继续编辑或重试保存。")
      drafts[draft.id] = draft
    }
    if !recovered.errors.isEmpty { recoveryIssue = L10n.tr("部分元信息草稿无法读取，原文件已保留。") }
  }
  var pendingDrafts: [BookMetadataDraft] {
    drafts.values.filter { $0.isDirty && $0.errorMessage != nil }.sorted { $0.id < $1.id }
  }
  func draft(_ bookID: UUID, _ field: BookField) -> BookMetadataDraft? { drafts[BookMetadataDraft.key(bookID, field)] }
  func begin(_ record: BookArchive, field: BookField) {
    if let current = draft(record.id, field), current.isDirty { return }
    let state = BookMetadataDraft(bookID: record.id, bookTitle: record.title, field: field,
      baseline: .read(field, from: record))
    drafts[state.id] = state
  }
  func update(_ bookID: UUID, field: BookField, text: String) {
    guard let state = draft(bookID, field) else { return }
    state.text = text
    if !state.isDirty { state.errorMessage = nil; clear(state.id); return }
    do { try store.save(state.snapshot) }
    catch { recoveryIssue = L10n.tr("元信息草稿副本未能写入，请保留输入窗口：") + error.localizedDescription }
  }
  @discardableResult
  func commit(_ bookID: UUID, field: BookField, context: ModelContext, undoManager: UndoManager?) -> Bool {
    guard let state = draft(bookID, field) else { return true }
    guard state.isDirty else {
      state.contributorRows?.removeAll(where: \.isEmptyNewRow)
      state.errorMessage = nil; clear(state.id)
      return true
    }
    do {
      let commands = BookMetadataCommands(context: context, undoManager: undoManager)
      let value: BookMetadataValue
      if let rows = state.contributorRows {
        let retained = rows.filter { !$0.isEmptyNewRow }
        value = try commands.saveContributors(bookID: bookID, field: field, names: retained.map(\.name), expected: state.baseline)
        if case .contributors(let saved) = value {
          state.contributorRows = zip(retained, saved).map { row, person in
            var row = row; row.name = person.name; row.savedName = person.name; return row
          }
        }
      } else {
        value = try commands.save(bookID: bookID, field: field, text: state.text, expected: state.baseline)
      }
      state.baseline = value; state.text = value.text; state.errorMessage = nil
      clear(state.id)
      return true
    } catch {
      state.errorMessage = L10n.tr("尚未保存：") + error.localizedDescription
      do { try store.save(state.snapshot) }
      catch { state.errorMessage! += L10n.tr(" 草稿副本也未能写入，请复制保留输入。") }
      return false
    }
  }
  func discard(_ bookID: UUID, field: BookField) {
    let key = BookMetadataDraft.key(bookID, field)
    drafts[key] = nil; clear(key)
  }
  func requestFocus(_ bookID: UUID, field: BookField) {
    focusRequest = BookMetadataFocusRequest(bookID: bookID, field: field)
  }
  private func clear(_ key: String) {
    do { try store.remove(key) }
    catch { recoveryIssue = L10n.tr("旧的元信息草稿副本未能清理：") + error.localizedDescription }
  }
}

extension BookMetadataEditingSession {
  @discardableResult
  func prepareContributors(_ record: BookArchive, field: BookField) -> BookMetadataDraft {
    let value = BookMetadataValue.read(field, from: record)
    if let state = draft(record.id, field) {
      if state.isDirty || (state.baseline == value && state.contributorRows != nil) {
        // Older recovery files stored comma-safe, delimiter-separated text.
        if state.contributorRows == nil {
          let names = state.text.components(separatedBy: CharacterSet(charactersIn: "、;；\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
          let saved: [String]
          if case .contributors(let people) = state.baseline { saved = people.map(\.name) } else { saved = [] }
          state.contributorRows = names.enumerated().map { index, name in
            var row = ContributorNameDraft(name: name, saved: false)
            row.savedName = saved.indices.contains(index) ? saved[index] : nil
            return row
          }
        }
        return state
      }
    }
    let state = BookMetadataDraft(bookID: record.id, bookTitle: record.title, field: field, baseline: value)
    if case .contributors(let people) = value { state.contributorRows = people.map { ContributorNameDraft(name: $0.name) } }
    drafts[state.id] = state
    return state
  }

  func addContributor(_ record: BookArchive, field: BookField, after rowID: UUID? = nil) -> UUID {
    let state = prepareContributors(record, field: field)
    if let blank = state.contributorRows?.first(where: \.isEmptyNewRow) { return blank.id }
    let row = ContributorNameDraft(name: "", saved: false)
    if let rowID, let index = state.contributorRows?.firstIndex(where: { $0.id == rowID }) {
      state.contributorRows?.insert(row, at: index + 1)
    } else {
      state.contributorRows?.append(row)
    }
    return row.id
  }

  func updateContributor(_ bookID: UUID, field: BookField, rowID: UUID, name: String) {
    guard let state = draft(bookID, field), let index = state.contributorRows?.firstIndex(where: { $0.id == rowID }) else { return }
    state.contributorRows?[index].name = name
    persistContributors(state)
  }

  func cancelContributor(_ bookID: UUID, field: BookField, rowID: UUID) {
    guard let state = draft(bookID, field), let index = state.contributorRows?.firstIndex(where: { $0.id == rowID }) else { return }
    if let saved = state.contributorRows?[index].savedName { state.contributorRows?[index].name = saved }
    else { state.contributorRows?.remove(at: index) }
    persistContributors(state)
  }

  func removeContributor(_ bookID: UUID, field: BookField, rowID: UUID, context: ModelContext, undoManager: UndoManager?) {
    guard let state = draft(bookID, field) else { return }
    state.contributorRows?.removeAll { $0.id == rowID }
    persistContributors(state)
    commit(bookID, field: field, context: context, undoManager: undoManager)
  }

  func moveContributor(_ bookID: UUID, field: BookField, rowID: UUID, to destination: Int, context: ModelContext, undoManager: UndoManager?) {
    guard let state = draft(bookID, field), var rows = state.contributorRows,
      let source = rows.firstIndex(where: { $0.id == rowID }), rows.indices.contains(destination), source != destination else { return }
    let row = rows.remove(at: source); rows.insert(row, at: destination); state.contributorRows = rows
    persistContributors(state)
    commit(bookID, field: field, context: context, undoManager: undoManager)
  }

  private func persistContributors(_ state: BookMetadataDraft) {
    state.text = state.contributorRows?.map(\.name).joined(separator: "\n") ?? ""
    if !state.isDirty { state.errorMessage = nil; clear(state.id); return }
    do { try store.save(state.snapshot) }
    catch { recoveryIssue = L10n.tr("元信息草稿副本未能写入，请保留输入窗口：") + error.localizedDescription }
  }
}
