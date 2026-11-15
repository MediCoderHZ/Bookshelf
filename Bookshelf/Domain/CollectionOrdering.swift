import Foundation

/// A value projection shared by sidebar placement, persistence commands and tests.
struct CollectionOrderingItem: Equatable, Identifiable, Sendable {
  let id: UUID
  let name: String
  var parentID: UUID?
  var sortOrder: Int
  let isSmart: Bool
  let updatedAt: Date

  init(id: UUID = UUID(), name: String, parentID: UUID? = nil, sortOrder: Int = 0,
    isSmart: Bool = false, updatedAt: Date = Date()) {
    self.id = id; self.name = name; self.parentID = parentID; self.sortOrder = sortOrder
    self.isSmart = isSmart; self.updatedAt = updatedAt
  }
  init(_ record: ManualCollectionRecord) {
    self.init(id: record.id, name: record.name, parentID: record.parentID,
      sortOrder: record.sortOrder, updatedAt: record.updatedAt)
  }
  init(_ record: SmartCollectionArchive) {
    self.init(id: record.id, name: record.name, sortOrder: record.sortOrder, isSmart: true, updatedAt: record.updatedAt)
  }
  init(_ collection: BookCollection) {
    self.init(id: collection.id, name: collection.name, parentID: collection.parentID,
      sortOrder: collection.sortOrder, isSmart: collection.isSmart, updatedAt: collection.updatedAt)
  }
}

/// A filtered collection tree, independent of the persisted navigation expansion.
struct CollectionSearchTree {
  let items: [CollectionOrderingItem]
  let matchedIDs: Set<UUID>
  let ancestorIDs: Set<UUID>
  let isFiltering: Bool
  private let paths: [UUID: String]

  init(items source: [CollectionOrderingItem], query: String) {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    isFiltering = !text.isEmpty
    let lookup = Dictionary(source.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var paths: [UUID: String] = [:]
    var ancestry: [UUID: Set<UUID>] = [:]
    for item in source {
      var names = [item.name], ancestors = Set<UUID>(), visited: Set<UUID> = [item.id]
      var parent = item.parentID
      while let id = parent, let ancestor = lookup[id], visited.insert(id).inserted {
        names.insert(ancestor.name, at: 0); ancestors.insert(id); parent = ancestor.parentID
      }
      paths[item.id] = names.joined(separator: " / ")
      ancestry[item.id] = ancestors
    }
    self.paths = paths
    // A name match must not pull in unrelated descendants just because their
    // path contains that parent's name. Explicit paths remain searchable.
    let pathQuery = text.split(separator: "/", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " / ")
    matchedIDs = Set(source.filter {
      text.isEmpty || $0.name.localizedStandardContains(text)
        || (text.contains("/") && paths[$0.id, default: ""].localizedStandardContains(pathQuery))
    }.map(\.id))
    ancestorIDs = matchedIDs.reduce(into: Set<UUID>()) { $0.formUnion(ancestry[$1] ?? []) }
    let included = matchedIDs.union(ancestorIDs)
    items = source.filter { included.contains($0.id) }
  }

  func path(_ id: UUID) -> String { paths[id, default: ""] }

  func initialExpansion(restoring original: Set<UUID>) -> Set<UUID> {
    isFiltering ? ancestorIDs : original
  }

  /// Keyboard traversal follows the displayed hierarchy and stored sibling order.
  func visibleItems(expanded: Set<UUID>) -> [CollectionOrderingItem] {
    let siblings = Dictionary(grouping: items, by: \.parentID)
    var visible: [CollectionOrderingItem] = [], visited = Set<UUID>()
    func appendChildren(of parent: UUID?) {
      for item in (siblings[parent] ?? []).sorted(by: CollectionOrdering.precedes) {
        guard visited.insert(item.id).inserted else { continue }
        visible.append(item)
        if expanded.contains(item.id) { appendChildren(of: item.id) }
      }
    }
    appendChildren(of: nil)
    return visible
  }
}

enum CollectionDropDestination: Equatable, Sendable {
  case inside(UUID?), before(UUID), after(UUID)
}

struct CollectionDragPayload: Codable, Equatable, Sendable {
  var version = 1
  let libraryID: UUID
  let collectionID: UUID
  let parentID: UUID?
  let sortOrder: Int
  let updatedAt: Date

