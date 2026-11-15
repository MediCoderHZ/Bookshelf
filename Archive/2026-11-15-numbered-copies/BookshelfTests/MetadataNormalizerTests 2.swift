import XCTest
import SwiftData

@testable import Bookshelf

final class MetadataNormalizerTests: XCTestCase {
  @MainActor
  func testBackupRoundTripAndRepeatedImportPreserveRelationships() async throws {
    let source = try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = source.mainContext
    let book = Book(title: "备份验收")
    book.notes = "个人笔记"
    book.isFavorite = true
    book.metadataSourceName = "豆瓣图书"
    book.metadataSourceURL = "https://book.douban.com/subject/123456/"
    book.metadataRetrievedAt = Date(timeIntervalSince1970: 1_700_000_000)
    context.insert(book)
    let author = Person(name: "测试作者")
    let tag = Tag(name: "技术")
    context.insert(author)
    context.insert(tag)
    context.insert(Contribution(book: book, person: author, role: .author, displayOrder: 0))
    context.insert(BookTag(book: book, tag: tag))
    for name in ["书单一", "书单二"] {
      let collection = BookCollection(name: name)
      context.insert(collection)
      context.insert(CollectionItem(collection: collection, book: book))
    }
    try context.save()
    let backup = try LibraryBackupService.exportData(from: context)
    let target = try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let first = try LibraryBackupService.importData(backup, into: target.mainContext)
    let second = try LibraryBackupService.importData(backup, into: target.mainContext)
    XCTAssertEqual(first.createdCount, 1)
    XCTAssertEqual(second.updatedCount, 1)
    let savedBooks = try target.mainContext.fetch(FetchDescriptor<Book>())
    XCTAssertEqual(savedBooks.count, 1)
    let saved = try XCTUnwrap(savedBooks.first)
    XCTAssertEqual(saved.notes, "个人笔记")
    XCTAssertTrue(saved.isFavorite)
    XCTAssertEqual(saved.metadataSourceName, book.metadataSourceName)
    XCTAssertEqual(saved.metadataSourceURL, book.metadataSourceURL)
    XCTAssertEqual(saved.metadataRetrievedAt, book.metadataRetrievedAt)
    XCTAssertEqual(saved.authorDisplayName, "测试作者")
    XCTAssertEqual(saved.tagDisplayName, "技术")
    XCTAssertEqual(Set(saved.collectionItems.compactMap(\.collection?.name)), ["书单一", "书单二"])
  }

  @MainActor
  func testBackupFromBeforeTranslatorFeatureStillImports() async throws {
    let source = try ModelContainer(for: Book.self, LibraryNote.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    source.mainContext.insert(Book(title: "旧版书库"))
    try source.mainContext.save()
    let backup = try LibraryBackupService.exportData(from: source.mainContext)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
    var records = try XCTUnwrap(object["books"] as? [[String: Any]])
    for key in ["metadataSourceName", "metadataSourceURL", "metadataRetrievedAt"] {
      records[0].removeValue(forKey: key)
    }
    object["books"] = records
    let target = try ModelContainer(for: Book.self, LibraryNote.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let summary = try LibraryBackupService.importData(try JSONSerialization.data(withJSONObject: object), into: target.mainContext)
    XCTAssertEqual(summary.createdCount, 1)
    let imported = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<Book>()).first)
    XCTAssertEqual(imported.title, "旧版书库")
    XCTAssertNil(imported.metadataSourceURL)
  }

  @MainActor
  func testFailedImportPreservesExistingCoverAndLibrary() async throws {
    let container = try ModelContainer(for: Book.self, LibraryNote.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    let book = Book(title: "保留原封面")
    let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Bookshelf/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-16.png")
    let png = try Data(contentsOf: fixtureURL)
    let cover = try CoverStore.save(png)
    defer { CoverStore.delete(cover) }
    book.coverFileName = cover
    context.insert(book)
    try context.save()
    let backup = try LibraryBackupService.exportData(from: context)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
    let records = try XCTUnwrap(object["books"] as? [[String: Any]])
    var withoutCover = try XCTUnwrap(records.first)
    withoutCover.removeValue(forKey: "coverData")
    withoutCover["title"] = "不应提交的修改"
    var invalid = withoutCover
    invalid["id"] = UUID().uuidString
    invalid["title"] = "损坏图片记录"
    invalid["coverData"] = Data("not an image".utf8).base64EncodedString()
    object["books"] = [withoutCover, invalid]
    let corrupt = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(try LibraryBackupService.importData(corrupt, into: context))
    XCTAssertNotNil(CoverStore.data(for: cover))
    let saved = try context.fetch(FetchDescriptor<Book>())
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved.first?.title, "保留原封面")
    XCTAssertEqual(saved.first?.coverFileName, cover)
  }

