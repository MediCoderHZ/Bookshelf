import Foundation
import XCTest
@testable import Bookshelf

@MainActor
final class LibraryReviewTests: XCTestCase {
  private func book(_ title: String, isbn: String? = nil, authors: [String] = []) -> Book {
    let book = Book(title: title)
    book.isbn13 = isbn
    book.contributions = authors.enumerated().map {
      Contribution(book: book, person: Person(name: $0.element), role: .author, displayOrder: $0.offset)
    }
    return book
  }

  func testISBNGroupsJoinAliasesAcrossDifferentTitlesAndExcludeTrash() throws {
    let a = book("第一种题名", isbn: "9780306406157")
    let b = book("另一种题名"); b.isbn10 = "0306406152"
    let c = book("已删除", isbn: a.isbn13); c.deletedAt = Date()
    let group = try XCTUnwrap(DuplicateDetector.groups(in: [a,b,c]).first)
    XCTAssertEqual(group.bookIDs, [a.id,b.id])
    XCTAssertEqual(group.reasons, [.isbn])
    XCTAssertFalse(group.requiresVersionReview)
  }

  func testKnownDifferentEditionsDoNotBecomeADuplicateGroup() {
    let a = book("同名书", isbn: "9780306406157", authors: ["作者"])
    let b = book("同名书", isbn: "9780743273565", authors: ["作者"])
    XCTAssertTrue(DuplicateDetector.groups(in: [a,b]).isEmpty)
  }

  func testMissingISBNBridgeCannotMakeDifferentEditionsMergeable() throws {
    let a = book("同名书", isbn: "9780306406157", authors: ["作者"])
    let b = book("同名书", isbn: "9780743273565", authors: ["作者"])
    let unknown = book("同名书", authors: ["作者"])
    let groups = DuplicateDetector.groups(in: [a,b,unknown])
    XCTAssertEqual(groups.count, 1)
    let group = try XCTUnwrap(groups.first)
    XCTAssertEqual(group.bookIDs, [a.id,b.id,unknown.id])
    XCTAssertTrue(group.requiresVersionReview)
    XCTAssertEqual(group.reasons, [.titleAndAuthor])
  }

