import Foundation
import SwiftData

enum ImportAction: String, CaseIterable, Identifiable {
  case skip, add, fill, update
  var id: String { rawValue }
  var title: String {
    switch self {
    case .skip: "保留本地 / 跳过"; case .add: "作为新记录添加"
    case .fill: "合并补全空白"; case .update: "采用导入的出版信息"
    }
  }
}
struct ImportChoice {
  var action: ImportAction
  var targetID: UUID?
}
struct ImportPreviewItem: Identifiable {
  let record: BookArchive
  let matches: [BookArchive]
  let repeatedInFile: Bool
  var id: UUID { record.id }
  var defaultChoice: ImportChoice {
    ImportChoice(action: matches.isEmpty && !repeatedInFile ? .add : .skip, targetID: matches.first?.id)
  }
  var explanation: String {
    if repeatedInFile { return "文件内有相似记录，请核对后选择是否添加。" }
    if matches.isEmpty { return record.deletedAt == nil ? "新书籍" : "备份中的回收站记录" }
    if matches.allSatisfy({ BookRecordMerge.differentEditions(record, $0) }) { return "ISBN 不同：作为不同版本保留，不允许覆盖。" }
    if matches.contains(where: { $0.deletedAt != nil }) { return "包含回收站记录；更新保留其回收站状态。" }
    if matches.contains(where: { $0.id == record.id }) { return "记录 ID 相同，默认保留本地。" }
    return "ISBN 或书名、作者相似，需确认合并对象。"
  }
}
struct LibraryImportPlan: Identifiable {
  let id = UUID()
  let items: [ImportPreviewItem]
  var smartCollections: [SmartCollectionArchive] = []
  var existingSmartIDs: Set<UUID> = []
  var isRIS = false
  var importSummary: String?
  var importNotices: [String] = []
  var manualCollections: [ManualCollectionRecord] = []
  var notes: [NoteRecord] = []
  var collectionBaseline: [UUID: ManualCollectionRecord] = [:]
  var noteBaseline: [UUID: NoteRecord] = [:]
}

@MainActor
enum LibraryImportPlanner {
  static func prepare(_ data: Data, context: ModelContext) throws -> LibraryImportPlan {
    let archive = try LibraryBackupService.decode(data)
    return try prepare(archive, context: context)
  }

  static func prepareRIS(_ data: Data, context: ModelContext, registry: TranslatorRegistry = TranslatorRegistry()) throws -> LibraryImportPlan {
    let decoded = try TranslationEngine(registry: registry).importFile(data)
    var plan = try prepare(LibraryArchive(schemaVersion: 3, exportedAt: Date(), books: decoded.records), context: context)
    plan.isRIS = true; plan.importSummary = decoded.summary; plan.importNotices = decoded.notices
    return plan
  }

  private static func prepare(_ archive: LibraryArchive, context: ModelContext) throws -> LibraryImportPlan {
    let incoming = archive.books
    let local = try context.fetch(FetchDescriptor<Book>()).map { BookArchive(book: $0) }
    var previous: [BookArchive] = []
    let items = incoming.map { record -> ImportPreviewItem in
      let exact = local.filter { $0.id == record.id }
      let matches = exact.isEmpty ? local.filter { related(record, $0) } : exact
      let repeated = previous.contains { related(record, $0) && !BookRecordMerge.differentEditions(record, $0) }
      previous.append(record)
      return ImportPreviewItem(record: record, matches: matches, repeatedInFile: repeated)
    }
    let localSmart = try SmartCollectionService.snapshots(in: context).values
    let smart = archive.smartCollections ?? []
    let knownIDs = Set(localSmart.map(\.id))
    var knownNames = Set(localSmart.map { MetadataNormalizer.normalizedName($0.name) })
    var existing = Set<UUID>()
    for record in smart {
      let name = MetadataNormalizer.normalizedName(record.name)
      if knownIDs.contains(record.id) || knownNames.contains(name) { existing.insert(record.id) }
      else { knownNames.insert(name) }
    }
    return LibraryImportPlan(items: items, smartCollections: smart, existingSmartIDs: existing,
      manualCollections: archive.collections ?? [], notes: archive.libraryNotes ?? [],
      collectionBaseline: try OrganizationStore.collections(in: context), noteBaseline: try OrganizationStore.notes(in: context))
  }

