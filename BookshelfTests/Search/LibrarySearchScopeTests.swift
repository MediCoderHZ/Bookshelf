import AppKit
import Foundation
import XCTest
@testable import Bookshelf

@MainActor
final class LibrarySearchScopeTests: XCTestCase {
  private func matches(_ book: Book, _ text: String, _ scope: LibrarySearchScope) -> Bool {
    LibraryFilter.matches(book, selection: .all, tagIDs: [], query: text, searchScope: scope)
  }

  private func contribute(_ name: String, role: ContributorRole, to book: Book) {
    book.contributions.append(Contribution(book: book, person: Person(name: name), role: role, displayOrder: book.contributions.count))
  }

  func testParenthesesApplySharedConditionsToAllAlternatives() {
    let economics = Book(title: "经济随笔"), finance = Book(title: "金融随笔")
    let textbook = Book(title: "经济教材"), financeTextbook = Book(title: "金融教材"), history = Book(title: "历史读物")
    contribute("王兴", role: .author, to: economics)
    contribute("李明", role: .author, to: finance)
    let books = [economics, finance, textbook, financeTextbook, history]
    let cases: [(String, [UUID])] = [
      ("(经济 OR 金融) -教材", [economics.id, finance.id]),
      ("经济 OR 金融 -教材", [economics.id, finance.id, textbook.id]),
      ("(经济 OR 金融) (王兴 OR 李明)", [economics.id, finance.id]),
      ("(经济 OR (金融 李明)) -教材", [economics.id, finance.id]),
      ("((经济 OR 金融) -教材) OR 历史", [economics.id, finance.id, history.id]),
      ("（经济 OR（金融 李明））－教材", [economics.id, finance.id]),
      ("(经济)OR(金融)", [economics.id, finance.id, textbook.id, financeTextbook.id])
    ]
    for scope in LibrarySearchScope.quickSearchScopes {
      for (text, expected) in cases {
        XCTAssertEqual(books.filter { matches($0, text, scope) }.map(\.id), expected, text)
        XCTAssertNil(LibrarySearchTerms(text).validationMessage, text)
      }
    }
  }

