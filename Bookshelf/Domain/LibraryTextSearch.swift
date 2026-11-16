import Foundation

enum LibrarySearchScope: String, Codable, CaseIterable, Identifiable {
  case titleCreatorYear, fieldsAndTags, everything
  // Persisted searches keep their original matching semantics. These older
  // single-field ranges are no longer offered in the quick-search menu.
  case allFields, title, author, isbn, tags

  static let quickSearchScopes: [Self] = [.titleCreatorYear, .fieldsAndTags, .everything]
  var id: String { rawValue }
  var title: String {
    switch self {
    case .titleCreatorYear: L10n.tr("标题、作者、年份")
    case .fieldsAndTags: L10n.tr("全部字段与标签")
    case .everything: L10n.tr("所有内容")
    case .allFields: L10n.tr("全部字段")
    case .title: L10n.tr("标题")
    case .author: L10n.tr("作者")
    case .isbn: "ISBN"
    case .tags: L10n.tr("标签")
    }
  }
  var includesNotes: Bool { self != .author && self != .isbn }
  var usesSearchTerms: Bool { Self.quickSearchScopes.contains(self) }
  var help: String {
    switch self {
    case .titleCreatorYear: L10n.tr("搜索标题、副标题、原书名、作者、译者及出版年份，也匹配笔记标题。")
    case .fieldsAndTags: L10n.tr("搜索书籍元信息、标签和笔记标题，不搜索笔记正文。")
    case .everything: L10n.tr("搜索书籍元信息、标签及笔记全文。")
    default: L10n.tr("保留已保存搜索的原有范围。")
    }
  }

  var editingScopes: [Self] {
    Self.quickSearchScopes.contains(self) ? Self.quickSearchScopes : Self.quickSearchScopes + [self]
  }

  static func migratePreference(in preferences: UserDefaults) {
    guard let raw = preferences.string(forKey: "librarySearchScope") else { return }
    let scope = Self(rawValue: raw)
    let replacement: Self
    switch scope {
    case .allFields: replacement = .everything
    case .title, .author: replacement = .titleCreatorYear
    case .isbn, .tags, nil: replacement = .fieldsAndTags
    default: return
    }
    preferences.set(replacement.rawValue, forKey: "librarySearchScope")
  }
}

/// Parentheses group expressions; implicit AND binds more tightly than OR.
/// Quotes and escapes preserve literal syntax characters.
struct LibrarySearchTerms {
  private indirect enum Expression {
    case term(String), all([Self]), any([Self]), not(Self)

    /// Keep positive AND terms on the same book/note. Exclusions apply to the
    /// whole searchable book family, so a child cannot bypass a sibling's veto.
    /// Evaluate the tree directly rather than expanding groups into exponentially
    /// many OR branches.
    func evaluate(count: Int, termMatches: (String, Int) -> Bool) -> [Bool] {
      switch self {
      case .term(let value): return (0..<count).map { termMatches(value, $0) }
      case .not(let child):
        return Array(repeating: !child.evaluate(count: count, termMatches: termMatches).contains(true), count: count)
      case .all(let children):
        var result = Array(repeating: true, count: count)
        for child in children {
          let values = child.evaluate(count: count, termMatches: termMatches)
          for index in result.indices { result[index] = result[index] && values[index] }
          if !result.contains(true) { break }
        }
        return result
      case .any(let children):
        var result = Array(repeating: false, count: count)
        for child in children {
          let values = child.evaluate(count: count, termMatches: termMatches)
          for index in result.indices { result[index] = result[index] || values[index] }
          if result.allSatisfy({ $0 }) { break }
        }
        return result
      }
    }
  }

  private enum Token: Equatable {
    case term(String, excluded: Bool), or, open(Character, excluded: Bool), close(Character)
  }

  private struct Parser {
    var tokens: [Token]
    var index = 0
    var hasIncompleteOR = false
    var groupingMessage: String?
    var cannotMatch = false