  static func apply(_ plan: LibraryImportPlan, choices: [UUID: ImportChoice], context: ModelContext,
    undoManager: UndoManager?, includeSmartCollections: Bool = true, includeOrganization: Bool = true) throws -> LibraryImportSummary {
    let local = try context.fetch(FetchDescriptor<Book>())
    if includeOrganization && (!plan.manualCollections.isEmpty || !plan.notes.isEmpty) {
      guard try OrganizationStore.collections(in: context) == plan.collectionBaseline,
        try OrganizationStore.notes(in: context) == plan.noteBaseline else { throw LibraryOperationError.changedSincePreview }
    }
    let organization = try OrganizationImport.collections(includeOrganization ? plan.manualCollections : [],
      local: Array(OrganizationStore.collections(in: context).values),
      reservedIDs: Set(try context.fetch(FetchDescriptor<BookCollection>()).map(\.id)).union(plan.smartCollections.map(\.id)))
    var bookMap: [UUID: UUID] = [:]
    var records: [BookArchive] = []
    var before: [UUID: BookArchive] = [:]
    var usedTargets = Set<UUID>()
    var created = 0
    var updated = 0
    var skipped = 0
    for item in plan.items {
      let choice = choices[item.id] ?? item.defaultChoice
      switch choice.action {
      case .skip:
        skipped += 1
        if let exact = local.first(where: { $0.id == item.id }),
          !BookRecordMerge.differentEditions(item.record, BookArchive(book: exact)) { bookMap[item.id] = exact.id }
      case .add:
        var record = item.record
        if local.contains(where: { $0.id == record.id }) || records.contains(where: { $0.id == record.id }) {
          record.id = UUID()
        }
        record.mergedIntoID = nil
        record.collections = record.collections.map { organization.nameMap[$0] ?? $0 }.sorted()
        bookMap[item.id] = record.id
        records.append(record)
        created += 1
      case .fill, .update:
        guard let id = choice.targetID, let expected = item.matches.first(where: { $0.id == id }),
          let target = local.first(where: { $0.id == id }), usedTargets.insert(id).inserted
        else { throw LibraryOperationError.invalidSelection }
        guard BookArchive(book: target) == expected else { throw LibraryOperationError.changedSincePreview }
        guard !BookRecordMerge.differentEditions(item.record, expected) else { throw LibraryOperationError.differentEditions }
        before[id] = expected
        // Keep incoming provenance even when the backup record has the same ID.
        var incoming = item.record
        incoming.collections = incoming.collections.map { organization.nameMap[$0] ?? $0 }.sorted()
        incoming.id = UUID()
        let fields = choice.action == .update
          ? Dictionary(uniqueKeysWithValues: BookField.allCases.filter { !$0.value(in: incoming).isEmpty }.map { ($0, incoming.id) })
          : [:]
        var merged = BookRecordMerge.combine(primary: expected, others: [incoming], choices: fields)
        merged.deletedAt = expected.deletedAt
        merged.mergedIntoID = expected.mergedIntoID
        records.append(merged)
        bookMap[item.id] = id
        updated += 1
      }
    }
    // Prevent a fresh import from overwriting an update to the same target.
    guard Set(records.map(\.id)).count == records.count else { throw LibraryOperationError.invalidSelection }
    let smart = try includeSmartCollections ? newSmartCollections(plan.smartCollections, context: context) : []
    let notes = try OrganizationImport.notes(includeOrganization ? plan.notes : [],
      existingIDs: Set(OrganizationStore.notes(in: context).keys), bookMap: bookMap, collectionMap: organization.idMap)
    if !records.isEmpty || !smart.isEmpty || !organization.records.isEmpty || !notes.isEmpty {
      try LibraryRepository.apply(records, smartCollections: smart, manualCollections: organization.records, notes: notes, into: context)
      let ids = Set(records.map(\.id))
      let after = try context.fetch(FetchDescriptor<Book>()).filter { ids.contains($0.id) }
      LibraryServices.forContext(context).history.register(plan.isRIS ? "导入 RIS 书目" : "导入备份", before: before, after: LibraryHistory.snapshots(after),
        afterSmart: try SmartCollectionService.snapshots(in: context, ids: Set(smart.map(\.id))),
        afterCollections: try OrganizationStore.collections(in: context, ids: Set(organization.records.map(\.id))),
        afterNotes: try OrganizationStore.notes(in: context, ids: Set(notes.map(\.id))),
        context: context, undoManager: undoManager)
    }
    return LibraryImportSummary(createdCount: created, updatedCount: updated, skippedCount: skipped,
      createdSmartCount: smart.count, skippedSmartCount: plan.smartCollections.count - smart.count,
      createdCollectionCount: organization.records.count, keptCollectionCount: includeOrganization ? plan.manualCollections.count - organization.records.count : 0,
      createdNoteCount: notes.count, skippedNoteCount: includeOrganization ? plan.notes.count - notes.count : 0)
  }

  static func newSmartCollections(_ incoming: [SmartCollectionArchive], context: ModelContext) throws -> [SmartCollectionArchive] {
    let all = try context.fetch(FetchDescriptor<BookCollection>())
    var knownIDs = Set(all.filter(\.isSmart).map(\.id))
    var usedIDs = Set(all.map(\.id))
    var names = Set(all.filter(\.isSmart).map(\.normalizedName))
    var result: [SmartCollectionArchive] = []
    for var record in incoming {
      let name = MetadataNormalizer.normalizedName(record.name)
      guard !knownIDs.contains(record.id), !names.contains(name) else { continue }
      knownIDs.insert(record.id); names.insert(name)
      if usedIDs.contains(record.id) { record.id = UUID() }
      usedIDs.insert(record.id)
      result.append(record)
    }
    return result
  }

  private static func related(_ a: BookArchive, _ b: BookArchive) -> Bool {
    if let isbn = ISBN.identity(a.isbn13) ?? ISBN.identity(a.isbn10),
      isbn == (ISBN.identity(b.isbn13) ?? ISBN.identity(b.isbn10)) { return true }
    return BookRecordMerge.sameTitleAndAuthor(a, b)
  }
}