  @MainActor
  func testCollectionMembershipIsIdempotentAndPreservesOtherCollections() async throws {
    let container = try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    let book = Book(title: "测试多书单")
    let first = BookCollection(name: "文学")
    let second = BookCollection(name: "今年阅读")
    context.insert(book)
    context.insert(first)
    context.insert(second)
    LibraryOrganization.setMembership(of: book, in: first, included: true, context: context)
    LibraryOrganization.setMembership(of: book, in: second, included: true, context: context)
    LibraryOrganization.setMembership(of: book, in: second, included: true, context: context)
    try context.save()
    XCTAssertEqual(book.collectionItems.count, 2)

    LibraryOrganization.setMembership(of: book, in: first, included: false, context: context)
    try context.save()
    let freshContext = ModelContext(container)
    let saved = try XCTUnwrap(freshContext.fetch(FetchDescriptor<Book>()).first)
    XCTAssertEqual(saved.collectionItems.compactMap(\.collection?.name), ["今年阅读"])
    XCTAssertEqual(try freshContext.fetch(FetchDescriptor<Book>()).count, 1)
    XCTAssertEqual(try freshContext.fetch(FetchDescriptor<CollectionItem>()).count, 1)
  }

  @MainActor
  func testFiltersCombineCollectionTagsAndNormalizedISBN() async throws {
    let container = try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    let book = Book(title: "Designing Books")
    book.isbn13 = "9787572605543"
    let collection = BookCollection(name: "设计")
    let first = Tag(name: "排版")
    let second = Tag(name: "参考")
    context.insert(book)
    context.insert(collection)
    context.insert(first)
    context.insert(second)
    context.insert(BookTag(book: book, tag: first))
    LibraryOrganization.setMembership(of: book, in: collection, included: true, context: context)
    try context.save()
    XCTAssertTrue(LibraryFilter.matches(book, selection: .collection(collection.id),
      tagIDs: [first.id], query: "978-7-5726-0554-3"))
    XCTAssertFalse(LibraryFilter.matches(book, selection: .all,
      tagIDs: [first.id, second.id], query: "Designing"))
    XCTAssertFalse(LibraryFilter.matches(book, selection: .unfiled, tagIDs: [], query: ""))
    context.insert(BookTag(book: book, tag: second))
    try context.save()
    XCTAssertTrue(LibraryFilter.matches(book, selection: .all,
      tagIDs: [first.id, second.id], query: "designing"))
    XCTAssertFalse(LibraryFilter.matches(book, selection: .collection(UUID()), tagIDs: [], query: ""))
  }

  func testISBNNormalization() {
    XCTAssertEqual(ISBN.normalized("978-7-5726-0554-3"), "9787572605543")
    XCTAssertEqual(ISBN.normalized("0-306-40615-X"), "030640615X")
    XCTAssertNil(ISBN.normalized("  "))
  }

  func testContributorParsing() {
    XCTAssertEqual(
      MetadataNormalizer.contributorNames(from: "张三、李四, 王五"),
      ["张三", "李四", "王五"]
    )
  }

  func testNameNormalization() {
    XCTAssertEqual(MetadataNormalizer.normalizedName("  Vibe Coding  "), "vibecoding")
  }

  func testTitleNormalization() {
    XCTAssertEqual(MetadataNormalizer.normalizedTitle("《底层：逻辑》"), "底层逻辑")
  }

  func testMetadataQueryRecognizesISBNAndTitle() {
    XCTAssertEqual(BookMetadataQuery("978-7-5726-0554-3"), .isbn("9787572605543"))
    XCTAssertEqual(BookMetadataQuery("底层逻辑"), .title("底层逻辑"))
    XCTAssertNil(BookMetadataQuery("   "))
  }

  func testOpenLibrarySearchResponseDecoding() throws {
    let data = Data(
      """
      {
        "docs": [
          {
            "key": "/works/OL123W",
            "title": "测试书籍",
            "subtitle": "一个副标题",
            "author_name": ["张三"],
            "publisher": ["测试出版社"],
            "publish_date": ["2025-03"],
            "isbn": ["9787572605543"],
            "number_of_pages_median": 320,
            "language": ["chi"],
            "cover_i": 123
          }
        ]
      }
      """.utf8
    )

    let result = try XCTUnwrap(
      OpenLibraryBookMetadataProvider.decodeSearchResponse(data).first
    )
    XCTAssertEqual(result.title, "测试书籍")
    XCTAssertEqual(result.authors, ["张三"])
    XCTAssertEqual(result.publisher, "测试出版社")
    XCTAssertEqual(result.publicationDate, "2025-03")
    XCTAssertEqual(result.isbn13, "9787572605543")
    XCTAssertEqual(result.pageCount, 320)
    XCTAssertEqual(result.languageCode, "zh-Hans")
  }

  func testDuplicateISBNDetection() {
    let existing = Book(title: "测试书籍")
    existing.isbn13 = "978-7-5726-0554-3"

    let result = DuplicateDetector.firstMatch(
      title: "另一本书",
      isbn: "9787572605543",
      authorNames: [],
      excluding: nil,
      in: [existing]
    )

    XCTAssertEqual(result?.book.id, existing.id)
  }
}
