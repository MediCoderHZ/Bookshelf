import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class SavedLibrarySearchTests: XCTestCase {
  private func query(_ scope: LibrarySearchScope, _ text: String) -> AdvancedBookQuery {
    .savingSearch(scope: scope, text: text)
  }
  private func results(_ books: [Book], query: AdvancedBookQuery, notes: [NoteRecord] = []) throws -> [UUID] {
    let smart = BookCollection(name: "保存的搜索"); smart.smartRulesJSON = try query.encoded()
    return LibraryQueries.results(books, collections: [smart], request: LibraryQueryRequest(selection: .smart(smart.id)), notes: notes).map(\.id)
  }

  func testGroupedQueriesPersistAndMatchEquivalentExpandedQueries() throws {
    let books = ["经济", "经济教材", "金融", "金融教材", "历史", "经济 入门", "金融 Study Guide"].map { Book(title: $0) }
    let cases = [
      ("(经济 OR 金融) -教材", "经济 -教材 OR 金融 -教材"),
      ("((经济 OR 金融) -教材) OR 历史", "经济 -教材 OR 金融 -教材 OR 历史"),
      (#"("经济 入门" OR 金融) -(教材 OR "Study Guide")"#, #""经济 入门" -教材 -"Study Guide" OR 金融 -教材 -"Study Guide""#),
      ("（经济 OR 金融）-教材", "经济 -教材 OR 金融 -教材")
    ]
    for scope in LibrarySearchScope.quickSearchScopes {
      for (grouped, expanded) in cases {
        let saved = try AdvancedBookQuery.decode(query(scope, grouped).encoded())
        XCTAssertEqual(saved.savedSearch?.text, grouped)
        let expected = try results(books, query: query(scope, expanded))
        XCTAssertEqual(try results(books, query: saved), expected, grouped)
        XCTAssertEqual(LibraryQueries.results(books, collections: [], request: LibraryQueryRequest(text: grouped, searchScope: scope)).map(\.id), expected)
        for book in books {
          let note = NoteRecord(title: book.title)
          XCTAssertEqual(saved.matches(note), query(scope, expanded).matches(note))
        }
      }
      for invalid in ["(经济 OR 金融", "经济)", "()", "(经济 OR)", "-(())", "（经济)"] {
        XCTAssertNotNil(query(scope, invalid).validationMessage)
        XCTAssertThrowsError(try query(scope, invalid).encoded())
      }
    }
    let literal = Book(title: "(经济 OR 金融)")
    XCTAssertEqual(try results([literal], query: query(.title, literal.title)), [literal.id])
    XCTAssertTrue(try results(books, query: query(.title, literal.title)).isEmpty)
  }

  func testGroupedBookAndChildQueriesShareExclusionsWithoutJoiningItems() throws {
    let book = Book(title: "资料")
    var economics = NoteRecord(title: "经济", parentBookID: book.id)
    var finance = NoteRecord(title: "金融", parentBookID: book.id)
    func check(_ text: String, _ expected: Bool, _ notes: [NoteRecord], scope: LibrarySearchScope = .everything) throws {
      let request = LibraryQueryRequest(text: text, searchScope: scope, noteMatchedBookIDs: [book.id])
      let live = LibraryQueries.results([book], collections: [], request: request, notes: notes).map(\.id)
      XCTAssertEqual(live, expected ? [book.id] : [], text)
      XCTAssertEqual(try results([book], query: query(scope, text), notes: notes), live)
    }
    let grouped = "(经济 OR 金融) -教材"
    try check(grouped, true, [economics, finance])
    book.title = "教材"; try check(grouped, false, [economics, finance])
    book.title = "资料"; finance.body = "教材"; try check(grouped, false, [economics, finance])
    try check(grouped, true, [economics, finance], scope: .fieldsAndTags)
    try check("((经济 OR 金融) -教材) OR 资料", true, [economics, finance])
    try check("(经济 OR 金融) -(教材 OR 习题)", false, [economics, finance])
    finance.deletedAt = Date(); try check(grouped, true, [economics, finance])
    finance.deletedAt = nil; finance.parentBookID = UUID(); try check(grouped, true, [economics, finance])
    finance.parentBookID = book.id; finance.body = "历史"
    try check("(经济) (金融 OR 历史)", false, [economics, finance])
    economics.body = "历史"; try check("(经济) (金融 OR 历史)", true, [economics, finance])
    book.deletedAt = Date(); finance.deletedAt = Date(); finance.body = "教材"
    let trash = LibraryQueryRequest(selection: .trash, text: grouped, searchScope: .everything)
    XCTAssertTrue(LibraryQueries.results([book], collections: [], request: trash, notes: [economics, finance]).isEmpty)
    finance.body = "随笔"
    XCTAssertEqual(LibraryQueries.results([book], collections: [], request: trash, notes: [economics, finance]).map(\.id), [book.id])
  }

  func testGroupedSearchSurvivesReopenBackupAndDynamicEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("grouped.store")
    let text = #"(("经济 入门" OR 金融) -教材) -"Study Guide""#
    var id = UUID(), economicsID = UUID(), financeID = UUID()
    do {
      let db = try LibraryDatabase.open(at: url), ctx = db.mainContext
      let economics = Book(title: "经济 入门"), finance = Book(title: "金融随笔")
      ctx.insert(economics); ctx.insert(finance); economicsID = economics.id; financeID = finance.id
      ctx.insert(Book(title: "经济 入门 教材")); ctx.insert(Book(title: "金融 Study Guide"))
      id = try SmartCollectionService.save(name: "分组搜索", query: query(.fieldsAndTags, text), context: ctx, undoManager: nil)
    }
    let reopened = try LibraryDatabase.open(at: url)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: reopened.mainContext)[id]?.query.savedSearch?.text, text)
    let data = try LibraryBackupService.exportData(from: reopened.mainContext)
    let restored = try LibraryDatabase.open(inMemory: true)
    let plan = try LibraryImportPlanner.prepare(data, context: restored.mainContext)
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: restored.mainContext, undoManager: nil)
    let collections = try restored.mainContext.fetch(FetchDescriptor<BookCollection>())
    let books = try restored.mainContext.fetch(FetchDescriptor<Book>())
    func found() -> Set<UUID> {
      Set(LibraryQueries.results(books, collections: collections, request: LibraryQueryRequest(selection: .smart(id))).map(\.id))
    }
    XCTAssertEqual(found(), [economicsID, financeID])
    let economics = try XCTUnwrap(books.first { $0.id == economicsID })
    economics.publisher = "教材出版社"; try restored.mainContext.save()
    XCTAssertEqual(found(), [financeID])
    economics.title = "金融入门"; try restored.mainContext.save()
    XCTAssertEqual(found(), [financeID]) // Parenthesized alternatives share the outer exclusion.
    economics.publisher = nil; try restored.mainContext.save()
    XCTAssertEqual(found(), [economicsID, financeID])
    XCTAssertEqual(collections.first?.smartQuery?.savedSearch?.text, text)
    // Editing the saved search to remove grouping restores ordinary OR precedence.
    let previous = try XCTUnwrap(SmartCollectionService.snapshots(in: restored.mainContext)[id])
    let edited = "经济 OR 金融 -教材"
    _ = try SmartCollectionService.save(name: "分组搜索", query: query(.fieldsAndTags, edited), replacing: previous,
      context: restored.mainContext, undoManager: nil)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: restored.mainContext)[id]?.query.savedSearch?.text, edited)
    XCTAssertEqual(found(), Set(books.map(\.id)))
  }

  func testORSearchesRoundTripAndKeepLiveAndSavedResultsIdentical() throws {
    let books = [Book(title: "经济教材"), Book(title: "金融随笔"), Book(title: "金融教材"), Book(title: "历史")]
    for scope in LibrarySearchScope.quickSearchScopes {
      for text in ["经济 OR 金融", "经济 OR 金融 -教材", #"经济 -教材 OR "金融随笔""#, "-教材 OR -随笔"] {
        let saved = try AdvancedBookQuery.decode(query(scope, text).encoded())
        XCTAssertEqual(saved.savedSearch?.text, text)
        let live = LibraryQueries.results(books, collections: [], request: LibraryQueryRequest(text: text, searchScope: scope)).map(\.id)
        XCTAssertEqual(try results(books, query: saved), live)
        let note = NoteRecord(title: books[0].title)
        XCTAssertEqual(saved.matches(note), NoteQueries.matches(note, text: text, searchScope: scope))
      }
      for incomplete in ["OR", "经济 OR", "OR 金融", "经济 OR OR 金融", #"经济 OR """#] {
        XCTAssertEqual(query(scope, incomplete).validationMessage, "请在 OR 两侧填写搜索条件。")
        XCTAssertThrowsError(try query(scope, incomplete).encoded())
      }
    }
    // Historical single-field queries keep literal matching semantics.
    let legacy = try AdvancedBookQuery.decode(query(.title, "经济 OR 金融").encoded())
    XCTAssertTrue(try results(books, query: legacy).isEmpty)
    let literal = Book(title: "经济 OR 金融")
    XCTAssertEqual(try results([literal], query: legacy), [literal.id])
  }

  func testORChildMatchesUseExclusionsFromTheSameBranchOnly() throws {
    let book = Book(title: "教材")
    var economics = NoteRecord(title: "经济随笔", parentBookID: book.id)
    var finance = NoteRecord(title: "金融资料", parentBookID: book.id)
    func check(_ text: String, _ expected: Bool, notes: [NoteRecord], scope: LibrarySearchScope = .everything) throws {
      let request = LibraryQueryRequest(text: text, searchScope: scope, noteMatchedBookIDs: [book.id])
      let live = LibraryQueries.results([book], collections: [], request: request, notes: notes).map(\.id)
      XCTAssertEqual(live, expected ? [book.id] : [], text)
      XCTAssertEqual(try results([book], query: query(scope, text), notes: notes), live, text)
    }
    try check("经济 -教材 OR 历史", false, notes: [economics, finance])
    try check("经济 -教材 OR 金融", true, notes: [economics, finance])
    finance.body = "习题摘录"
    try check("经济 -教材 OR 金融 -习题", false, notes: [economics, finance])
    try check("经济 -教材 OR 金融 -习题", true, notes: [economics, finance], scope: .fieldsAndTags)
    economics.body = "金融习题"
    try check("经济 -教材 OR 金融 -习题", false, notes: [economics, finance])
    finance.body = "资料"; economics.body = "习题"; economics.deletedAt = Date()
    try check("经济 -教材 OR 金融 -习题", true, notes: [economics, finance])
    economics.deletedAt = nil; economics.parentBookID = UUID()
    try check("经济 -教材 OR 金融 -习题", true, notes: [economics, finance])
    economics.parentBookID = book.id; economics.body = ""; book.title = "资料"
    try check("经济 金融 OR 历史", false, notes: [economics, finance]) // Never join positive terms across notes.
    book.deletedAt = Date(); economics.deletedAt = Date(); economics.body = "习题"
    let trash = LibraryQueryRequest(selection: .trash, text: "经济 -教材 OR 金融 -习题", searchScope: .everything)
    XCTAssertEqual(LibraryQueries.results([book], collections: [], request: trash, notes: [economics, finance]).map(\.id), [book.id])
    economics.body = "教材 习题"
    XCTAssertTrue(LibraryQueries.results([book], collections: [], request: trash, notes: [economics, finance]).isEmpty)
  }

  func testORRespectsCollectionTagAndTrashBoundaries() {
    let included = Book(title: "经济"), outside = Book(title: "金融"), deleted = Book(title: "金融")
    let collection = BookCollection(name: "范围"), tag = Tag(name: "参考")
    included.collectionItems = [CollectionItem(collection: collection, book: included)]
    included.tagLinks = [BookTag(book: included, tag: tag)]
    deleted.deletedAt = Date()
    let books = [included, outside, deleted]
    var request = LibraryQueryRequest(selection: .collection(collection.id), text: "经济 OR 金融", searchScope: .fieldsAndTags)
    XCTAssertEqual(LibraryQueries.results(books, collections: [collection], request: request).map(\.id), [included.id])
    request.selection = .all; request.tagIDs = [tag.id]
    XCTAssertEqual(LibraryQueries.results(books, collections: [collection], request: request).map(\.id), [included.id])
    request.tagIDs = []; request.selection = .trash
    XCTAssertEqual(LibraryQueries.results(books, collections: [collection], request: request).map(\.id), [deleted.id])
  }

  func testORSearchSurvivesReopenBackupAndDynamicEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let text = #""经济 入门" -教材 OR 金融 -"Study Guide""#
    let url = directory.appendingPathComponent("alternatives.store")
    var id = UUID(), economicsID = UUID(), financeID = UUID()
    do {
      let db = try LibraryDatabase.open(at: url), ctx = db.mainContext
      let economics = Book(title: "经济 入门"), finance = Book(title: "金融随笔")
      ctx.insert(economics); ctx.insert(finance); economicsID = economics.id; financeID = finance.id
      ctx.insert(Book(title: "经济 入门 教材")); ctx.insert(Book(title: "金融 Study Guide"))
      ctx.insert(Book(title: "经济方法 入门"))
      id = try SmartCollectionService.save(name: "经济或金融", query: query(.fieldsAndTags, text), context: ctx, undoManager: nil)
    }
    let reopened = try LibraryDatabase.open(at: url)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: reopened.mainContext)[id]?.query.savedSearch?.text, text)
    let data = try LibraryBackupService.exportData(from: reopened.mainContext)
    let restored = try LibraryDatabase.open(inMemory: true)
    let plan = try LibraryImportPlanner.prepare(data, context: restored.mainContext)
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: restored.mainContext, undoManager: nil)
    let collections = try restored.mainContext.fetch(FetchDescriptor<BookCollection>())
    let books = try restored.mainContext.fetch(FetchDescriptor<Book>())
    func found() -> Set<UUID> {
      Set(LibraryQueries.results(books, collections: collections, request: LibraryQueryRequest(selection: .smart(id))).map(\.id))
    }
    XCTAssertEqual(found(), [economicsID, financeID])
    let economics = try XCTUnwrap(books.first { $0.id == economicsID })
    economics.publisher = "教材出版社"; try restored.mainContext.save()
    XCTAssertEqual(found(), [financeID])
    economics.title = "金融入门"; try restored.mainContext.save()
    XCTAssertEqual(found(), [economicsID, financeID]) // The first branch's exclusion cannot reject the second.
    economics.publisher = "Study Guide"; try restored.mainContext.save()
    XCTAssertEqual(found(), [financeID])
    XCTAssertEqual(collections.first?.smartQuery?.savedSearch?.text, text)
  }

  func testExclusionSearchesMatchLiveResultsAndValidateNegativeOnlyConditions() throws {
    let textbook = Book(title: "经济教材"), essay = Book(title: "经济随笔"), history = Book(title: "历史随笔")
    let books = [textbook, essay, history]
    for scope in LibrarySearchScope.quickSearchScopes {
      for text in ["经济 -教材", "-教材", #"经济 -"经济教材" -历史"#, "经济 -经济"] {
        let restored = try AdvancedBookQuery.decode(query(scope, text).encoded())
        XCTAssertEqual(restored.savedSearch?.text, text)
        let live = LibraryQueries.results(books, collections: [], request: LibraryQueryRequest(text: text, searchScope: scope)).map(\.id)
        XCTAssertEqual(try results(books, query: restored), live)
      }
      XCTAssertEqual(try results(books, query: query(scope, "经济 -教材")), [essay.id])
      XCTAssertEqual(try results(books, query: query(scope, "-教材")), [essay.id, history.id])
      for empty in ["-", #"-"""#, "- -“ ”"] { XCTAssertThrowsError(try query(scope, empty).encoded()) }
    }
  }

  func testChildMatchesCannotBypassBookOrSiblingExclusions() throws {
    let book = Book(title: "经济教材")
    var matching = NoteRecord(title: "经济随笔", parentBookID: book.id)
    var sibling = NoteRecord(title: "资料", parentBookID: book.id); sibling.body = "教材摘录"
    let text = "经济 -教材"
    func live(_ notes: [NoteRecord], scope: LibrarySearchScope = .everything,
      selection: LibrarySelection = .all, term: String = "经济 -教材") -> [UUID] {
      let matchingParents = Set(notes.filter { $0.deletedAt == nil || selection == .trash }
        .filter { NoteQueries.matches($0, text: term, searchScope: scope) }.compactMap(\.parentBookID))
      return LibraryQueries.results([book], collections: [], request: LibraryQueryRequest(selection: selection,
        text: term, searchScope: scope, noteMatchedBookIDs: matchingParents), notes: notes).map(\.id)
    }
    // A clean child used to bypass a rejected book by supplying a matched parent ID.
    for term in [text, "-教材"] {
      XCTAssertTrue(live([matching], term: term).isEmpty)
      XCTAssertTrue(try results([book], query: query(.everything, term), notes: [matching]).isEmpty)
    }
    book.title = "其他书籍"
    XCTAssertEqual(live([matching]), [book.id])
    XCTAssertEqual(try results([book], query: query(.everything, text), notes: [matching]), [book.id])
    XCTAssertTrue(live([matching, sibling]).isEmpty)
    XCTAssertTrue(try results([book], query: query(.everything, text), notes: [matching, sibling]).isEmpty)
    XCTAssertEqual(live([matching, sibling], scope: .fieldsAndTags), [book.id]) // Body is outside this scope.
    sibling.deletedAt = Date()
    XCTAssertEqual(live([matching, sibling]), [book.id])
    XCTAssertEqual(try results([book], query: query(.everything, text), notes: [matching, sibling]), [book.id])
    sibling.deletedAt = nil; sibling.parentBookID = UUID()
    XCTAssertEqual(live([matching, sibling]), [book.id]) // An unrelated note cannot veto the book.
    book.deletedAt = Date(); matching.body = "教材"
    XCTAssertTrue(live([matching], selection: .trash).isEmpty)
    matching.body = "随笔"
    XCTAssertEqual(live([matching], selection: .trash), [book.id])
    XCTAssertTrue(live([matching]).isEmpty) // Exclusions do not bypass the trash boundary.
  }

  func testExcludedSearchSurvivesReopenBackupAndDynamicEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("exclusions.store")
    let text = #"经济 -教材 -"Study Guide""#
    var id = UUID(), bookID = UUID()
    do {
      let db = try LibraryDatabase.open(at: url), ctx = db.mainContext
      let book = Book(title: "经济随笔"); ctx.insert(book); bookID = book.id
      ctx.insert(Book(title: "经济教材")); ctx.insert(Book(title: "经济 Study Guide"))
      id = try SmartCollectionService.save(name: "经济非教材", query: query(.fieldsAndTags, text), context: ctx, undoManager: nil)
    }
    let reopened = try LibraryDatabase.open(at: url)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: reopened.mainContext)[id]?.query.savedSearch?.text, text)
    let data = try LibraryBackupService.exportData(from: reopened.mainContext)
    let restored = try LibraryDatabase.open(inMemory: true)
    let plan = try LibraryImportPlanner.prepare(data, context: restored.mainContext)
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: restored.mainContext, undoManager: nil)
    let collections = try restored.mainContext.fetch(FetchDescriptor<BookCollection>())
    let books = try restored.mainContext.fetch(FetchDescriptor<Book>())
    func found() -> [UUID] {
      LibraryQueries.results(books, collections: collections, request: LibraryQueryRequest(selection: .smart(id))).map(\.id)
    }
    XCTAssertEqual(found(), [bookID])
    let book = try XCTUnwrap(books.first { $0.id == bookID })
    book.publisher = "教材出版社"; try restored.mainContext.save()
    XCTAssertTrue(found().isEmpty)
    book.publisher = nil; try restored.mainContext.save()
    XCTAssertEqual(found(), [bookID])
    XCTAssertEqual(collections.first?.smartQuery?.savedSearch?.text, text)
  }

  func testKeywordAndPhraseSearchesRoundTripAndMatchLiveResults() throws {
    let book = Book(title: "A Life in Books"); book.publicationDate = "2024"
    book.contributions = [Contribution(book: book, person: Person(name: "Émile Zola"), role: .author, displayOrder: 0)]
    let other = Book(title: "Books in Life"); other.publicationDate = "2024"
    for scope in LibrarySearchScope.quickSearchScopes {
      for text in ["Books Life 2024", #""Life in Books" 2024"#, #"“Life in Books” Emile"#] {
        let saved = try AdvancedBookQuery.decode(query(scope, text).encoded())
        XCTAssertEqual(saved.savedSearch?.text, text)
        let live = LibraryQueries.results([book, other], collections: [],
          request: LibraryQueryRequest(text: text, searchScope: scope)).map(\.id)
        XCTAssertEqual(try results([book, other], query: saved), live)
      }
      XCTAssertThrowsError(try query(scope, #""" “ ”"#).encoded())
    }
    var child = NoteRecord(title: "心得", parentBookID: book.id)
    child.body = "A Life in Books"; child.tags = ["参考"]
    let saved = query(.everything, #"心得 "Life in Books" 参考"#)
    XCTAssertEqual(try results([book, other], query: saved, notes: [child]), [book.id])
    let noteIDs = Set([child].filter { NoteQueries.matches($0, text: saved.savedSearch!.text, searchScope: .everything) }.compactMap(\.parentBookID))
    XCTAssertEqual(LibraryQueries.results([book, other], collections: [], request: LibraryQueryRequest(
      text: saved.savedSearch!.text, searchScope: .everything, noteMatchedBookIDs: noteIDs), notes: [child]).map(\.id), [book.id])
    child.body = "Books in Life"
    XCTAssertTrue(try results([book], query: saved, notes: [child]).isEmpty)
    child.body = "A Life in Books"; child.deletedAt = Date()
    XCTAssertTrue(try results([book], query: saved, notes: [child]).isEmpty)
  }

  func testSavedSearchMatchesLiveSearchForEveryScope() throws {
    let book = Book(title: "身体与命运"); book.subtitle = "副标题"; book.isbn13 = "9780306406157"
    book.publisher = "大学出版社"; book.originalTitle = "只在原书名"
    book.contributions = [Contribution(book: book, person: Person(name: "王兴"), role: .author, displayOrder: 0)]
    book.tagLinks = [BookTag(book: book, tag: Tag(name: "参考"))]
    let other = Book(title: "王兴的书"); other.publisher = "参考出版社"
    let books = [book, other]
    for (scope, text) in [(LibrarySearchScope.allFields, "出版社"), (.title, "副标题"), (.title, "只在原书名"),
      (.author, "王兴"), (.isbn, "0-306-40615-2"), (.isbn, "978-030"), (.tags, "参考"),
      (.titleCreatorYear, "王兴"), (.fieldsAndTags, "出版社"), (.everything, "原书名")] {
      let live = LibraryQueries.results(books, collections: [], request: LibraryQueryRequest(text: text, searchScope: scope)).map(\.id)
      XCTAssertEqual(try results(books, query: query(scope, text)), live, "\(scope): \(text)")
    }
  }

  func testQuotedSearchSurvivesStoreReopenAndBackupRestore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("phrases.store")
    let text = #""Life in Books" 2024"#
    var id = UUID(), bookID = UUID()
    do {
      let db = try LibraryDatabase.open(at: url), ctx = db.mainContext
      let book = Book(title: "A Life in Books"); book.publicationDate = "2024"; ctx.insert(book); bookID = book.id
      let other = Book(title: "Books in Life"); other.publicationDate = "2024"; ctx.insert(other)
      id = try SmartCollectionService.save(name: "精确短语", query: query(.titleCreatorYear, text), context: ctx, undoManager: nil)
    }
    let reopened = try LibraryDatabase.open(at: url)
    let snapshot = try XCTUnwrap(SmartCollectionService.snapshots(in: reopened.mainContext)[id])
    XCTAssertEqual(snapshot.query.savedSearch?.text, text)
    let data = try LibraryBackupService.exportData(from: reopened.mainContext)
    let restored = try LibraryDatabase.open(inMemory: true)
    let plan = try LibraryImportPlanner.prepare(data, context: restored.mainContext)
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: restored.mainContext, undoManager: nil)
    let collections = try restored.mainContext.fetch(FetchDescriptor<BookCollection>())
    let books = try restored.mainContext.fetch(FetchDescriptor<Book>())
    XCTAssertEqual(LibraryQueries.results(books, collections: collections,
      request: LibraryQueryRequest(selection: .smart(id))).map(\.id), [bookID])
    books.first { $0.id == bookID }?.publicationDate = "2025"
    XCTAssertTrue(LibraryQueries.results(books, collections: collections,
      request: LibraryQueryRequest(selection: .smart(id))).isEmpty)
  }

  func testLegacyAndSavedSearchEncodingAndInvalidPayloads() throws {
    let old = try AdvancedBookQuery.decode("{\"version\":1,\"mode\":\"all\",\"rules\":[]}")
    XCTAssertNil(old.savedSearch); XCTAssertFalse(old.hasConditions)
    XCTAssertFalse(try old.encoded().contains("savedSearch"))
    let saved = query(.author, "  王兴 \n")
    XCTAssertEqual(saved.version, 2); XCTAssertEqual(saved.savedSearch?.text, "王兴")
    XCTAssertEqual(try AdvancedBookQuery.decode(saved.encoded()), saved)
    XCTAssertTrue(SmartCollectionArchive(name: "作者", query: saved).isValid)
    XCTAssertFalse(SmartCollectionArchive(name: " ", query: saved).isValid)
    XCTAssertThrowsError(try query(.title, " \n ").encoded())
    XCTAssertThrowsError(try AdvancedBookQuery.decode("{\"version\":2,\"mode\":\"all\",\"rules\":[]}"))
    for invalid in [
      "{\"version\":1,\"mode\":\"all\",\"rules\":[],\"savedSearch\":{\"scope\":\"title\",\"text\":\"书\"}}",
      "{\"version\":2,\"mode\":\"all\",\"rules\":[],\"savedSearch\":{\"scope\":\"unknown\",\"text\":\"书\"}}"
    ] { XCTAssertThrowsError(try AdvancedBookQuery.decode(invalid)) }
  }

  func testNewModesRoundTripAndKeepNoteResultsDynamic() throws {
    let book = Book(title: "父书籍")
    var child = NoteRecord(title: "读书笔记", parentBookID: book.id)
    child.body = "只在正文"; child.tags = ["参考"]
    for scope in LibrarySearchScope.quickSearchScopes {
      let original = query(scope, "只在正文")
      let restored = try AdvancedBookQuery.decode(original.encoded())
      XCTAssertEqual(restored, original)
      XCTAssertEqual(try results([book], query: restored, notes: [child]), scope == .everything ? [book.id] : [])
    }
    let full = query(.everything, "只在正文")
    child.body = "已修改"
    XCTAssertTrue(try results([book], query: full, notes: [child]).isEmpty)
    child.body = "只在正文"; child.deletedAt = Date()
    XCTAssertTrue(try results([book], query: full, notes: [child]).isEmpty)
    for raw in ["allFields", "title", "author", "isbn", "tags"] {
      let json = "{\"version\":2,\"mode\":\"all\",\"rules\":[],\"savedSearch\":{\"scope\":\"\(raw)\",\"text\":\"关键词\"}}"
      let restored = try AdvancedBookQuery.decode(json)
      XCTAssertEqual(restored.savedSearch?.scope.rawValue, raw)
      XCTAssertEqual(try AdvancedBookQuery.decode(restored.encoded()), restored)
    }
  }

  func testDynamicBookEditsAndTrashChangeResultsWithoutMemberships() throws {
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let book = Book(title: "待添加"), other = Book(title: "阅读清单"); ctx.insert(book); ctx.insert(other)
    let id = try SmartCollectionService.save(name: "阅读搜索", query: query(.title, "阅读"), context: ctx, undoManager: nil)
    let smart = try XCTUnwrap(ctx.fetch(FetchDescriptor<BookCollection>()).first { $0.id == id })
    func found() -> [UUID] {
      LibraryQueries.results([book, other], collections: [smart], request: LibraryQueryRequest(selection: .smart(id))).map(\.id)
    }
    XCTAssertEqual(found(), [other.id])
    book.subtitle = "阅读方法"; try ctx.save(); XCTAssertEqual(found(), [book.id, other.id])
    other.title = "已改名"; try ctx.save(); XCTAssertEqual(found(), [book.id])
    book.deletedAt = Date(); try ctx.save(); XCTAssertTrue(found().isEmpty)
    book.deletedAt = nil; try ctx.save(); XCTAssertEqual(found(), [book.id])
    XCTAssertTrue(book.collectionItems.isEmpty); XCTAssertTrue(smart.items.isEmpty)
  }

  func testChildNotesAndStandaloneNotesFollowIdenticalSearchRules() throws {
    let book = Book(title: "父书籍")
    var child = NoteRecord(title: "子笔记", parentBookID: book.id); child.body = "边际收益"; child.tags = ["经济"]
    var standalone = NoteRecord(title: "独立笔记"); standalone.body = "边际收益"; standalone.tags = ["经济"]
    let all = query(.allFields, "边际收益")
    XCTAssertEqual(try results([book], query: all, notes: [child, standalone]), [book.id])
    XCTAssertTrue(all.matches(standalone)); XCTAssertFalse(all.matches(child))
    XCTAssertEqual(NoteQueries.results([child, standalone], books: [book], collections: [], scope: .smart(UUID()),
      text: "", smartQuery: all).map(\.id), [standalone.id])
    XCTAssertFalse(query(.title, "边际收益").matches(standalone))
    XCTAssertTrue(try results([book], query: query(.title, "边际收益"), notes: [child]).isEmpty)
    XCTAssertEqual(try results([book], query: query(.tags, "经济"), notes: [child]), [book.id])
    for scope in [LibrarySearchScope.author, .isbn] {
      XCTAssertFalse(query(scope, "边际收益").matches(standalone))
      XCTAssertTrue(try results([book], query: query(scope, "边际收益"), notes: [child]).isEmpty)
    }
    child.body = "已改写"; XCTAssertTrue(try results([book], query: all, notes: [child]).isEmpty)
    child.body = "边际收益"; child.deletedAt = Date()
    XCTAssertTrue(try results([book], query: all, notes: [child]).isEmpty)
    standalone.deletedAt = Date(); XCTAssertFalse(all.matches(standalone))
  }

  func testSavedSearchIntersectsFurtherTextTagsAndRules() throws {
    let book = Book(title: "阅读方法"); book.publisher = "甲出版社"
    let other = Book(title: "阅读目录"); other.publisher = "乙出版社"
    let tag = Tag(name: "参考"); book.tagLinks = [BookTag(book: book, tag: tag)]
    let smart = BookCollection(name: "阅读"); smart.smartRulesJSON = try query(.title, "阅读").encoded()
    var request = LibraryQueryRequest(selection: .smart(smart.id), text: "甲", searchScope: .allFields)
    XCTAssertEqual(LibraryQueries.results([book, other], collections: [smart], request: request).map(\.id), [book.id])
    request.text = ""; request.tagIDs = [tag.id]
    XCTAssertEqual(LibraryQueries.results([book, other], collections: [smart], request: request).map(\.id), [book.id])
    var combined = query(.title, "阅读")
    combined.rules = [BookSearchRule(field: .publisher, comparison: .contains, value: "甲")]
    XCTAssertEqual(try results([book, other], query: combined), [book.id])
    var note = NoteRecord(title: "阅读方法"); note.body = "甲"
    XCTAssertFalse(combined.matches(note))
  }

  func testCreateEditUndoRedoAndDuplicateNameUseExistingSmartCollectionHistory() throws {
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let undo = UndoManager(); undo.groupsByEvent = false
    undo.beginUndoGrouping()
    let id = try SmartCollectionService.save(name: "作者：王兴", query: query(.author, "王兴"), context: ctx, undoManager: undo)
    undo.endUndoGrouping()
    let initial = try XCTUnwrap(SmartCollectionService.snapshots(in: ctx)[id])
    XCTAssertThrowsError(try SmartCollectionService.save(name: "作者：王兴", query: query(.title, "书"), context: ctx, undoManager: undo))
    undo.undo(); XCTAssertTrue(try SmartCollectionService.snapshots(in: ctx).isEmpty)
    undo.redo(); XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx)[id], initial)
    undo.beginUndoGrouping()
    _ = try SmartCollectionService.save(name: "标签搜索", query: query(.tags, "参考"), replacing: initial, context: ctx, undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx)[id]?.query.savedSearch?.scope, .tags)
    undo.undo(); XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx)[id], initial)
    XCTAssertNil(LibraryServices.forContext(ctx).history.errorMessage)
  }

  func testSavedSearchSurvivesReopenAndBackupImportWithNotes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("search.store")
    var id = UUID(), bookID = UUID()
    do {
      let db = try LibraryDatabase.open(at: url), ctx = db.mainContext
      let book = Book(title: "不含关键词"); ctx.insert(book); bookID = book.id
      let note = LibraryNote(title: "笔记", body: "边际收益"); note.parentBookID = book.id; ctx.insert(note)
      id = try SmartCollectionService.save(name: "经济笔记搜索", query: query(.allFields, "边际收益"), context: ctx, undoManager: nil)
    }
    let reopened = try LibraryDatabase.open(at: url), ctx = reopened.mainContext
    let restored = try XCTUnwrap(SmartCollectionService.snapshots(in: ctx)[id])
    XCTAssertEqual(restored.query.savedSearch, SavedLibrarySearch(scope: .allFields, text: "边际收益"))
    let data = try LibraryBackupService.exportData(from: ctx), decoded = try LibraryBackupService.decode(data)
    XCTAssertEqual(decoded.smartCollections?.first?.query, restored.query)
    let target = try LibraryDatabase.open(inMemory: true)
    let plan = try LibraryImportPlanner.prepare(data, context: target.mainContext)
    _ = try LibraryImportPlanner.apply(plan, choices: [:], context: target.mainContext, undoManager: nil)
    let smart = try target.mainContext.fetch(FetchDescriptor<BookCollection>())
    let books = try target.mainContext.fetch(FetchDescriptor<Book>())
    let notes = try target.mainContext.fetch(FetchDescriptor<LibraryNote>()).map(NoteRecord.init)
    XCTAssertEqual(LibraryQueries.results(books, collections: smart, request: LibraryQueryRequest(selection: .smart(id)), notes: notes).map(\.id), [bookID])
  }

  func testEmptyResultCanBeSavedAndLaterNewBooksAppear() throws {
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    let id = try SmartCollectionService.save(name: "未来阅读", query: query(.tags, "未来"), context: ctx, undoManager: nil)
    let collections = try ctx.fetch(FetchDescriptor<BookCollection>())
    XCTAssertTrue(LibraryQueries.results([], collections: collections, request: LibraryQueryRequest(selection: .smart(id))).isEmpty)
    let book = Book(title: "新书"); ctx.insert(book)
    ctx.insert(BookTag(book: book, tag: Tag(name: "未来"))); try ctx.save()
    XCTAssertEqual(LibraryQueries.results([book], collections: collections, request: LibraryQueryRequest(selection: .smart(id))).map(\.id), [book.id])
  }

  func testRetirementPreservesCombinedSearchWithDefaultName() throws {
    let db = try LibraryDatabase.open(inMemory: true), ctx = db.mainContext
    var restricted = query(.title, "特定标题")
    restricted.rules = [BookSearchRule(field: .bookType, comparison: .equals, value: BookType.chineseOriginal.rawValue)]
    _ = try SmartCollectionService.save(name: BookType.chineseOriginal.title, query: restricted, context: ctx, undoManager: nil)
    let suite = "SavedSearchDefaults." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    let storeID = ctx.container.configurations.map { $0.url.standardizedFileURL.absoluteString }.sorted().joined(separator: "|")
    prefs.set(true, forKey: "bookTypeSmartCollectionsInstalled.v1." + storeID)
    let before = try SmartCollectionService.snapshots(in: ctx)
    try SmartCollectionService.retireBookTypeDefaults(in: ctx, preferences: prefs)
    XCTAssertEqual(try SmartCollectionService.snapshots(in: ctx), before)
  }
}
