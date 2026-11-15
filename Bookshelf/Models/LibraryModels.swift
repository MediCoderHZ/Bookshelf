import Foundation
import SwiftData

@Model
final class Book {
  var id: UUID = UUID()
  var title: String = ""
  var subtitle: String?
  var originalTitle: String?
  var bookTypeRaw: String?
  var originalLanguageCode: String?
  var isbn10: String?
  var isbn13: String?
  var publisher: String?
  var publicationDate: String?
  var edition: String?
  var pageCount: Int?
  var languageCode: String?
  var bookDescription: String?
  var metadataSourceName: String?
  var metadataSourceURL: String?
  var metadataRetrievedAt: Date?
  var metadataFieldSourcesJSON: String?
  var deletedAt: Date?
  var mergedIntoID: UUID?
  var notes: String?
  var addedAt: Date = Date()
  var createdAt: Date = Date()
  var updatedAt: Date = Date()

  @Relationship(deleteRule: .cascade, inverse: \Contribution.book)
  var contributions: [Contribution] = []

  @Relationship(deleteRule: .cascade, inverse: \BookTag.book)
  var tagLinks: [BookTag] = []

  @Relationship(deleteRule: .cascade, inverse: \CollectionItem.book)
  var collectionItems: [CollectionItem] = []

  @Relationship(deleteRule: .cascade, inverse: \SeriesMembership.book)
  var seriesMemberships: [SeriesMembership] = []

  init(title: String) {
    self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var bookType: BookType? { BookType(rawValue: bookTypeRaw ?? "") }

  var authors: [Person] {
    contributions
      .filter { $0.role == .author }
      .sorted { $0.displayOrder < $1.displayOrder }
      .compactMap(\.person)
  }

  var translators: [Person] {
    contributions
      .filter { $0.role == .translator }
      .sorted { $0.displayOrder < $1.displayOrder }
      .compactMap(\.person)
  }

  var authorDisplayName: String {
    let names = authors.map(\.name)
    return names.isEmpty ? "未知作者" : names.joined(separator: "、")
  }

  var tagDisplayName: String {
    tagLinks.compactMap(\.tag?.name).sorted().joined(separator: "、")
  }

  var normalizedISBN: String? {
    ISBN.normalized(isbn13) ?? ISBN.normalized(isbn10)
  }

  var searchableText: String {
    [
      title,
      subtitle,
      originalTitle,
      bookType?.title,
      originalLanguageCode,
      isbn10,
      isbn13,
      publisher,
      bookDescription,
      notes,
      authorDisplayName,
      contributions.sorted { $0.displayOrder < $1.displayOrder }.compactMap(\.person?.name).joined(separator: " "),
      seriesMemberships.compactMap(\.series?.name).joined(separator: " "),
      tagDisplayName,
    ]
    .compactMap { $0 }
    .joined(separator: " ")
    .localizedLowercase
  }
}

@Model
final class Person {
  var id: UUID = UUID()
  var name: String = ""
  var normalizedName: String = ""
  var sortName: String?
  var notes: String?

  @Relationship(deleteRule: .cascade, inverse: \Contribution.person)
  var contributions: [Contribution] = []

  init(name: String) {
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.normalizedName = MetadataNormalizer.normalizedName(name)
  }
}

@Model
final class Contribution {
  var id: UUID = UUID()
  var roleRaw: String = ContributorRole.author.rawValue
  var displayOrder: Int = 0
  var book: Book?
  var person: Person?

  init(book: Book?, person: Person?, role: ContributorRole, displayOrder: Int) {
    self.book = book
    self.person = person
    self.roleRaw = role.rawValue
    self.displayOrder = displayOrder
  }

  var role: ContributorRole {
    get { ContributorRole(rawValue: roleRaw) ?? .other }
    set { roleRaw = newValue.rawValue }
  }
}

@Model
final class Tag {
  var id: UUID = UUID()
  var name: String = ""
  var normalizedName: String = ""
  var createdAt: Date = Date()

  @Relationship(deleteRule: .cascade, inverse: \BookTag.tag)
  var bookLinks: [BookTag] = []

  init(name: String) {
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.normalizedName = MetadataNormalizer.normalizedName(name)
  }
}

@Model
final class BookTag {
  var id: UUID = UUID()
  var book: Book?
  var tag: Tag?

  init(book: Book?, tag: Tag?) {
    self.book = book
    self.tag = tag
  }
}

@Model
final class BookCollection {
  var id: UUID = UUID()
  var name: String = ""
  var normalizedName: String = ""
  var symbolName: String = "folder"
  var smartRulesJSON: String?
  var parentID: UUID?
  var colorKey: String?
  var sortOrder: Int = 0
  var createdAt: Date = Date()
  var updatedAt: Date = Date()

  @Relationship(deleteRule: .cascade, inverse: \CollectionItem.collection)
  var items: [CollectionItem] = []

  init(name: String) {
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.normalizedName = MetadataNormalizer.normalizedName(name)
  }
}

/// Notes are library records, not files. A nil parent is a standalone note.
@Model
final class LibraryNote {
  var id: UUID = UUID()
  var title: String = ""
  var body: String = ""
  var parentBookID: UUID?
  var collectionIDs: [UUID] = []
  var tags: [String] = []
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
  var deletedAt: Date?

  init(title: String, body: String = "") {
    self.title = title
    self.body = body
  }
}

@Model
final class CollectionItem {
  var id: UUID = UUID()
  var addedAt: Date = Date()
  var sortOrder: Int = 0
  var collection: BookCollection?
  var book: Book?

  init(collection: BookCollection?, book: Book?, sortOrder: Int = 0) {
    self.collection = collection
    self.book = book
    self.sortOrder = sortOrder
  }
}

@Model
final class BookSeries {
  var id: UUID = UUID()
  var name: String = ""
  var normalizedName: String = ""
  var sortName: String?

  @Relationship(deleteRule: .cascade, inverse: \SeriesMembership.series)
  var memberships: [SeriesMembership] = []

  init(name: String) {
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.normalizedName = MetadataNormalizer.normalizedName(name)
  }
}

@Model
final class SeriesMembership {
  var id: UUID = UUID()
  var volumeLabel: String?
  var displayOrder: Int = 0
  var series: BookSeries?
  var book: Book?

  init(series: BookSeries?, book: Book?, volumeLabel: String? = nil, displayOrder: Int = 0) {
    self.series = series
    self.book = book
    self.volumeLabel = volumeLabel
    self.displayOrder = displayOrder
  }
}

