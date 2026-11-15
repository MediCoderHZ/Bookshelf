import Foundation

struct PublisherUsage {
  let name: String
  let bookID: UUID

  init(name: String, bookID: UUID) {
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.bookID = bookID
  }

  @MainActor init?(_ book: Book) {
    guard book.deletedAt == nil, let name = book.publisher,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    self.init(name: name, bookID: book.id)
  }
}

enum PublisherSuggestions {
  static func matches(_ text: String, usages: [PublisherUsage], limit: Int = 50) -> [NameSuggestion] {
    let query = MetadataNormalizer.normalizedName(text)
    guard !query.isEmpty, limit > 0 else { return [] }
    let exact = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let grouped = Dictionary(grouping: usages, by: \.name)
    return grouped.keys.compactMap { name -> (name: String, rank: Int, count: Int)? in
      let key = MetadataNormalizer.normalizedName(name)
      guard !key.isEmpty, key.contains(query), name.rangeOfCharacter(from: .newlines) == nil else { return nil }
      let rank = name == exact ? 0 : key == query ? 1 : key.hasPrefix(query) ? 2 : 3
      return (name, rank, Set((grouped[name] ?? []).map(\.bookID)).count)
    }.sorted {
      if $0.rank != $1.rank { return $0.rank < $1.rank }
      if $0.count != $1.count { return $0.count > $1.count }
      let comparison = $0.name.localizedStandardCompare($1.name)
      return comparison == .orderedSame ? $0.name < $1.name : comparison == .orderedAscending
    }.prefix(limit).map { NameSuggestion(name: $0.name) }
  }
}
