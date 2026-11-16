import Foundation
import SwiftData

@MainActor
enum SmartCollectionService {
  /// Retire the old automatic presets once per store. New libraries start empty;
  /// subsequent user-created type searches must never be removed on startup.
  static func retireBookTypeDefaults(in context: ModelContext, preferences: UserDefaults = .standard) throws {
    let storeID = context.container.configurations.map { $0.url.standardizedFileURL.absoluteString }.sorted().joined(separator: "|")
    let key = "bookTypeSmartCollectionsRetired.v1." + storeID
    guard !preferences.bool(forKey: key) else { return }
    if preferences.bool(forKey: "bookTypeSmartCollectionsInstalled.v1." + storeID) {
      let collections = try context.fetch(FetchDescriptor<BookCollection>())
      // The old installer stored no per-collection provenance. Match both the
      // generated name and the complete preset rule, preserving renamed searches,
      // different rules, saved text searches, and ordinary collections.
      let presets = collections.filter { collection in
        guard collection.parentID == nil, let query = collection.smartQuery,
          query.version == 1, query.mode == .all, query.savedSearch == nil,
          query.rules.count == 1, let rule = query.rules.first,
          rule.field == .bookType, rule.comparison == .equals,
          let type = BookType(rawValue: rule.value) else { return false }
        let name = collection.name
        return name == type.legacyPresetName || name == type.legacyPresetName + "（类型）" ||
          name.range(of: "^" + NSRegularExpression.escapedPattern(for: type.legacyPresetName) + "（类型 (?:[2-9]|[1-9][0-9]+)）$",
            options: .regularExpression) != nil
      }
      if !presets.isEmpty {
        // Keep the retired definitions locally before the transaction. A retry
        // after interruption retains the first backup instead of overwriting it.
        let backupKey = key + ".backup"
        if preferences.data(forKey: backupKey) == nil {
          preferences.set(try JSONEncoder().encode(presets.map { try SmartCollectionArchive($0) }), forKey: backupKey)
        }
        try LibraryRepository.apply([], removingSmartIDs: Set(presets.map(\.id)), into: context)
      }
    }
    preferences.set(true, forKey: key)
  }

  static func snapshots(in context: ModelContext, ids: Set<UUID>? = nil) throws -> [UUID: SmartCollectionArchive] {
    let collections = try context.fetch(FetchDescriptor<BookCollection>()).filter { $0.isSmart && (ids == nil || ids!.contains($0.id)) }
    return try Dictionary(uniqueKeysWithValues: collections.map { ($0.id, try SmartCollectionArchive($0)) })
  }
  static func save(name: String, query: AdvancedBookQuery, replacing expected: SmartCollectionArchive? = nil,
    context: ModelContext, undoManager: UndoManager?) throws -> UUID {
    var record = SmartCollectionArchive(name: name.trimmingCharacters(in: .whitespacesAndNewlines), query: query)
    var before: [UUID: SmartCollectionArchive] = [:]
    if let expected {
      before = try snapshots(in: context, ids: [expected.id])
      guard before[expected.id] == expected else { throw LibraryOperationError.changedSincePreview }
      record.id = expected.id; record.createdAt = expected.createdAt
      record.sortOrder = expected.sortOrder
    } else {
      record.sortOrder = CollectionOrdering.nextOrder(in: try context.fetch(FetchDescriptor<BookCollection>()).map(CollectionOrderingItem.init), parentID: nil)
    }
    try LibraryRepository.apply([], smartCollections: [record], into: context)
    LibraryServices.forContext(context).history.register(expected == nil ? L10n.tr("新建智能文件夹") : L10n.tr("编辑智能文件夹"), before: [:], after: [:],
      beforeSmart: before, afterSmart: try snapshots(in: context, ids: [record.id]), context: context, undoManager: undoManager)
    return record.id
  }
  static func remove(_ collection: BookCollection, context: ModelContext, undoManager: UndoManager?) throws {
    guard collection.isSmart else { throw LibraryOperationError.invalidSelection }
    let before = try snapshots(in: context, ids: [collection.id])
    try LibraryRepository.apply([], removingSmartIDs: [collection.id], into: context)
    LibraryServices.forContext(context).history.register(L10n.tr("移除智能文件夹"), before: [:], after: [:], beforeSmart: before, afterSmart: [:], context: context, undoManager: undoManager)
  }

}
