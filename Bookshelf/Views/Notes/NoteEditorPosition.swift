import AppKit

/// Positions refer to rendered UTF-16 text, never Markdown source offsets.
struct NoteEditorPosition: Codable, Equatable {
  var location = 0
  var length = 0
  var scrollY = 0.0
  var anchor = 0
  var offsetInLine = 0.0
  var atBottom = false

  var isValid: Bool {
    location >= 0 && location != NSNotFound && length >= 0 && anchor >= 0 && anchor != NSNotFound &&
      scrollY.isFinite && scrollY >= 0 && offsetInLine.isFinite
  }

  func selection(in text: String) -> NSRange {
    let text = text as NSString
    let start = min(max(0, location), text.length)
    let count = min(max(0, length), text.length - start)
    // Never restore a caret inside an emoji, surrogate pair or combining sequence.
    if count == 0 {
      let boundary = start < text.length ? text.rangeOfComposedCharacterSequence(at: start).location : start
      return NSRange(location: boundary, length: 0)
    }
    return text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: count))
  }
}

/// A window keeps its own live positions; disk writes merge only changed notes.
@MainActor
final class NoteEditorPositionStore {
  static let storageKey = "noteEditorPositions.v1"
  private let defaults: UserDefaults
  private var positions: [UUID: NoteEditorPosition]
  private var dirtyIDs: Set<UUID> = []
  private var pendingSave: Task<Void, Never>?
  private var lastFocusToken: UUID?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    positions = Self.load(defaults)
  }
  subscript(id: UUID) -> NoteEditorPosition? { positions[id] }
  func consumeFocus(_ token: UUID) -> Bool {
    guard lastFocusToken != token else { return false }
    lastFocusToken = token
    return true
  }
  func remember(_ position: NoteEditorPosition, for id: UUID) {
    guard position.isValid, positions[id] != position else { return }
    positions[id] = position; dirtyIDs.insert(id)
    pendingSave?.cancel()
    pendingSave = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
      self?.flush()
    }
  }
  func retain(noteIDs: Set<UUID>) {
    let removed = Set(positions.keys).subtracting(noteIDs)
    for id in removed { positions.removeValue(forKey: id) }
    dirtyIDs.formUnion(removed)
    if !removed.isEmpty { flush() }
  }
  func flush() {
    pendingSave?.cancel(); pendingSave = nil
    guard !dirtyIDs.isEmpty else { return }
    var persisted = Self.load(defaults)
    for id in dirtyIDs { persisted[id] = positions[id] }
    guard let data = try? JSONEncoder().encode(persisted) else { return }
    defaults.set(data, forKey: Self.storageKey); dirtyIDs.removeAll()
  }
  private static func load(_ defaults: UserDefaults) -> [UUID: NoteEditorPosition] {
    guard let data = defaults.data(forKey: storageKey),
      let positions = try? JSONDecoder().decode([UUID: NoteEditorPosition].self, from: data) else { return [:] }
    return positions.filter { $0.value.isValid }
  }
}

final class NoteEditorScrollView: NSScrollView {
  var positionTracker: NoteEditorPositionTracker?
  override func layout() {
    super.layout()
    positionTracker?.restoreAfterLayout()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    positionTracker?.scheduleRestoration()
  }
}

/// Native scroll/selection notifications keep caret and viewport independent.
/// Restoring a selection deliberately does not scroll it into view.
@MainActor
final class NoteEditorPositionTracker: NSObject {
  private weak var scroll: NoteEditorScrollView?
  private weak var view: RichNoteTextView?
  private let noteID: UUID
  private let store: NoteEditorPositionStore
  private var pendingPosition: NoteEditorPosition?
  private var restoredSize: NSSize?
  private var lastPosition: NoteEditorPosition?
  private var applying = false
  private var ready = false
  private var stopped = false
  private var scheduled = false

