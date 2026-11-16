import Foundation
import SwiftData

extension CollectionCommands {
  @discardableResult
  func move(_ payload: CollectionDragPayload, to destination: CollectionDropDestination) throws -> Bool {
    guard payload.version == 1, payload.libraryID == LibraryServices.forContext(context).dragScopeID else {
      throw CollectionMoveError.staleDrag
    }
    let manual = try OrganizationStore.collections(in: context)
    let smart = try SmartCollectionService.snapshots(in: context)
    let items = manual.values.map(CollectionOrderingItem.init) + smart.values.map(CollectionOrderingItem.init)
    guard let source = items.first(where: { $0.id == payload.collectionID }), payload.matches(source) else {
      throw CollectionMoveError.staleDrag
    }
    let changes = try CollectionOrdering.move(payload.collectionID, to: destination, in: items)
    guard !changes.isEmpty else { return false }
    let modifiedAt = Date()
    var updatedManual: [ManualCollectionRecord] = [], updatedSmart: [SmartCollectionArchive] = []
    for change in changes {
      if var record = manual[change.id] {
        record.parentID = change.parentID; record.sortOrder = change.sortOrder; record.updatedAt = modifiedAt
        updatedManual.append(record)
      } else if var record = smart[change.id] {
        record.sortOrder = change.sortOrder; record.updatedAt = modifiedAt; updatedSmart.append(record)
      }
    }
    let manualIDs = Set(updatedManual.map(\.id)), smartIDs = Set(updatedSmart.map(\.id))
    try LibraryRepository.apply([], smartCollections: updatedSmart, manualCollections: updatedManual, into: context)
    LibraryServices.forContext(context).history.register(L10n.tr("移动文件夹"), before: [:], after: [:],
      beforeSmart: smart.filter { smartIDs.contains($0.key) },
      afterSmart: try SmartCollectionService.snapshots(in: context, ids: smartIDs),
      beforeCollections: manual.filter { manualIDs.contains($0.key) },
      afterCollections: try OrganizationStore.collections(in: context, ids: manualIDs),
      context: context, undoManager: undoManager)
    return true
  }
}