    mutating func parse() -> Expression? {
      let result = parseOR(depth: 0)
      if index < tokens.count { invalidGrouping(L10n.tr("存在没有对应左括号的右括号。")) }
      return result
    }

    mutating func parseOR(depth: Int) -> Expression? {
      var alternatives: [Expression] = []
      if let first = parseAND(depth: depth) { alternatives.append(first) }
      while index < tokens.count, tokens[index] == .or {
        index += 1
        if alternatives.isEmpty { hasIncompleteOR = true }
        if let next = parseAND(depth: depth) { alternatives.append(next) }
        else { hasIncompleteOR = true }
      }
      return alternatives.isEmpty ? nil : alternatives.count == 1 ? alternatives[0] : .any(alternatives)
    }

    mutating func parseAND(depth: Int) -> Expression? {
      var required: [Expression] = []
      while index < tokens.count {
        switch tokens[index] {
        case .or, .close: return combined(required)
        case .term(let value, let excluded):
          index += 1
          required.append(excluded ? .not(.term(value)) : .term(value))
        case .open(let closing, let excluded):
          index += 1
          guard depth < 64 else {
            invalidGrouping(L10n.tr("括号嵌套过深，请简化搜索条件。"))
            index = tokens.count
            return nil
          }
          let child = parseOR(depth: depth + 1)
          if index < tokens.count, case .close(let actual) = tokens[index] {
            index += 1
            if actual != closing { invalidGrouping(L10n.tr("请使用成对的括号。")) }
          } else if groupingMessage == nil { groupingMessage = L10n.tr("请补全搜索条件中的右括号。") }
          if let child { required.append(excluded ? .not(child) : child) }
          else { invalidGrouping(L10n.tr("括号内请填写搜索条件。")) }
        }
      }
      return combined(required)
    }

    private func combined(_ required: [Expression]) -> Expression? {
      required.isEmpty ? nil : required.count == 1 ? required[0] : .all(required)
    }

    private mutating func invalidGrouping(_ message: String) {
      if groupingMessage == nil { groupingMessage = message }
      cannotMatch = true
    }
  }

  private let expression: Expression?
  private let cannotMatch: Bool
  let hasIncompleteOR: Bool
  let groupingMessage: String?
  let values: [String]
  let excludedValues: [String]
  var isEmpty: Bool { expression == nil }
  var validationMessage: String? {
    if let groupingMessage { return groupingMessage }
    if hasIncompleteOR { return L10n.tr("请在 OR 两侧填写搜索条件。") }
    return isEmpty ? L10n.tr("请填写搜索关键词。") : nil
  }

