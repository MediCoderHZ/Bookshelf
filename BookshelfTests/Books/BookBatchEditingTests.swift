import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class BookBatchEditingTests: XCTestCase {
  private func container() throws -> ModelContainer {
    try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
  }
  private func record(_ title: String = "批量验收") -> BookArchive { BookArchive(book: Book(title: title)) }
  private func prepare(_ records: [BookArchive], _ draft: BookBatchEditDraft) throws -> BookBatchEditPlan {
    try BookBatchEditing.prepare(records, draft: draft)
  }

  func testDefaultDraftPreservesEveryFieldWithoutChanges() throws {
    var original = record(); original.publisher = "原出版社"
    original.metadataSourceName = "历史来源"; original.notes = "原笔记"; original.tags = ["文学"]
    let plan = try prepare([original], BookBatchEditDraft())
    XCTAssertTrue(plan.changedItems.isEmpty); XCTAssertEqual(plan.items[0].after, original)
  }

  func testFillOnlyChangesBlankValuesAndLeavesUnchangedTimestamp() throws {
    var a = record("空白"), b = record("已有")
    a.publisher = " \n"; b.publisher = "已有出版社"
    var draft = BookBatchEditDraft()
    draft.metadata[.publisher] = BatchTextChange(mode: .fill, value: " 新出版社 ")
    let plan = try prepare([a,b], draft)
    XCTAssertEqual(plan.changedItems.count, 1)
    XCTAssertEqual(plan.items[0].after.publisher, "新出版社")
    XCTAssertEqual(plan.items[1].after, b)
  }

  func testReplaceAndExplicitClearAreSeparateFromEmptyInput() throws {
    var original = record(); original.publisher = "旧出版社"; original.publicationDate = "2000"; original.edition = "第 1 版"
    var draft = BookBatchEditDraft()
    draft.metadata[.publisher] = BatchTextChange(mode: .replace, value: " \n")
    XCTAssertThrowsError(try prepare([original], draft))
    draft.metadata[.publisher] = BatchTextChange(mode: .replace, value: " 新出版社 ")
    draft.metadata[.publicationDate] = BatchTextChange(mode: .clear)
    draft.metadata[.language] = BatchTextChange(mode: .fill, value: "zh")
    let result = try prepare([original], draft).items[0]
    XCTAssertEqual(result.after.publisher, "新出版社"); XCTAssertNil(result.after.publicationDate)
    XCTAssertEqual(result.after.languageCode, "zh"); XCTAssertEqual(result.after.edition, original.edition)
    XCTAssertEqual(Set(result.differences.map(\.id)), ["publisher", "publicationDate", "language"])
  }

  func testTagUnionAndRemovalRespectNormalizedNamesAndCanonicalSpelling() throws {
    var a = record("甲"), b = record("乙"); a.tags = ["历史", "旧标签"]; b.tags = ["文学"]
    var draft = BookBatchEditDraft(); draft.tagsToAdd = "历史、ＣＡＦÉ, cafe，文学"
    draft.tagsToRemove = [MetadataNormalizer.normalizedName("旧标签")]
    let plan = try BookBatchEditing.prepare([a,b], draft: draft, knownTagNames: ["Café", "历史", "文学"])
    XCTAssertEqual(Set(plan.items[0].after.tags), ["历史", "Café", "文学"])
    XCTAssertEqual(Set(plan.items[1].after.tags), ["历史", "Café", "文学"])
    XCTAssertEqual(plan.items[1].after.tags.count, 3)
    XCTAssertEqual(plan.items[0].differences.first?.label, "标签")
  }

  func testConflictingAndEmptyTagsRejectPreview() throws {
    var draft = BookBatchEditDraft(); draft.tagsToAdd = "ＣＡＦÉ"
    draft.tagsToRemove = [MetadataNormalizer.normalizedName("cafe")]
    XCTAssertThrowsError(try prepare([record()], draft))
    draft.tagsToRemove = []; draft.tagsToAdd = "、，，；"
    XCTAssertThrowsError(try prepare([record()], draft))
  }

  func testOnlyChangedMetadataFieldsReceiveManualProvenance() throws {
    var original = record(); original.publisher = "旧出版社"; original.publicationDate = "2020"
    original.metadataSourceName = "豆瓣"; original.metadataSourceURL = "https://book.douban.com/subject/1/"
    var draft = BookBatchEditDraft(); draft.tagsToAdd = "阅读"
    let organized = try prepare([original], draft).items[0].after
    XCTAssertNil(organized.metadataFieldSourcesJSON)
    draft.metadata[.publisher] = BatchTextChange(mode: .replace, value: "新出版社")
    let changed = try prepare([original], draft).items[0].after
    let origins = BookRecordMerge.origins(changed)
    XCTAssertEqual(origins["publisher"]?.name, "手动编辑")
    XCTAssertNil(origins["publisher"]?.url)
    XCTAssertEqual(origins["publicationDate"]?.name, "豆瓣")
    XCTAssertEqual(changed.metadataSourceURL, original.metadataSourceURL)
  }

  func testEmptyDuplicateAndTrashedSelectionsAreRejected() throws {
    let original = record()
    XCTAssertThrowsError(try prepare([], BookBatchEditDraft()))
    XCTAssertThrowsError(try prepare([original,original], BookBatchEditDraft()))
    var deleted = original; deleted.deletedAt = Date()
    XCTAssertThrowsError(try prepare([deleted], BookBatchEditDraft()))
  }

  func testApplyUndoRedoPreserveNotesContributorsAndCollections() throws {
    let c = try container(), ctx = c.mainContext
    let a = Book(title: "甲"), b = Book(title: "乙"), untouched = Book(title: "未选中")
    a.notes = "重要笔记"; a.isbn13 = "9780306406157"; a.metadataSourceName = "已有来源"
    for book in [a,b,untouched] { ctx.insert(book) }
    let person = Person(name: "作者"), collection = BookCollection(name: "普通文件夹")
    ctx.insert(person); ctx.insert(collection)
    ctx.insert(Contribution(book: a, person: person, role: .author, displayOrder: 0))
    LibraryOrganization.setMembership(of: a, in: collection, included: true, context: ctx)
    try ctx.save()
    let before = LibraryHistory.snapshots([a,b]), other = BookArchive(book: untouched)
    var draft = BookBatchEditDraft(); draft.tagsToAdd = "批量标签"
    draft.metadata[.publisher] = BatchTextChange(mode: .fill, value: "出版社")
    let plan = try prepare([a,b].map { BookArchive(book: $0) }, draft)
    let undo = UndoManager(); undo.groupsByEvent = false
    undo.beginUndoGrouping(); XCTAssertEqual(try BookBatchEditing.apply(plan, context: ctx, undoManager: undo), 2); undo.endUndoGrouping()
    XCTAssertEqual(a.publisher, "出版社"); XCTAssertEqual(b.tagDisplayName, "批量标签")
    XCTAssertEqual(a.notes, "重要笔记"); XCTAssertEqual(a.authorDisplayName, "作者")
    XCTAssertEqual(a.collectionItems.first?.collection?.name, "普通文件夹")
    XCTAssertEqual(BookArchive(book: untouched), other)
    let after = LibraryHistory.snapshots([a,b])
    undo.undo(); XCTAssertEqual(LibraryHistory.snapshots([a,b]), before)
    undo.redo(); XCTAssertEqual(LibraryHistory.snapshots([a,b]), after)
    XCTAssertEqual(BookArchive(book: untouched), other)
    XCTAssertNil(LibraryServices.forContext(ctx).history.errorMessage)
  }

  func testConcurrentChangeAbortsWholeBatchAndPreservesNewEdits() throws {
    let c = try container(), ctx = c.mainContext
    let a = Book(title: "甲"), b = Book(title: "乙"); ctx.insert(a); ctx.insert(b); try ctx.save()
    var draft = BookBatchEditDraft()
    draft.metadata[.publisher] = BatchTextChange(mode: .replace, value: "新出版社")
    let plan = try prepare([a,b].map { BookArchive(book: $0) }, draft)
    b.notes = "另一个窗口的新笔记"; try ctx.save()
    XCTAssertThrowsError(try BookBatchEditing.apply(plan, context: ctx, undoManager: nil))
    XCTAssertNil(a.publisher); XCTAssertNil(b.publisher)
    XCTAssertEqual(b.notes, "另一个窗口的新笔记")
  }

  func testNoOpDoesNotChangeDatesOrAddUndoHistory() throws {
    let c = try container(), ctx = c.mainContext, undo = UndoManager()
    let book = Book(title: "无需修改"); book.publisher = "已有"; ctx.insert(book); try ctx.save()
    let before = BookArchive(book: book)
    var draft = BookBatchEditDraft(); draft.metadata[.publisher] = BatchTextChange(mode: .fill, value: "新值")
    let plan = try prepare([before], draft)
    XCTAssertEqual(try BookBatchEditing.apply(plan, context: ctx, undoManager: undo), 0)
    XCTAssertEqual(BookArchive(book: book), before); XCTAssertFalse(undo.canUndo)
  }

  func testTagRemovalLeavesOtherBooksAndTrashUnchanged() throws {
    let c = try container(), ctx = c.mainContext
    var a = record("所选"), b = record("其他"), trash = record("回收站")
    a.tags = ["共享标签", "保留标签"]; b.tags = a.tags; trash.tags = a.tags
    trash.deletedAt = Date()
    try LibraryBackupService.apply([a,b,trash], into: ctx)
    let books = try ctx.fetch(FetchDescriptor<Book>())
    let selected = try XCTUnwrap(books.first { $0.id == a.id })
    let other = try XCTUnwrap(books.first { $0.id == b.id }), deleted = try XCTUnwrap(books.first { $0.id == trash.id })
    let untouched = LibraryHistory.snapshots([other,deleted])
    var draft = BookBatchEditDraft(); draft.tagsToRemove = [MetadataNormalizer.normalizedName("共享标签")]
    let plan = try prepare([BookArchive(book: selected)], draft)
    try BookBatchEditing.apply(plan, context: ctx, undoManager: nil)
    XCTAssertEqual(selected.tagDisplayName, "保留标签")
    XCTAssertEqual(LibraryHistory.snapshots([other,deleted]), untouched)
  }

  func testBatchUpdatesSmartCollectionMatchesAndSurvivesBackup() throws {
    let c = try container(), ctx = c.mainContext
    let book = Book(title: "动态查询"); ctx.insert(book); try ctx.save()
    let query = AdvancedBookQuery(rules: [BookSearchRule(field: .tag, comparison: .equals, value: "已整理")])
    _ = try SmartCollectionService.save(name: "已整理", query: query, context: ctx, undoManager: nil)
    XCTAssertFalse(query.matches(book))
    var draft = BookBatchEditDraft(); draft.tagsToAdd = "已整理"
    try BookBatchEditing.apply(prepare([BookArchive(book: book)], draft), context: ctx, undoManager: nil)
    XCTAssertTrue(query.matches(book))
    let target = try container()
    _ = try LibraryBackupService.importData(LibraryBackupService.exportData(from: ctx), into: target.mainContext)
    let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<Book>()).first)
    XCTAssertTrue(query.matches(restored))
  }

  func testUnchangedRelationshipIdentityAndOrderingSurviveBatchAndUndo() throws {
    let c = try container(), ctx = c.mainContext
    let book = Book(title: "关系保留"), author = Person(name: "作者"), list = BookCollection(name: "文件夹"), series = BookSeries(name: "丛书")
    ctx.insert(book); ctx.insert(author); ctx.insert(list); ctx.insert(series)
    let contributor = Contribution(book: book, person: author, role: .author, displayOrder: 3)
    let membership = CollectionItem(collection: list, book: book, sortOrder: 42)
    let volume = SeriesMembership(series: series, book: book, volumeLabel: "第三册", displayOrder: 7)
    let date = Date(timeIntervalSince1970: 1_000_000); membership.addedAt = date
    ctx.insert(contributor); ctx.insert(membership); ctx.insert(volume); try ctx.save()
    var draft = BookBatchEditDraft(); draft.tagsToAdd = "新标签"
    draft.metadata[.publisher] = BatchTextChange(mode: .replace, value: "出版社")
    let plan = try prepare([BookArchive(book: book)], draft)
    let undo = UndoManager(); undo.groupsByEvent = false
    undo.beginUndoGrouping(); try BookBatchEditing.apply(plan, context: ctx, undoManager: undo); undo.endUndoGrouping()
    for shouldUndo in [false, true] {
      if shouldUndo { undo.undo() }
      XCTAssertEqual(book.contributions.first?.id, contributor.id)
      XCTAssertEqual(book.collectionItems.first?.id, membership.id)
      XCTAssertEqual(book.collectionItems.first?.addedAt, date)
      XCTAssertEqual(book.collectionItems.first?.sortOrder, 42)
      XCTAssertEqual(book.seriesMemberships.first?.id, volume.id)
      XCTAssertEqual(book.seriesMemberships.first?.displayOrder, 7)
    }
  }
}
