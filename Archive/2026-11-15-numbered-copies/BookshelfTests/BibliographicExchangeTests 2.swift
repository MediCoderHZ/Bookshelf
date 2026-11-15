import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class BibliographicExchangeTests: XCTestCase {
  private func parse(_ text: String) throws -> RISImportResult { try BibliographicExchange.decodeRIS(Data(text.utf8)) }
  private func ris(_ title: String, fields: String = "", type: String = "BOOK") -> String {
    "TY  - \(type)\nTI  - \(title)\n\(fields)ER  - \n"
  }
  private func container() throws -> ModelContainer {
    try ModelContainer(for: Book.self, LibraryNote.self, BookCollection.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
  }

  func testImportsBookFieldsCreatorsAndProvenance() throws {
    let result = try parse(ris("测试图书", fields: """
      AU  - Doe, Jane
      AU  - 张三
      A4  - 李四
      A2  - 编辑甲
      PB  - 测试出版社
      DA  - 2024/03/15/
      PY  - 2024
      SN  - 978-0-306-40615-7
      SN  - 0-306-40615-2
      SP  - 320
      ET  - 第 2 版
      LA  - zh
      AB  - 简介
      N1  - <p>原始笔记</p>
      KW  - 科学
      KW  - 科学
      T2  - 科学丛书
      VL  - 2
      UR  - https://example.org/book

      """))
    let book = try XCTUnwrap(result.records.first)
    XCTAssertEqual(book.title, "测试图书"); XCTAssertEqual(book.publisher, "测试出版社")
    XCTAssertEqual(book.publicationDate, "2024-03-15"); XCTAssertEqual(book.pageCount, 320)
    XCTAssertEqual(book.isbn13, "9780306406157"); XCTAssertEqual(book.isbn10, "0306406152")
    XCTAssertEqual(book.contributors.filter { $0.roleRaw == "author" }.map(\.name), ["Doe, Jane", "张三"])
    XCTAssertEqual(book.contributors.filter { $0.roleRaw == "translator" }.map(\.name), ["李四"])
    XCTAssertEqual(book.contributors.filter { $0.roleRaw == "editor" }.map(\.name), ["编辑甲"])
    XCTAssertEqual(book.notes, "<p>原始笔记</p>"); XCTAssertEqual(book.tags, ["科学"])
    XCTAssertEqual(book.seriesMemberships.first?.volumeLabel, "2")
    XCTAssertEqual(BookRecordMerge.origins(book)["publisher"]?.name, "RIS 文件导入")
    XCTAssertNil(BookRecordMerge.origins(book)["publisher"]?.inferred)
    XCTAssertTrue(result.notices.isEmpty)
  }

  func testBOMUTF16CRLFAndMultilineValues() throws {
    let input = "\u{FEFF}TY  - EBOOK\r\nT1  - 中文书\r\nAB  - 第一行\r\n第二行\r\nN1  - 甲\r\n      乙\r\nER  - \r\n"
    for data in [Data(input.utf8), try XCTUnwrap(input.data(using: .utf16))] {
      let book = try XCTUnwrap(BibliographicExchange.decodeRIS(data).records.first)
      XCTAssertEqual(book.title, "中文书"); XCTAssertEqual(book.bookDescription, "第一行\n第二行")
      XCTAssertEqual(book.notes, "甲\n乙")
    }
  }

  func testAliasesAndDatePriority() throws {
    let book = try XCTUnwrap(parse("TY  - EDBOOK\nT1  - 别名\nA1  - 作者\nA3  - 编辑\nY1  - 2022/05//\nPY  - 2021\nN2  - 摘要\nRN  - 笔记\nT3  - 丛书\nER  -\n").records.first)
    XCTAssertEqual(book.publicationDate, "2022-05"); XCTAssertEqual(book.bookDescription, "摘要")
    XCTAssertEqual(book.notes, "笔记"); XCTAssertEqual(book.seriesMemberships.first?.seriesName, "丛书")
    XCTAssertFalse(book.isFavorite)
  }

  func testUnsupportedTypesMissingTitlesAndUnknownFieldsAreReported() throws {
    let result = try parse(ris("文章", type: "JOUR") + ris("章节", type: "CHAP") + ris("") + ris("保留", fields: "L1  - file:///private/secret.pdf\nDO  - 10.1/example\n"))
    XCTAssertEqual(result.totalCount, 4); XCTAssertEqual(result.records.map(\.title), ["保留"])
    XCTAssertEqual(result.notices.count, 4)
    XCTAssertTrue(result.notices.last?.contains("L1") == true)
    XCTAssertNil(result.records.first?.coverData)
  }

  func testMalformedInputRejectsWholeFile() throws {
    for input in ["TI  - 无记录\n", "TY  - BOOK\nTI  - 缺结束\n", "TY  - BOOK\nTY  - BOOK\nER  -\n", "ER  -\n", "任意文本", ""] {
      XCTAssertThrowsError(try parse(input))
    }
    XCTAssertThrowsError(try parse(ris("完整") + "TY  - BOOK\nTI  - 截断"))
    XCTAssertThrowsError(try BibliographicExchange.decodeRIS(Data([0xFF,0xFF])))
    XCTAssertThrowsError(try parse(ris("含\0空字节")))
    XCTAssertThrowsError(try parse(ris("只有文章", type: "JOUR")))
  }

  func testImportLimitsRejectOversizedFilesAndTooManyRecords() throws {
    XCTAssertThrowsError(try BibliographicExchange.decodeRIS(Data(repeating: 65, count: BibliographicExchange.maximumImportBytes + 1)))
    XCTAssertThrowsError(try parse(String(repeating: ris("数量限制"), count: BibliographicExchange.maximumImportRecords + 1)))
  }

  func testInvalidISBNPagesAndUnsafeURLsRemainEmptyWithNotices() throws {
    let bookResult = try parse(ris("无效字段", fields: "SN  - 9780306406158\nSP  - 10-20\nUR  - file:///tmp/secret\n"))
    let book = bookResult.records[0]
    XCTAssertNil(book.isbn13); XCTAssertNil(book.isbn10); XCTAssertNil(book.pageCount); XCTAssertNil(book.metadataSourceURL)
    XCTAssertEqual(bookResult.notices.count, 3)
    let authenticated = try parse(ris("带凭据网址", fields: "UR  - https://name:password@example.org/book\n"))
    XCTAssertNil(authenticated.records[0].metadataSourceURL)
  }

  func testMultipleISBNVersionsPreserveOnlyTheFirstEdition() throws {
    let result = try parse(ris("多版本", fields: "SN  - 9780306406157; 9780743273565\nSN  - 0306406152\n"))
    XCTAssertEqual(result.records[0].isbn13, "9780306406157")
    XCTAssertEqual(result.records[0].isbn10, "0306406152")
    XCTAssertEqual(result.notices.count, 1)
  }

  func testRISExportRoundTripAndNotesOptIn() throws {
    var original = BookArchive(book: Book(title: "原书名")); original.subtitle = "副标题"
    original.publisher = "出版社"; original.notes = "私密笔记"; original.bookDescription = "多行\n简介"
    original.isbn10 = "0306406152"; original.publicationDate = "2024-03"; original.pageCount = 234
    original.contributors = [ContributorArchive(name: "作者", role: .author, order: 0), ContributorArchive(name: "译者", role: .translator, order: 0)]
    original.tags = ["文学", "科学"]
    let normal = BibliographicExchange.export([original], format: .ris)
    XCTAssertFalse(String(decoding: normal, as: UTF8.self).contains("私密笔记"))
    let restored = try XCTUnwrap(BibliographicExchange.decodeRIS(normal).records.first)
    XCTAssertEqual(restored.title, "原书名: 副标题"); XCTAssertEqual(restored.publisher, original.publisher)
    XCTAssertEqual(restored.bookDescription, original.bookDescription); XCTAssertEqual(restored.pageCount, original.pageCount)
    XCTAssertEqual(restored.tags, original.tags); XCTAssertEqual(restored.contributors, original.contributors)
    XCTAssertEqual(restored.isbn10, original.isbn10); XCTAssertEqual(restored.publicationDate, original.publicationDate)
    let withNotes = BibliographicExchange.export([original], format: .ris, includeNotes: true)
    XCTAssertEqual(try BibliographicExchange.decodeRIS(withNotes).records.first?.notes, original.notes)
  }

  func testNewlinesCannotInjectRISRecordsDuringExport() throws {
    var original = BookArchive(book: Book(title: "合法\nER  -\nTY  - BOOK\nTI  - 注入"))
    original.notes = "笔记\r\nER  -\rTY  - JOUR\nTI  - 另一本\nER  -"
    let decoded = try BibliographicExchange.decodeRIS(BibliographicExchange.export([original], format: .ris, includeNotes: true))
    XCTAssertEqual(decoded.records.count, 1)
    XCTAssertEqual(decoded.records[0].title, original.title)
    XCTAssertTrue(decoded.records[0].notes?.contains("TY  - JOUR") == true)
  }

  func testCSVQuotesUnicodeNewlinesAndNotesOptIn() {
    var original = BookArchive(book: Book(title: "中文,\"书\"")); original.isbn10 = "0306406152"
    original.bookDescription = "第一行\n第二行"; original.isFavorite = true; original.notes = "个人秘密"
    let csv = String(decoding: BibliographicExchange.export([original], format: .csv), as: UTF8.self)
    XCTAssertTrue(csv.hasPrefix("\u{FEFF}")); XCTAssertTrue(csv.contains("\"中文,\"\"书\"\"\""))
    XCTAssertTrue(csv.contains("\"第一行\n第二行\"")); XCTAssertTrue(csv.contains("\"'0306406152\""))
    XCTAssertTrue(csv.contains("\"是\"")); XCTAssertFalse(csv.contains("个人秘密")); XCTAssertFalse(csv.contains("个人笔记"))
    let opted = String(decoding: BibliographicExchange.export([original], format: .csv, includeNotes: true), as: UTF8.self)
    XCTAssertTrue(opted.contains("个人秘密")); XCTAssertTrue(opted.contains("个人笔记"))
  }

  func testCSVFormulaPrefixesAreEscapedWithoutUsingFormulasForISBN() {
    for text in ["=1+1", "+SUM(A1)", "-1+2", "@test", "  =HYPERLINK(\"url\")", "\ttext", "＝1+1"] {
      XCTAssertTrue(BibliographicExchange.csvCell(text).hasPrefix("\"'"))
    }
    XCTAssertEqual(BibliographicExchange.csvCell("普通文字"), "\"普通文字\"")
    XCTAssertEqual(BibliographicExchange.csvCell("0306406152", forceText: true), "\"'0306406152\"")
  }

  func testCSVRetiresStatusAndRatingWithoutShiftingOtherValues() {
    var record = BookArchive(book: Book(title: "导出验证"))
    record.isFavorite = true
    record.metadataSourceURL = "https://example.com/book"; record.notes = "笔记"
    for includeNotes in [false, true] {
      let csv = String(decoding: BibliographicExchange.export([record], format: .csv, includeNotes: includeNotes), as: UTF8.self)
      let lines = csv.components(separatedBy: "\r\n")
      let headers = lines[0].components(separatedBy: ","), values = lines[1].components(separatedBy: ",")
      XCTAssertEqual(headers.count, includeNotes ? 20 : 19); XCTAssertEqual(values.count, headers.count)
      XCTAssertFalse(csv.contains("阅读状态")); XCTAssertFalse(csv.contains("在读"))
      XCTAssertFalse(csv.contains("评分"))
      XCTAssertEqual(headers[15], "\"收藏\""); XCTAssertEqual(values[15], "\"是\"")
      XCTAssertEqual(values[16], "\"https://example.com/book\"")
    }
  }

  func testExportHonorsSuppliedSelectionAndExcludesTrash() throws {
    let a = BookArchive(book: Book(title: "所选"))
    var trash = BookArchive(book: Book(title: "回收站")); trash.deletedAt = Date()
    for format in BibliographicFormat.allCases {
      let text = String(decoding: BibliographicExchange.export([a,trash], format: format), as: UTF8.self)
      XCTAssertTrue(text.contains("所选")); XCTAssertFalse(text.contains("回收站"))
    }
  }

  func testRISImportConflictPreviewAndUndoRedoUseExistingSafetyRules() throws {
    let c = try container(), ctx = c.mainContext
    let original = Book(title: "原书"); original.isbn13 = "9780306406157"; original.notes = "原笔记"; original.isFavorite = true
    ctx.insert(original); try ctx.save()
    let before = BookArchive(book: original)
    let input = ris("外部书名", fields: "SN  - 9780306406157\nPB  - 外部出版社\nN1  - 导入笔记\n") + ris("全新书")
    let plan = try LibraryImportPlanner.prepareRIS(Data(input.utf8), context: ctx)
    XCTAssertTrue(plan.isRIS); XCTAssertEqual(plan.items[0].defaultChoice.action, .skip)
    XCTAssertEqual(plan.items[1].defaultChoice.action, .add); XCTAssertEqual(BookArchive(book: original), before)
    let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
    let summary = try LibraryImportPlanner.apply(plan, choices: [plan.items[0].id: ImportChoice(action: .fill, targetID: original.id)], context: ctx, undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertEqual(summary.createdCount, 1); XCTAssertEqual(summary.updatedCount, 1)
    XCTAssertEqual(original.title, "原书"); XCTAssertEqual(original.publisher, "外部出版社")
    XCTAssertTrue(original.isFavorite); XCTAssertTrue(original.notes?.contains("原笔记") == true)
    XCTAssertTrue(original.notes?.contains("导入笔记") == true); XCTAssertEqual(undo.undoActionName, "导入 RIS 书目")
    undo.undo(); XCTAssertEqual(BookArchive(book: original), before); XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 1)
    undo.redo(); XCTAssertEqual(original.publisher, "外部出版社"); XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 2)
    XCTAssertNil(LibraryServices.forContext(ctx).history.errorMessage)
  }

  func testRISDuplicatesWithinFileAndStaleUpdatesAreProtected() throws {
    let c = try container(), ctx = c.mainContext
    let book = Book(title: "本地"); book.isbn10 = "0306406152"; ctx.insert(book); try ctx.save()
    let input = ris("来自外部", fields: "SN  - 9780306406157\n") + ris("来自外部", fields: "SN  - 9780306406157\n")
    let plan = try LibraryImportPlanner.prepareRIS(Data(input.utf8), context: ctx)
    XCTAssertTrue(plan.items[1].repeatedInFile)
    book.notes = "预览后的修改"; try ctx.save()
    XCTAssertThrowsError(try LibraryImportPlanner.apply(plan, choices: [plan.items[0].id: ImportChoice(action: .update, targetID: book.id)], context: ctx, undoManager: nil))
    XCTAssertEqual(book.notes, "预览后的修改"); XCTAssertEqual(try ctx.fetch(FetchDescriptor<Book>()).count, 1)
  }
}
