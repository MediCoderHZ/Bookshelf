import Foundation

struct ManualCollectionRecord: Codable, Equatable, Identifiable {
  var id = UUID()
  var name: String
  var parentID: UUID?
  var sortOrder = 0
  var createdAt = Date()
  var updatedAt = Date()
  var bookIDs: Set<UUID> = []

  init(name: String, parentID: UUID? = nil) { self.name = name; self.parentID = parentID }
  init(_ collection: BookCollection) {
    id = collection.id; name = collection.name; parentID = collection.parentID; sortOrder = collection.sortOrder
    createdAt = collection.createdAt; updatedAt = collection.updatedAt
    bookIDs = Set(collection.items.compactMap(\.book?.id))
  }

  private enum CodingKeys: String, CodingKey { case id, name, parentID, sortOrder, createdAt, updatedAt, bookIDs }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
    parentID = try values.decodeIfPresent(UUID.self, forKey: .parentID)
    sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    createdAt = try values.decode(Date.self, forKey: .createdAt); updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    bookIDs = try values.decode(Set<UUID>.self, forKey: .bookIDs)
  }
}

struct NoteRecord: Codable, Equatable, Identifiable {
  var id = UUID()
  var title = ""
  var body = ""
  var parentBookID: UUID?
  var collectionIDs: [UUID] = []
  var tags: [String] = []
  var createdAt = Date()
  var updatedAt = Date()
  var deletedAt: Date?

  init(title: String = "", parentBookID: UUID? = nil) { self.title = title; self.parentBookID = parentBookID }
  init(_ note: LibraryNote) {
    id = note.id; title = note.title; body = note.body; parentBookID = note.parentBookID
    collectionIDs = note.collectionIDs; tags = note.tags
    createdAt = note.createdAt; updatedAt = note.updatedAt; deletedAt = note.deletedAt
  }
  var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NoteMarkdown.title(from: body) : title }
  var searchableText: String { ([displayTitle, body] + tags).joined(separator: " ") }
}

struct CollectionNode: Identifiable {
  let record: ManualCollectionRecord
  var children: [CollectionNode]?
  var id: UUID { record.id }
}

struct CollectionLocation: Identifiable {
  let record: ManualCollectionRecord
  let depth: Int
  let isDirectMember: Bool
  var id: UUID { record.id }
}

enum CollectionTree {
  /// Include only actual placements and their ancestors; an ancestor is not a membership.
  static func locations(for memberships: Set<UUID>, in records: [ManualCollectionRecord]) -> [CollectionLocation] {
    let lookup = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var included = Set<UUID>()
    for id in memberships {
      var current: UUID? = id
      while let id = current, let record = lookup[id], included.insert(id).inserted {
        current = record.parentID
      }
    }
    var result: [CollectionLocation] = [], visited = Set<UUID>()
    let ordered = lookup.values.filter { included.contains($0.id) }.sorted {
      if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
      let comparison = $0.name.localizedStandardCompare($1.name)
      return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
    }
    func append(_ record: ManualCollectionRecord, depth: Int) {
      guard visited.insert(record.id).inserted else { return }
      result.append(CollectionLocation(record: record, depth: depth, isDirectMember: memberships.contains(record.id)))
      for child in ordered where child.parentID == record.id { append(child, depth: depth + 1) }
    }
    for record in ordered where record.parentID.map({ !included.contains($0) }) ?? true { append(record, depth: 0) }
    // Render recoverable placements even if an imported hierarchy contains a cycle.
    for record in ordered where !visited.contains(record.id) { append(record, depth: 0) }
    return result
  }

  static func descendants(of id: UUID, in records: [ManualCollectionRecord]) -> Set<UUID> {
    var result: Set<UUID> = [id]
    var pending = [id]
    while let parent = pending.popLast() {
      for child in records where child.parentID == parent && result.insert(child.id).inserted { pending.append(child.id) }
    }
    return result
  }
  static func path(_ id: UUID, in records: [ManualCollectionRecord]) -> String {
    let lookup = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var parts: [String] = [], seen = Set<UUID>(), current: UUID? = id
    while let value = current, seen.insert(value).inserted, let record = lookup[value] {
      parts.append(record.name); current = record.parentID
    }
    return parts.reversed().joined(separator: " / ")
  }
  static func nodes(_ records: [ManualCollectionRecord]) -> [CollectionNode] {
    func children(_ parent: UUID?, visited: Set<UUID>) -> [CollectionNode] {
      records.filter { $0.parentID == parent && !visited.contains($0.id) }
        .sorted { CollectionOrdering.precedes(CollectionOrderingItem($0), CollectionOrderingItem($1)) }
        .map { record in
          let nested = children(record.id, visited: visited.union([record.id]))
          return CollectionNode(record: record, children: nested.isEmpty ? nil : nested)
        }
    }
    return children(nil, visited: [])
  }
  static func validate(_ records: [ManualCollectionRecord]) throws {
    let ids = Set(records.map(\.id))
    guard ids.count == records.count else { throw OrganizationError.invalidHierarchy }
    var names = Set<String>()
    for record in records {
      let name = MetadataNormalizer.normalizedName(record.name)
      guard !name.isEmpty, names.insert(name).inserted else { throw CollectionCommandError.invalidName }
      var seen: Set<UUID> = [record.id], parent = record.parentID
      while let id = parent {
        guard ids.contains(id), seen.insert(id).inserted else { throw OrganizationError.invalidHierarchy }
        parent = records.first { $0.id == id }?.parentID
      }
    }
  }
}

enum OrganizationError: LocalizedError {
  case invalidHierarchy, missingParent, noteInTrash, collectionInUse
  var errorDescription: String? {
    switch self {
    case .invalidHierarchy: "文件夹层级无效：不能移动到自己或子文件夹下，父文件夹必须存在。"
    case .missingParent: "关联的书籍或文件夹已变化，请重新打开编辑器。"
    case .noteInTrash: "请先恢复笔记及其所属书籍，再编辑内容。"
    case .collectionInUse: "文件夹或书籍中已有新的内容，已停止撤销以保留这些内容。"
    }
  }
}
