import AppKit
import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class MarkdownNoteTests: XCTestCase {
  func testAutomaticNameUsesFirstContentLineWithoutMarkdown() {
    XCTAssertEqual(NoteMarkdown.title(from: "\n# **读书**与[思考](https://example.com)\n第二行"), "读书与思考")
    XCTAssertEqual(NoteMarkdown.title(from: "---\n> - [x] 阅读完成"), "阅读完成")
    XCTAssertEqual(NoteMarkdown.title(from: "```swift\nlet a = 1\n```"), "let a = 1")
    XCTAssertEqual(NoteMarkdown.title(from: " \n\n"), "新笔记")
    XCTAssertEqual(NoteMarkdown.title(from: String(repeating: "📚", count: 90)).count, 80)
  }

  func testBlankNamePersistsAndKeepsFollowingBodyWhileCustomNameIsPreserved() throws {
    let db = try LibraryDatabase.open(inMemory: true), context = db.mainContext
    let commands = NoteCommands(context: context, undoManager: nil)
    var note = try commands.save(NoteRecord(), expected: nil)
    XCTAssertEqual(note.title, ""); XCTAssertEqual(note.displayTitle, "新笔记")
    var edit = note; edit.body = "## 第一行\n正文"
    note = try commands.save(edit, expected: note)
    XCTAssertEqual(note.title, ""); XCTAssertEqual(note.displayTitle, "第一行")
    edit = note; edit.body = "**修改后的首行**\n正文"
    note = try commands.save(edit, expected: note)
    XCTAssertEqual(note.displayTitle, "修改后的首行")
    XCTAssertTrue(NoteQueries.matches(note, text: "修改后的首行"))
    edit = note; edit.title = "旧笔记的自定义名称"
    note = try commands.save(edit, expected: note)
    edit = note; edit.body = "替换正文"
    note = try commands.save(edit, expected: note)
    XCTAssertEqual(note.displayTitle, "旧笔记的自定义名称")
    edit = note; edit.title = "  "
    note = try commands.save(edit, expected: note)
    XCTAssertEqual(note.displayTitle, "替换正文")
    XCTAssertEqual(try OrganizationStore.notes(in: context)[note.id]?.title, "")
  }

  func testUntitledMarkdownBackupRoundTripAndTrashUndo() throws {
    let db = try LibraryDatabase.open(inMemory: true), other = try LibraryDatabase.open(inMemory: true)
    let undo = UndoManager(); undo.groupsByEvent = false
    let commands = NoteCommands(context: db.mainContext, undoManager: undo)
    var draft = NoteRecord(); draft.body = "# 中文 📚\n\n- **重点**\n\n```swift\nlet a = 1\n```"
    undo.beginUndoGrouping(); let saved = try commands.save(draft, expected: nil); undo.endUndoGrouping()
    let data = try LibraryBackupService.exportData(from: db.mainContext)
    let decoded = try LibraryBackupService.decode(data)
    XCTAssertEqual(decoded.libraryNotes?.first?.title, "")
    XCTAssertEqual(decoded.libraryNotes?.first?.body, draft.body)
    _ = try LibraryBackupService.importData(data, into: other.mainContext)
    let imported = try XCTUnwrap(OrganizationStore.notes(in: other.mainContext).values.first)
    XCTAssertEqual(imported.body, draft.body); XCTAssertEqual(imported.displayTitle, "中文 📚")
    undo.beginUndoGrouping(); try commands.setTrashed(true, expected: saved); undo.endUndoGrouping()
    undo.undo()
    XCTAssertEqual(try OrganizationStore.notes(in: db.mainContext)[saved.id], saved)
    undo.undo(); XCTAssertTrue(try OrganizationStore.notes(in: db.mainContext).isEmpty)
    undo.redo(); XCTAssertEqual(try OrganizationStore.notes(in: db.mainContext)[saved.id], saved)
  }

  func testPreviewPreservesInlineFormattingAndBlockHierarchy() throws {
    let blocks = NoteMarkdown.blocks(from: "# **标题**\n\n正文与 *斜体*、~~删除~~、`代码`。\n\n1. 一\n2. 二\n   - 子项\n\n> 引用\n\n```swift\nlet a = 1\n```\n\n---")
    XCTAssertEqual(blocks.first?.heading, 1)
    XCTAssertTrue(try XCTUnwrap(blocks.first?.text.runs.first?.inlinePresentationIntent).contains(.stronglyEmphasized))
    XCTAssertEqual(blocks.compactMap(\.marker), ["1.", "2.", "•"])
    XCTAssertTrue(blocks.contains { $0.listDepth == 2 })
    XCTAssertTrue(blocks.contains { $0.quoteDepth == 1 })
    XCTAssertEqual(blocks.first(where: \.code).map { String($0.text.characters) }, "let a = 1\n")
    XCTAssertTrue(blocks.last?.rule == true)
  }

  func testTaskPreviewAndLinksDoNotLoadImagesOrExecuteURLs() {
    let blocks = NoteMarkdown.blocks(from: "- [ ] 未完成\n- [x] 完成\n\n[正常](https://example.com) [危险](javascript:alert) ![图片](https://example.com/a.png)\n\n<script>alert(1)</script>")
    XCTAssertEqual(blocks.prefix(2).compactMap(\.marker), ["☐", "☑"])
    XCTAssertEqual(String(blocks[0].text.characters), "未完成")
    let runs = blocks.flatMap { Array($0.text.runs) }
    XCTAssertEqual(runs.compactMap(\.link).map(\.scheme), ["https"])
    XCTAssertTrue(runs.compactMap(\.imageURL).isEmpty)
    XCTAssertTrue(blocks.contains { String($0.text.characters).contains("<script>") })
  }

}
