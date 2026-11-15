import Foundation

enum SearchMatchMode: String, Codable, CaseIterable, Identifiable {
  case all, any
  var id: String { rawValue }
  var title: String { self == .all ? "满足全部条件" : "满足任一条件" }
}

enum SearchComparison: String, Codable, CaseIterable, Identifiable {
  case contains, notContains, equals, notEquals, atLeast, atMost, isEmpty, isNotEmpty
  var id: String { rawValue }
  var title: String {
    switch self {
    case .contains: "包含"; case .notContains: "不包含"
    case .equals: "等于"; case .notEquals: "不等于"
    case .atLeast: "不低于"; case .atMost: "不高于"
    case .isEmpty: "为空"; case .isNotEmpty: "不为空"
    }
  }
  var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }
}

enum SearchBookField: String, Codable, CaseIterable, Identifiable {
  case bookType
  case title, author, translator, publisher, publicationYear, isbn, language
  case tag, collection, pageCount, notes, source, cover, favorite
  var id: String { rawValue }
  var title: String {
    switch self {
    case .bookType: "条目类型"
    case .title: "书名（含副标题与原书名）"; case .author: "作者"; case .translator: "译者"
    case .publisher: "出版社"; case .publicationYear: "出版年份"; case .isbn: "ISBN"
    case .language: "语言"; case .tag: "标签"; case .collection: "普通书单"
    case .pageCount: "页数"
    case .notes: "个人笔记"; case .source: "元信息来源"; case .cover: "封面"; case .favorite: "收藏"
    }
  }
  var isNumber: Bool { [.publicationYear, .pageCount].contains(self) }
  var choices: [(value: String, title: String)] {
    switch self {
    case .bookType: BookType.allCases.map { ($0.rawValue, $0.title) }
    case .cover: [("true", "有封面"), ("false", "无封面")]
    case .favorite: [("true", "已收藏"), ("false", "未收藏")]
    default: []
    }
  }
  var comparisons: [SearchComparison] {
    if self == .bookType { return [.equals, .notEquals, .isEmpty, .isNotEmpty] }
    if !choices.isEmpty { return [.equals, .notEquals] }
    if isNumber { return [.equals, .notEquals, .atLeast, .atMost, .isEmpty, .isNotEmpty] }
    return [.contains, .notContains, .equals, .notEquals, .isEmpty, .isNotEmpty]
  }
  var placeholder: String {
    switch self {
    case .publicationYear: "例如 2020"; case .pageCount: "例如 300"
    default: "输入条件值"
    }
  }
}

struct BookSearchRule: Codable, Equatable, Identifiable {
  var id = UUID()
  var field: SearchBookField = .title
  var comparison: SearchComparison = .contains
  var value = ""

  var summary: String {
    let displayValue = field.choices.first { $0.value == value }?.title ?? value
    return "\(field.title) \(comparison.title)" + (comparison.needsValue ? " \(displayValue)" : "")
  }

  var validationMessage: String? {
    guard field.comparisons.contains(comparison) else { return "不支持的筛选方式。" }
    guard comparison.needsValue else { return nil }
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "请填写\(field.title)的条件值。" }
    if !field.choices.isEmpty && !field.choices.contains(where: { $0.value == text }) { return "请选择有效的\(field.title)。" }
    if field.isNumber {
      guard let number = Double(text), number.isFinite else { return "\(field.title)需要数字。" }
      switch field {
      case .publicationYear:
        if !(1...9999).contains(number) || number.rounded() != number { return "出版年份需为 1–9999 的整数。" }
      case .pageCount:
        if number < 0 || number > 1_000_000 || number.rounded() != number { return "页数需为 0–1000000 的整数。" }
      default: break
      }
    }
    return nil
  }

  func matches(_ book: Book) -> Bool {
    guard validationMessage == nil else { return false }
    if field.isNumber {
      let actual: Double?
      switch field {
      case .publicationYear: actual = Self.publicationYear(book.publicationDate).map(Double.init)
      default: actual = book.pageCount.map(Double.init)
      }
      if comparison == .isEmpty { return actual == nil }
      if comparison == .isNotEmpty { return actual != nil }
      guard let actual, let expected = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
      switch comparison {
      case .equals: return actual == expected
      case .notEquals: return actual != expected
      case .atLeast: return actual >= expected
      case .atMost: return actual <= expected
      default: return false
      }
    }
    let values = textValues(book).map(Self.normalized).filter { !$0.isEmpty }
    let expected = Self.normalized(value)
    if comparison == .isEmpty { return values.isEmpty }
    if comparison == .isNotEmpty { return !values.isEmpty }
    let equals: Bool
    if field == .isbn, let key = ISBN.identity(value) {
      equals = (ISBN.identity(book.isbn13) ?? ISBN.identity(book.isbn10)) == key
    } else { equals = values.contains(expected) }
    let contains = field == .isbn
      ? values.contains { (ISBN.normalized($0) ?? "").contains(ISBN.normalized(value) ?? expected) }
      : values.contains { $0.contains(expected) }
    switch comparison {
    case .equals: return equals
    case .notEquals: return !equals
    case .contains: return contains
    case .notContains: return !contains
    default: return false
    }
  }

  private func textValues(_ book: Book) -> [String] {
    switch field {
    case .bookType: [book.bookTypeRaw ?? ""]
    case .title: [book.title, book.subtitle ?? "", book.originalTitle ?? ""]
    case .author: book.authors.map(\.name)
    case .translator: book.translators.map(\.name)
    case .publisher: [book.publisher ?? ""]
    case .isbn: [book.isbn10 ?? "", book.isbn13 ?? ""]
    case .language: [book.languageCode ?? ""]
    case .tag: book.tagLinks.compactMap(\.tag?.name)
    case .collection: book.collectionItems.compactMap(\.collection).filter { !$0.isSmart }.map(\.name)
    case .notes: [book.notes ?? ""]
    case .source:
      [book.metadataSourceName ?? ""] + BookRecordMerge.origins(BookArchive(book: book, includeCover: false)).values.map(\.name)
    case .cover: [book.coverFileName == nil ? "false" : "true"]
    case .favorite: [book.isFavorite ? "true" : "false"]
    default: []
    }
  }
  private static func normalized(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
  static func publicationYear(_ value: String?) -> Int? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.count >= 4,
      value.prefix(4).allSatisfy({ $0.isASCII && $0.isNumber }),
      value.count == 4 || !value.dropFirst(4).first!.isNumber,
      let year = Int(value.prefix(4)), year > 0 else { return nil }
    return year
  }
}

