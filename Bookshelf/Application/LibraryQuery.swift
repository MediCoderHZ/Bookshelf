import Foundation

struct LibraryQueryRequest {
  var selection: LibrarySelection = .all
  var tagIDs: Set<UUID> = []
  var text = ""
  var searchScope: LibrarySearchScope = .allFields
  var advanced = AdvancedBookQuery()
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
      duplicateIDs = Set(groups.flatMap(\.bookIDs))
    }
    let usesTerms = request.searchScope.usesSearchTerms
    let terms = LibrarySearchTerms(request.text, preserveISBN: request.searchScope != .titleCreatorYear)
    let notesByParent = usesTerms && !terms.isEmpty
      ? Dictionary(grouping: notes.filter { $0.parentBookID != nil }, by: { $0.parentBookID! }) : [:]
    return books.filter {
      (duplicateIDs == nil || duplicateIDs!.contains($0.id)) &&
      (!usesTerms || LibraryTextSearch.matches($0, terms: terms, scope: request.searchScope,
        notes: notesByParent[$0.id] ?? [])) &&
      (smart == nil || smart!.matches($0, notes: notes)) &&
      (!request.advanced.hasConditions || request.advanced.matches($0, notes: notes)) &&
      (collectionScope == nil || $0.collectionItems.contains { $0.collection.map { collectionScope!.contains($0.id) } ?? false }) &&
      LibraryFilter.matches($0, selection: collectionScope == nil ? request.selection : .all, tagIDs: request.tagIDs,
        query: usesTerms || (request.searchScope.includesNotes && request.noteMatchedBookIDs.contains($0.id)) ? "" : request.text,
        searchScope: request.searchScope)
    }
  }
}

enum LibrarySelection: Hashable, Codable {
  case all, recent, unfiled, trash, duplicates, notes, standaloneNotes, noteTrash
  case collection(UUID)
  case smart(UUID)

  func title(collections: [BookCollection]) -> String {
    switch self {
    case .all: L10n.tr("全部书籍")
    case .recent: L10n.tr("最近添加")
    case .unfiled: L10n.tr("未加入文件夹")
    case .trash: L10n.tr("回收站")
    case .duplicates: L10n.tr("重复书目")
    case .notes: L10n.tr("全部笔记")
    case .standaloneNotes: L10n.tr("独立笔记")
    case .noteTrash: L10n.tr("笔记回收站")
    case .collection(let id): collections.first { $0.id == id }?.name ?? L10n.tr("文件夹")
    case .smart(let id): collections.first { $0.id == id }?.name ?? L10n.tr("智能文件夹")
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
    case .unfiled: matchesSection = book.collectionItems.compactMap(\.collection).isEmpty
    case .collection(let id):
      matchesSection = book.collectionItems.contains { $0.collection?.id == id }
    case .notes, .standaloneNotes, .noteTrash: matchesSection = false
    }
    let bookTags = Set(book.tagLinks.compactMap(\.tag?.id))
    return matchesSection && tagIDs.isSubset(of: bookTags) && LibraryTextSearch.matches(book, query: query, scope: searchScope)
  }

}
