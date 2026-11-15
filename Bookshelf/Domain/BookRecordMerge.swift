import Foundation

enum BookField: String, CaseIterable, Identifiable {
  case bookType, originalLanguage
  case title, subtitle, originalTitle, authors, translators, publisher, publicationDate, isbn, edition
  case pageCount, language, description
  var id: String { rawValue }
  var label: String {
    switch self {
    case .bookType: "条目类型"; case .originalLanguage: "原作语言"
    case .title: "标题"; case .subtitle: "副标题"; case .originalTitle: "原书名"
    case .authors: "作者"; case .translators: "译者"; case .publisher: "出版社"
    case .publicationDate: "出版日期"; case .isbn: "ISBN"; case .edition: "版次"
    case .pageCount: "页数"; case .language: "语言"; case .description: "简介"
    }
  }
  func value(in record: BookArchive) -> String {
    switch self {
    case .bookType: record.bookType?.title ?? record.bookTypeRaw ?? ""
    case .originalLanguage: record.originalLanguageCode ?? ""
    case .title: record.title
    case .subtitle: record.subtitle ?? ""
    case .originalTitle: record.originalTitle ?? ""
    case .authors: record.contributors.filter { $0.roleRaw == "author" }.map(\.name).joined(separator: "、")
    case .translators: record.contributors.filter { $0.roleRaw == "translator" }.map(\.name).joined(separator: "、")
    case .publisher: record.publisher ?? ""
    case .publicationDate: record.publicationDate ?? ""
    case .isbn: record.isbn13 ?? record.isbn10 ?? ""
    case .edition: record.edition ?? ""
    case .pageCount: record.pageCount.map(String.init) ?? ""
    case .language: record.languageCode ?? ""
    case .description: record.bookDescription ?? ""
    }
  }
  func copy(from source: BookArchive, to target: inout BookArchive) {
    switch self {
    case .bookType: target.bookTypeRaw = source.bookTypeRaw
    case .originalLanguage: target.originalLanguageCode = source.originalLanguageCode
    case .title: target.title = source.title
    case .subtitle: target.subtitle = source.subtitle
    case .originalTitle: target.originalTitle = source.originalTitle
    case .authors, .translators:
      let role = self == .authors ? "author" : "translator"
      target.contributors.removeAll { $0.roleRaw == role }
      target.contributors += source.contributors.filter { $0.roleRaw == role }
    case .publisher: target.publisher = source.publisher
    case .publicationDate: target.publicationDate = source.publicationDate
    case .isbn: target.isbn10 = source.isbn10; target.isbn13 = source.isbn13
    case .edition: target.edition = source.edition
    case .pageCount: target.pageCount = source.pageCount
    case .language: target.languageCode = source.languageCode
    case .description: target.bookDescription = source.bookDescription
    }
  }
}

struct MetadataFieldOrigin: Codable, Equatable {
  let name: String
  let url: String?
  let retrievedAt: Date?
  var inferred: Bool? = nil
}

enum BookRecordMerge {
  /// Only distinct, nonblank values need a choice. Input order determines the
  /// representative record, so callers can put the primary record first. An
  /// explicit field choice keeps its source even when the new primary has the
  /// same value and would otherwise replace it during deduplication.
  static func fieldCandidates(_ field: BookField, in records: [BookArchive], preferredID: UUID? = nil) -> [BookArchive] {
    let preferred = records.first { $0.id == preferredID }
    let ordered = preferred.map { chosen in [chosen] + records.filter { $0.id != chosen.id } } ?? records
    var seen = Set<[String]>()
    return ordered.filter { record in
      guard let key = fieldValueKey(field, in: record) else { return false }
      return seen.insert(key).inserted
    }
  }

  private static func fieldValueKey(_ field: BookField, in record: BookArchive) -> [String]? {
    let value = field.value(in: record).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    switch field {
    case .isbn:
      return [ISBN.identity(value) ?? value]
    case .authors, .translators:
      // Compare ordered names as separate values, not their joined display text.
      let role = field == .authors ? "author" : "translator"
      let names = record.contributors.filter { $0.roleRaw == role }
        .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      return names.isEmpty ? nil : names
    default:
      return [value]
    }
  }

  static func defaultMetadataFields(current: BookArchive, incoming: BookArchive) -> Set<BookField> {
    Set(BookField.allCases.filter { $0.value(in: current).isEmpty && !$0.value(in: incoming).isEmpty })
  }

  static func applyingMetadata(_ incoming: BookArchive, to current: BookArchive, fields: Set<BookField>) -> BookArchive {
    var result = current
    var sources = origins(current)
    for field in fields where !field.value(in: incoming).isEmpty {
      field.copy(from: incoming, to: &result)
      sources[field.rawValue] = origins(incoming)[field.rawValue]
    }
    result.metadataFieldSourcesJSON = encodeOrigins(sources)
    if !fields.isEmpty {
      result.metadataSourceName = incoming.metadataSourceName
      result.metadataSourceURL = incoming.metadataSourceURL
      result.metadataRetrievedAt = incoming.metadataRetrievedAt
    }
    return result
  }

  static func differentEditions(_ first: BookArchive, _ second: BookArchive) -> Bool {
    guard let a = ISBN.identity(first.isbn13) ?? ISBN.identity(first.isbn10),
      let b = ISBN.identity(second.isbn13) ?? ISBN.identity(second.isbn10) else { return false }
    return a != b
  }

