import AppKit
import XCTest
@testable import Bookshelf

@MainActor
final class NoteEditorPositionTests: XCTestCase {
  private let source = (1...100).map { "第\($0)段：中文📚和 **加粗文字**，用于验证笔记位置。" }.joined(separator: "\n")
  private func defaults() -> UserDefaults {
    let name = "Bookshelf.NoteEditorPositionsTests.\(UUID())"
    addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    return UserDefaults(suiteName: name)!
  }
  private func editor(_ id: UUID, store: NoteEditorPositionStore, source: String? = nil,
    width: CGFloat = 360, startsAtZero: Bool = false) -> (RichNoteTextView, NoteEditorScrollView, NoteEditorPositionTracker) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 260),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NoteEditorScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 260))
    scroll.hasVerticalScroller = true
    let view = RichNoteTextView(frame: startsAtZero ? .zero : NSRect(x: 0, y: 0, width: width, height: 260))
    view.load(source ?? self.source); scroll.documentView = view; window.contentView = scroll
    let tracker = NoteEditorPositionTracker(noteID: id, store: store, scroll: scroll, view: view)
    addTeardownBlock { @MainActor () async throws in tracker.stop(); window.close() }
    scroll.layoutSubtreeIfNeeded(); tracker.restoreAfterLayout()
    return (view, scroll, tracker)
  }
  private func scroll(_ scroll: NSScrollView, to y: CGFloat) {
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
  }

  func testZeroSizedSwiftUIAttachmentLeavesTheDocumentVisibleAtTheTop() {
    let store = NoteEditorPositionStore(defaults: defaults())
    let (view, scroll, _) = editor(UUID(), store: store, startsAtZero: true)
    XCTAssertEqual(view.frame.origin, .zero)
    XCTAssertGreaterThan(view.frame.height, scroll.contentSize.height)
    XCTAssertEqual(view.visibleRect.minY, 0, accuracy: 0.5)
    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.5)
    XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
  }

  func testReturningToNoteRestoresNativeSelectionAndViewportWithoutEditing() throws {
    let store = NoteEditorPositionStore(defaults: defaults()), id = UUID()
    let (view, scroll, tracker) = editor(id, store: store)
    let range = (view.string as NSString).range(of: "第30段")
    view.setSelectedRange(range); self.scroll(scroll, to: 720)
    let expected = try XCTUnwrap(store[id]); tracker.stop()
    let (restored, newScroll, _) = editor(id, store: store)
    var changes = 0; restored.onChange = { _ in changes += 1 }
    XCTAssertEqual(restored.selectedRange(), range)
    XCTAssertEqual(newScroll.contentView.bounds.minY, expected.scrollY, accuracy: 0.5)
    XCTAssertEqual(restored.source, source); XCTAssertEqual(changes, 0)
    XCTAssertFalse(restored.undoManager!.canUndo)
  }

  func testNotesKeepIndependentPositionsAcrossStoreReload() throws {
    let preferences = defaults(), a = UUID(), b = UUID()
    let store = NoteEditorPositionStore(defaults: preferences)
    let (first, firstScroll, firstTracker) = editor(a, store: store)
    first.setSelectedRange(NSRange(location: 10, length: 0)); scroll(firstScroll, to: 420); firstTracker.stop()
    let (second, secondScroll, secondTracker) = editor(b, store: store)
    second.setSelectedRange(NSRange(location: 70, length: 4)); scroll(secondScroll, to: 800); secondTracker.stop()
    let expectedA = try XCTUnwrap(store[a]), expectedB = try XCTUnwrap(store[b])
    let reopened = NoteEditorPositionStore(defaults: preferences)
    XCTAssertEqual(reopened[a], expectedA); XCTAssertEqual(reopened[b], expectedB)
    let (returned, returnedScroll, _) = editor(a, store: reopened)
    XCTAssertEqual(returned.selectedRange(), expectedA.selection(in: returned.string))
    XCTAssertEqual(returnedScroll.contentView.bounds.minY, expectedA.scrollY, accuracy: 0.5)
  }

  func testCaretOutsideViewportDoesNotPullScrollBackWhenRestoredOrFocused() throws {
    let store = NoteEditorPositionStore(defaults: defaults()), id = UUID()
    let (view, scroll, tracker) = editor(id, store: store)
    view.setSelectedRange(NSRange(location: 2, length: 0)); self.scroll(scroll, to: 950); tracker.stop()
    let (returned, newScroll, newTracker) = editor(id, store: store)
    newTracker.focus()
    XCTAssertEqual(returned.selectedRange(), NSRange(location: 2, length: 0))
    XCTAssertEqual(newScroll.contentView.bounds.minY, 950, accuracy: 0.5)
    self.scroll(newScroll, to: 1100)
    XCTAssertEqual(try XCTUnwrap(store[id]).scrollY, 1100, accuracy: 0.5)
  }

  func testRenderedMarkdownOffsetsAndTypingAtRestoredCaret() {
    let store = NoteEditorPositionStore(defaults: defaults()), id = UUID()
    let source = "**前缀**📚正文"
    let (view, _, tracker) = editor(id, store: store, source: source)
    view.setSelectedRange(NSRange(location: 4, length: 0)); tracker.stop()
    let (returned, _, _) = editor(id, store: store, source: source)
    returned.insertText("继续", replacementRange: returned.selectedRange())
    XCTAssertEqual(returned.string, "前缀📚继续正文")
    XCTAssertEqual(returned.source, "**前缀**📚继续正文")
    returned.undoManager?.undo(); XCTAssertEqual(returned.source, source)
  }

  func testShortenedContentClampsSelectionAndScrollAndDoesNotPublishEdit() {
    let store = NoteEditorPositionStore(defaults: defaults()), id = UUID()
    let (view, scroll, tracker) = editor(id, store: store)
    view.setSelectedRange(NSRange(location: 1500, length: 30)); self.scroll(scroll, to: 1200)
    var changes = 0; view.onChange = { _ in changes += 1 }
    tracker.reload("短📚"); tracker.restoreAfterLayout()
    XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.5)
    XCTAssertEqual(changes, 0); XCTAssertEqual(view.source, "短📚")
  }

  func testResizingBeforeInteractionRestoresTheSameVisibleTextAnchor() throws {
    let store = NoteEditorPositionStore(defaults: defaults()), id = UUID()
    let (view, scroll, tracker) = editor(id, store: store, width: 500)
    view.setSelectedRange(NSRange(location: 200, length: 0)); self.scroll(scroll, to: 710); tracker.stop()
    let expected = try XCTUnwrap(store[id])
    let (returned, newScroll, _) = editor(id, store: store, width: 250)
    let manager = try XCTUnwrap(returned.layoutManager)
    let glyph = manager.glyphIndexForCharacter(at: expected.anchor)
    let y = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + returned.textContainerOrigin.y
    XCTAssertEqual(newScroll.contentView.bounds.minY, y + expected.offsetInLine, accuracy: 0.5)
    XCTAssertEqual(returned.selectedRange(), expected.selection(in: returned.string))
  }

  func testIMECompositionDoesNotPersistTransientSelection() throws {
    let store = NoteEditorPositionStore(defaults: defaults()), id = UUID()
    let (view, _, _) = editor(id, store: store, source: "正文")
    view.setSelectedRange(NSRange(location: 2, length: 0))
    let before = try XCTUnwrap(store[id])
    view.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(view.hasMarkedText()); XCTAssertEqual(store[id], before)
    view.unmarkText()
    XCTAssertEqual(store[id]?.location, view.selectedRange().location)
  }

  func testStoppedEditorCannotOverwriteLaterPosition() throws {
    let store = NoteEditorPositionStore(defaults: defaults()), id = UUID()
    let (old, _, tracker) = editor(id, store: store); tracker.stop()
    let (current, _, _) = editor(id, store: store)
    current.setSelectedRange(NSRange(location: 20, length: 0)); let expected = try XCTUnwrap(store[id])
    old.setSelectedRange(NSRange(location: 1, length: 0)); tracker.focus()
    XCTAssertEqual(store[id], expected)
  }

  func testUnicodeAndOutOfRangeSelectionsAreSafe() {
    XCTAssertEqual(NoteEditorPosition(location: 2).selection(in: "中📚文"), NSRange(location: 1, length: 0))
    XCTAssertEqual(NoteEditorPosition(location: 1, length: 1).selection(in: "中📚文"), NSRange(location: 1, length: 2))
    XCTAssertEqual(NoteEditorPosition(location: Int.max, length: Int.max).selection(in: "短"), NSRange(location: 1, length: 0))
    XCTAssertEqual(NoteEditorPosition(location: 1).selection(in: "e\u{301}"), NSRange(location: 0, length: 0))
  }

  func testPreferenceMergeAndPruningPreserveOtherNotesAndSettings() {
    let defaults = defaults(), a = UUID(), b = UUID()
    defaults.set("keep", forKey: "other")
    let first = NoteEditorPositionStore(defaults: defaults), second = NoteEditorPositionStore(defaults: defaults)
    first.remember(NoteEditorPosition(location: 4, scrollY: 150), for: a); first.flush()
    second.remember(NoteEditorPosition(location: 9, scrollY: 350), for: b); second.flush()
    let reopened = NoteEditorPositionStore(defaults: defaults)
    XCTAssertEqual(reopened[a]?.location, 4); XCTAssertEqual(reopened[b]?.location, 9)
    reopened.retain(noteIDs: [b])
    let pruned = NoteEditorPositionStore(defaults: defaults)
    XCTAssertNil(pruned[a]); XCTAssertEqual(pruned[b]?.location, 9)
    XCTAssertEqual(defaults.string(forKey: "other"), "keep")
  }

  func testCorruptPreferencesAndInvalidPositionsFallBackAndFocusDoesNotReplay() {
    let defaults = defaults(), id = UUID(), token = UUID()
    defaults.set(Data("bad".utf8), forKey: NoteEditorPositionStore.storageKey)
    let store = NoteEditorPositionStore(defaults: defaults)
    XCTAssertNil(store[id])
    store.remember(NoteEditorPosition(scrollY: .infinity), for: id); XCTAssertNil(store[id])
    store.remember(NoteEditorPosition(location: NSNotFound), for: id); XCTAssertNil(store[id])
    XCTAssertTrue(store.consumeFocus(token)); XCTAssertFalse(store.consumeFocus(token))
    XCTAssertTrue(store.consumeFocus(UUID()))
  }
}