  func testTitleOnlyEvidenceIsExplicitAndDistinctAuthorsStaySeparate() throws {
    let a = book("共同书名"), b = book("共同书名")
    let c = book("共同书名", authors: ["甲"]), d = book("共同书名", authors: ["乙"])
    let groups = DuplicateDetector.groups(in: [a,b,c,d])
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].bookIDs, [a.id,b.id])
    XCTAssertEqual(groups[0].reasons, [.titleOnly])
  }

  func testAuthorOverlapGroupsHaveStableIDsAndMembership() throws {
    let a = book("共同作品", authors: ["作者甲","作者乙"])
    let b = book("共同作品", authors: ["作者乙"])
    let c = book("独立作品"), d = book("独立作品")
    let first = DuplicateDetector.groups(in: [a,b,c,d])
    let reversed = DuplicateDetector.groups(in: [d,c,b,a])
    XCTAssertEqual(first.map(\.id), reversed.map(\.id))
    XCTAssertEqual(first.map(\.bookIDs), reversed.map(\.bookIDs))
    XCTAssertEqual(Set(first.map(\.bookIDs)), [Set([a.id,b.id]), Set([c.id,d.id])])
  }

  func testLargeLibraryFindsOnlyIntendedGroup() {
    let unique = (0..<2_000).map { book("独立书籍 \($0)") }
    let duplicates = (0..<200).map { _ in book("重复书籍", isbn: "9780306406157") }
    let groups = DuplicateDetector.groups(in: unique + duplicates)
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups.first?.bookIDs, Set(duplicates.map(\.id)))
  }

  func testClickingEitherDuplicateResolvesTheCompleteGroupAmongOtherGroups() throws {
    let a = book("A"), b = book("A"), c = book("B"), d = book("B")
    let groups = DuplicateDetector.groups(in: [a, b, c, d])
    for id in [a.id, b.id] {
      XCTAssertEqual(DuplicateSelection.group(for: [id], previous: [], in: groups)?.bookIDs, [a.id, b.id])
    }
    XCTAssertEqual(DuplicateSelection.group(for: [c.id], previous: [a.id, b.id], in: groups)?.bookIDs, [c.id, d.id])
  }

  func testCommandSelectingAnotherGroupReplacesRatherThanCombinesGroups() {
    let a = book("A"), b = book("A"), c = book("B"), d = book("B")
    let groups = DuplicateDetector.groups(in: [a, b, c, d])
    let resolved = DuplicateSelection.group(for: [a.id, b.id, c.id], previous: [a.id, b.id], in: groups)
    XCTAssertEqual(resolved?.bookIDs, [c.id, d.id])
    XCTAssertNil(DuplicateSelection.group(for: [a.id, c.id], previous: [], in: groups))
  }

  func testGroupSelectionSurvivesReselectAndClearsWithoutPickingAnArbitraryGroup() {
    let a = book("A"), b = book("A")
    let groups = DuplicateDetector.groups(in: [a, b])
    XCTAssertEqual(DuplicateSelection.group(for: [a.id, b.id], previous: [a.id, b.id], in: groups)?.bookIDs, [a.id, b.id])
    XCTAssertEqual(DuplicateSelection.group(for: [a.id], previous: [a.id, b.id], in: groups)?.bookIDs, [a.id, b.id])
    XCTAssertNil(DuplicateSelection.group(for: [], previous: [a.id, b.id], in: groups))
    XCTAssertNil(DuplicateSelection.group(for: [a.id, UUID()], previous: [], in: groups))
    XCTAssertNil(DuplicateSelection.group(for: [a.id], previous: [], in: []))
  }

  func testGroupSelectionIncludesHiddenMembersButRetainsVersionConflict() throws {
    let a = book("同名书", isbn: "9780306406157")
    let b = book("同名书", isbn: "9780743273565")
    let unknown = book("同名书")
    let groups = DuplicateDetector.groups(in: [a, b, unknown])
    let selected = try XCTUnwrap(DuplicateSelection.group(for: [unknown.id], previous: [], in: groups))
    XCTAssertEqual(selected.bookIDs, [a.id, b.id, unknown.id])
    XCTAssertTrue(selected.requiresVersionReview)
    b.deletedAt = Date()
    XCTAssertEqual(DuplicateSelection.group(for: [a.id], previous: selected.bookIDs,
      in: DuplicateDetector.groups(in: [a, b, unknown]))?.bookIDs, [a.id, unknown.id])
  }

  func testMergePreviewIgnoresBlankAndRepeatedValuesAndAutofillsPrimary() {
    let primary = book("同名书"), source = book("同名书"), repeated = book("同名书")
    primary.publisher = " \n "; source.publisher = "出版社"; repeated.publisher = "出版社"
    source.subtitle = "补全的副标题"
    let a = BookArchive(book: primary), b = BookArchive(book: source), c = BookArchive(book: repeated)
    XCTAssertEqual(BookRecordMerge.fieldCandidates(.title, in: [a,b,c]).map(\.id), [a.id])
    XCTAssertEqual(BookRecordMerge.fieldCandidates(.publisher, in: [a,b,c]).map(\.id), [b.id])
    XCTAssertTrue(BookRecordMerge.fieldCandidates(.edition, in: [a,b,c]).isEmpty)
    let merged = BookRecordMerge.combine(primary: a, others: [b,c])
    XCTAssertEqual(merged.publisher, "出版社")
    XCTAssertEqual(merged.subtitle, "补全的副标题")
    XCTAssertEqual(primary.publisher, " \n ", "A preview must not change its source records")
  }

  func testMergePreviewOffersEachConflictingNonblankValueOnceAndHonorsChoice() {
    let a = book("同名书"), b = book("同名书"), duplicate = book("同名书"), blank = book("同名书")
    a.publisher = "出版社甲"; b.publisher = "出版社乙"; duplicate.publisher = " 出版社甲 "
    let records = [a,b,duplicate,blank].map { BookArchive(book: $0) }
    XCTAssertEqual(BookRecordMerge.fieldCandidates(.publisher, in: records).map(\.id), [a.id,b.id])
    let chosen = BookRecordMerge.combine(primary: records[0], others: Array(records.dropFirst()), choices: [.publisher:b.id])
    XCTAssertEqual(chosen.publisher, "出版社乙")
    let newPrimary = [records[1], records[0], records[2], records[3]]
    XCTAssertEqual(BookRecordMerge.fieldCandidates(.publisher, in: newPrimary).map(\.id), [b.id,a.id])
  }

  func testManualMergeChoicesSurviveEveryPrimaryWhileUntouchedFieldsFollowIt() {
    let a = book("同名书"), b = book("同名书"), c = book("同名书")
    a.publisher = "出版社甲"; a.publicationDate = "2020"; a.pageCount = 100
    b.publisher = "出版社乙"; b.publicationDate = "2021"; b.pageCount = 200
    c.publisher = "出版社甲"; c.publicationDate = "2022"; c.pageCount = 300
    a.subtitle = "自动补全的副标题"
    let records = [a,b,c].map { BookArchive(book: $0) }
    // Choosing the initial primary's default is still an explicit choice.
    let choices: [BookField: UUID] = [.publisher:a.id, .pageCount:b.id]
    for primary in records {
      let merged = BookRecordMerge.combine(primary: primary, others: records.filter { $0.id != primary.id }, choices: choices)
      XCTAssertEqual(merged.id, primary.id)
      XCTAssertEqual(merged.publisher, "出版社甲")
      XCTAssertEqual(merged.pageCount, 200)
      XCTAssertEqual(merged.publicationDate, primary.publicationDate)
      XCTAssertEqual(merged.subtitle, "自动补全的副标题")
    }
  }

  func testManualMergeSourceRemainsInDeduplicatedCandidatesAfterPrimaryChanges() {
    let chosen = book("同名书"), newPrimary = book("同名书"), alternative = book("同名书")
    chosen.publisher = "出版社甲"; newPrimary.publisher = "出版社甲"; alternative.publisher = "出版社乙"
    let records = [newPrimary,alternative,chosen].map { BookArchive(book: $0) }
    XCTAssertEqual(BookRecordMerge.fieldCandidates(.publisher, in: records).map(\.id), [newPrimary.id,alternative.id])
    XCTAssertEqual(BookRecordMerge.fieldCandidates(.publisher, in: records, preferredID: chosen.id).map(\.id), [chosen.id,alternative.id])
  }

  func testMergePreviewTreatsEquivalentISBNFormsAsOneValueButKeepsEditionConflicts() {
    let a = book("同名书"), b = book("同名书", isbn: "9780306406157")
    a.isbn10 = "0306406152"
    let other = book("同名书", isbn: "9780743273565")
    let records = [a,b,other].map { BookArchive(book: $0) }
    XCTAssertEqual(BookRecordMerge.fieldCandidates(.isbn, in: Array(records.prefix(2))).map(\.id), [a.id])
    XCTAssertEqual(BookRecordMerge.fieldCandidates(.isbn, in: records).map(\.id), [a.id,other.id])
    XCTAssertTrue(BookRecordMerge.differentEditions(records[0], records[2]))
  }

  func testMergePreviewDistinguishesOrderedNamesFromAnIdenticalJoinedDisplay() {
    let a = book("同名书", authors: ["甲", "乙"])
    let b = book("同名书", authors: ["甲、乙"])
    let c = book("同名书", authors: ["乙", "甲"])
    let records = [a,b,c].map { BookArchive(book: $0) }
    XCTAssertEqual(BookField.authors.value(in: records[0]), BookField.authors.value(in: records[1]))
    XCTAssertEqual(BookRecordMerge.fieldCandidates(.authors, in: records).map(\.id), [a.id,b.id,c.id])
    XCTAssertTrue(BookRecordMerge.fieldCandidates(.translators, in: records).isEmpty)
  }

  func testFreshLookupHasExplicitFieldOriginsAndNoOriginForMissingValues() {
    let result = BookMetadataSearchResult(id: "sample", title: "来源验收", subtitle: nil, authors: ["作者"],
      publisher: "出版社", publicationDate: "2026-11", isbn10: nil, isbn13: nil, pageCount: nil,
      languageCode: nil, sourceName: "示例来源", sourceURL: URL(string: "https://example.com/book/1"))
    let record = BookArchive(metadata: result)
    let sources = BookRecordMerge.origins(record)
    XCTAssertEqual(sources["publisher"]?.name, "示例来源")
    XCTAssertNotNil(sources["publisher"]?.retrievedAt)
    XCTAssertNotEqual(sources["publisher"]?.inferred, true)
    XCTAssertNil(sources["pageCount"])
    XCTAssertNil(sources["cover"])
  }

  func testLegacySourceRemainsMarkedAsInferredAfterSerialization() {
    let book = book("旧书")
    book.publisher = "原出版社"; book.metadataSourceName = "旧来源"
    var record = BookArchive(book: book)
    let legacy = BookRecordMerge.origins(record)
    XCTAssertEqual(legacy["publisher"]?.inferred, true)
    record.metadataFieldSourcesJSON = BookRecordMerge.encodeOrigins(legacy)
    XCTAssertEqual(BookRecordMerge.origins(record)["publisher"]?.inferred, true)
  }

  func testOlderPerFieldSourceJSONRemainsReadable() {
    var record = BookArchive(book: book("旧来源记录"))
    record.metadataFieldSourcesJSON = #"{"title":{"name":"已记录来源","url":"https://example.com/book/1"}}"#
    let origin = BookRecordMerge.origins(record)["title"]
    XCTAssertEqual(origin?.name, "已记录来源")
    XCTAssertNil(origin?.inferred)
  }

  func testManualChangeClearsOnlyChangedFieldSourceAndKeepsLegacyFlagElsewhere() {
    let book = book("原书名")
    book.publisher = "原出版社"; book.metadataSourceName = "旧来源"
    let baseline = BookArchive(book: book)
    var edited = baseline; edited.publisher = "手动修正"
    let result = BookRecordMerge.markingManualChanges(edited, comparedTo: baseline)
    let sources = BookRecordMerge.origins(result)
    XCTAssertEqual(sources["publisher"]?.name, "手动编辑")
    XCTAssertNil(sources["publisher"]?.url)
    XCTAssertNotEqual(sources["publisher"]?.inferred, true)
    XCTAssertEqual(sources["title"]?.name, "旧来源")
    XCTAssertEqual(sources["title"]?.inferred, true)
    XCTAssertEqual(result.notes, baseline.notes)
  }
}
