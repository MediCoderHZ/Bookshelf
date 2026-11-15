import AppKit
import SwiftUI

/// SwiftUI owns the native split views and their constraints. Observe divider
/// drags without replacing their delegates or intercepting the mouse events.
struct PanelWidthPersistence: NSViewRepresentable {
  enum Edge { case leading, trailing }
  let edge: Edge
  var initialWidth: CGFloat? = nil
  var restorationID: AnyHashable? = nil
  let onResize: (CGFloat) -> Void

  func makeNSView(context: Context) -> PanelWidthObserver {
    let view = PanelWidthObserver()
    view.edge = edge
    view.initialWidth = initialWidth
    view.restorationID = restorationID
    view.onResize = onResize
    return view
  }

  func updateNSView(_ view: PanelWidthObserver, context: Context) {
    view.edge = edge
    view.initialWidth = initialWidth
    view.onResize = onResize
    if view.restorationID != restorationID {
      view.restorationID = restorationID
      view.restoreAfterLayoutChange()
    }
  }

  static func dismantleNSView(_ view: PanelWidthObserver, coordinator: ()) {
    view.stopObserving()
  }
}

final class PanelWidthObserver: NSView {
  var edge: PanelWidthPersistence.Edge = .leading
  var initialWidth: CGFloat?
  var restorationID: AnyHashable?
  private var restoredInitialWidth = false
  var onResize: (CGFloat) -> Void = { _ in }
  private var mouseMonitor: Any?
  private var dragCompletion: Timer?
  private var drag: DividerDrag?

  private struct DividerDrag {
    weak var split: NSSplitView?
    weak var pane: NSView?
    let initialWidth: CGFloat
    var lastWidth: CGFloat
    var lastChange: TimeInterval
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopObserving()
    guard window != nil else { return }
    restoredInitialWidth = false
    DispatchQueue.main.async { [weak self] in self?.restoreInitialWidth() }
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
      if event.type == .leftMouseDown { self?.beginDrag(event) }
      else { self?.finishDrag() }
      return event
    }
  }

  override func layout() {
    super.layout()
    restoreInitialWidth()
  }

  func restoreAfterLayoutChange() {
    // Let SwiftUI insert/remove panes and settle their new constraints first.
    // User divider drags do not change restorationID, so they remain untouched.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil, self.drag == nil else { return }
      self.restoredInitialWidth = false
      self.restoreInitialWidth()
    }
  }

  private func restoreInitialWidth() {
    guard !restoredInitialWidth, let width = initialWidth, width.isFinite, width > 0,
      window != nil, let (split, pane) = enclosingPane(), split.bounds.width > width,
      let index = split.arrangedSubviews.firstIndex(of: pane) else { return }
    let divider = edge == .trailing ? index - 1 : index
    guard divider >= 0, divider < split.arrangedSubviews.count - 1 else { return }
    // HSplitView initially divides space evenly. Restore the saved width once;
    // subsequent user drags and window resizing remain owned by AppKit.
    restoredInitialWidth = true
    let position = edge == .trailing ? pane.frame.maxX - width : pane.frame.minX + width
    split.setPosition(position, ofDividerAt: divider)
  }

  func stopObserving() {
    if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    mouseMonitor = nil
    dragCompletion?.invalidate()
    dragCompletion = nil
    drag = nil
  }

  private func beginDrag(_ event: NSEvent) {
    guard event.window === window, let (split, pane) = enclosingPane() else { return }
    let point = split.convert(event.locationInWindow, from: nil)
    // The content pane can extend behind glass sidebars. Use this panel's edge,
    // rather than the adjacent content pane's potentially overlapping frame.
    let x = edge == .leading ? pane.frame.maxX : pane.frame.minX
    let hitArea = NSRect(x: x - 4, y: split.bounds.minY, width: 8, height: split.bounds.height)
    guard hitArea.contains(point) else { return }
    dragCompletion?.invalidate()
    drag = DividerDrag(split: split, pane: pane, initialWidth: pane.frame.width,
      lastWidth: pane.frame.width, lastChange: ProcessInfo.processInfo.systemUptime)

    // Some AppKit versions consume mouse-up in a nested tracking loop. Poll only
    // for the duration of this drag as a fallback to the normal mouse-up event.
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.checkDragCompletion()
      }
    }
    dragCompletion = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func checkDragCompletion() {
    guard var drag, let pane = drag.pane else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if abs(pane.frame.width - drag.lastWidth) > 0.1 {
      drag.lastWidth = pane.frame.width
      drag.lastChange = now
      self.drag = drag
    }
    // Also supports native/synthetic tracking that consumes mouse-up without
    // updating the process's physical mouse-button state. A moving divider is
    // never considered finished; a held physical mouse button keeps it active.
    if NSEvent.pressedMouseButtons & 1 == 0, now - drag.lastChange >= 0.2 {
      finishDrag()
    }
  }

  private func finishDrag() {
    guard let drag else { return }
    self.drag = nil
    dragCompletion?.invalidate()
    dragCompletion = nil
    // Let the native divider finish handling mouse-up before reading its width.
    DispatchQueue.main.async { [weak self, weak split = drag.split, weak pane = drag.pane] in
      guard let self, let split, let pane, self.window != nil, self.window?.inLiveResize != true,
        pane.superview === split, !split.isSubviewCollapsed(pane), !pane.isHidden else { return }
      let width = pane.frame.width
      guard width.isFinite, width > 0, abs(width - drag.initialWidth) > 0.5 else { return }
      self.onResize(width)
    }
  }

  private func enclosingPane() -> (NSSplitView, NSView)? {
    var pane: NSView = self
    while let parent = pane.superview {
      // arrangedSubviews excludes native divider decorations and glass views.
      if let split = parent as? NSSplitView, split.isVertical,
        split.arrangedSubviews.count > 1, split.arrangedSubviews.contains(pane) {
        return (split, pane)
      }
      pane = parent
    }
    return nil
  }
}