  init(noteID: UUID, store: NoteEditorPositionStore, scroll: NoteEditorScrollView, view: RichNoteTextView) {
    self.noteID = noteID; self.store = store; self.scroll = scroll; self.view = view
    pendingPosition = store[noteID] ?? NoteEditorPosition()
    super.init()
    scroll.positionTracker = self
    scroll.contentView.postsBoundsChangedNotifications = true
    scroll.contentView.postsFrameChangedNotifications = true
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    center.addObserver(self, selector: #selector(viewportChanged), name: NSView.frameDidChangeNotification, object: scroll.contentView)
    center.addObserver(self, selector: #selector(selectionChanged), name: NSTextView.didChangeSelectionNotification, object: view)
    center.addObserver(self, selector: #selector(terminate), name: NSApplication.willTerminateNotification, object: nil)
    view.onSelectionChange = { [weak self] in self?.contentChanged() }
    scheduleRestoration()
  }

  func scheduleRestoration() {
    guard !scheduled, !stopped else { return }
    scheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.scheduled = false
      self.restoreAfterLayout()
    }
  }

  func restoreAfterLayout() {
    guard !stopped, !applying, let scroll, let view, scroll.window != nil,
      scroll.contentSize.width > 0, scroll.contentSize.height > 0, let position = pendingPosition else { return }
    let size = scroll.contentView.bounds.size
    guard !ready || restoredSize != size else { return }
    applying = true
    // NSTextView must finish wrapping at the actual viewport width before locating the anchor.
    view.setFrameSize(NSSize(width: scroll.contentSize.width, height: view.frame.height))
    view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
    view.sizeToFit()
    // Growing a zero-sized document during SwiftUI attachment can leave a negative origin.
    // The document and its saved scroll coordinates always start at (0, 0).
    view.setFrameOrigin(.zero)
    view.restoreEditorSelection(position.selection(in: view.string))
    let maximum = max(0, view.frame.height - scroll.contentView.bounds.height)
    var y = CGFloat(position.scrollY)
    if position.atBottom { y = maximum }
    else if position.scrollY > 0, position.anchor < view.attributedString().length, let lineY = lineOrigin(at: position.anchor) {
      y = lineY + CGFloat(position.offsetInLine)
    }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, y))))
    scroll.reflectScrolledClipView(scroll.contentView)
    restoredSize = scroll.contentView.bounds.size
    ready = true; applying = false
    remember()
  }

  func reload(_ source: String) {
    guard let view else { return }
    let position = (ready ? capture() : nil) ?? pendingPosition ?? NoteEditorPosition()
    applying = true; view.load(source); applying = false
    pendingPosition = position; ready = false; restoredSize = nil
    scheduleRestoration()
  }

  func focus() {
    guard !stopped, let view else { return }
    if let window = view.window {
      window.makeFirstResponder(view)
      restoreAfterLayout()
    } else { view.pendingFocus = true; scheduleRestoration() }
  }

  func stop() {
    guard !stopped else { return }
    remember(); store.flush(); stopped = true
    NotificationCenter.default.removeObserver(self)
    view?.onSelectionChange = nil
    scroll?.positionTracker = nil
  }

  @objc private func terminate() { remember(); store.flush() }

  @objc private func viewportChanged() {
    guard !stopped, !applying, let scroll else { return }
    if !ready || (pendingPosition != nil && restoredSize != scroll.contentView.bounds.size) {
      scheduleRestoration(); return
    }
    if let previous = lastPosition, abs(scroll.contentView.bounds.minY - previous.scrollY) > 0.5 {
      pendingPosition = nil // Manual scrolling takes over from startup layout restoration.
    }
    remember()
  }
  @objc private func selectionChanged() {
    guard ready, !applying, view?.hasMarkedText() == false else { return }
    if let view, let lastPosition, view.selectedRange() != lastPosition.selection(in: view.string) {
      pendingPosition = nil
    }
    remember()
  }
  private func contentChanged() {
    guard ready, !applying, view?.hasMarkedText() == false else { return }
    pendingPosition = nil
    remember()
  }
  private func remember() {
    guard !stopped, ready, !applying, view?.hasMarkedText() == false, let position = capture() else { return }
    lastPosition = position
    store.remember(position, for: noteID)
  }
  private func capture() -> NoteEditorPosition? {
    guard let view, let scroll, scroll.window != nil, scroll.contentSize.height > 0 else { return nil }
    let range = view.selectedRange()
    let y = max(0, scroll.contentView.bounds.minY)
    let maximum = max(0, view.frame.height - scroll.contentView.bounds.height)
    let anchor = min(view.attributedString().length,
      view.characterIndexForInsertion(at: NSPoint(x: view.textContainerOrigin.x + 1, y: y + 1)))
    let lineY = lineOrigin(at: anchor) ?? y
    return NoteEditorPosition(location: range.location, length: range.length, scrollY: y,
      anchor: anchor, offsetInLine: y - lineY, atBottom: maximum > 1 && maximum - y <= 1)
  }
  private func lineOrigin(at character: Int) -> CGFloat? {
    guard let view, let manager = view.layoutManager, character < view.attributedString().length else { return nil }
    let glyph = manager.glyphIndexForCharacter(at: character)
    guard glyph < manager.numberOfGlyphs else { return nil }
    return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + view.textContainerOrigin.y
  }
}
