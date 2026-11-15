import AppKit
import XCTest
@testable import Bookshelf

@MainActor
final class CollectionHoverExpansionTests: XCTestCase {
  private final class HoverState {
    var valid = true
    var expanded = false
  }

  @MainActor
  private final class Scheduler {
    final class Job {
      let delay: Duration
      let action: @MainActor () -> Void
      var cancelled = false
      init(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
        self.delay = delay; self.action = action
      }
    }
    var jobs: [Job] = []
    func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> (() -> Void) {
      let job = Job(delay, action); jobs.append(job)
      return { job.cancelled = true }
    }
  }

  func testContinuousHoverExpandsOnceWithoutRestartingDelay() {
    let clock = Scheduler()
    let target = SidebarDragHoverExpansion(schedule: clock.schedule)
    var expanded = false, expansions = 0
    for _ in 0..<20 {
      target.update(eligible: true, stillEligible: { !expanded }, expand: { expanded = true; expansions += 1 })
    }
    XCTAssertEqual(clock.jobs.count, 1)
    XCTAssertEqual(clock.jobs[0].delay, .milliseconds(650))
    XCTAssertFalse(expanded)
    clock.jobs[0].action(); clock.jobs[0].action()
    XCTAssertTrue(expanded); XCTAssertEqual(expansions, 1)
  }

  func testLeavingRowOrMovingToInsertionEdgeCancelsPendingExpansion() {
    let clock = Scheduler()
    let hover = SidebarDragHoverExpansion(schedule: clock.schedule)
    var expansions = 0
    hover.update(eligible: true, stillEligible: { true }, expand: { expansions += 1 })
    hover.update(eligible: false, stillEligible: { true }, expand: { expansions += 1 })
    XCTAssertTrue(clock.jobs[0].cancelled)
    // A callback already queued by a timer must be harmless after cancellation.
    clock.jobs[0].action()
    XCTAssertEqual(expansions, 0)
    hover.update(eligible: false, stillEligible: { true }, expand: { expansions += 1 })
    XCTAssertEqual(clock.jobs.count, 1)
  }

  func testCancelledCallbackCannotExpandOrClearNewHover() {
    let clock = Scheduler()
    let target = SidebarDragHoverExpansion(schedule: clock.schedule)
    var expansions = 0
    target.update(eligible: true, stillEligible: { true }, expand: { expansions += 1 })
    target.cancel() // Also used when dropping, disappearing, or changing row identity.
    target.update(eligible: true, stillEligible: { true }, expand: { expansions += 1 })
    clock.jobs[0].action()
    XCTAssertEqual(expansions, 0)
    target.update(eligible: true, stillEligible: { true }, expand: { expansions += 1 })
    XCTAssertEqual(clock.jobs.count, 2)
    clock.jobs[1].action()
    XCTAssertEqual(expansions, 1)
  }

  func testTimerRechecksDragAndExpansionEligibilityBeforeOpening() {
    let clock = Scheduler(), hover = SidebarDragHoverExpansion(schedule: clock.schedule)
    let state = HoverState()
    hover.update(eligible: true, stillEligible: { state.valid }, expand: { state.expanded = true })
    state.valid = false // Drag ended, source changed, or the target was opened manually.
    clock.jobs[0].action()
    XCTAssertFalse(state.expanded)
    state.valid = true
    hover.update(eligible: true, stillEligible: { state.valid }, expand: { state.expanded = true })
    clock.jobs[1].action()
    XCTAssertTrue(state.expanded)
  }

  func testMovingBetweenRowsOnlyExpandsCurrentTarget() {
    let clock = Scheduler()
    let first = SidebarDragHoverExpansion(schedule: clock.schedule)
    let second = SidebarDragHoverExpansion(schedule: clock.schedule)
    var opened: [String] = []
    first.update(eligible: true, stillEligible: { true }, expand: { opened.append("first") })
    first.cancel()
    second.update(eligible: true, stillEligible: { true }, expand: { opened.append("second") })
    clock.jobs[0].action(); clock.jobs[1].action()
    XCTAssertEqual(opened, ["second"])
    XCTAssertTrue(clock.jobs[0].cancelled)
  }

  func testNativeTimerFiresDuringEventTracking() {
    _ = NSApplication.shared
    let hover = SidebarDragHoverExpansion(delay: .milliseconds(5))
    var expanded = false
    hover.update(eligible: true, stillEligible: { true }, expand: { expanded = true })
    let deadline = Date().addingTimeInterval(1)
    while !expanded && Date() < deadline {
      RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
    }
    hover.cancel()
    XCTAssertTrue(expanded, "Expansion must run while a native drag is still tracking the mouse")
  }
}
