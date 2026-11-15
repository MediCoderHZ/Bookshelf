import Foundation

/// A section-relative bookmark survives changes to the sections above it.
struct InspectorReadingPosition: Codable, Equatable {
  var section: InspectorPanel
  var offsetInSection: Double
  var absoluteOffset: Double
  var atBottom: Bool
  var activePanel: InspectorPanel
  var expandedPanels: Set<InspectorPanel>

  var isValid: Bool {
    offsetInSection.isFinite && offsetInSection >= 0 && absoluteOffset.isFinite && absoluteOffset >= 0
  }

  init?(geometry: InspectorScrollGeometry, activePanel: InspectorPanel, expandedPanels: Set<InspectorPanel>) {
    guard geometry.isValid else { return nil }
    section = InspectorPanel.allCases.last { (geometry.sections[$0]?.minY ?? .infinity) <= 0 } ?? .info
    offsetInSection = Double(max(0, -(geometry.sections[section]?.minY ?? 0)))
    absoluteOffset = Double(geometry.offset)
    atBottom = geometry.maximumOffset > 1 && geometry.maximumOffset - geometry.offset <= 1
    self.activePanel = activePanel
    self.expandedPanels = expandedPanels
  }

  func offset(in geometry: InspectorScrollGeometry) -> CGFloat {
    guard isValid, geometry.isValid else { return 0 }
    if atBottom { return geometry.maximumOffset }
    let proposed: CGFloat
    if let frame = geometry.sections[section] {
      let sectionStart = frame.minY - geometry.content.minY
      proposed = sectionStart + min(CGFloat(offsetInSection), max(0, frame.height - 1))
    } else { proposed = CGFloat(absoluteOffset) }
    return min(geometry.maximumOffset, max(0, proposed))
  }

  func highlightedPanel(in geometry: InspectorScrollGeometry) -> InspectorPanel {
    geometry.isVisible(activePanel) ? activePanel : geometry.visiblePanel
  }
}

/// Layout can change again while a restored window is being attached and sized.
/// A requested scroll is not considered restored until the measured offset agrees.
struct InspectorPositionRestoration {
  enum Update: Equatable {
    case scroll(to: CGFloat)
    case settled(InspectorPanel)
    case userScrolled
  }
  let position: InspectorReadingPosition
  private var settledGeometry: InspectorScrollGeometry?

  init(position: InspectorReadingPosition) { self.position = position }

  mutating func update(_ geometry: InspectorScrollGeometry) -> Update {
    if let previous = settledGeometry, geometry.hasSameLayout(as: previous),
      abs(geometry.offset - previous.offset) > 0.5 { return .userScrolled }
    let target = position.offset(in: geometry)
    guard abs(geometry.offset - target) <= 0.5 else {
      settledGeometry = nil
      return .scroll(to: target)
    }
    settledGeometry = geometry
    return .settled(position.highlightedPanel(in: geometry))
  }
}

/// Window-owned memory; only this preference key is written, never library records.
@MainActor
final class InspectorReadingPositionStore {
  static let storageKey = "inspectorReadingPositions.v1"
  private let defaults: UserDefaults
  private var positions: [UUID: InspectorReadingPosition]
  private var dirtyIDs: Set<UUID> = []
  private var pendingSave: Task<Void, Never>?
  private var lastNavigationID: UUID?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    positions = Self.load(defaults)
  }

  subscript(bookID: UUID) -> InspectorReadingPosition? { positions[bookID] }

  func hasHandledNavigation(_ id: UUID) -> Bool { lastNavigationID == id }
  func consumeNavigation(_ id: UUID) -> Bool {
    guard !hasHandledNavigation(id) else { return false }
    lastNavigationID = id
    return true
  }

  func remember(_ position: InspectorReadingPosition, for bookID: UUID) {
    guard position.isValid, positions[bookID] != position else { return }
    positions[bookID] = position
    dirtyIDs.insert(bookID)
    pendingSave?.cancel()
    pendingSave = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
      self?.flush()
    }
  }

  func retain(bookIDs: Set<UUID>) {
    let removed = Set(positions.keys).subtracting(bookIDs)
    for id in removed { positions.removeValue(forKey: id) }
    dirtyIDs.formUnion(removed)
    if !removed.isEmpty { flush() }
  }

  func flush() {
    pendingSave?.cancel(); pendingSave = nil
    guard !dirtyIDs.isEmpty else { return }
    // Merge only changed books so another window's bookmarks are not overwritten.
    var persisted = Self.load(defaults)
    for id in dirtyIDs { persisted[id] = positions[id] }
    guard let data = try? JSONEncoder().encode(persisted) else { return }
    defaults.set(data, forKey: Self.storageKey)
    dirtyIDs.removeAll()
  }

  private static func load(_ defaults: UserDefaults) -> [UUID: InspectorReadingPosition] {
    guard let data = defaults.data(forKey: storageKey),
      let decoded = try? JSONDecoder().decode([UUID: InspectorReadingPosition].self, from: data) else { return [:] }
    return decoded.filter { $0.value.isValid }
  }
}