  init(libraryID: UUID, item: CollectionOrderingItem) {
    self.libraryID = libraryID; collectionID = item.id; parentID = item.parentID
    sortOrder = item.sortOrder; updatedAt = item.updatedAt
  }
  func matches(_ item: CollectionOrderingItem) -> Bool {
    collectionID == item.id && parentID == item.parentID && sortOrder == item.sortOrder && updatedAt == item.updatedAt
  }
}

enum CollectionOrdering {
  static func precedes(_ lhs: CollectionOrderingItem, _ rhs: CollectionOrderingItem) -> Bool {
    if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
    // Preserve the pre-drag layout of older libraries, whose stored ranks are all zero.
    if lhs.isSmart != rhs.isSmart { return !lhs.isSmart }
    let comparison = lhs.name.localizedStandardCompare(rhs.name)
    return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
  }

  static func nextOrder(in items: [CollectionOrderingItem], parentID: UUID?) -> Int {
    guard let last = items.filter({ $0.parentID == parentID }).map(\.sortOrder).max() else { return 0 }
    return last == Int.max ? Int.max : last + 1
  }

  /// Produces only changed placements. The subtree and all its memberships keep their IDs.
  static func move(_ id: UUID, to destination: CollectionDropDestination,
    in items: [CollectionOrderingItem]) throws -> [CollectionOrderingItem] {
    guard Set(items.map(\.id)).count == items.count,
      let source = items.first(where: { $0.id == id }) else { throw CollectionMoveError.invalidTarget }
    let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    let parentID: UUID?
    let anchorID: UUID?
    let after: Bool
    switch destination {
    case .inside(let parent): parentID = parent; anchorID = nil; after = false
    case .before(let anchor), .after(let anchor):
      guard let target = lookup[anchor] else { throw CollectionMoveError.invalidTarget }
      if anchor == id { return [] }
      parentID = target.parentID; anchorID = anchor
      if case .after = destination { after = true } else { after = false }
    }
    if source.isSmart && parentID != nil { throw CollectionMoveError.smartHierarchy }
    var parent = parentID, visited: Set<UUID> = [id]
    while let current = parent {
      guard let ancestor = lookup[current], !ancestor.isSmart, visited.insert(current).inserted
      else { throw CollectionMoveError.invalidTarget }
      parent = ancestor.parentID
    }
    let original = items.filter { $0.parentID == parentID }.sorted(by: precedes)
    var destinationItems = original.filter { $0.id != id }
    var insertion = destinationItems.count
    if let anchorID {
      guard let index = destinationItems.firstIndex(where: { $0.id == anchorID }) else { throw CollectionMoveError.invalidTarget }
      insertion = index + (after ? 1 : 0)
    }
    var moved = source; moved.parentID = parentID
    destinationItems.insert(moved, at: insertion)
    if source.parentID == parentID && destinationItems.map(\.id) == original.map(\.id) { return [] }
    var changed: [CollectionOrderingItem] = []
    func appendChanges(_ siblings: [CollectionOrderingItem]) {
      for (rank, var item) in siblings.enumerated() {
        item.sortOrder = rank
        if lookup[item.id] != item { changed.append(item) }
      }
    }
    if source.parentID != parentID {
      appendChanges(items.filter { $0.parentID == source.parentID && $0.id != id }.sorted(by: precedes))
    }
    appendChanges(destinationItems)
    return changed
  }
}

enum CollectionMoveError: LocalizedError {
  case invalidTarget, smartHierarchy, staleDrag
  var errorDescription: String? {
    switch self {
    case .invalidTarget: "无法移动到该位置：文件夹必须存在，且不能移入自己或自己的子文件夹。"
    case .smartHierarchy: "智能文件夹只能在顶层调整顺序。"
    case .staleDrag: "文件夹已发生变化，请重新拖动。"
    }
  }
}
