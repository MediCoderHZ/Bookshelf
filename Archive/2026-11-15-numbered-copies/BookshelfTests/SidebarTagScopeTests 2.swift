import Foundation
import XCTest
@testable import Bookshelf

@MainActor
final class SidebarTagScopeTests: XCTestCase {
  private func book(_ title: String, tags: [Tag], collection: BookCollection? = nil) -> Book {
    let book = Book(title: title)
    book.tagLinks = tags.map { BookTag(book: book, tag: $0) }
    if let collection { book.collectionItems = [CollectionItem(collection: collection, book: book)] }
    return book
  }

  func testCollectionScopeHonorsSubcollectionsAndExcludesOtherBooksAndTrash() {
    let parent = BookCollection(name: "父书单"), child = BookCollection(name: "子书单")
    child.parentID = parent.id
    let elsewhere = BookCollection(name: "另一书单")
    let parentTag = Tag(name: "父级"), childTag = Tag(name: "子级"), shared = Tag(name: "共同")
    let outsideTag = Tag(name: "其他"), deletedTag = Tag(name: "已删除")
    let direct = book("父级书籍", tags: [parentTag, shared], collection: parent)
    let nested = book("子级书籍", tags: [childTag, shared], collection: child)
    let outside = book("范围外书籍", tags: [outsideTag], collection: elsewhere)
    let deleted = book("删除的书籍", tags: [deletedTag], collection: parent); deleted.deletedAt = Date()
    let books = [direct, nested, outside, deleted], collections = [parent, child, elsewhere]
    var request = LibraryQueryRequest(selection: .collection(parent.id))
    XCTAssertEqual(LibraryQueries.tagBookCounts(in: LibraryQueries.results(books, collections: collections, request: request)),
      [parentTag.id: 1, shared.id: 1])
    request.includeSubcollections = true
    XCTAssertEqual(LibraryQueries.tagBookCounts(in: LibraryQueries.results(books, collections: collections, request: request)),
      [parentTag.id: 1, childTag.id: 1, shared.id: 2])
    request.selection = .collection(elsewhere.id)
    XCTAssertEqual(LibraryQueries.tagBookCounts(in: LibraryQueries.results(books, collections: collections, request: request)),
      [outsideTag.id: 1])
  }

  func testSmartCollectionsAndTrashHaveTheirOwnTagCounts() throws {
    let smart = BookCollection(name: "已读")
    smart.smartRulesJSON = try AdvancedBookQuery(rules: [
      BookSearchRule(field: .favorite, comparison: .equals, value: "true")
    ]).encoded()
    let readTag = Tag(name: "读完"), unreadTag = Tag(name: "待读"), trashTag = Tag(name: "回收站")
    let read = book("读完的书", tags: [readTag]); read.isFavorite = true
    let unread = book("待读的书", tags: [unreadTag])
    let deleted = book("已删除的书", tags: [trashTag]); deleted.isFavorite = true; deleted.deletedAt = Date()
    let books = [read, unread, deleted]
    let smartBooks = LibraryQueries.results(books, collections: [smart], request: LibraryQueryRequest(selection: .smart(smart.id)))
    XCTAssertEqual(LibraryQueries.tagBookCounts(in: smartBooks), [readTag.id: 1])
    let trashBooks = LibraryQueries.results(books, collections: [smart], request: LibraryQueryRequest(selection: .trash))
    XCTAssertEqual(LibraryQueries.tagBookCounts(in: trashBooks), [trashTag.id: 1])
    unread.isFavorite = true
    let updated = LibraryQueries.results(books, collections: [smart], request: LibraryQueryRequest(selection: .smart(smart.id)))
    XCTAssertEqual(LibraryQueries.tagBookCounts(in: updated), [readTag.id: 1, unreadTag.id: 1])
  }

  func testSearchAndTagIntersectionUpdateCandidatesWithoutLosingActiveFilters() {
    let swift = Tag(name: "Swift"), history = Tag(name: "历史"), shared = Tag(name: "共同")
    let tags = [swift, history, shared]
    let books = [book("编程入门", tags: [swift, shared]), book("历史入门", tags: [history, shared])]
    var request = LibraryQueryRequest(text: "编程")
    var counts = LibraryQueries.tagBookCounts(in: LibraryQueries.results(books, collections: [], request: request))
    XCTAssertEqual(LibraryQueries.visibleTags(tags, bookCounts: counts).map(\.id), [swift.id, shared.id])
    request.text = ""; request.tagIDs = [shared.id, history.id]
    counts = LibraryQueries.tagBookCounts(in: LibraryQueries.results(books, collections: [], request: request))
    XCTAssertEqual(LibraryQueries.visibleTags(tags, bookCounts: counts, selectedIDs: request.tagIDs).map(\.id), [history.id, shared.id])
    request.text = "不存在的书名"
    counts = LibraryQueries.tagBookCounts(in: LibraryQueries.results(books, collections: [], request: request))
    XCTAssertTrue(counts.isEmpty)
    XCTAssertEqual(LibraryQueries.visibleTags(tags, bookCounts: counts, selectedIDs: request.tagIDs).map(\.id), [history.id, shared.id])
    XCTAssertTrue(LibraryQueries.visibleTags(tags, bookCounts: counts).isEmpty)
  }

  func testShowAllPreservesGlobalTagsAndSearchWhileCountsTrackLiveUsage() {
    let used = Tag(name: "阅读"), unused = Tag(name: "History")
    let tags = [used, unused]
    let item = book("一本书", tags: [used, used])
    var counts = LibraryQueries.tagBookCounts(in: [item])
    XCTAssertEqual(counts, [used.id: 1])
    XCTAssertEqual(LibraryQueries.visibleTags(tags, bookCounts: counts).map(\.id), [used.id])
    XCTAssertEqual(LibraryQueries.visibleTags(tags, bookCounts: counts, showAll: true).map(\.id), tags.map(\.id))
    XCTAssertEqual(LibraryQueries.visibleTags(tags, bookCounts: counts, showAll: true, text: " history ").map(\.id), [unused.id])
    XCTAssertEqual(counts[unused.id, default: 0], 0)
    item.tagLinks = [BookTag(book: item, tag: unused)]
    counts = LibraryQueries.tagBookCounts(in: [item])
    XCTAssertEqual(LibraryQueries.visibleTags(tags, bookCounts: counts).map(\.id), [unused.id])
    XCTAssertEqual(LibraryQueries.visibleTags(tags, bookCounts: [:], showAll: true).map(\.id), tags.map(\.id))
  }
}