  init(_ query: String, preserveISBN: Bool = false) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let characters = Array(trimmed)
    var tokens: [Token] = [], current = "", closingQuote: Character?
    var isExcluded = false, isQuoted = false, startsAtBoundary = true
    func finishTerm(atBoundary: Bool = true) {
      let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
      if value == "OR", !isExcluded, !isQuoted, startsAtBoundary, atBoundary {
        tokens.append(.or)
      } else if !value.isEmpty { tokens.append(.term(value, excluded: isExcluded)) }
      current = ""; isExcluded = false; isQuoted = false
    }
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if current.isEmpty, closingQuote == nil {
        startsAtBoundary = index == 0 || characters[index - 1].isWhitespace || "()（）".contains(characters[index - 1])
      }
      if character == "\\", index + 1 < characters.count,
        "\\\"“”＂-－()（）".contains(characters[index + 1]) {
        current.append(characters[index + 1]); index += 2
        continue
      }
      if let quote = closingQuote {
        if character == quote { finishTerm(atBoundary: false); closingQuote = nil }
        else { current.append(character) }
      } else if "\"“”＂".contains(character) {
        if !current.isEmpty { finishTerm(atBoundary: false) }
        closingQuote = character == "“" ? "”" : character
        isQuoted = true
      } else if "(（".contains(character) {
        // A pending minus belongs to this group, as in -(教材 OR 习题).
        if !current.isEmpty { finishTerm() }
        tokens.append(.open(character == "(" ? ")" : "）", excluded: isExcluded))
        current = ""; isExcluded = false; isQuoted = false
      } else if ")）".contains(character) {
        finishTerm()
        tokens.append(.close(character))
      } else if "-－".contains(character), current.isEmpty, !isExcluded {
        isExcluded = true
      } else if character.isWhitespace { finishTerm() }
      else { current.append(character) }
      index += 1
    }
    finishTerm()
    if preserveISBN, tokens.allSatisfy({ if case .term(_, false) = $0 { return true }; return false }),
      let number = Self.isbnNumber(trimmed), ISBN.identity(number) != nil {
      // Keep the existing whole-ISBN shortcut, without swallowing exclusions.
      tokens = [.term(trimmed, excluded: false)]
    }
    values = tokens.compactMap { if case .term(let value, false) = $0 { return value }; return nil }
    excludedValues = tokens.compactMap { if case .term(let value, true) = $0 { return value }; return nil }
    var parser = Parser(tokens: tokens)
    expression = parser.parse()
    hasIncompleteOR = parser.hasIncompleteOR
    groupingMessage = parser.groupingMessage
    cannotMatch = parser.cannotMatch
  }

  /// Only numeric ISBN input is normalized; digits inside ordinary search
  /// terms must never cause the surrounding text to be silently discarded.
  static func isbnNumber(_ value: String) -> String? {
    let number = value.folding(options: .widthInsensitive, locale: .current).uppercased()
      .filter { !$0.isWhitespace && !"-‐‑‒–—−".contains($0) }
    guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "X") }) else { return nil }
    return number
  }

  func matches(fields: [String], additionalMatch: (String) -> Bool = { _ in false }) -> Bool {
    matches(candidateCount: 1) { term, _ in
      fields.contains { $0.localizedStandardContains(term) } || additionalMatch(term)
    }
  }

  func matches(candidateCount: Int, termMatches: (String, Int) -> Bool) -> Bool {
    guard !cannotMatch else { return false }
    // Empty or unfinished operators must never introduce a match-all branch.
    guard let expression else { return !hasIncompleteOR && groupingMessage == nil }
    return expression.evaluate(count: candidateCount, termMatches: termMatches).contains(true)
  }
}

