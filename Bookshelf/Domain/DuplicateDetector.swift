import Foundation

struct DuplicateMatch {
  let book: Book
  let reason: String
}

enum DuplicateReason: Int, Hashable {
  case isbn, titleAndAuthor, titleOnly
  var title: String {
    switch self {
    case .isbn: "ISBN 相同（含 ISBN-10/13 对应号码）"
    case .titleAndAuthor: "书名相同且作者有交集，部分记录缺少有效 ISBN"
    case .titleOnly: "仅书名相同，作者与版本需要核对"
    }
  }
}

struct DuplicateGroup: Identifiable {
  let books: [Book]
  let reasons: [DuplicateReason]
  var id: UUID { books[0].id }
  var bookIDs: Set<UUID> { Set(books.map(\.id)) }
  var title: String { books[0].title }
  var requiresVersionReview: Bool {
    Set(books.compactMap { ISBN.identity($0.isbn13) ?? ISBN.identity($0.isbn10) }).count > 1
  }
  var explanation: String { reasons.map(\.title).joined(separator: "；") }
}

/// Resolve the group touched by a native table selection without depending on
/// Set iteration order or combining unrelated groups for a merge.
enum DuplicateSelection {
  static func group(for proposed: Set<UUID>, previous: Set<UUID>, in groups: [DuplicateGroup]) -> DuplicateGroup? {
    guard !proposed.isEmpty else { return nil }
    let added = proposed.subtracting(previous)
    let touched = added.isEmpty ? proposed : added
    let matches = groups.filter { !$0.bookIDs.isDisjoint(with: touched) }
    guard matches.count == 1, let group = matches.first,
      touched.isSubset(of: group.bookIDs) else { return nil }
    return group
  }
}

enum DuplicateDetector {
  static func firstMatch(
    title: String,
    isbn: String?,
    authorNames: [String],
    excluding excludedBookID: UUID?,
    in books: [Book]
  ) -> DuplicateMatch? {
    let normalizedISBN = ISBN.identity(isbn)
    let normalizedTitle = MetadataNormalizer.normalizedTitle(title)
    let normalizedAuthors = Set(authorNames.map(MetadataNormalizer.normalizedName))

    for book in books where book.id != excludedBookID && book.deletedAt == nil {
      let candidateISBN = ISBN.identity(book.isbn13) ?? ISBN.identity(book.isbn10)
      if let normalizedISBN, let candidateISBN, normalizedISBN != candidateISBN { continue }
      if let normalizedISBN,
        normalizedISBN == candidateISBN
      {
        return DuplicateMatch(book: book, reason: "ISBN 与《\(book.title)》相同")
      }

      guard !normalizedTitle.isEmpty,
        normalizedTitle == MetadataNormalizer.normalizedTitle(book.title)
      else { continue }

      let candidateAuthors = Set(book.authors.map { MetadataNormalizer.normalizedName($0.name) })
      if normalizedAuthors.isEmpty && candidateAuthors.isEmpty {
        return DuplicateMatch(book: book, reason: "书名与《\(book.title)》相同")
      }

      if !normalizedAuthors.isDisjoint(with: candidateAuthors) {
        return DuplicateMatch(book: book, reason: "书名和作者与《\(book.title)》相同")
      }
    }

    return nil
  }

  static func duplicateIDs(in books: [Book]) -> Set<UUID> {
    Set(groups(in: books).flatMap { $0.books.map(\.id) })
  }

  /// Index once instead of comparing every book against the entire library.
  /// A missing ISBN can connect multiple editions; such groups are review-only.
  static func groups(in books: [Book]) -> [DuplicateGroup] {
    let active = books.filter { $0.deletedAt == nil }
    let isbns = active.map { ISBN.identity($0.isbn13) ?? ISBN.identity($0.isbn10) }
    var isbnIndex: [String: [Int]] = [:]
    var titleIndex: [TitleAuthorKey: [Int]] = [:]
    for (index, book) in active.enumerated() {
      if let isbn = isbns[index] { isbnIndex[isbn, default: []].append(index) }
      let title = MetadataNormalizer.normalizedTitle(book.title)
      guard !title.isEmpty else { continue }
      let authors = Set(book.authors.map { MetadataNormalizer.normalizedName($0.name) }.filter { !$0.isEmpty })
      if authors.isEmpty { titleIndex[TitleAuthorKey(title: title, author: nil), default: []].append(index) }
      for author in authors { titleIndex[TitleAuthorKey(title: title, author: author), default: []].append(index) }
    }
    var links = DuplicateLinks(count: active.count)
    var evidence: [Int: Set<DuplicateReason>] = [:]
    func connect(_ indices: [Int], reason: DuplicateReason) {
      guard indices.count > 1, let first = indices.first else { return }
      for index in indices {
        links.join(first, index)
        evidence[index, default: []].insert(reason)
      }
    }
    for indices in isbnIndex.values { connect(indices, reason: .isbn) }
    for (key, indices) in titleIndex where indices.contains(where: { isbns[$0] == nil }) {
      connect(indices, reason: key.author == nil ? .titleOnly : .titleAndAuthor)
    }
    var members: [Int: [Int]] = [:]
    for index in active.indices { members[links.root(index), default: []].append(index) }
    return members.values.filter { $0.count > 1 }.map { indices in
      DuplicateGroup(books: indices.map { active[$0] }.sorted { $0.id.uuidString < $1.id.uuidString },
        reasons: Set(indices.flatMap { evidence[$0] ?? [] }).sorted { $0.rawValue < $1.rawValue })
    }.sorted {
      let order = $0.title.localizedStandardCompare($1.title)
      return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
    }
  }
}

private struct TitleAuthorKey: Hashable { let title: String; let author: String? }
private struct DuplicateLinks {
  var parents: [Int]
  var sizes: [Int]
  init(count: Int) { parents = Array(0..<count); sizes = Array(repeating: 1, count: count) }
  mutating func root(_ index: Int) -> Int {
    var current = index
    while parents[current] != current {
      parents[current] = parents[parents[current]]
      current = parents[current]
    }
    return current
  }
  mutating func join(_ a: Int, _ b: Int) {
    var x = root(a), y = root(b)
    guard x != y else { return }
    if sizes[x] < sizes[y] { swap(&x, &y) }
    parents[y] = x; sizes[x] += sizes[y]
  }
}
