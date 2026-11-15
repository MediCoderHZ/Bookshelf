import Foundation
import SwiftData

@MainActor
enum LibraryRepository {
  static func writeCollection(_ record: ManualCollectionRecord?, expected: ManualCollectionRecord?,
    id: UUID, context: ModelContext) throws {
    let all = try context.fetch(FetchDescriptor<BookCollection>())
    let current = all.first { $0.id == id }
    guard current?.isSmart != true, current.map(ManualCollectionRecord.init) == expected,
      record == nil || record?.id == id else { throw LibraryOperationError.changedSincePreview }
    if let record {
      guard !record.name.isEmpty, !all.contains(where: { !$0.isSmart && $0.id != id &&
        $0.normalizedName == MetadataNormalizer.normalizedName(record.name) }) else {
        throw CollectionCommandError.invalidName
      }
    } else if current?.items.isEmpty == false { throw LibraryOperationError.changedSincePreview }
    try apply([], manualCollections: record.map { [$0] } ?? [],
      removingCollectionIDs: record == nil ? [id] : [], into: context)
  }
  static func snapshots(in context: ModelContext, ids: Set<UUID>? = nil) throws -> [UUID: BookArchive] {
    let books = try context.fetch(FetchDescriptor<Book>()).filter { ids == nil || ids!.contains($0.id) }
    return LibraryHistory.snapshots(books)
  }
  /// Exact transactional writer shared by import, merge and undo.
  static func apply(_ records: [BookArchive], removing removedIDs: Set<UUID> = [],
    smartCollections: [SmartCollectionArchive] = [], removingSmartIDs: Set<UUID> = [],
    manualCollections: [ManualCollectionRecord] = [], removingCollectionIDs: Set<UUID> = [],
    notes: [NoteRecord] = [], removingNoteIDs: Set<UUID> = [],
    tags: [TagRecord] = [], removingTagIDs: Set<UUID> = [], into modelContext: ModelContext) throws {
    guard Set(records.map(\.id)).count == records.count,
      removedIDs.isDisjoint(with: records.map(\.id)) else { throw LibraryBackupError.invalidDocument }
    var books = try modelContext.fetch(FetchDescriptor<Book>())
    var peopleByName = Dictionary(
      try modelContext.fetch(FetchDescriptor<Person>()).map { ($0.name, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var tagsByName = Dictionary(
      try modelContext.fetch(FetchDescriptor<Tag>()).map { ($0.normalizedName, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var collectionsByName = Dictionary(
      try modelContext.fetch(FetchDescriptor<BookCollection>()).filter { !$0.isSmart }.map { ($0.normalizedName, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var seriesByName = Dictionary(
      try modelContext.fetch(FetchDescriptor<BookSeries>()).map { ($0.normalizedName, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    do {
      try TagStore.stage(tags, removing: removingTagIDs, changingNoteIDs: Set(notes.map(\.id)), context: modelContext)
      if !tags.isEmpty || !removingTagIDs.isEmpty {
        tagsByName = Dictionary(try modelContext.fetch(FetchDescriptor<Tag>())
          .filter { !removingTagIDs.contains($0.id) }.map { ($0.normalizedName, $0) },
          uniquingKeysWith: { first, _ in first })
      }
      try SmartCollectionStore.stage(smartCollections, removing: removingSmartIDs, context: modelContext)
      try OrganizationStore.stageCollections(manualCollections, removing: removingCollectionIDs, context: modelContext)
      // Include newly staged hierarchy nodes before resolving legacy name memberships.
      collectionsByName = Dictionary(try modelContext.fetch(FetchDescriptor<BookCollection>())
        .filter { !$0.isSmart && !removingCollectionIDs.contains($0.id) }.map { ($0.normalizedName, $0) },
        uniquingKeysWith: { first, _ in first })
      for book in books where removedIDs.contains(book.id) {
        modelContext.delete(book)
      }
      for record in records {
        let book = books.first { $0.id == record.id } ?? Book(title: record.title)
        if book.modelContext == nil {
          book.id = record.id
          modelContext.insert(book)
          books.append(book)
        }

        let previous = BookArchive(book: book)
        let contributorsChanged = previous.contributors != record.contributors
        let tagsChanged = previous.tags != record.tags
        let collectionsChanged = previous.collections != record.collections
        let seriesChanged = previous.seriesMemberships != record.seriesMemberships
        applyScalarValues(record, to: book)
        // Keep unrelated membership IDs, dates and ordering intact for edits and undo.
        if contributorsChanged {
          book.contributions.forEach(modelContext.delete); book.contributions.removeAll()
        }
        if tagsChanged {
          book.tagLinks.forEach(modelContext.delete); book.tagLinks.removeAll()
        }
        if collectionsChanged {
          book.collectionItems.forEach(modelContext.delete); book.collectionItems.removeAll()
        }
        if seriesChanged {
          book.seriesMemberships.forEach(modelContext.delete); book.seriesMemberships.removeAll()
        }

        for contributor in record.contributors.sorted(by: { $0.displayOrder < $1.displayOrder }) where contributorsChanged {
          // Preserve each book's spelling/capitalization without renaming a shared person.
          let name = contributor.name.trimmingCharacters(in: .whitespacesAndNewlines)
          let person = peopleByName[name] ?? Person(name: name)
          if peopleByName[name] == nil {
            modelContext.insert(person)
            peopleByName[name] = person
          }
          let contribution = Contribution(
            book: book,
            person: person,
            role: ContributorRole(rawValue: contributor.roleRaw) ?? .other,
            displayOrder: contributor.displayOrder
          )
          modelContext.insert(contribution)
        }

        for tagName in record.tags where tagsChanged {
          let normalizedName = MetadataNormalizer.normalizedName(tagName)
          let tag = tagsByName[normalizedName] ?? Tag(name: tagName)
          if tagsByName[normalizedName] == nil {
            modelContext.insert(tag)
            tagsByName[normalizedName] = tag
          }
          modelContext.insert(BookTag(book: book, tag: tag))
        }

        for collectionName in record.collections where collectionsChanged {
          let normalizedName = MetadataNormalizer.normalizedName(collectionName)
          let collection = collectionsByName[normalizedName] ?? BookCollection(name: collectionName)
          if collectionsByName[normalizedName] == nil {
            modelContext.insert(collection)
            collectionsByName[normalizedName] = collection
          }
          modelContext.insert(CollectionItem(collection: collection, book: book))
        }

        for membership in record.seriesMemberships where seriesChanged {
          let normalizedName = MetadataNormalizer.normalizedName(membership.seriesName)
          let series = seriesByName[normalizedName] ?? BookSeries(name: membership.seriesName)
          if seriesByName[normalizedName] == nil {
            modelContext.insert(series)
            seriesByName[normalizedName] = series
          }
          modelContext.insert(
            SeriesMembership(
              series: series,
              book: book,
              volumeLabel: membership.volumeLabel,
              displayOrder: membership.displayOrder
            )
          )
        }

      }

      try OrganizationStore.stageNotes(notes, removing: removingNoteIDs,
        removingBookIDs: removedIDs, removingCollectionIDs: removingCollectionIDs, context: modelContext)
      try modelContext.save()
      LibraryNotifier.forContext(modelContext).publish(
        books: Set(records.map(\.id)).union(removedIDs),
        collections: Set(smartCollections.map(\.id)).union(removingSmartIDs).union(manualCollections.map(\.id)).union(removingCollectionIDs),
        notes: Set(notes.map(\.id)).union(removingNoteIDs),
        tags: Set(tags.map(\.id)).union(removingTagIDs))
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  private static func applyScalarValues(_ record: BookArchive, to book: Book) {
    book.title = record.title
    book.subtitle = record.subtitle
    book.originalTitle = record.originalTitle
    book.bookTypeRaw = record.bookTypeRaw
    book.originalLanguageCode = record.originalLanguageCode
    book.isbn10 = record.isbn10
    book.isbn13 = record.isbn13
    book.publisher = record.publisher
    book.publicationDate = record.publicationDate
    book.edition = record.edition
    book.pageCount = record.pageCount
    book.languageCode = record.languageCode
    book.bookDescription = record.bookDescription
    book.metadataSourceName = record.metadataSourceName
    book.metadataSourceURL = record.metadataSourceURL
    book.metadataRetrievedAt = record.metadataRetrievedAt
    book.metadataFieldSourcesJSON = RetiredReadingData.cleanFieldOrigins(record.metadataFieldSourcesJSON)
    book.deletedAt = record.deletedAt
    book.mergedIntoID = record.mergedIntoID
    book.notes = record.notes
    book.addedAt = record.addedAt
    book.createdAt = record.createdAt
    book.updatedAt = record.updatedAt
  }

}

enum CollectionCommandError: LocalizedError {
  case invalidName
  var errorDescription: String? { "文件夹名称不能为空，也不能与已有普通文件夹重名。" }
}
