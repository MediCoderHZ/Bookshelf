import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CollectionDragTransfer {
  static let type = UTType(exportedAs: "org.bookshelf.collection-drag", conformingTo: .data)

  static func provider(for payload: CollectionDragPayload, title: String) -> NSItemProvider {
    let provider = NSItemProvider()
    guard let data = try? JSONEncoder().encode(payload) else { return provider }
    provider.suggestedName = title
    provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
      completion(data, nil); return nil
    }
    return provider
  }

  @MainActor
  static func load(_ provider: NSItemProvider) async throws -> CollectionDragPayload {
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
        if let error { continuation.resume(throwing: error) }
        else if let data { continuation.resume(returning: data) }
        else { continuation.resume(throwing: CollectionMoveError.staleDrag) }
      }
    }
    return try JSONDecoder().decode(CollectionDragPayload.self, from: data)
  }
}

/// A row owns one pending expansion. Repeated drag updates do not restart its
/// delay; leaving, dropping or removing the row invalidates even a queued callback.
@MainActor
final class SidebarDragHoverExpansion {
  typealias Schedule = (Duration, @escaping @MainActor () -> Void) -> (() -> Void)
  private let delay: Duration
  private let schedule: Schedule
  private var token: UUID?
  private var cancelPending: (() -> Void)?

  init(delay: Duration = .milliseconds(650), schedule: Schedule? = nil) {
    self.delay = delay
    self.schedule = schedule ?? { delay, action in
      let parts = delay.components
      let interval = TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
      let timer = Timer(timeInterval: interval, repeats: false) { _ in
        MainActor.assumeIsolated { action() }
      }
      // Native dragging runs an event-tracking loop. A common-mode timer keeps
      // the delay running while the mouse is held, not only after the drop ends.
      RunLoop.main.add(timer, forMode: .common)
      return { timer.invalidate() }
    }
  }

  func update(eligible: Bool, stillEligible: @escaping @MainActor () -> Bool,
    expand: @escaping @MainActor () -> Void) {
    guard eligible else { cancel(); return }
    guard token == nil else { return }
    let pending = UUID()
    token = pending
    cancelPending = schedule(delay) { [weak self] in
      guard let self, self.token == pending else { return }
      self.token = nil; self.cancelPending = nil
      if stillEligible() { expand() }
    }
  }

  func cancel() {
    token = nil
    cancelPending?(); cancelPending = nil
  }
}

/// One drop handler distinguishes adding books from moving a collection. Stacking
/// two onDrop modifiers on the same sidebar row would mask one of the operations.
struct SidebarCollectionDropTarget: ViewModifier {
  let rowID: UUID?
  var canContainCollections = true
  let canMove: (CollectionDropDestination) -> Bool
  let onMove: (CollectionDragPayload, CollectionDropDestination) throws -> Void
  var onBooks: (([BookDragPayload]) throws -> Void)?
  let onError: (Error) -> Void
  var expansion: Binding<Bool>?
  var canExpandCollection: () -> Bool = { false }
  @State private var indicator: SidebarDropIndicator?
  @State private var rowHeight: CGFloat = 22
  @State private var hoverExpansion = SidebarDragHoverExpansion()

  func body(content: Content) -> some View {
    content
      .background {
        GeometryReader { geometry in
          Color.clear.onAppear { rowHeight = geometry.size.height }
            .onChange(of: geometry.size.height) { _, height in rowHeight = height }
        }
      }
      .background {
        if indicator == .inside { RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.16)) }
      }
      .overlay {
        if let indicator {
          Group {
            if indicator == .inside { RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 1) }
            else {
              Rectangle().fill(Color.accentColor).frame(height: 2)
                .frame(maxHeight: .infinity, alignment: indicator == .before ? .top : .bottom)
            }
          }.allowsHitTesting(false)
        }
      }
      .onDrop(of: onBooks == nil ? [CollectionDragTransfer.type] : [CollectionDragTransfer.type, BookDragTransfer.type],
        delegate: SidebarCollectionDropDelegate(rowID: rowID, canContainCollections: canContainCollections,
          rowHeight: rowHeight, indicator: $indicator, canMove: canMove, onMove: onMove, onBooks: onBooks, onError: onError,
          expansion: expansion, canExpandCollection: canExpandCollection, hoverExpansion: hoverExpansion))
      .onChange(of: expansion?.wrappedValue) { _, _ in hoverExpansion.cancel() }
      .onChange(of: rowID) { _, _ in hoverExpansion.cancel() }
      .onDisappear { hoverExpansion.cancel() }
  }
}

