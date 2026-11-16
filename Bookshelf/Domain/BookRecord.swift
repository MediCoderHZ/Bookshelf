import Foundation

struct LibraryArchive: Codable {
  let schemaVersion: Int
  let exportedAt: Date
  let books: [BookArchive]
  var smartCollections: [SmartCollectionArchive]? = nil
  var collections: [ManualCollectionRecord]? = nil
  var libraryNotes: [NoteRecord]? = nil
}

struct BookArchive: Codable, Equatable {
  var id: UUID
  var title: String
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
  var addedAt: Date
  var createdAt: Date
  var updatedAt: Date
  var contributors: [ContributorArchive]
  var tags: [String]
  var collections: [String]
  var seriesMemberships: [SeriesMembershipArchive]

  var bookType: BookType? { BookType(rawValue: bookTypeRaw ?? "") }

  init(book: Book) {
    id = book.id
    title = book.title
    subtitle = book.subtitle
    originalTitle = book.originalTitle
    bookTypeRaw = book.bookTypeRaw
    originalLanguageCode = book.originalLanguageCode
    isbn10 = book.isbn10
    isbn13 = book.isbn13
    publisher = book.publisher
    publicationDate = book.publicationDate
    edition = book.edition
    pageCount = book.pageCount
    languageCode = book.languageCode
    bookDescription = book.bookDescription
    metadataSourceName = book.metadataSourceName
    metadataSourceURL = book.metadataSourceURL
    metadataRetrievedAt = book.metadataRetrievedAt
    metadataFieldSourcesJSON = RetiredReadingData.cleanFieldOrigins(book.metadataFieldSourcesJSON)
    deletedAt = book.deletedAt
    mergedIntoID = book.mergedIntoID
    notes = book.notes
    addedAt = book.addedAt
    createdAt = book.createdAt
    updatedAt = book.updatedAt
    contributors = book.contributions.map { ContributorArchive(contribution: $0) }.sorted { ($0.roleRaw, $0.displayOrder, $0.name) < ($1.roleRaw, $1.displayOrder, $1.name) }
    tags = book.tagLinks.compactMap(\.tag?.name).sorted()
    collections = book.collectionItems.compactMap(\.collection).filter { !$0.isSmart }.map(\.name).sorted()
    seriesMemberships = book.seriesMemberships.compactMap {
      SeriesMembershipArchive(membership: $0)
    }.sorted { ($0.seriesName, $0.displayOrder) < ($1.seriesName, $1.displayOrder) }
  }
}

struct ContributorArchive: Codable, Equatable {
  var name: String
  var roleRaw: String
  var displayOrder: Int

  init(contribution: Contribution) {
    name = contribution.person?.name ?? L10n.tr("未知")
    roleRaw = contribution.roleRaw
    displayOrder = contribution.displayOrder
  }
}

struct SeriesMembershipArchive: Codable, Equatable {
  var seriesName: String
  var volumeLabel: String?
  var displayOrder: Int

  init?(membership: SeriesMembership) {
    guard let seriesName = membership.series?.name else { return nil }
    self.seriesName = seriesName
    volumeLabel = membership.volumeLabel
    displayOrder = membership.displayOrder
  }
}

