import Foundation

struct CollectionImportResolution {
  var records: [ManualCollectionRecord] = []
  var idMap: [UUID: UUID] = [:]
  var nameMap: [String: String] = [:]
}

enum OrganizationImport {
  static func collections(_ incoming: [ManualCollectionRecord], local: [ManualCollectionRecord],
    reservedIDs: Set<UUID>) throws -> CollectionImportResolution {
    try CollectionTree.validate(incoming)
    var result = CollectionImportResolution(), pending = incoming, known = local
    var usedIDs = reservedIDs.union(local.map(\.id))
    while !pending.isEmpty {
      guard let index = pending.firstIndex(where: { $0.parentID == nil || result.idMap[$0.parentID!] != nil })
      else { throw OrganizationError.invalidHierarchy }
      let original = pending.remove(at: index)
      if let match = known.first(where: { $0.id == original.id }) ?? known.first(where: {
        MetadataNormalizer.normalizedName($0.name) == MetadataNormalizer.normalizedName(original.name)
      }) {
        result.idMap[original.id] = match.id; result.nameMap[original.name] = match.name
      } else {
        var record = original
        if usedIDs.contains(record.id) { record.id = UUID() }
        record.parentID = original.parentID.flatMap { result.idMap[$0] }
        record.bookIDs = [] // Membership is resolved by the selected book import actions.
        result.idMap[original.id] = record.id; result.nameMap[original.name] = record.name
        result.records.append(record); known.append(record); usedIDs.insert(record.id)
      }
    }
    return result
  }

  static func notes(_ incoming: [NoteRecord], existingIDs: Set<UUID>, bookMap: [UUID: UUID],
    collectionMap: [UUID: UUID]) -> [NoteRecord] {
    incoming.compactMap { original in
      guard !existingIDs.contains(original.id) else { return nil }
      var note = original
      if let parent = original.parentBookID {
        guard let mapped = bookMap[parent] else { return nil }
        note.parentBookID = mapped; note.collectionIDs = []
      } else {
        note.collectionIDs = Array(Set(original.collectionIDs.compactMap { collectionMap[$0] })).sorted { $0.uuidString < $1.uuidString }
      }
      return note
    }
  }
}