private enum SidebarDropIndicator { case before, inside, after }

private struct SidebarCollectionDropDelegate: DropDelegate {
  let rowID: UUID?
  let canContainCollections: Bool
  let rowHeight: CGFloat
  @Binding var indicator: SidebarDropIndicator?
  let canMove: (CollectionDropDestination) -> Bool
  let onMove: (CollectionDragPayload, CollectionDropDestination) throws -> Void
  let onBooks: (([BookDragPayload]) throws -> Void)?
  let onError: (Error) -> Void
  let expansion: Binding<Bool>?
  let canExpandCollection: () -> Bool
  let hoverExpansion: SidebarDragHoverExpansion

  private func destination(_ info: DropInfo) -> (CollectionDropDestination, SidebarDropIndicator)? {
    guard let rowID else { return (.inside(nil), .inside) }
    let edge = max(5, rowHeight * 0.25)
    if info.location.y < edge { return (.before(rowID), .before) }
    if info.location.y > rowHeight - edge { return (.after(rowID), .after) }
    return canContainCollections ? (.inside(rowID), .inside) : nil
  }
  private func isCollection(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [CollectionDragTransfer.type]) }
  func validateDrop(info: DropInfo) -> Bool {
    if isCollection(info) {
      guard let rowID else { return canMove(.inside(nil)) }
      return canMove(.before(rowID)) || canMove(.after(rowID)) || (canContainCollections && canMove(.inside(rowID)))
        || (expansion?.wrappedValue == false && canExpandCollection())
    }
    return onBooks != nil && info.hasItemsConforming(to: [BookDragTransfer.type])
  }
  private func updateIndicator(_ info: DropInfo) {
    let collection = isCollection(info)
    if collection {
      indicator = destination(info).flatMap { canMove($0.0) ? $0.1 : nil }
    } else { indicator = validateDrop(info: info) ? .inside : nil }
    // Book drops always target the row; collection insertion edges must remain
    // stable while sorting. A valid no-op parent drop may still reveal children.
    let overCenter = !collection || destination(info)?.1 == .inside
    let eligible = rowID != nil && canContainCollections && expansion?.wrappedValue == false
      && overCenter && (collection ? canExpandCollection() : validateDrop(info: info))
    hoverExpansion.update(eligible: eligible, stillEligible: {
      expansion?.wrappedValue == false && NSEvent.pressedMouseButtons & 1 != 0
        && (!collection || canExpandCollection())
    }, expand: { expansion?.wrappedValue = true })
  }
  func dropEntered(info: DropInfo) { updateIndicator(info) }
  func dropExited(info: DropInfo) { indicator = nil; hoverExpansion.cancel() }
  func dropUpdated(info: DropInfo) -> DropProposal? {
    updateIndicator(info)
    return DropProposal(operation: indicator == nil ? .forbidden : (isCollection(info) ? .move : .copy))
  }
  func performDrop(info: DropInfo) -> Bool {
    hoverExpansion.cancel()
    indicator = nil
    guard validateDrop(info: info) else { return false }
    if isCollection(info) {
      guard let target = destination(info)?.0,
        canMove(target),
        let provider = info.itemProviders(for: [CollectionDragTransfer.type]).first else { return false }
      Task { @MainActor in
        do { try onMove(try await CollectionDragTransfer.load(provider), target) }
        catch { onError(error) }
      }
    } else {
      let providers = info.itemProviders(for: [BookDragTransfer.type])
      Task { @MainActor in
        do { try onBooks?([try await BookDragTransfer.loadSelection(from: providers)]) }
        catch { onError(error) }
      }
    }
    return true
  }
}