  static func sameTitleAndAuthor(_ a: BookArchive, _ b: BookArchive) -> Bool {
    guard MetadataNormalizer.normalizedTitle(a.title) == MetadataNormalizer.normalizedTitle(b.title) else { return false }
    let x = Set(a.contributors.filter { $0.roleRaw == "author" }.map { MetadataNormalizer.normalizedName($0.name) })
    let y = Set(b.contributors.filter { $0.roleRaw == "author" }.map { MetadataNormalizer.normalizedName($0.name) })
    return (x.isEmpty && y.isEmpty) || !x.isDisjoint(with: y)
  }

  static func origins(_ record: BookArchive) -> [String: MetadataFieldOrigin] {
    if let json = record.metadataFieldSourcesJSON, let data = json.data(using: .utf8),
      let origins = try? JSONDecoder().decode([String: MetadataFieldOrigin].self, from: data) { return origins.filter { $0.key != "cover" } }
    guard let name = record.metadataSourceName else { return [:] }
    return Dictionary(uniqueKeysWithValues: BookField.allCases.filter { !$0.value(in: record).isEmpty }.map {
      ($0.rawValue, MetadataFieldOrigin(name: name, url: record.metadataSourceURL, retrievedAt: record.metadataRetrievedAt, inferred: true))
    })
  }

  static func encodeOrigins(_ origins: [String: MetadataFieldOrigin]) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(origins)).flatMap { String(data: $0, encoding: .utf8) }
  }

  static func markingManualChanges(_ current: BookArchive, comparedTo baseline: BookArchive) -> BookArchive {
    var result = current
    var sources = origins(current)
    for field in BookField.allCases {
      let changed = field.value(in: current) != field.value(in: baseline)
      if changed { sources[field.rawValue] = MetadataFieldOrigin(name: "手动编辑", url: nil, retrievedAt: nil) }
    }
    result.metadataFieldSourcesJSON = encodeOrigins(sources)
    return result
  }

  /// A selected field is copied as a unit (including the ISBN pair and contributor role).
  /// Personal organization is always unioned; conflicting notes remain separate blocks.
  static func combine(primary: BookArchive, others: [BookArchive], choices: [BookField: UUID] = [:]) -> BookArchive {
    var result = primary
    let records = [primary] + others
    var origins = origins(primary)
    for field in BookField.allCases {
      let selected = choices[field].flatMap { id in records.first { $0.id == id } }
        ?? (fieldValueKey(field, in: primary) == nil ? others.first { fieldValueKey(field, in: $0) != nil } : nil)
      if let selected {
        field.copy(from: selected, to: &result)
        origins[field.rawValue] = Self.origins(selected)[field.rawValue]
          ?? MetadataFieldOrigin(name: "手动记录", url: nil, retrievedAt: nil)
      }
    }
    result.metadataFieldSourcesJSON = encodeOrigins(origins)
    result.tags = uniqueNames(records.flatMap(\.tags))
    result.collections = uniqueNames(records.flatMap(\.collections))
    var seriesKeys = Set<String>()
    result.seriesMemberships = records.flatMap(\.seriesMemberships).filter {
      seriesKeys.insert(MetadataNormalizer.normalizedName($0.seriesName) + "\u{0}" + ($0.volumeLabel ?? "")).inserted
    }
    var contributorKeys = Set(result.contributors.map { $0.roleRaw + "\u{0}" + MetadataNormalizer.normalizedName($0.name) })
    for contributor in others.flatMap(\.contributors) where !["author", "translator"].contains(contributor.roleRaw) {
      if contributorKeys.insert(contributor.roleRaw + "\u{0}" + MetadataNormalizer.normalizedName(contributor.name)).inserted {
        result.contributors.append(contributor)
      }
    }
    let separator = "\n\n—— 合并保留的笔记 ——\n\n"
    var seenNotes = Set<String>()
    let noteBlocks = records.flatMap { ($0.notes ?? "").components(separatedBy: separator) }
      .filter { value in
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && seenNotes.insert(key).inserted
      }
    result.notes = noteBlocks.isEmpty ? nil : noteBlocks.joined(separator: separator)
    result.addedAt = records.map(\.addedAt).min() ?? primary.addedAt
    result.updatedAt = Date()
    return result
  }

  private static func uniqueNames(_ names: [String]) -> [String] {
    var seen = Set<String>()
    return names.filter { seen.insert(MetadataNormalizer.normalizedName($0)).inserted }
  }
}

extension BookArchive {
  init(metadata: BookMetadataSearchResult) {
    self.init(book: Book(title: metadata.title))
    subtitle = metadata.subtitle
    originalTitle = metadata.originalTitle
    publisher = metadata.publisher
    publicationDate = metadata.publicationDate
    isbn10 = metadata.isbn10
    isbn13 = metadata.isbn13
    pageCount = metadata.pageCount
    languageCode = metadata.languageCode
    bookDescription = metadata.bookDescription
    metadataSourceName = metadata.sourceName
    metadataSourceURL = metadata.sourceURL?.absoluteString
    metadataRetrievedAt = Date()
    contributors = metadata.authors.enumerated().map { ContributorArchive(name: $0.element, roleRaw: "author", displayOrder: $0.offset) }
      + metadata.translators.enumerated().map { ContributorArchive(name: $0.element, roleRaw: "translator", displayOrder: $0.offset) }
    let source = MetadataFieldOrigin(name: metadata.sourceName, url: metadata.sourceURL?.absoluteString, retrievedAt: metadataRetrievedAt)
    metadataFieldSourcesJSON = BookRecordMerge.encodeOrigins(Dictionary(uniqueKeysWithValues:
      BookField.allCases.filter { !$0.value(in: self).isEmpty }.map { ($0.rawValue, source) }))
  }
}
extension ContributorArchive {
  init(name: String, roleRaw: String, displayOrder: Int) {
    self.name = name; self.roleRaw = roleRaw; self.displayOrder = displayOrder
  }
}