struct AdvancedBookQuery: Codable, Equatable {
  var version = 1
  var mode: SearchMatchMode = .all
  var rules: [BookSearchRule] = []
  var savedSearch: SavedLibrarySearch?
  var hasConditions: Bool { !rules.isEmpty || savedSearch != nil }
  var summary: String {
    let rulesSummary = "\(mode.title) · \(rules.count) 条条件"
    guard let savedSearch else { return rulesSummary }
    return savedSearch.summary + (rules.isEmpty ? "" : " · " + rulesSummary)
  }
  static func savingSearch(scope: LibrarySearchScope, text: String) -> Self {
    Self(version: 2, savedSearch: SavedLibrarySearch(scope: scope, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
  }
  var validationMessage: String? {
    // Version 1 remains byte-compatible with existing rule-only collections.
    // Older readers reject version 2 instead of silently dropping its search.
    if version != (savedSearch == nil ? 1 : 2) { return "不支持此版本的筛选规则。" }
    if let message = savedSearch?.validationMessage { return message }
    if rules.count > 50 { return "每个筛选最多支持 50 条条件。" }
    if Set(rules.map(\.id)).count != rules.count { return "筛选条件标识重复。" }
    return rules.compactMap(\.validationMessage).first
  }
  func matches(_ book: Book, notes: [NoteRecord] = []) -> Bool {
    guard book.deletedAt == nil, validationMessage == nil else { return false }
    if let savedSearch, !savedSearch.matches(book, notes: notes) { return false }
    if rules.isEmpty { return true }
    return mode == .all ? rules.allSatisfy { $0.matches(book) } : rules.contains { $0.matches(book) }
  }
  func matches(_ note: NoteRecord) -> Bool {
    // Book-specific advanced rules cannot be satisfied by a standalone note.
    note.parentBookID == nil && note.deletedAt == nil && rules.isEmpty && validationMessage == nil &&
      savedSearch?.matches(note) == true
  }
  func encoded() throws -> String {
    guard validationMessage == nil else { throw SmartCollectionError.invalidRules }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
  static func decode(_ text: String) throws -> Self {
    let result = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
    guard result.validationMessage == nil else { throw SmartCollectionError.invalidRules }
    return result
  }
}

extension BookCollection {
  var isSmart: Bool { smartRulesJSON != nil }
  var smartQuery: AdvancedBookQuery? {
    guard let smartRulesJSON else { return nil }
    return try? AdvancedBookQuery.decode(smartRulesJSON)
  }
}

struct SmartCollectionArchive: Codable, Equatable, Identifiable {
  var id: UUID
  var name: String
  var query: AdvancedBookQuery
  var createdAt: Date
  var updatedAt: Date
  var sortOrder: Int
  init(id: UUID = UUID(), name: String, query: AdvancedBookQuery, createdAt: Date = Date(), updatedAt: Date = Date(), sortOrder: Int = 0) {
    self.id = id; self.name = name; self.query = query; self.createdAt = createdAt; self.updatedAt = updatedAt
    self.sortOrder = sortOrder
  }
  init(_ collection: BookCollection) throws {
    guard let query = collection.smartQuery else { throw SmartCollectionError.invalidRules }
    self.init(id: collection.id, name: collection.name, query: query, createdAt: collection.createdAt, updatedAt: collection.updatedAt, sortOrder: collection.sortOrder)
  }
  private enum CodingKeys: String, CodingKey { case id, name, query, createdAt, updatedAt, sortOrder }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
    query = try values.decode(AdvancedBookQuery.self, forKey: .query)
    createdAt = try values.decode(Date.self, forKey: .createdAt); updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
  }
  var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && query.hasConditions && query.validationMessage == nil }
}

enum SmartCollectionError: LocalizedError {
  case invalidRules, duplicateName
  var errorDescription: String? {
    switch self {
    case .invalidRules: "智能书单规则不可用，请检查条件或从备份恢复。"
    case .duplicateName: "已有同名智能书单，请使用不同的名称。"
    }
  }
}

