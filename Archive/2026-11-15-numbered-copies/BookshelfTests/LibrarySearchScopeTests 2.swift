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
    let parent = BookCollection(name: "父书单"), child = BookCollection(name: "子书单"); child.parentID = parent.id
    let tag = Tag(name: "参考"), book = Book(title: "目标"), outside = Book(title: "范围外")
    for item in [book, outside] { contribute("王兴", role: .author, to: item) }
    book.collectionItems = [CollectionItem(collection: child, book: book)]
    book.tagLinks = [BookTag(book: book, tag: tag)]
    var request = LibraryQueryRequest(selection: .collection(parent.id), tagIDs: [tag.id], text: "王兴", searchScope: .author)
    XCTAssertTrue(LibraryQueries.results([book, outside], collections: [parent, child], request: request).isEmpty)
    request.includeSubcollections = true
    XCTAssertEqual(LibraryQueries.results([book, outside], collections: [parent, child], request: request).map(\.id), [book.id])
    let smart = BookCollection(name: "已读")
    smart.smartRulesJSON = try AdvancedBookQuery(rules: [BookSearchRule(field: .favorite, comparison: .equals, value: "true")]).encoded()
    request.selection = .smart(smart.id)
    XCTAssertTrue(LibraryQueries.results([book], collections: [smart], request: request).isEmpty)
    book.isFavorite = true
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
    let collection = ManualCollectionRecord(name: "笔记书单")
    var note = NoteRecord(title: "标题"); note.body = "正文关键词"; note.tags = ["参考"]; note.collectionIDs = [collection.id]
    XCTAssertTrue(NoteQueries.results([note], books: [], collections: [collection], scope: .collection(collection.id), text: "正文关键词", searchScope: .title).isEmpty)
    XCTAssertEqual(NoteQueries.results([note], books: [], collections: [collection], scope: .collection(collection.id), text: "参考", searchScope: .tags).map(\.id), [note.id])
    note.deletedAt = Date()
    XCTAssertTrue(NoteQueries.results([note], books: [], collections: [], scope: .all, text: "参考", searchScope: .tags).isEmpty)
    XCTAssertEqual(NoteQueries.results([note], books: [], collections: [], scope: .trash, text: "参考", searchScope: .tags).map(\.id), [note.id])
  }
}
