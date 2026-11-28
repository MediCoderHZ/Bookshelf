import Foundation
import SwiftData

struct AIMetadataError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

enum AIMetadata {
  static let fields: [BookField] = [.title, .subtitle, .originalTitle, .authors, .translators, .publisher,
    .publicationDate, .isbn, .edition, .pageCount, .language, .originalLanguage]

  static var schema: [String: Any] {
    var properties: [String: Any] = [:]
    for field in fields {
      switch field {
      case .authors, .translators:
        properties[field.rawValue] = ["type": "array", "items": ["type": "string"], "maxItems": 50] as [String: Any]
      case .pageCount: properties[field.rawValue] = ["type": "integer", "minimum": 1] as [String: Any]
      default: properties[field.rawValue] = ["type": "string"]
      }
    }
    return ["type": "object", "properties": properties, "minProperties": 1, "additionalProperties": false]
  }

  // This allowlist is also the boundary between bibliographic data and private library content.
  static func publicFields(_ record: BookArchive) -> [String: Any] {
    var values: [String: Any] = [:]
    for field in fields where !field.value(in: record).isEmpty {
      switch field {
      case .authors, .translators:
        let role = field == .authors ? "author" : "translator"
        values[field.rawValue] = record.contributors.filter { $0.roleRaw == role }.map(\.name)
      case .pageCount: values[field.rawValue] = record.pageCount
      default: values[field.rawValue] = field.value(in: record)
      }
    }
    return values
  }

  static func proposal(_ values: [String: Any], current: BookArchive, source: String) throws -> MetadataUpdateProposal {
    var incoming = BookArchive(book: Book(title: ""))
    incoming.bookTypeRaw = nil
    let invalid = AIMetadataError(L10n.tr("AI 建议的字段或格式无效。"))
    for (key, raw) in values {
      // Older clients may still include a description alongside supported fields.
      if key == BookField.description.rawValue { continue }
      guard let field = BookField(rawValue: key), fields.contains(field) else { throw invalid }
      if raw is NSNull { continue }
      switch field {
      case .authors, .translators:
        guard let names = raw as? [String], names.count <= 50 else { throw invalid }
        var seen = Set<String>()
        for (index, value) in names.enumerated() {
          let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !name.isEmpty, name.count <= 200 else { throw invalid }
          if seen.insert(MetadataNormalizer.normalizedName(name)).inserted {
            incoming.contributors.append(ContributorArchive(name: name, roleRaw: field == .authors ? "author" : "translator", displayOrder: index))
          }
        }
      case .pageCount:
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          let pages = raw as? Int, pages > 0 else { throw BookMetadataEditError.invalidPageCount }
        incoming.pageCount = pages
      default:
        guard let raw = raw as? String, raw.utf8.count <= 2_048 else { throw invalid }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { continue }
        switch field {
        case .title: incoming.title = value
        case .subtitle: incoming.subtitle = value
        case .originalTitle: incoming.originalTitle = value
        case .publisher: incoming.publisher = value
        case .publicationDate: incoming.publicationDate = value
        case .edition: incoming.edition = value
        case .language: incoming.languageCode = value
        case .originalLanguage: incoming.originalLanguageCode = value
        case .isbn:
          let digits = value.uppercased().filter { !$0.isWhitespace && !"-‐‑–—".contains($0) }
          guard digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "X") }), let identity = ISBN.identity(digits)
          else { throw BookMetadataEditError.invalidISBN }
          incoming.isbn10 = digits.count == 10 ? digits : nil
          incoming.isbn13 = identity
        default: throw invalid
        }
      }
    }
    guard fields.contains(where: { !$0.value(in: incoming).isEmpty && BookMetadataValue.read($0, from: incoming) != BookMetadataValue.read($0, from: current) })
    else { throw AIMetadataError(L10n.tr("没有可补充或更改的元信息。")) }
    incoming.metadataSourceName = source
    incoming.metadataRetrievedAt = Date()
    let origin = MetadataFieldOrigin(name: source, url: nil, retrievedAt: incoming.metadataRetrievedAt)
    incoming.metadataFieldSourcesJSON = BookRecordMerge.encodeOrigins(Dictionary(uniqueKeysWithValues:
      fields.filter { !$0.value(in: incoming).isEmpty }.map { ($0.rawValue, origin) }))
    return MetadataUpdateProposal(current: current, incoming: incoming)
  }

  @MainActor
  static func book(_ id: UUID, context: ModelContext) throws -> Book {
    var request = FetchDescriptor<Book>(predicate: #Predicate { $0.id == id && $0.deletedAt == nil })
    request.fetchLimit = 1
    guard let book = try context.fetch(request).first else { throw BookMetadataEditError.missingBook }
    return book
  }

  @MainActor
  static func apply(_ proposal: MetadataUpdateProposal, fields selected: Set<BookField>, context: ModelContext,
    undoManager: UndoManager?) throws {
    let selected = selected.intersection(proposal.suppliedFields)
    guard !selected.isEmpty else { return }
    let book = try book(proposal.current.id, context: context)
    let latest = BookArchive(book: book)
    // A change of title or ISBN can identify another edition, even when the selected fields are still blank.
    guard selected.union([.title, .isbn]).allSatisfy({ BookMetadataValue.read($0, from: latest) == BookMetadataValue.read($0, from: proposal.current) })
    else { throw BookMetadataEditError.conflict }
    try LibraryCommands(context: context, undoManager: undoManager).update([book], name: L10n.tr("AI 补全元信息")) {
      $0 = BookRecordMerge.applyingMetadata(proposal.incoming, to: $0, fields: selected)
    }
  }
}
