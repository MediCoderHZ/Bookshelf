import Foundation
import XCTest
@testable import Bookshelf

final class InspectorScrollTrackingTests: XCTestCase {
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

  func testScrollingBothDirectionsTracksTheSectionAtTheViewportTop() {
    var tracking = InspectorScrollTracking()
    XCTAssertEqual(tracking.update(snapshot(), activePanel: .tags), .info)
    XCTAssertEqual(tracking.update(snapshot(offset: 590), activePanel: .info), .notes)
    XCTAssertEqual(tracking.update(snapshot(offset: 870), activePanel: .notes), .collections)
    XCTAssertEqual(tracking.update(snapshot(offset: 590), activePanel: .collections), .notes)
    XCTAssertEqual(tracking.update(snapshot(offset: 0), activePanel: .notes), .info)
  }

  func testBottomSelectsLastSectionEvenWhenItCannotReachTheViewportTop() {
    var tracking = InspectorScrollTracking()
    _ = tracking.update(snapshot(offset: 870), activePanel: .collections)
    let bottom = snapshot(offset: 964)
    XCTAssertGreaterThan(bottom.sections[.tags]!.minY, 24)
    XCTAssertEqual(tracking.update(bottom, activePanel: .collections), .tags)
    XCTAssertEqual(tracking.update(snapshot(offset: 900), activePanel: .tags), .collections)
  }

  func testRubberBandingDoesNotOverrideExplicitSelectionInAShortInspector() {
    var tracking = InspectorScrollTracking()
    _ = tracking.update(snapshot(viewport: 400, heights: [32, 32, 32, 32]), activePanel: .info)
    XCTAssertNil(tracking.update(snapshot(offset: 20, viewport: 400, heights: [32, 32, 32, 32]), activePanel: .tags))
    XCTAssertNil(tracking.update(snapshot(offset: -20, viewport: 400, heights: [32, 32, 32, 32]), activePanel: .tags))
  }

  func testNavigationAnimationKeepsTargetSelectedAndUserScrollingResumesTracking() {
    var tracking = InspectorScrollTracking()
    _ = tracking.update(snapshot(), activePanel: .info)
    let request = UUID()
    tracking.beginNavigation(request)
    XCTAssertNil(tracking.update(snapshot(offset: 590), activePanel: .tags))
    XCTAssertNil(tracking.update(snapshot(offset: 964), activePanel: .tags))
    tracking.finishNavigation(request)
    XCTAssertNil(tracking.update(snapshot(offset: 964), activePanel: .tags))
    XCTAssertEqual(tracking.update(snapshot(offset: 870), activePanel: .tags), .collections)
  }

  func testOlderAnimationCannotUnlockANewerNavigation() {
    var tracking = InspectorScrollTracking()
    let first = UUID(), second = UUID()
    tracking.beginNavigation(first)
    tracking.beginNavigation(second)
    tracking.finishNavigation(first)
    XCTAssertNil(tracking.update(snapshot(offset: 590), activePanel: .tags))
    tracking.finishNavigation(second)
    XCTAssertEqual(tracking.update(snapshot(offset: 870), activePanel: .tags), .collections)
  }

  func testResizeAndExpansionKeepVisibleSelectionButReplaceOffscreenSelection() {
    var tracking = InspectorScrollTracking()
    _ = tracking.update(snapshot(offset: 870), activePanel: .collections)
    XCTAssertNil(tracking.update(snapshot(offset: 870, viewport: 350), activePanel: .collections))
    XCTAssertNil(tracking.update(snapshot(offset: 870, viewport: 350, heights: [600, 280, 320, 160]), activePanel: .collections))
    XCTAssertEqual(tracking.update(snapshot(offset: 870, viewport: 120, heights: [600, 280, 320, 160]), activePanel: .tags), .collections)
  }

  func testIncompleteLayoutDoesNotResetTrackingOrSelection() {
    var tracking = InspectorScrollTracking()
    let valid = snapshot(offset: 590)
    _ = tracking.update(valid, activePanel: .notes)
    XCTAssertNil(tracking.update(InspectorScrollGeometry(), activePanel: .notes))
    XCTAssertEqual(tracking.geometry, valid)
    XCTAssertNil(tracking.update(valid, activePanel: .notes))
  }
}
