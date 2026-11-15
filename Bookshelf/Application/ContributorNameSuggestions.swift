import Foundation

struct ContributorNameUsage {
  let name: String
  let roleRaw: String
  let bookID: UUID

  init(name: String, roleRaw: String, bookID: UUID) {
    self.name = name; self.roleRaw = roleRaw; self.bookID = bookID
  }

  /// People can outlive their last contribution. Only names used by active books qualify.
  @MainActor init?(_ contribution: Contribution) {
    guard let book = contribution.book, book.deletedAt == nil,
      let person = contribution.person, !person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    self.init(name: person.name, roleRaw: contribution.roleRaw, bookID: book.id)
  }
}

enum ContributorNameSuggestions {
  static func matches(_ text: String, usages: [ContributorNameUsage], field: BookField, limit: Int = 50) -> [NameSuggestion] {
    let query = MetadataNormalizer.normalizedName(text)
    guard !query.isEmpty, limit > 0 else { return [] }
    let exact = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let role = field == .translators ? "translator" : "author"
    // Keep distinct spellings available; selecting a name must never rename a shared person.
    let grouped = Dictionary(grouping: usages, by: \.name)
    return grouped.keys.compactMap { name -> (name: String, rank: Int, role: Int, count: Int)? in
      let key = MetadataNormalizer.normalizedName(name)
      guard !key.isEmpty, key.contains(query), name.rangeOfCharacter(from: .newlines) == nil else { return nil }
      let rank = name == exact ? 0 : key == query ? 1 : key.hasPrefix(query) ? 2 : 3
      let uses = grouped[name] ?? []
      return (name, rank, uses.contains { $0.roleRaw == role } ? 0 : 1, Set(uses.map(\.bookID)).count)
    }.sorted {
      if $0.rank != $1.rank { return $0.rank < $1.rank }
      if $0.role != $1.role { return $0.role < $1.role }
      if $0.count != $1.count { return $0.count > $1.count }
      let comparison = $0.name.localizedStandardCompare($1.name)
      return comparison == .orderedSame ? $0.name < $1.name : comparison == .orderedAscending
    }.prefix(limit).map { NameSuggestion(name: $0.name) }
  }
}
