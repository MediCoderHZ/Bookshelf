import Foundation

/// Book-focused categories. A missing value on legacy/imported records is not a fourth type.
enum BookType: String, Codable, CaseIterable, Identifiable {
  case chineseOriginal, englishOriginal, chineseTranslation
  var id: String { rawValue }
  var title: String {
    switch self {
    case .chineseOriginal: L10n.tr("中文原版书")
    case .englishOriginal: L10n.tr("英文原版书")
    case .chineseTranslation: L10n.tr("中文译本")
    }
  }
  /// Names written by the retired preset installer; stable across interface languages.
  var legacyPresetName: String {
    switch self {
    case .chineseOriginal: "中文原版书"
    case .englishOriginal: "英文原版书"
    case .chineseTranslation: "中文译本"
    }
  }
  var isTranslation: Bool { self == .chineseTranslation }
}

/// Type changes affect presentation only; all stored contributors and original-work fields survive.
enum BookMetadataLayout {
  static func allows(_ field: BookField, type: BookType?) -> Bool {
    if field == .originalTitle || field == .originalLanguage { return type == .chineseTranslation }
    if field == .translators { return type == nil || type?.isTranslation == true }
    return true
  }
  static func requiresVisible(_ field: BookField, type: BookType?) -> Bool {
    [.title, .subtitle, .authors, .publisher, .publicationDate, .isbn].contains(field)
      || (field == .translators && type?.isTranslation == true)
  }
}

enum ContributorRole: String, Codable, CaseIterable {
  case author
  case translator
  case editor
  case illustrator
  case other

  var title: String {
    switch self {
    case .author: L10n.tr("作者")
    case .translator: L10n.tr("译者")
    case .editor: L10n.tr("编者")
    case .illustrator: L10n.tr("绘者")
    case .other: L10n.tr("其他")
    }
  }
}

enum ISBN {
  /// A checked edition key shared by lookup, import and duplicate detection.
  static func identity(_ value: String?) -> String? {
    guard let value = normalized(value), value.allSatisfy({ $0.isASCII }) else { return nil }
    let digits = value.compactMap(\.wholeNumberValue)
    if value.count == 13, digits.count == 13,
      digits.enumerated().reduce(0, { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 1 : 3) }) % 10 == 0 {
      return value
    }
    guard value.count == 10 else { return nil }
    let numbers = value.enumerated().compactMap { index, character -> Int? in
      character == "X" && index == 9 ? 10 : character.wholeNumberValue
    }
    guard numbers.count == 10, numbers.enumerated().reduce(0, { $0 + $1.element * (10 - $1.offset) }) % 11 == 0 else { return nil }
    let prefix = "978" + value.prefix(9)
    let sum = prefix.compactMap(\.wholeNumberValue).enumerated().reduce(0) {
      $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 1 : 3)
    }
    return prefix + String((10 - sum % 10) % 10)
  }

  static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.uppercased().filter { $0.isNumber || $0 == "X" }
    return result.isEmpty ? nil : result
  }
}

enum MetadataNormalizer {
  static func normalizedName(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current
      )
      .replacingOccurrences(of: " ", with: "")
      .localizedLowercase
  }

  static func normalizedTitle(_ value: String) -> String {
    normalizedName(value).filter { $0.isLetter || $0.isNumber }
  }

  static func contributorNames(from value: String) -> [String] {
    value
      .components(separatedBy: CharacterSet(charactersIn: "、,，;/；\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

struct TagSuggestion: Identifiable, Equatable {
  let name: String
  let isAssigned: Bool
  var id: String { MetadataNormalizer.normalizedName(name) }
}

enum TagSuggestions {
  static func matches(_ query: String, names: [String], assignedNames: [String]) -> [TagSuggestion] {
    let key = MetadataNormalizer.normalizedName(query)
    guard !key.isEmpty else { return [] }
    let assigned = Set(assignedNames.map(MetadataNormalizer.normalizedName))
    var seen = Set<String>()
    return names.compactMap { name -> TagSuggestion? in
      let normalized = MetadataNormalizer.normalizedName(name)
      guard normalized.contains(key), seen.insert(normalized).inserted else { return nil }
      return TagSuggestion(name: name, isAssigned: assigned.contains(normalized))
    }.sorted { lhs, rhs in
      func rank(_ item: TagSuggestion) -> Int { item.id == key ? 0 : item.id.hasPrefix(key) ? 1 : 2 }
      let leftRank = rank(lhs), rightRank = rank(rhs)
      if leftRank != rightRank { return leftRank < rightRank }
      let order = lhs.name.localizedStandardCompare(rhs.name)
      return order == .orderedSame ? lhs.name < rhs.name : order == .orderedAscending
    }
  }
}
