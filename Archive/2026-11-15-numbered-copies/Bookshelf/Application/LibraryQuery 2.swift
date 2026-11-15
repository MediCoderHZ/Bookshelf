import Foundation

struct LibraryQueryRequest {
  var selection: LibrarySelection = .all
  var tagIDs: Set<UUID> = []
  var text = ""
  var searchScope: LibrarySearchScope = .allFields
  var advanced = AdvancedBookQuery()
  var duplicateGroupID: UUID?
  var includeSubcollections = false
  var noteMatchedBookIDs: Set<UUID> = []
}

enum LibraryQueries {
  /// Count query results, including trashed books only when the current scope
  /// includes them. Duplicate links must not inflate the number of books.
  static func tagBookCounts(in books: [Book]) -> [UUID: Int] {
    var counts: [UUID: Int] = [:]
    for book in books {
      for id in Set(book.tagLinks.compactMap(\.tag?.id)) { counts[id, default: 0] += 1 }
    }
    return counts
  }

  static func visibleTags(_ tags: [Tag], bookCounts: [UUID: Int], selectedIDs: Set<UUID> = [],
    showAll: Bool = false, text: String = "") -> [Tag] {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return tags.filter {
      // Keep an active filter available for deselection even if a search or
      // metadata edit leaves it with no matching books.
      (showAll || bookCounts[$0.id, default: 0] > 0 || selectedIDs.contains($0.id)) &&
        (query.isEmpty || $0.name.localizedStandardContains(query))
    }
  }

  static func results(_ books: [Book], collections: [BookCollection], request: LibraryQueryRequest, notes: [NoteRecord] = []) -> [Book] {
    var smart: AdvancedBookQuery?
    if case .smart(let id) = request.selection {
      guard let query = collections.first(where: { $0.id == id && $0.isSmart })?.smartQuery else { return [] }
      smart = query
    }
    var duplicateIDs: Set<UUID>?
    var collectionScope: Set<UUID>?
    if case .collection(let id) = request.selection {
      collectionScope = request.includeSubcollections
        ? CollectionTree.descendants(of: id, in: collections.filter { !$0.isSmart }.map(ManualCollectionRecord.init)) : [id]
    }
    if request.selection == .duplicates {
      let groups = DuplicateDetector.groups(in: books.filter { $0.deletedAt == nil })
      duplicateIDs = groups.first { $0.id == request.duplicateGroupID }?.bookIDs ?? Set(groups.flatMap(\.bookIDs))
    }
    return books.filter {
      (duplicateIDs == nil || duplicateIDs!.contains($0.id)) &&
      (smart == nil || smart!.matches($0, notes: notes)) &&
      (!request.advanced.hasConditions || request.advanced.matches($0, notes: notes)) &&
      (collectionScope == nil || $0.collectionItems.contains { $0.collection.map { collectionScope!.contains($0.id) } ?? false }) &&
      LibraryFilter.matches($0, selection: collectionScope == nil ? request.selection : .all, tagIDs: request.tagIDs,
        query: request.searchScope.includesNotes && request.noteMatchedBookIDs.contains($0.id) ? "" : request.text,
        searchScope: request.searchScope)
    }
  }
}

enum LibrarySelection: Hashable, Codable {
  case all, recent, favorites, unfiled, trash, duplicates, notes, standaloneNotes, noteTrash
  case collection(UUID)
  case smart(UUID)

  func title(collections: [BookCollection]) -> String {
    switch self {
    case .all: "全部书籍"
    case .recent: "最近添加"
    case .favorites: "我的收藏"
    case .unfiled: "未加入书单"
    case .trash: "回收站"
    case .duplicates: "重复书目"
    case .notes: "全部笔记"
    case .standaloneNotes: "独立笔记"
    case .noteTrash: "笔记回收站"
    case .collection(let id): collections.first { $0.id == id }?.name ?? "书单"
    case .smart(let id): collections.first { $0.id == id }?.name ?? "智能书单"
    }
  }
}

enum LibraryFilter {
  static func matches(_ book: Book, selection: LibrarySelection, tagIDs: Set<UUID>, query: String,
    searchScope: LibrarySearchScope = .allFields)
    -> Bool
  {
    guard (selection == .trash) == (book.deletedAt != nil) else { return false }
    let matchesSection: Bool
    switch selection {
    case .all, .trash, .duplicates, .smart: matchesSection = true
    case .recent:
      matchesSection =
        book.addedAt
        >= (Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast)
    case .favorites: matchesSection = book.isFavorite
    case .unfiled: matchesSection = book.collectionItems.compactMap(\.collection).isEmpty
    case .collection(let id):
      matchesSection = book.collectionItems.contains { $0.collection?.id == id }
    case .notes, .standaloneNotes, .noteTrash: matchesSection = false
    }
    let bookTags = Set(book.tagLinks.compactMap(\.tag?.id))
    return matchesSection && tagIDs.isSubset(of: bookTags) && LibraryTextSearch.matches(book, query: query, scope: searchScope)
  }

}
