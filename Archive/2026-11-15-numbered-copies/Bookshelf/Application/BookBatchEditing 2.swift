import Foundation
import SwiftData

enum BatchValueMode: String, CaseIterable, Identifiable {
  case keep, fill, replace, clear
  var id: String { rawValue }
  var title: String {
    switch self {
    case .keep: "保持原样"; case .fill: "仅补空白"; case .replace: "替换为"; case .clear: "清空"
    }
  }
  var needsValue: Bool { self == .fill || self == .replace }
}

enum BatchMetadataField: String, CaseIterable, Identifiable {
  case publisher, publicationDate, edition, language
  var id: String { rawValue }
  var field: BookField {
    switch self {
    case .publisher: .publisher; case .publicationDate: .publicationDate
    case .edition: .edition; case .language: .language
    }
  }
  var keyPath: WritableKeyPath<BookArchive, String?> {
    switch self {
    case .publisher: \.publisher; case .publicationDate: \.publicationDate
    case .edition: \.edition; case .language: \.languageCode
    }
  }
  var placeholder: String {
    switch self {
    case .publicationDate: "例如 2024-03"; case .edition: "例如 第 2 版"
    case .language: "例如 zh 或 en"; case .publisher: "输入出版社"
    }
  }
}

struct BatchTextChange: Equatable {
  var mode: BatchValueMode = .keep
  var value = ""
  func applying(to old: String?) -> String? {
    switch mode {
    case .keep: old
    case .clear: nil
    case .replace: value.trimmingCharacters(in: .whitespacesAndNewlines)
    case .fill: (old?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
      ? value.trimmingCharacters(in: .whitespacesAndNewlines) : old
    }
  }
}

struct BookBatchEditDraft: Equatable {
  var metadata: [BatchMetadataField: BatchTextChange] = [:]
  var favorite: Bool?
  var tagsToAdd = ""
  // Normalized names, restricted to tags present in the selected books by the UI.
  var tagsToRemove: Set<String> = []

  var addedTags: [String] {
    var seen = Set<String>()
    return MetadataNormalizer.contributorNames(from: tagsToAdd).filter {
      seen.insert(MetadataNormalizer.normalizedName($0)).inserted
    }
  }
  var validationMessage: String? {
    for field in BatchMetadataField.allCases {
      let change = metadata[field] ?? BatchTextChange()
      if change.mode.needsValue && change.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "请填写\(field.field.label)；需要删除内容时请选择“清空”。"
      }
    }
    if !tagsToAdd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && addedTags.isEmpty {
      return "请填写有效的标签名称，用逗号或顿号分隔。"
    }
    if !Set(addedTags.map(MetadataNormalizer.normalizedName)).isDisjoint(with: tagsToRemove) {
      return "同一个标签不能同时添加和移除，请调整选择。"
    }
    return nil
  }
}

struct BatchFieldDifference: Identifiable {
  let id: String
  let label: String
  let oldValue: String
  let newValue: String
  var isMetadata = false
}

struct BookBatchEditItem: Identifiable {
  let before: BookArchive
  let after: BookArchive
  let differences: [BatchFieldDifference]
  var id: UUID { before.id }
  var hasChanges: Bool { !differences.isEmpty }
}

struct BookBatchEditPlan {
  let items: [BookBatchEditItem]
  var changedItems: [BookBatchEditItem] { items.filter(\.hasChanges) }
}

enum BookBatchEditError: LocalizedError {
  case invalidDraft(String)
  var errorDescription: String? {
    switch self { case .invalidDraft(let message): message }
  }
}

@MainActor
enum BookBatchEditing {
  static func prepare(_ records: [BookArchive], draft: BookBatchEditDraft, knownTagNames: [String] = []) throws -> BookBatchEditPlan {
    guard !records.isEmpty, Set(records.map(\.id)).count == records.count,
      records.allSatisfy({ $0.deletedAt == nil }) else { throw LibraryOperationError.invalidSelection }
    if let message = draft.validationMessage { throw BookBatchEditError.invalidDraft(message) }
    let tagNames = Dictionary(knownTagNames.map { (MetadataNormalizer.normalizedName($0), $0) }, uniquingKeysWith: { first, _ in first })
    let items = records.map { record in
      var result = record
      var differences: [BatchFieldDifference] = []
      for field in BatchMetadataField.allCases {
        let change = draft.metadata[field] ?? BatchTextChange()
        let before = record[keyPath: field.keyPath]
        let after = change.applying(to: before)
        if before != after {
          result[keyPath: field.keyPath] = after
          differences.append(BatchFieldDifference(id: field.rawValue, label: field.field.label,
            oldValue: before ?? "", newValue: after ?? "", isMetadata: true))
        }
      }
      if !differences.isEmpty { result = BookRecordMerge.markingManualChanges(result, comparedTo: record) }
      if let favorite = draft.favorite, favorite != record.isFavorite {
        result.isFavorite = favorite
        differences.append(BatchFieldDifference(id: "favorite", label: "收藏",
          oldValue: record.isFavorite ? "已收藏" : "未收藏", newValue: favorite ? "已收藏" : "未收藏"))
      }
      var updatedTags = record.tags.filter { !draft.tagsToRemove.contains(MetadataNormalizer.normalizedName($0)) }
      var seen = Set(updatedTags.map(MetadataNormalizer.normalizedName))
      for tag in draft.addedTags {
        let key = MetadataNormalizer.normalizedName(tag)
        if seen.insert(key).inserted { updatedTags.append(tagNames[key] ?? tag) }
      }
      if updatedTags != record.tags {
        result.tags = updatedTags.sorted()
        differences.append(BatchFieldDifference(id: "tags", label: "标签",
          oldValue: record.tags.joined(separator: "、"), newValue: result.tags.joined(separator: "、")))
      }
      return BookBatchEditItem(before: record, after: result, differences: differences)
    }
    return BookBatchEditPlan(items: items)
  }

  @discardableResult
  static func apply(_ plan: BookBatchEditPlan, context: ModelContext, undoManager: UndoManager?) throws -> Int {
    let ids = Set(plan.items.map(\.id))
    guard !ids.isEmpty, ids.count == plan.items.count,
      plan.items.allSatisfy({ $0.before.deletedAt == nil && $0.after.deletedAt == nil && $0.before.id == $0.after.id })
    else { throw LibraryOperationError.invalidSelection }
    let current = try context.fetch(FetchDescriptor<Book>()).filter { ids.contains($0.id) }
    let expected = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0.before) })
    guard LibraryHistory.snapshots(current) == expected else { throw LibraryOperationError.changedSincePreview }
    let changed = plan.changedItems
    guard !changed.isEmpty else { return 0 }
    let now = Date()
    let records = changed.map { item in var record = item.after; record.updatedAt = now; return record }
    try LibraryRepository.apply(records, into: context)
    let changedIDs = Set(changed.map(\.id))
    LibraryServices.forContext(context).history.register("批量编辑书籍", before: Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0.before) }),
      after: LibraryHistory.snapshots(current.filter { changedIDs.contains($0.id) }), context: context, undoManager: undoManager)
    return changed.count
  }

}
