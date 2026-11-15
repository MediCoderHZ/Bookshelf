import Foundation
import XCTest
@testable import Bookshelf

@MainActor
final class InspectorReadingPositionTests: XCTestCase {
  private func snapshot(offset: CGFloat = 0, viewport: CGFloat = 300,
    heights: [CGFloat] = [600, 280, 220, 160]) -> InspectorScrollGeometry {
    var sections: [InspectorPanel: CGRect] = [:]
    var y: CGFloat = 0
    for (panel, height) in zip(InspectorPanel.allCases, heights) {
      sections[panel] = CGRect(x: 0, y: y - offset, width: 330, height: height)
      y += height + 1
    }
    return InspectorScrollGeometry(sections: sections,
      content: CGRect(x: 0, y: -offset, width: 330, height: y), viewportHeight: viewport)
  }

  private func position(_ offset: CGFloat, active: InspectorPanel = .notes) -> InspectorReadingPosition {
    InspectorReadingPosition(geometry: snapshot(offset: offset), activePanel: active,
      expandedPanels: Set(InspectorPanel.allCases))!
  }

  private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "Bookshelf.InspectorPositionsTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }

  func testRestoresExactPositionInsideASectionAndHighlight() {
    let saved = position(710)
    XCTAssertEqual(saved.section, .notes)
    XCTAssertEqual(saved.offset(in: snapshot()), 710, accuracy: 0.01)
    XCTAssertEqual(saved.highlightedPanel(in: snapshot(offset: 710)), .notes)
  }

  func testChangesAboveTheBookmarkKeepTheSamePositionWithinItsSection() {
    let saved = position(710)
    // The information section grows by 200 points; stay on the same part of the notes.
    XCTAssertEqual(saved.offset(in: snapshot(heights: [800, 280, 220, 160])), 910, accuracy: 0.01)
  }

  func testRemovedContentAndLargerViewportClampToAvailableRange() {
    let saved = position(900, active: .collections)
    let short = snapshot(viewport: 500, heights: [32, 32, 32, 32])
    XCTAssertEqual(saved.offset(in: short), 0)
    let removed = snapshot(heights: [600, 32, 32, 160])
    XCTAssertLessThanOrEqual(saved.offset(in: removed), removed.maximumOffset)
  }

  func testBottomBookmarkStaysAtBottomAfterResize() {
    let saved = position(964, active: .tags)
    XCTAssertTrue(saved.atBottom)
    let resized = snapshot(viewport: 500)
    XCTAssertEqual(saved.offset(in: resized), resized.maximumOffset)
  }

  func testInitialWindowLayoutKeepsRestoringUntilMeasuredOffsetMatches() {
    var restoration = InspectorPositionRestoration(position: position(710))
    XCTAssertEqual(restoration.update(snapshot()), .scroll(to: 710))
    // A provisional window layout lands short of the requested offset.
    XCTAssertEqual(restoration.update(snapshot(offset: 312)), .scroll(to: 710))
    XCTAssertEqual(restoration.update(snapshot(offset: 710)), .settled(.notes))
    XCTAssertEqual(restoration.update(snapshot(offset: 720)), .userScrolled)
  }

  func testLateLayoutChangesReanchorBeforeUserScrollingTakesOver() {
    var restoration = InspectorPositionRestoration(position: position(710))
    XCTAssertEqual(restoration.update(snapshot(offset: 710)), .settled(.notes))
    XCTAssertEqual(restoration.update(snapshot(offset: 710, heights: [800, 280, 220, 160])), .scroll(to: 910))
    XCTAssertEqual(restoration.update(snapshot(offset: 910, heights: [800, 280, 220, 160])), .settled(.notes))
    XCTAssertEqual(restoration.update(snapshot(offset: 920, heights: [800, 280, 220, 160])), .userScrolled)
  }

  func testShortInspectorRetainsAnExplicitVisibleNavigationSelection() {
    let geometry = snapshot(viewport: 500, heights: [32, 32, 32, 32])
    let saved = InspectorReadingPosition(geometry: geometry, activePanel: .tags, expandedPanels: [])!
    XCTAssertFalse(saved.atBottom)
    XCTAssertEqual(saved.offset(in: geometry), 0)
    XCTAssertEqual(saved.highlightedPanel(in: geometry), .tags)
    XCTAssertTrue(saved.expandedPanels.isEmpty)
  }

  func testBooksKeepIndependentPositionsExpansionAndHighlightAcrossReload() {
    withDefaults { defaults in
      let first = UUID(), second = UUID(), store = InspectorReadingPositionStore(defaults: defaults)
      var a = position(710), b = position(900, active: .collections)
      a.expandedPanels = [.info, .notes]; b.expandedPanels = [.info, .collections, .tags]
      store.remember(a, for: first); store.remember(b, for: second)
      XCTAssertEqual(store[first], a); XCTAssertEqual(store[second], b)
      store.flush()
      let reopened = InspectorReadingPositionStore(defaults: defaults)
      XCTAssertEqual(reopened[first], a); XCTAssertEqual(reopened[second], b)
    }
  }

  func testOldNavigationRequestIsNotReplayedWhenReturningToABook() {
    withDefaults { defaults in
      let store = InspectorReadingPositionStore(defaults: defaults), request = UUID(), book = UUID()
      XCTAssertTrue(store.consumeNavigation(request))
      store.remember(position(710), for: book) // Scroll elsewhere after clicking the rail.
      XCTAssertTrue(store.hasHandledNavigation(request))
      XCTAssertFalse(store.consumeNavigation(request))
      XCTAssertEqual(store[book]?.offset(in: snapshot()), 710)
      XCTAssertTrue(store.consumeNavigation(UUID()))
      store.flush()
    }
  }

  func testWindowsMergeChangesWithoutDroppingOtherBooks() {
    withDefaults { defaults in
      let a = UUID(), b = UUID()
      let first = InspectorReadingPositionStore(defaults: defaults), second = InspectorReadingPositionStore(defaults: defaults)
      first.remember(position(710), for: a); first.flush()
      second.remember(position(900), for: b); second.flush()
      let reopened = InspectorReadingPositionStore(defaults: defaults)
      XCTAssertNotNil(reopened[a]); XCTAssertNotNil(reopened[b])
    }
  }

  func testPurgedBookBookmarksAreRemovedWithoutTouchingOtherPreferences() {
    withDefaults { defaults in
      defaults.set("keep", forKey: "unrelated")
      let a = UUID(), b = UUID(), store = InspectorReadingPositionStore(defaults: defaults)
      store.remember(position(710), for: a); store.remember(position(900), for: b); store.flush()
      store.retain(bookIDs: [a])
      let reopened = InspectorReadingPositionStore(defaults: defaults)
      XCTAssertNotNil(reopened[a]); XCTAssertNil(reopened[b])
      XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }
  }

  func testInvalidPreferencesAndNonFinitePositionsFallBackSafely() {
    withDefaults { defaults in
      defaults.set(Data("invalid".utf8), forKey: InspectorReadingPositionStore.storageKey)
      let store = InspectorReadingPositionStore(defaults: defaults), book = UUID()
      XCTAssertNil(store[book])
      var invalid = position(710); invalid.offsetInSection = .nan
      store.remember(invalid, for: book)
      XCTAssertNil(store[book]); XCTAssertEqual(invalid.offset(in: snapshot()), 0)
      XCTAssertNil(InspectorReadingPosition(geometry: InspectorScrollGeometry(), activePanel: .info, expandedPanels: []))
    }
  }
}
