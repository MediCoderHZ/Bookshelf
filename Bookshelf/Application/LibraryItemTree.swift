import Foundation

enum LibraryItemID: Hashable {
  case book(UUID), note(UUID)
  var bookID: UUID? { if case .book(let id) = self { id } else { nil } }
  var noteID: UUID? { if case .note(let id) = self { id } else { nil } }
}

/// A presentation projection. Notes retain their own identity and never become books.
struct LibraryItemRow: Identifiable {
  let id: LibraryItemID
  let book: Book?
  let note: NoteRecord?
  var children: [LibraryItemRow] = []
  var title: String { book?.title ?? note?.displayTitle ?? "" }
}

enum LibraryItemTree {
  /// In trash, notes are already scoped by NoteQueries, including notes whose
  /// parent is trashed. Individually deleted notes can have an active parent.
  static func rows(books: [Book], notes: [NoteRecord], inTrash: Bool = false) -> [LibraryItemRow] {
    let grouped = Dictionary(grouping: notes.filter { $0.parentBookID != nil && (inTrash || $0.deletedAt == nil) }, by: { $0.parentBookID! })
    let bookRows = books.map { book in
      let children = (grouped[book.id] ?? []).sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }.map { LibraryItemRow(id: .note($0.id), book: nil, note: $0) }
      return LibraryItemRow(id: .book(book.id), book: book, note: nil, children: children)
    }
    let parentIDs = Set(books.map(\.id))
    let separateNotes = notes.filter {
      if inTrash { return $0.parentBookID.map { !parentIDs.contains($0) } ?? true }
      return $0.parentBookID == nil && $0.deletedAt == nil
    }
      .sorted {
        let left = $0.deletedAt ?? $0.updatedAt, right = $1.deletedAt ?? $1.updatedAt
        return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
      }
      .map { LibraryItemRow(id: .note($0.id), book: nil, note: $0) }
    return bookRows + separateNotes
  }

  /// Keep book and note batches separate. The newly selected item kind wins
  /// when a command/shift selection crosses between books and notes.
  static func selection(_ proposed: Set<LibraryItemID>, previous: Set<LibraryItemID>) -> (books: Set<UUID>, notes: Set<UUID>) {
    let notes = Set(proposed.compactMap(\.noteID)), books = Set(proposed.compactMap(\.bookID))
    if proposed.subtracting(previous).contains(where: { $0.noteID != nil }) { return ([], notes) }
    if !books.isEmpty { return (books, []) }
    return ([], notes)
  }

}

/// Sort books and standalone notes together; child rows always follow their parent.
struct LibraryItemSort: SortComparator {
  var bookComparator: KeyPathComparator<Book>
  var order: SortOrder {
    get { bookComparator.order }
    set { bookComparator.order = newValue }
  }
  func compare(_ lhs: LibraryItemRow, _ rhs: LibraryItemRow) -> ComparisonResult {
    if let left = lhs.book, let right = rhs.book { return bookComparator.compare(left, right) }
    guard let column = LibraryTableColumn.allCases.first(where: { $0.comparator.keyPath == bookComparator.keyPath })
    else { return .orderedSame }
    let result: ComparisonResult
    switch column {
    case .addedAt:
      result = (lhs.book?.addedAt ?? lhs.note?.createdAt ?? .distantPast)
        .compare(rhs.book?.addedAt ?? rhs.note?.createdAt ?? .distantPast)
    case .updatedAt:
      result = (lhs.book?.updatedAt ?? lhs.note?.updatedAt ?? .distantPast)
        .compare(rhs.book?.updatedAt ?? rhs.note?.updatedAt ?? .distantPast)
    case .pageCount, .publicationYear:
      let left = column == .pageCount ? lhs.book?.pageCountSortValue : lhs.book?.publicationYearSortValue
      let right = column == .pageCount ? rhs.book?.pageCountSortValue : rhs.book?.publicationYearSortValue
      result = (left ?? -1) == (right ?? -1) ? .orderedSame : ((left ?? -1) < (right ?? -1) ? .orderedAscending : .orderedDescending)
    default:
      result = column.text(for: lhs).localizedStandardCompare(column.text(for: rhs))
    }
    guard order == .reverse else { return result }
    switch result {
    case .orderedAscending: return .orderedDescending
    case .orderedDescending: return .orderedAscending
    case .orderedSame: return .orderedSame
    }
  }
}