  func testGroupsCombinePhrasesISBNAndGroupExclusions() {
    let book = Book(title: "经济 入门 Study Guide"); book.isbn13 = "9780306406157"
    XCTAssertTrue(matches(book, #"("经济 入门" OR "金融 史") -教材"#, .titleCreatorYear))
    XCTAssertFalse(matches(book, #"("经济 入门" OR 金融) -"Study Guide""#, .titleCreatorYear))
    XCTAssertFalse(matches(book, #"("经济 入门" OR 金融) -(教材 OR "Study Guide")"#, .titleCreatorYear))
    XCTAssertTrue(matches(book, "经济 -(教材 OR 习题)", .titleCreatorYear))
    XCTAssertTrue(matches(book, "经济 -(Study Missing)", .titleCreatorYear))
    XCTAssertFalse(matches(book, "经济 -(Study Guide)", .titleCreatorYear))
    XCTAssertTrue(matches(book, "-(-经济)", .titleCreatorYear))
    for scope in [LibrarySearchScope.fieldsAndTags, .everything] {
      XCTAssertTrue(matches(book, #"("0 306 40615 2" OR 金融) -教材"#, scope))
      XCTAssertFalse(matches(book, "(经济 OR 金融) -(0-306-40615-2 OR 教材)", scope))
    }
    var note = NoteRecord(title: "金融随笔"); note.body = "经济教材"; note.tags = ["参考"]
    XCTAssertFalse(NoteQueries.matches(note, text: "(经济 OR 金融) -教材", searchScope: .everything))
    XCTAssertTrue(NoteQueries.matches(note, text: "(经济 OR 金融) -教材", searchScope: .fieldsAndTags))
    XCTAssertFalse(NoteQueries.matches(note, text: "(经济 OR 金融) -(参考 OR 教材)", searchScope: .fieldsAndTags))
  }

  func testQuotedAndEscapedParenthesesRemainLiteral() {
    let book = Book(title: "经济(入门)"), without = Book(title: "经济入门")
    for text in [#""经济(入门)""#, #"经济\(入门\)"#, #""(""#, #"\("#] {
      XCTAssertTrue(matches(book, text, .titleCreatorYear), text)
      XCTAssertFalse(matches(without, text, .titleCreatorYear), text)
      XCTAssertNil(LibrarySearchTerms(text).validationMessage)
    }
    XCTAssertTrue(matches(Book(title: "经济（入门）"), #"“经济（入门）”"#, .titleCreatorYear))
    XCTAssertTrue(matches(Book(title: "(经济 OR 金融)"), #""(经济 OR 金融)""#, .titleCreatorYear))
    XCTAssertFalse(matches(book, #""(经济 OR 金融)""#, .titleCreatorYear))
    XCTAssertFalse(matches(book, #"经济 -"(入门)""#, .titleCreatorYear))
  }

  func testIncompleteAndInvalidGroupsNeverBecomeUnfilteredSearches() {
    for text in ["(", "()", "( )", "-()", "-(())", "经济 OR ()", ")", "经济)", "(经济）", "（经济)"] {
      XCTAssertNotNil(LibrarySearchTerms(text).groupingMessage, text)
      XCTAssertFalse(matches(Book(title: "经济随笔"), text, .titleCreatorYear), text)
      XCTAssertFalse(matches(Book(title: "其他"), text, .titleCreatorYear), text)
    }
    for text in ["(经济 OR 金融", "((经济 OR 金融) -教材"] {
      XCTAssertEqual(LibrarySearchTerms(text).groupingMessage, "请补全搜索条件中的右括号。")
      XCTAssertTrue(matches(Book(title: "经济随笔"), text, .titleCreatorYear))
      XCTAssertFalse(matches(Book(title: "历史"), text, .titleCreatorYear))
    }
    for text in ["(经济 OR)", "(OR 金融)", "(经济 OR OR 金融)"] {
      XCTAssertTrue(LibrarySearchTerms(text).hasIncompleteOR)
      XCTAssertFalse(matches(Book(title: "其他"), text, .titleCreatorYear))
    }
  }

  func testGroupedQueriesAvoidCombinatorialExpansionAndLimitNesting() {
    // Expanding this into OR branches would allocate 2^24 combinations.
    let product = Array(repeating: "(经济 OR 金融)", count: 24).joined(separator: " ") + " -教材"
    XCTAssertTrue(matches(Book(title: "经济随笔"), product, .titleCreatorYear))
    XCTAssertFalse(matches(Book(title: "金融教材"), product, .titleCreatorYear))
    let nested = String(repeating: "(", count: 64) + "经济" + String(repeating: ")", count: 64)
    XCTAssertTrue(matches(Book(title: "经济随笔"), nested, .titleCreatorYear))
    XCTAssertNil(LibrarySearchTerms(nested).validationMessage)
    XCTAssertNotNil(LibrarySearchTerms("(" + nested + ")").validationMessage)
    XCTAssertFalse(matches(Book(title: "经济随笔"), "(" + nested + ")", .titleCreatorYear))
  }

  func testORAlternativesBindLessTightlyThanSpacesAndExclusions() {
    let economics = Book(title: "经济教材"), finance = Book(title: "金融随笔"), textbook = Book(title: "金融教材")
    let history = Book(title: "历史读物")
    contribute("王兴", role: .author, to: economics)
    contribute("李明", role: .author, to: finance)
    let books = [economics, finance, textbook, history]
    let cases: [(String, [UUID])] = [
      ("经济 OR 金融", [economics.id, finance.id, textbook.id]),
      ("经济 王兴 OR 金融 李明", [economics.id, finance.id]),
      ("经济 OR 金融 -教材", [economics.id, finance.id]),
      ("经济 -教材 OR 金融 -教材", [finance.id]),
      ("经济 -教材 OR 历史", [history.id]),
      ("-教材 OR -随笔", [economics.id, finance.id, textbook.id, history.id]),
      ("经济\nOR　金融 OR 历史", books.map(\.id))
    ]
    for scope in LibrarySearchScope.quickSearchScopes {
      for (text, expected) in cases {
        XCTAssertEqual(books.filter { matches($0, text, scope) }.map(\.id), expected, "\(scope): \(text)")
      }
    }
  }

  func testORCombinesQuotedPhrasesAndPreservesLiteralOR() {
    let book = Book(title: "经济入门 A Study Guide")
    for text in [#""经济入门" OR 金融"#, "“经济入门” OR ＂金融 随笔＂",
      #"金融 OR "经济入门" -"Advanced Guide""#, #"金融 OR "经济入门"#] {
      XCTAssertTrue(matches(book, text, .titleCreatorYear), text)
    }
    XCTAssertFalse(matches(book, #"金融 OR "经济 入门""#, .titleCreatorYear))
    XCTAssertFalse(matches(book, #"金融 OR "经济入门" -"Study Guide""#, .titleCreatorYear))
    XCTAssertTrue(matches(Book(title: "OR 操作符"), #""OR""#, .titleCreatorYear))
    XCTAssertFalse(matches(Book(title: "普通书籍"), #""OR""#, .titleCreatorYear))
    XCTAssertFalse(matches(Book(title: "OR 操作符"), "-OR", .titleCreatorYear))
    for text in ["经济 or 金融", "经济 Or 金融", "经济OR金融", #"经济 OR"金融""#, #""经济"OR 金融"#] {
      XCTAssertFalse(LibrarySearchTerms(text).hasIncompleteOR, text)
      XCTAssertFalse(matches(Book(title: "经济"), text, .titleCreatorYear), text)
    }
    XCTAssertTrue(matches(Book(title: "War or Peace"), "War or Peace", .titleCreatorYear))
    XCTAssertTrue(matches(Book(title: "经济 OR 金融"), #""经济 OR 金融""#, .titleCreatorYear))
    XCTAssertFalse(matches(book, #""经济 OR 金融""#, .titleCreatorYear))
  }

  func testIncompleteORNeverAddsAMatchEverythingBranch() {
    for text in ["经济 OR", "OR 经济", "经济 OR OR 金融", #"经济 OR """#, "经济 OR -"] {
      XCTAssertTrue(LibrarySearchTerms(text).hasIncompleteOR, text)
      XCTAssertTrue(matches(Book(title: "经济"), text, .titleCreatorYear), text)
      XCTAssertFalse(matches(Book(title: "历史"), text, .titleCreatorYear), text)
    }
    for text in ["OR", "OR OR", #""" OR -"""#] {
      XCTAssertTrue(LibrarySearchTerms(text).hasIncompleteOR)
      XCTAssertFalse(matches(Book(title: "历史"), text, .titleCreatorYear))
    }
    XCTAssertFalse(LibrarySearchTerms(#""OR""#).hasIncompleteOR)
    XCTAssertFalse(LibrarySearchTerms("经济 OR -教材").hasIncompleteOR)
  }

  func testORWithISBNAndNoteSearchScopes() {
    let book = Book(title: "经济读物"); book.isbn13 = "9780306406157"
    for scope in [LibrarySearchScope.fieldsAndTags, .everything] {
      XCTAssertTrue(matches(book, #"金融 OR "0 306 40615 2""#, scope))
      XCTAssertTrue(matches(book, "经济 OR 金融 -0-306-40615-2", scope))
      XCTAssertFalse(matches(book, "经济 -0-306-40615-2 OR 金融", scope))
    }
    var note = NoteRecord(title: "金融随笔"); note.body = "经济教材"; note.tags = ["参考"]
    let query = #""金融随笔" -教材 OR 历史"#
    XCTAssertFalse(NoteQueries.matches(note, text: query, searchScope: .everything))
    XCTAssertTrue(NoteQueries.matches(note, text: query, searchScope: .fieldsAndTags))
    XCTAssertTrue(NoteQueries.matches(note, text: "经济 OR 金融 -教材", searchScope: .everything))
    XCTAssertFalse(NoteQueries.matches(note, text: #""金融 参考" OR 历史"#, searchScope: .everything))
  }

  func testMinusTermsExcludeAnyMatchInTheSelectedFields() {
    let book = Book(title: "经济入门"); book.publisher = "大学出版社"
    for scope in LibrarySearchScope.quickSearchScopes {
      XCTAssertTrue(matches(book, "经济 -教材", scope))
      XCTAssertTrue(matches(book, "-教材", scope))
      XCTAssertFalse(matches(book, "经济 -入门", scope))
      XCTAssertFalse(matches(book, "经济 -教材 -入门", scope))
      XCTAssertFalse(matches(book, "历史 -教材", scope))
      XCTAssertFalse(matches(book, "经济 -经济", scope))
    }
    book.tagLinks = [BookTag(book: book, tag: Tag(name: "教材"))]
    XCTAssertTrue(matches(book, "经济 -教材", .titleCreatorYear))
    XCTAssertFalse(matches(book, "经济 -教材", .fieldsAndTags))
    XCTAssertFalse(matches(book, "经济 -教材", .everything))
    XCTAssertFalse(matches(book, "经济 -出版社", .fieldsAndTags))
  }

  func testExcludedPhrasesStayContiguousAndAllowMixedPositivePhrases() {
    let book = Book(title: "经济入门 A Study Guide")
    contribute("Émile Zola", role: .author, to: book)
    for text in [#"经济 -"Study Guide""#, "经济 -“Study Guide”", "经济 －＂Study Guide＂", "经济 -EMILE",
      #""经济入门" -"Study Guide"#, "-经济"] {
      XCTAssertFalse(matches(book, text, .titleCreatorYear), text)
    }
    XCTAssertTrue(matches(book, #""经济入门" -"Study Advanced Guide""#, .titleCreatorYear))
    XCTAssertTrue(matches(book, #"经济 -"Zola A Study""#, .titleCreatorYear)) // Never join fields into a phrase.
  }

  func testMinusParsingKeepsLiteralHyphensAndIgnoresUnfinishedOperators() {
    let parsed = LibrarySearchTerms(#"经济 -教材 -"study guide""#)
    XCTAssertEqual(parsed.values, ["经济"])
    XCTAssertEqual(parsed.excludedValues, ["教材", "study guide"])
    XCTAssertFalse(LibrarySearchTerms("-教材").isEmpty)
    XCTAssertTrue(LibrarySearchTerms(#"- -"" -“ ”"#).isEmpty)
    XCTAssertEqual(LibrarySearchTerms(#"经济 -"unfinished phrase"#).excludedValues, ["unfinished phrase"])
    let literal = LibrarySearchTerms(#"co-author "-教材" \-教材 978-0-306-40615-7"#)
    XCTAssertEqual(literal.values, ["co-author", "-教材", "-教材", "978-0-306-40615-7"])
    XCTAssertEqual(literal.excludedValues, [])
    XCTAssertTrue(matches(Book(title: "包含 -教材 字样"), #""-教材""#, .titleCreatorYear))
    XCTAssertTrue(matches(Book(title: "包含 -教材 字样"), #"\-教材"#, .titleCreatorYear))
    XCTAssertEqual(LibrarySearchTerms("- 教材").values, ["教材"])
    XCTAssertEqual(LibrarySearchTerms("- 教材").excludedValues, [])
  }

  func testExcludedISBNUsesEquivalentNumbersAndDoesNotBecomePositive() {
    let book = Book(title: "经济入门"); book.isbn13 = "9780306406157"
    for scope in [LibrarySearchScope.fieldsAndTags, .everything] {
      for text in ["-9780306406157", "经济 -0-306-40615-2", #"经济 -"0 306 40615 2""#, "经济 －９７８０３０６４０６１５７"] {
        XCTAssertFalse(matches(book, text, scope), text)
      }
      XCTAssertTrue(matches(book, "978-0-306-40615-7 -教材", scope))
      XCTAssertTrue(matches(book, "978 - 0 - 306 - 40615 - 7", scope))
      XCTAssertFalse(matches(book, "978 -0306406157", scope))
      XCTAssertTrue(matches(book, "经济 -9780306406158", scope))
    }
    XCTAssertTrue(matches(book, "经济 -9780306406157", .titleCreatorYear))
    XCTAssertEqual(LibrarySearchTerms("-9780306406157", preserveISBN: true).excludedValues, ["9780306406157"])
    XCTAssertEqual(LibrarySearchTerms("978 -0306406157", preserveISBN: true).excludedValues, ["0306406157"])
  }

  func testNotesRespectExclusionScopeAndNegativeOnlySearches() {
    var note = NoteRecord(title: "经济阅读"); note.body = "大学教材"; note.tags = ["参考"]
    XCTAssertFalse(NoteQueries.matches(note, text: "经济 -教材", searchScope: .everything))
    XCTAssertTrue(NoteQueries.matches(note, text: "经济 -教材", searchScope: .fieldsAndTags))
    XCTAssertFalse(NoteQueries.matches(note, text: "-参考", searchScope: .fieldsAndTags))
    XCTAssertTrue(NoteQueries.matches(note, text: "-参考", searchScope: .titleCreatorYear))
    XCTAssertTrue(NoteQueries.matches(note, text: #"经济 -"大学 参考""#, searchScope: .everything))
  }

  func testSpaceSeparatedTermsMatchAcrossFieldsInAnyOrder() {
    let book = Book(title: "身体与命运"); book.subtitle = "A Life in Books"
    book.publicationDate = "2024-05"; book.publisher = "复旦大学出版社"
    contribute("Émile Zola", role: .author, to: book)
    book.tagLinks = [BookTag(book: book, tag: Tag(name: "参考资料"))]
    for scope in LibrarySearchScope.quickSearchScopes {
      for text in ["身体 EMILE 2024", "2024  命运\tEmile\nLife", "身体　命运", "Books Life"] {
        XCTAssertTrue(matches(book, text, scope), "\(scope): \(text)")
      }
      XCTAssertFalse(matches(book, "身体 不存在", scope))
      XCTAssertFalse(matches(book, "身体 2023", scope))
    }
    XCTAssertTrue(matches(book, "身体 出版社 参考", .fieldsAndTags))
    XCTAssertFalse(matches(book, "身体 出版社 参考", .titleCreatorYear))
  }

  func testQuotedPhrasesRequireContiguousTextWithinOneField() {
    let book = Book(title: "A Life in Books"); book.subtitle = "Learning every day"
    contribute("Émile Zola", role: .author, to: book)
    for scope in LibrarySearchScope.quickSearchScopes {
      for text in [#""Life in Books" Emile"#, "“Life in Books” Emile", "＂Life in Books＂ Emile",
        #""Life in Books" "Emile Zola""#, #"Emile "Life in Books"#] {
        XCTAssertTrue(matches(book, text, scope), text)
      }
      for text in [#""Life Books""#, #""Books Life""#, #""Books Learning""#,
        #""Emile Zola" missing"#] {
        XCTAssertFalse(matches(book, text, scope), text)
      }
    }
    book.tagLinks = ["经济", "阅读"].map { BookTag(book: book, tag: Tag(name: $0)) }
    XCTAssertTrue(matches(book, "经济 阅读", .fieldsAndTags))
    XCTAssertFalse(matches(book, #""经济 阅读""#, .fieldsAndTags))
  }

  func testQueryParsingHandlesEmptyPhrasesUnclosedQuotesAndEscapes() {
    XCTAssertEqual(LibrarySearchTerms(" \t　\n").values, [])
    XCTAssertEqual(LibrarySearchTerms(#""" “ ” ＂＂"#).values, [])
    XCTAssertEqual(LibrarySearchTerms(#"alpha "two words" beta"#).values, ["alpha", "two words", "beta"])
    XCTAssertEqual(LibrarySearchTerms(#"alpha "two words"#).values, ["alpha", "two words"])
    XCTAssertEqual(LibrarySearchTerms(#""one phrase""another phrase""#).values, ["one phrase", "another phrase"])
    XCTAssertEqual(LibrarySearchTerms(#""say \"hello\"""#).values, [#"say "hello""#])
    XCTAssertEqual(LibrarySearchTerms(#"C:\Books O'Reilly"#).values, [#"C:\Books"#, "O'Reilly"])
    let book = Book(title: #"He said "hello""#)
    XCTAssertTrue(matches(book, #""said \"hello\"""#, .titleCreatorYear))
  }

  func testSpacedISBNRetainsEditionIdentityWithoutSwallowingOtherTerms() {
    let book = Book(title: "身体与命运"); book.isbn13 = "9780306406157"
    for scope in [LibrarySearchScope.fieldsAndTags, .everything] {
      for text in ["0 306 40615 2", "９７８ ０３０６４０６１５７", #"身体 "0 306 40615 2""#,
        "身体 0-306-40615-2"] {
        XCTAssertTrue(matches(book, text, scope), text)
      }
      XCTAssertFalse(matches(book, "missing 9780306406157", scope))
      XCTAssertFalse(matches(book, "身体 9780306406158", scope))
    }
    XCTAssertEqual(LibrarySearchTerms("chapter 9780306406157", preserveISBN: true).values,
      ["chapter", "9780306406157"])
    XCTAssertEqual(LibrarySearchTerms("2024 2025", preserveISBN: true).values, ["2024", "2025"])
    XCTAssertTrue(matches(Book(title: "号码 0 306 40615 2"), "0 306 40615 2", .fieldsAndTags))
  }

  func testNoteTermsCanMatchTitleTagsAndBodyWithoutJoiningPhraseBoundaries() {
    var note = NoteRecord(title: "阅读心得")
    note.body = "A Life in Books brings new ideas"; note.tags = ["经济", "参考"]
    XCTAssertTrue(NoteQueries.matches(note, text: #"阅读 "Life in Books" 参考"#, searchScope: .everything))
    XCTAssertFalse(NoteQueries.matches(note, text: #"阅读 "Life Books""#, searchScope: .everything))
    XCTAssertFalse(NoteQueries.matches(note, text: #""心得 A Life""#, searchScope: .everything))
    XCTAssertFalse(NoteQueries.matches(note, text: #""经济 参考""#, searchScope: .everything))
    XCTAssertTrue(NoteQueries.matches(note, text: "阅读 经济", searchScope: .fieldsAndTags))
    XCTAssertFalse(NoteQueries.matches(note, text: "阅读 new", searchScope: .fieldsAndTags))
    XCTAssertFalse(NoteQueries.matches(note, text: "阅读 经济", searchScope: .titleCreatorYear))
  }

  func testThreeQuickSearchRangesHaveDistinctBoundaries() {
    let book = Book(title: "身体与命运")
    book.subtitle = "副标题"; book.originalTitle = "Original work"
    book.publicationDate = "2024-06-15"; book.publisher = "大学出版社"
    book.edition = "第二版"; book.pageCount = 425; book.languageCode = "zh-CN"
    book.isbn13 = "9780306406157"; book.notes = "仅在个人备注"
    contribute("Émile Zola", role: .author, to: book)
    contribute("王兴", role: .translator, to: book)
    book.tagLinks = [BookTag(book: book, tag: Tag(name: "参考资料"))]
    for text in ["身体", "副标题", "Original work", "EMILE", "王兴", "2024"] {
      for scope in LibrarySearchScope.quickSearchScopes { XCTAssertTrue(matches(book, text, scope), text) }
    }
    for text in ["出版社", "参考资料", "2024-06-15", "第二版", "425", "zh-CN", "0-306-40615-2"] {
      XCTAssertFalse(matches(book, text, .titleCreatorYear), text)
      XCTAssertTrue(matches(book, text, .fieldsAndTags), text)
      XCTAssertTrue(matches(book, text, .everything), text)
    }
    XCTAssertFalse(matches(book, "仅在个人备注", .fieldsAndTags))
    XCTAssertTrue(matches(book, "仅在个人备注", .everything))
    for scope in LibrarySearchScope.quickSearchScopes {
      XCTAssertFalse(matches(Book(title: "无作者"), "未知作者", scope))
    }
  }

  func testNewNoteRangesKeepBodySeparateFromTitleAndTags() {
    var note = NoteRecord(title: "读书心得")
    note.body = "只在正文中出现的关键词"; note.tags = ["经济"]
    for scope in LibrarySearchScope.quickSearchScopes {
      XCTAssertTrue(NoteQueries.matches(note, text: "读书", searchScope: scope))
    }
    XCTAssertFalse(NoteQueries.matches(note, text: "经济", searchScope: .titleCreatorYear))
    XCTAssertTrue(NoteQueries.matches(note, text: "经济", searchScope: .fieldsAndTags))
    XCTAssertFalse(NoteQueries.matches(note, text: "正文", searchScope: .fieldsAndTags))
    XCTAssertTrue(NoteQueries.matches(note, text: "正文", searchScope: .everything))
    note.title = ""; note.body = "# 自动标题\n\n正文关键词"
    XCTAssertTrue(NoteQueries.matches(note, text: "自动标题", searchScope: .fieldsAndTags))
    XCTAssertFalse(NoteQueries.matches(note, text: "正文关键词", searchScope: .fieldsAndTags))
  }

  func testOnlyLivePreferenceMigratesAndNewChoicesRemainStable() throws {
    let name = "SearchScopeTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    LibrarySearchScope.migratePreference(in: defaults)
    XCTAssertNil(defaults.string(forKey: "librarySearchScope"))
    for (old, new) in [("allFields", "everything"), ("title", "titleCreatorYear"),
      ("author", "titleCreatorYear"), ("isbn", "fieldsAndTags"), ("tags", "fieldsAndTags"), ("unknown", "fieldsAndTags")] {
      defaults.set(old, forKey: "librarySearchScope")
      LibrarySearchScope.migratePreference(in: defaults)
      XCTAssertEqual(defaults.string(forKey: "librarySearchScope"), new)
      LibrarySearchScope.migratePreference(in: defaults)
      XCTAssertEqual(defaults.string(forKey: "librarySearchScope"), new)
    }
    for scope in LibrarySearchScope.quickSearchScopes {
      defaults.set(scope.rawValue, forKey: "librarySearchScope")
      LibrarySearchScope.migratePreference(in: defaults)
      XCTAssertEqual(defaults.string(forKey: "librarySearchScope"), scope.rawValue)
    }
    XCTAssertEqual(LibrarySearchScope.author.editingScopes.last, .author)
    XCTAssertEqual(LibrarySearchScope.fieldsAndTags.editingScopes, LibrarySearchScope.quickSearchScopes)
  }

  func testSearchControlsDoNotOverlapAtNarrowWidthsAndLargerFonts() {
    let cell = FilterSearchFieldCell(textCell: "")
    for width in [140.0, 240, 420] {
      for size in [12.0, 13, 18] {
        for text in ["", "很长的搜索词 long search text"] {
          cell.font = .systemFont(ofSize: size); cell.stringValue = text
          let bounds = NSRect(x: 0, y: 0, width: width, height: 32)
          let editor = cell.searchTextRect(forBounds: bounds)
          let search = cell.searchButtonRect(forBounds: bounds)
          let clear = cell.cancelButtonRect(forBounds: bounds)
          let filter = FilterSearchFieldCell.filterButtonRect(forBounds: bounds)
          XCTAssertGreaterThan(editor.width, 30)
          XCTAssertTrue(bounds.contains(editor)); XCTAssertTrue(bounds.contains(filter))
          XCTAssertLessThanOrEqual(search.maxX, editor.minX)
          XCTAssertLessThanOrEqual(editor.maxX, text.isEmpty ? filter.minX : clear.minX)
          XCTAssertLessThanOrEqual(clear.maxX, filter.minX)
        }
      }
    }
  }

  func testTitleIncludesSubtitleButDoesNotSearchOtherFields() {
    let book = Book(title: "身体与命运"); book.subtitle = "A Life in Books"
    book.publisher = "大学出版社"; book.originalTitle = "Original work"; book.notes = "个人备注"
    XCTAssertTrue(matches(book, "身体", .title))
    XCTAssertTrue(matches(book, "  life in books  ", .title))
    for text in ["大学出版社", "Original work", "个人备注"] { XCTAssertFalse(matches(book, text, .title)) }
  }

  func testAuthorUsesRealAuthorNamesOnlyAndMatchesCaseAndAccents() {
    let book = Book(title: "王兴谈阅读")
    contribute("Émile Zola", role: .author, to: book)
    contribute("李四", role: .author, to: book)
    contribute("王兴", role: .translator, to: book)
    XCTAssertTrue(matches(book, "EMILE", .author))
    XCTAssertTrue(matches(book, "李四", .author))
    XCTAssertFalse(matches(book, "王兴", .author))
    XCTAssertTrue(matches(book, "王兴", .allFields))
    XCTAssertFalse(matches(Book(title: "无作者"), "未知作者", .author))
  }

  func testTagsUseAssignedNamesInsteadOfTitleOrCrossTagText() {
    let book = Book(title: "历史的教训")
    book.tagLinks = ["Reference", "经济", "阅读"].map { BookTag(book: book, tag: Tag(name: $0)) }
    XCTAssertTrue(matches(book, "reference", .tags))
    XCTAssertTrue(matches(book, "经济", .tags))
    XCTAssertFalse(matches(book, "历史", .tags))
    XCTAssertFalse(matches(book, "经济 阅读", .tags))
  }

  func testISBNSeparatorsPartialNumbersAndEquivalentEditions() {
    let book = Book(title: "一本书"); book.isbn13 = "9780306406157"
    for text in ["978-0-306-40615-7", "978 0306406157", "９７８０３０６４０６１５７", "0306406152", "640615"] {
      XCTAssertTrue(matches(book, text, .isbn), text)
    }
    let old = Book(title: "旧版"); old.isbn10 = "0-306-40615-2"
    XCTAssertTrue(matches(old, "9780306406157", .isbn))
    let x = Book(title: "带 X 校验位"); x.isbn10 = "080442957X"
    XCTAssertTrue(matches(x, "080442957x", .isbn))
    for text in ["一本书", "chapter 640615", "---", "9780306406158"] {
      XCTAssertFalse(matches(book, text, .isbn), text)
    }
    XCTAssertFalse(matches(Book(title: "9780306406157"), "9780306406157", .isbn))
  }

  func testAllFieldsRetainsPublisherTranslatorNotesAndISBNSearch() {
    let book = Book(title: "一本书"); book.publisher = "大学出版社"; book.notes = "边际收益的例子"
    book.isbn13 = "9780306406157"; contribute("某位译者", role: .translator, to: book)
    for text in ["出版社", "某位译者", "边际收益", "0-306-40615-2"] {
      XCTAssertEqual(LibraryQueries.results([book], collections: [], request: LibraryQueryRequest(text: text)).map(\.id), [book.id])
    }
  }

  func testEmptyQueryDoesNotRequireTheSelectedField() {
    let book = Book(title: "仅有标题"), deleted = Book(title: "已删除"); deleted.deletedAt = Date()
    for scope in LibrarySearchScope.allCases {
      XCTAssertTrue(matches(book, " \n ", scope))
      XCTAssertFalse(matches(deleted, "", scope))
      XCTAssertTrue(LibraryFilter.matches(deleted, selection: .trash, tagIDs: [], query: "", searchScope: scope))
    }
  }

  func testScopedQueryStillIntersectsCollectionTagsSmartRulesAndTrash() throws {
    let parent = BookCollection(name: "父文件夹"), child = BookCollection(name: "子文件夹"); child.parentID = parent.id
    let tag = Tag(name: "参考"), book = Book(title: "目标"), outside = Book(title: "范围外")
    for item in [book, outside] { contribute("王兴", role: .author, to: item) }
    book.collectionItems = [CollectionItem(collection: child, book: book)]
    book.tagLinks = [BookTag(book: book, tag: tag)]
    var request = LibraryQueryRequest(selection: .collection(parent.id), tagIDs: [tag.id], text: "王兴", searchScope: .author)
    XCTAssertTrue(LibraryQueries.results([book, outside], collections: [parent, child], request: request).isEmpty)
    request.includeSubcollections = true
    XCTAssertEqual(LibraryQueries.results([book, outside], collections: [parent, child], request: request).map(\.id), [book.id])
    let smart = BookCollection(name: "已读")
    smart.smartRulesJSON = try AdvancedBookQuery(rules: [BookSearchRule(field: .publisher, comparison: .equals, value: "测试出版社")]).encoded()
    request.selection = .smart(smart.id)
    XCTAssertTrue(LibraryQueries.results([book], collections: [smart], request: request).isEmpty)
    book.publisher = "测试出版社"
    XCTAssertEqual(LibraryQueries.results([book], collections: [smart], request: request).map(\.id), [book.id])
    book.deletedAt = Date()
    XCTAssertTrue(LibraryQueries.results([book], collections: [smart], request: request).isEmpty)
    request.selection = .trash
    XCTAssertEqual(LibraryQueries.results([book], collections: [], request: request).map(\.id), [book.id])
  }

  func testNotesMatchOnlyTheirApplicableFieldsIncludingGeneratedTitle() {
    var note = NoteRecord(title: "读书心得"); note.body = "王兴和 9780306406157 的例子"; note.tags = ["经济"]
    XCTAssertTrue(NoteQueries.matches(note, text: "读书", searchScope: .title))
    XCTAssertFalse(NoteQueries.matches(note, text: "王兴", searchScope: .title))
    XCTAssertTrue(NoteQueries.matches(note, text: "经济", searchScope: .tags))
    XCTAssertFalse(NoteQueries.matches(note, text: "读书", searchScope: .tags))
    XCTAssertFalse(NoteQueries.matches(note, text: "王兴", searchScope: .author))
    XCTAssertFalse(NoteQueries.matches(note, text: "9780306406157", searchScope: .isbn))
    XCTAssertTrue(NoteQueries.matches(note, text: "王兴"))
    note.title = ""; note.body = "# 自动标题\n\n仅正文关键词"
    XCTAssertTrue(NoteQueries.matches(note, text: "自动标题", searchScope: .title))
    XCTAssertFalse(NoteQueries.matches(note, text: "仅正文关键词", searchScope: .title))
    for scope in LibrarySearchScope.allCases { XCTAssertTrue(NoteQueries.matches(note, text: "", searchScope: scope)) }
  }

  func testNoteMatchesCannotBypassAuthorISBNOrBookLibraryFilters() {
    let book = Book(title: "父书籍")
    var request = LibraryQueryRequest(text: "笔记关键词", noteMatchedBookIDs: [book.id])
    for scope in [LibrarySearchScope.allFields, .title, .tags] {
      request.searchScope = scope
      XCTAssertEqual(LibraryQueries.results([book], collections: [], request: request).map(\.id), [book.id])
    }
    for scope in [LibrarySearchScope.author, .isbn] {
      request.searchScope = scope
      XCTAssertTrue(LibraryQueries.results([book], collections: [], request: request).isEmpty)
    }
    request.searchScope = .allFields; request.tagIDs = [UUID()]
    XCTAssertTrue(LibraryQueries.results([book], collections: [], request: request).isEmpty)
    request.tagIDs = []; book.deletedAt = Date()
    XCTAssertTrue(LibraryQueries.results([book], collections: [], request: request).isEmpty)
  }

  func testNoteResultsApplySearchScopeInCollectionsAndTrash() {
    let collection = ManualCollectionRecord(name: "笔记文件夹")
    var note = NoteRecord(title: "标题"); note.body = "正文关键词"; note.tags = ["参考"]; note.collectionIDs = [collection.id]
    XCTAssertTrue(NoteQueries.results([note], books: [], collections: [collection], scope: .collection(collection.id), text: "正文关键词", searchScope: .title).isEmpty)
    XCTAssertEqual(NoteQueries.results([note], books: [], collections: [collection], scope: .collection(collection.id), text: "参考", searchScope: .tags).map(\.id), [note.id])
    note.deletedAt = Date()
    XCTAssertTrue(NoteQueries.results([note], books: [], collections: [], scope: .all, text: "参考", searchScope: .tags).isEmpty)
    XCTAssertEqual(NoteQueries.results([note], books: [], collections: [], scope: .trash, text: "参考", searchScope: .tags).map(\.id), [note.id])
  }
}
