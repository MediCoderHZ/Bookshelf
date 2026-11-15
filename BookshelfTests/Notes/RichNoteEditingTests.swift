import AppKit
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class RichNoteEditingTests: XCTestCase {
  private func editor(_ source: String = "") -> RichNoteTextView {
    let view = RichNoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
    view.load(source); view.setSelectedRange(NSRange(location: view.attributedString().length, length: 0))
    return view
  }
  private func type(_ value: String, in view: RichNoteTextView) {
    for character in value {
      if character == "\n" { view.insertNewline(nil) }
      else { view.insertText(String(character), replacementRange: view.selectedRange()) }
    }
  }
  private func flag(_ key: NSAttributedString.Key, in view: RichNoteTextView, at location: Int = 0) -> Bool {
    view.attributedString().attribute(key, at: location, effectiveRange: nil) as? Bool == true
  }
  func testOpeningExistingMarkdownDoesNotRewriteOrSaveIt() {
    let source = "## 名称\n\n**内容**与 [链接](https://example.com/a)\n"
    let view = editor(source); var writes = 0; view.onChange = { _ in writes += 1 }
    view.unmarkText()
    XCTAssertEqual(view.source, source); XCTAssertEqual(writes, 0)
    XCTAssertEqual(view.string, "名称\n\n内容与 链接\n")
    XCTAssertEqual(RichNoteBlock(attributes: view.attributedString().attributes(at: 0, effectiveRange: nil)).kind, "heading")
    XCTAssertFalse(view.undoManager!.canUndo)
  }
  func testTypedHeadingConvertsAndReturnStartsNormalParagraph() {
    let view = editor()
    type("# ", in: view)
    XCTAssertEqual(view.string, ""); XCTAssertEqual(RichNoteBlock(attributes: view.typingAttributes).kind, "heading")
    type("中文📚", in: view)
    XCTAssertEqual(view.string, "中文📚"); XCTAssertEqual(view.source, "# 中文📚")
    view.insertNewline(nil); type("正文", in: view)
    XCTAssertEqual(view.source, "# 中文📚\n正文")
    XCTAssertEqual(RichNoteBlock(attributes: view.typingAttributes).kind, "plain")
  }
  func testBoldInputRuleHasIndependentUndoAndRedoAndKeepsLiteralOnReopen() {
    let view = editor(); type("**中文📚**", in: view)
    XCTAssertEqual(view.string, "中文📚"); XCTAssertTrue(flag(.noteBold, in: view))
    XCTAssertEqual(view.source, "**中文📚**")
    view.undoManager?.undo()
    XCTAssertEqual(view.string, "**中文📚**"); XCTAssertFalse(flag(.noteBold, in: view))
    XCTAssertEqual(editor(view.source).string, "**中文📚**")
    view.undoManager?.redo()
    XCTAssertEqual(view.string, "中文📚"); XCTAssertTrue(flag(.noteBold, in: view))
    type("后续", in: view)
    XCTAssertFalse(flag(.noteBold, in: view, at: 4))
  }
  func testInlineRulesCoverItalicStrikeCodeAndLinks() {
    for (source, visible, key) in [("*斜体*", "斜体", NSAttributedString.Key.noteItalic),
      ("~~删去~~", "删去", .noteStrike), ("`代码`", "代码", .noteInlineCode)] {
      let view = editor(); type(source, in: view)
      XCTAssertEqual(view.string, visible); XCTAssertTrue(flag(key, in: view))
      XCTAssertEqual(editor(view.source).string, visible)
    }
    let link = editor(); type("[链接](https://example.com)", in: link)
    XCTAssertEqual(link.string, "链接")
    XCTAssertEqual(link.attributedString().attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
  }
  func testListContinuationExitAndTaskConversion() {
    let view = editor(); type("1. 一", in: view)
    XCTAssertEqual(view.string, "1.\t一")
    view.insertNewline(nil); type("二", in: view)
    XCTAssertEqual(view.source, "1. 一\n2. 二")
    view.insertNewline(nil); view.insertNewline(nil); type("正文", in: view)
    XCTAssertEqual(view.source, "1. 一\n2. 二\n正文")
    let task = editor(); type("- [x] 已读", in: task)
    XCTAssertEqual(task.string, "☑\t已读"); XCTAssertEqual(task.source, "- [x] 已读")
    task.insertNewline(nil); XCTAssertTrue(task.string.hasSuffix("☐\t"))
  }
  func testCodeFenceIsEditableAndDoesNotInterpretInlineMarkers() {
    let view = editor(); type("```swift", in: view); view.insertNewline(nil)
    type("let a = \"**字面量**\"", in: view)
    XCTAssertEqual(view.string, "let a = \"**字面量**\"")
    XCTAssertEqual(view.source, "```swift\nlet a = \"**字面量**\"\n```")
    view.insertNewline(nil); view.insertNewline(nil); type("正文", in: view)
    XCTAssertTrue(view.source.hasSuffix("```\n正文"))
  }
  func testToolbarFormatsVisibleSelectionAndUndoDoesNotCrossNotes() {
    let view = editor("前缀📚中文后缀"), other = editor("另一条笔记")
    view.setSelectedRange((view.string as NSString).range(of: "📚中文")); view.apply(.bold)
    XCTAssertEqual(view.string, "前缀📚中文后缀"); XCTAssertTrue(flag(.noteBold, in: view, at: 2))
    XCTAssertEqual(view.source, "前缀**📚中文**后缀")
    view.undoManager?.undo(); XCTAssertFalse(flag(.noteBold, in: view, at: 2))
    view.undoManager?.redo(); XCTAssertTrue(flag(.noteBold, in: view, at: 2))
    XCTAssertFalse(other.undoManager!.canUndo)
    view.apply(.heading(2)); XCTAssertTrue(view.source.hasPrefix("## "))
    view.apply(.heading(0)); XCTAssertFalse(view.source.hasPrefix("#"))
  }
  func testPasteMarkdownRendersAndStoresAllSupportedBlocks() {
    let source = "# 标题\n\n段落 **重点**和*强调*与~~删除~~。\n\n- 清单\n  - 子项\n- [x] 任务\n\n> 引用\n\n```swift\nlet a = `1`\n```\n\n![图片](https://example.com/a.png)\n<script>literal</script>"
    let view = editor(); view.insertMarkdown(source)
    XCTAssertFalse(view.string.contains("**")); XCTAssertTrue(view.string.contains("•\t清单"))
    XCTAssertTrue(view.string.contains("☑\t任务")); XCTAssertTrue(view.string.contains("│\t引用"))
    let reopened = editor(view.source)
    XCTAssertEqual(reopened.string, view.string)
    XCTAssertTrue(view.source.contains("https://example.com/a.png")); XCTAssertTrue(view.string.contains("<script>"))
    view.undoManager?.undo(); XCTAssertEqual(view.string, "")
  }
  func testLinkEditingAndUnsafeLinksPreserveTextWithoutExecutableAttributes() {
    let view = editor("[原文](javascript:alert) ![图片](https://example.com/a.png)")
    XCTAssertNil(view.attributedString().attribute(.link, at: 0, effectiveRange: nil))
    view.setSelectedRange(NSRange(location: 0, length: 2))
    view.setLink("https://example.com", range: view.selectedRange(), label: "")
    XCTAssertTrue(view.source.contains("[原文](https://example.com)"))
    view.setLink(nil, range: view.selectedRange(), label: "")
    XCTAssertFalse(view.source.contains("javascript:")); XCTAssertTrue(view.source.contains("![图片]"))
  }
  func testCompositionDoesNotTransformUntilCommitted() {
    let view = editor()
    view.setMarkedText("**组合**", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(view.string, "**组合**")
    XCTAssertTrue(view.hasMarkedText())
    view.unmarkText()
    XCTAssertEqual(view.string, "组合"); XCTAssertFalse(view.hasMarkedText())
  }
  func testNestedFormattingAndEmojiSurviveSerialization() {
    let view = editor("**前*📚中*后**")
    view.setSelectedRange(NSRange(location: view.attributedString().length, length: 0))
    type("。", in: view)
    let reopened = editor(view.source)
    XCTAssertEqual(reopened.string, view.string)
    XCTAssertTrue(flag(.noteBold, in: reopened, at: 0))
    XCTAssertTrue(flag(.noteItalic, in: reopened, at: 1))
    XCTAssertTrue(flag(.noteBold, in: reopened, at: 4))
  }
  func testSplittingHeadingAndBackspacingListProduceNormalText() {
    let view = editor("# 标题正文")
    view.setSelectedRange(NSRange(location: 2, length: 0)); view.insertNewline(nil)
    XCTAssertEqual(view.source, "# 标题\n正文")
    let list = editor("- 条目")
    list.setSelectedRange(NSRange(location: 2, length: 0)); list.deleteBackward(nil)
    XCTAssertEqual(list.string, "条目"); XCTAssertEqual(list.source, "条目")
  }
  func testPastingIntoAnEmptyHeadingRetainsItsParagraphStyle() {
    let view = editor(); type("## ", in: view); view.insertMarkdown("中文标题")
    XCTAssertEqual(view.source, "## 中文标题")
    XCTAssertEqual(RichNoteBlock(attributes: view.attributedString().attributes(at: 0, effectiveRange: nil)).level, 2)
  }
  func testIncompleteDestinationsAreNotLinks() {
    XCTAssertNil(RichNoteCodec.safeLink("https://"))
    XCTAssertNil(RichNoteCodec.safeLink("mailto:"))
    XCTAssertNil(RichNoteCodec.safeLink("javascript:alert(1)"))
    XCTAssertNotNil(RichNoteCodec.safeLink("https://example.com/books"))
  }
  func testPastingCodeKeepsLiteralMarkdownAndNewlines() {
    let view = editor(); type("```", in: view); view.insertNewline(nil)
    view.insertMarkdown("**literal**\n# code")
    XCTAssertEqual(view.string, "**literal**\n# code")
    XCTAssertEqual(view.source, "```\n**literal**\n# code\n```")
  }
  func testRuleWaitsForReturnSoTypingAsterisksDoesNotEraseText() {
    let view = editor(); type("***", in: view)
    XCTAssertEqual(view.string, "***")
    view.insertNewline(nil)
    XCTAssertEqual(view.string, "────────\n"); XCTAssertEqual(view.source, "---\n")
    view.undoManager?.undo(); XCTAssertEqual(view.string, "***")
  }
  func testRichEditsAutosaveThroughExistingSessionAndBackup() throws {
    let db = try LibraryDatabase.open(inMemory: true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = NoteEditingSession(recovery: NoteDraftRecoveryStore(directory: directory))
    let note = try NoteCommands(context: db.mainContext, undoManager: nil).save(NoteRecord(), expected: nil)
    let state = session.open(note), view = editor()
    view.onChange = { source in session.update(state, context: db.mainContext, undoManager: nil) { $0.value.body = source } }
    type("# 阅读\n", in: view)
    view.insertMarkdown("**重点**与[书籍](https://example.com)")
    let saved = try XCTUnwrap(OrganizationStore.notes(in: db.mainContext)[note.id])
    XCTAssertEqual(saved.body, view.source); XCTAssertEqual(saved.displayTitle, "阅读")
    let archive = try LibraryBackupService.decode(LibraryBackupService.exportData(from: db.mainContext))
    XCTAssertEqual(archive.libraryNotes?.first?.body, saved.body)
    XCTAssertEqual(editor(saved.body).string, view.string)
  }
}