/// Shared by live library filtering and persisted smart-collection searches.
enum LibraryTextSearch {
  static func matches(_ book: Book, query: String, scope: LibrarySearchScope) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    switch scope {
    case .titleCreatorYear:
      return LibrarySearchTerms(trimmed).matches(fields: titleCreatorYearFields(book))
    case .fieldsAndTags, .everything:
      return LibrarySearchTerms(trimmed, preserveISBN: true).matches(fields: bookFields(book, scope: scope)) {
        matchesISBN(book, query: $0)
      }
    case .allFields:
      return book.searchableText.localizedStandardContains(trimmed) || matchesISBN(book, query: trimmed)
    case .title:
      return [book.title, book.subtitle].compactMap { $0 }.contains { $0.localizedStandardContains(trimmed) }
    case .author:
      return book.authors.contains { $0.name.localizedStandardContains(trimmed) }
    case .isbn:
      return matchesISBN(book, query: trimmed)
    case .tags:
      return book.tagLinks.compactMap(\.tag?.name).contains { $0.localizedStandardContains(trimmed) }
    }
  }

  /// Evaluate the grouped query against the book and each searchable child.
  /// Positive terms stay within one item; exclusions inspect the whole family.
  static func matches(_ book: Book, terms: LibrarySearchTerms, scope: LibrarySearchScope,
    notes: [NoteRecord]) -> Bool {
    if terms.isEmpty { return terms.matches(fields: []) }
    let fields = bookFields(book, scope: scope)
    let childFields = notes.filter {
      $0.parentBookID == book.id && ($0.deletedAt == nil || book.deletedAt != nil)
    }.map { noteFields($0, scope: scope) }
    let candidates = [fields] + childFields
    return terms.matches(candidateCount: candidates.count) { term, index in
      candidates[index].contains { $0.localizedStandardContains(term) } ||
        (index == 0 && scope != .titleCreatorYear && matchesISBN(book, query: term))
    }
  }

  private static func bookFields(_ book: Book, scope: LibrarySearchScope) -> [String] {
    if scope == .titleCreatorYear { return titleCreatorYearFields(book) }
    return metadataFields(book) + (scope == .everything ? [book.notes].compactMap { $0 } : [])
  }

  private static func noteFields(_ note: NoteRecord, scope: LibrarySearchScope) -> [String] {
    switch scope {
    case .titleCreatorYear: return [note.displayTitle]
    case .fieldsAndTags: return [note.displayTitle] + note.tags
    case .everything: return [note.displayTitle, note.body] + note.tags
    default: return []
    }
  }

  private static func titleCreatorYearFields(_ book: Book) -> [String] {
    [book.title, book.subtitle, book.originalTitle,
      BookSearchRule.publicationYear(book.publicationDate).map { String($0) }].compactMap { $0 }
      + book.contributions.compactMap(\.person?.name)
  }

  private static func metadataFields(_ book: Book) -> [String] {
    titleCreatorYearFields(book) + [book.bookType?.title, book.isbn10, book.isbn13,
      book.publisher, book.publicationDate, book.edition, book.pageCount.map { String($0) },
      book.languageCode, book.originalLanguageCode, book.bookDescription].compactMap { $0 }
      + book.seriesMemberships.compactMap(\.series?.name) + book.tagLinks.compactMap(\.tag?.name)
  }

  private static func matchesISBN(_ book: Book, query: String) -> Bool {
    // Accept partial numbers while typing, separators, and equivalent ISBN-10/13.
    // Do not turn arbitrary words containing digits into an ISBN query.
    guard let number = LibrarySearchTerms.isbnNumber(query) else { return false }
    let values = [book.isbn10, book.isbn13].compactMap { $0 }
    if let identity = ISBN.identity(number), values.contains(where: { ISBN.identity($0) == identity }) { return true }
    return values.contains { ISBN.normalized($0)?.contains(number) == true }
  }

  static func matches(_ note: NoteRecord, query: String, scope: LibrarySearchScope) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    switch scope {
    case .everything, .titleCreatorYear, .fieldsAndTags:
      return LibrarySearchTerms(trimmed).matches(fields: noteFields(note, scope: scope))
    case .allFields: return note.searchableText.localizedStandardContains(trimmed)
    case .title: return note.displayTitle.localizedStandardContains(trimmed)
    case .tags: return note.tags.contains { $0.localizedStandardContains(trimmed) }
    case .author, .isbn: return false
    }
  }
}

struct SavedLibrarySearch: Codable, Equatable {
  var scope: LibrarySearchScope
  var text: String
  var validationMessage: String? {
    if scope.usesSearchTerms {
      return LibrarySearchTerms(text).validationMessage
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.tr("请填写搜索关键词。") : nil
  }
  var summary: String { scope.title + "：" + text.trimmingCharacters(in: .whitespacesAndNewlines) }
  var suggestedName: String { scope.title + "：" + String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) }

  func matches(_ book: Book, notes: [NoteRecord]) -> Bool {
    guard validationMessage == nil else { return false }
    if scope.usesSearchTerms {
      return LibraryTextSearch.matches(book, terms: LibrarySearchTerms(text, preserveISBN: scope != .titleCreatorYear),
        scope: scope, notes: notes)
    }
    return LibraryTextSearch.matches(book, query: text, scope: scope) || (scope.includesNotes && notes.contains {
      $0.parentBookID == book.id && $0.deletedAt == nil && LibraryTextSearch.matches($0, query: text, scope: scope)
    })
  }
  func matches(_ note: NoteRecord) -> Bool {
    validationMessage == nil && LibraryTextSearch.matches(note, query: text, scope: scope)
  }
}
