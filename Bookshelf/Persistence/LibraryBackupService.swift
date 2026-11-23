import Foundation
import SwiftData

struct LibraryImportSummary {
  let createdCount: Int
  let updatedCount: Int
  var skippedCount: Int = 0
  var createdSmartCount: Int = 0
  var skippedSmartCount: Int = 0
  var createdCollectionCount: Int = 0
  var keptCollectionCount: Int = 0
  var createdNoteCount: Int = 0
  var skippedNoteCount: Int = 0

  var message: String {
    L10n.tr("已新增 \(createdCount) 本，更新 \(updatedCount) 本，跳过 \(skippedCount) 本。")
      + (createdSmartCount + skippedSmartCount > 0 ? L10n.tr("智能文件夹新增 \(createdSmartCount) 个，跳过 \(skippedSmartCount) 个。") : "")
      + (createdCollectionCount + keptCollectionCount > 0 ? L10n.tr("普通文件夹新增 \(createdCollectionCount) 个，沿用本地 \(keptCollectionCount) 个。") : "")
      + (createdNoteCount + skippedNoteCount > 0 ? L10n.tr("笔记新增 \(createdNoteCount) 条，跳过 \(skippedNoteCount) 条（已存在或所属书籍未导入）。") : "")
  }
}

@MainActor
enum LibraryBackupService {
  static func exportData(from modelContext: ModelContext) throws -> Data {
    let books = try modelContext.fetch(
      FetchDescriptor<Book>(sortBy: [SortDescriptor(\Book.addedAt, order: .reverse)])
    )
    let ids = Set(books.flatMap { $0.attachmentIDs ?? [] })
    let files: [PortableAttachment]?
    if ids.isEmpty { files = nil }
    else {
      let store = try BookAttachmentStore(context: modelContext)
      files = try ids.sorted { $0.uuidString < $1.uuidString }.map(store.portable)
    }
    let archive = LibraryArchive(
      schemaVersion: files.map { $0.contains(where: { $0.webURL != nil }) ? 11 : 10 } ?? 9,
      exportedAt: Date(),
      books: books.map { BookArchive(book: $0) },
      smartCollections: try SmartCollectionService.snapshots(in: modelContext).values.sorted { $0.name < $1.name },
      collections: try OrganizationStore.collections(in: modelContext).values.sorted { $0.name < $1.name },
      attachmentFiles: files,
      libraryNotes: try OrganizationStore.notes(in: modelContext).values.sorted { $0.id.uuidString < $1.id.uuidString }
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(archive)
  }

  static func decode(_ data: Data) throws -> LibraryArchive {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(LibraryArchive.self, from: RetiredReadingData.cleanBackup(data))
    guard (1...11).contains(archive.schemaVersion) else { throw LibraryBackupError.unsupportedSchema(archive.schemaVersion) }
    guard Set(archive.books.map(\.id)).count == archive.books.count,
      archive.books.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { throw LibraryBackupError.invalidDocument }
    let files = archive.attachmentFiles ?? []
    let attachmentIDs = files.map(\.id)
    for file in files {
      try file.validate()
      if file.webURL != nil && archive.schemaVersion < 11 { throw LibraryBackupError.invalidDocument }
    }
    guard Set(attachmentIDs).count == files.count,
      Set(attachmentIDs) == Set(archive.books.flatMap { $0.attachmentIDs ?? [] }),
      archive.books.allSatisfy({ Set($0.attachmentIDs ?? []).count == ($0.attachmentIDs?.count ?? 0) })
    else { throw LibraryBackupError.invalidDocument }
    let smart = archive.smartCollections ?? []
    guard Set(smart.map(\.id)).count == smart.count, smart.allSatisfy(\.isValid) else { throw SmartCollectionError.invalidRules }
    let collections = archive.collections ?? [], notes = archive.libraryNotes ?? []
    try CollectionTree.validate(collections)
    let collectionIDs = Set(collections.map(\.id)), bookIDs = Set(archive.books.map(\.id))
    guard collectionIDs.isDisjoint(with: smart.map(\.id)),
      collections.allSatisfy({ $0.bookIDs.isSubset(of: bookIDs) }),
      Set(notes.map(\.id)).count == notes.count,
      notes.allSatisfy({ ($0.parentBookID.map { bookIDs.contains($0) } ?? true) &&
        ($0.parentBookID == nil || $0.collectionIDs.isEmpty) && Set($0.collectionIDs).isSubset(of: collectionIDs) })
    else { throw LibraryBackupError.invalidDocument }
    return archive
  }

  // Non-UI convenience for verified backups and regression fixtures. The UI always
  // prepares an ImportPlan and requires explicit conflict decisions.
  static func importData(_ data: Data, into modelContext: ModelContext) throws -> LibraryImportSummary {
    let archive = try decode(data)
    let existing = try modelContext.fetch(FetchDescriptor<Book>())
    var records: [BookArchive] = []
    var updated = 0
    var bookMap: [UUID: UUID] = [:]
    let organization = try OrganizationImport.collections(archive.collections ?? [],
      local: Array(OrganizationStore.collections(in: modelContext).values),
      reservedIDs: Set(try modelContext.fetch(FetchDescriptor<BookCollection>()).map(\.id)).union((archive.smartCollections ?? []).map(\.id)))
    for var record in archive.books {
      let originalID = record.id
      let exact = existing.first { $0.id == record.id }
      let isbn = ISBN.identity(record.isbn13) ?? ISBN.identity(record.isbn10)
      let match = exact ?? existing.first {
        isbn != nil && isbn == (ISBN.identity($0.isbn13) ?? ISBN.identity($0.isbn10))
      }
      if let match, !BookRecordMerge.differentEditions(record, BookArchive(book: match)) {
        let incoming = record.attachmentIDs ?? []
        let local = match.attachmentIDs ?? []
        let ids = local + incoming.filter { !local.contains($0) }
        record.attachmentIDs = ids.isEmpty ? nil : ids
        record.id = match.id
        updated += 1
      } else if existing.contains(where: { $0.id == record.id }) {
        record.id = UUID()
      }
      record.collections = record.collections.map { organization.nameMap[$0] ?? $0 }.sorted()
      bookMap[originalID] = record.id; records.append(record)
    }
    let smart = try LibraryImportPlanner.newSmartCollections(archive.smartCollections ?? [], context: modelContext)
    let notes = try OrganizationImport.notes(archive.libraryNotes ?? [], existingIDs: Set(OrganizationStore.notes(in: modelContext).keys),
      bookMap: bookMap, collectionMap: organization.idMap)
    try BookAttachmentStore.commitImport(records, files: archive.attachmentFiles ?? [], context: modelContext) { restored in
      try LibraryRepository.apply(restored, smartCollections: smart, manualCollections: organization.records, notes: notes, into: modelContext)
    }
    return LibraryImportSummary(createdCount: records.count - updated, updatedCount: updated,
      createdSmartCount: smart.count, skippedSmartCount: (archive.smartCollections?.count ?? 0) - smart.count,
      createdCollectionCount: organization.records.count, keptCollectionCount: (archive.collections?.count ?? 0) - organization.records.count,
      createdNoteCount: notes.count, skippedNoteCount: (archive.libraryNotes?.count ?? 0) - notes.count)
  }

  // Compatibility entry for older integrations; persistence belongs to the repository.
  static func apply(_ records: [BookArchive], removing removedIDs: Set<UUID> = [],
    smartCollections: [SmartCollectionArchive] = [], removingSmartIDs: Set<UUID> = [], into modelContext: ModelContext) throws {
    try LibraryRepository.apply(records, removing: removedIDs, smartCollections: smartCollections,
      removingSmartIDs: removingSmartIDs, into: modelContext)
  }
}

enum LibraryBackupError: LocalizedError {
  case invalidDocument
  case unsupportedSchema(Int)

  var errorDescription: String? {
    switch self {
    case .invalidDocument:
      L10n.tr("无法读取这个备份文件。")
    case .unsupportedSchema(let version):
      L10n.tr("暂不支持版本为 \(version) 的 Bookshelf 备份。")
    }
  }
}
