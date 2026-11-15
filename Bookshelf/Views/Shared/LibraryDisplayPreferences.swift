import SwiftUI

enum LibraryDisplayDensity: String, CaseIterable, Identifiable {
  case compact, comfortable
  var id: Self { self }
  var title: String { self == .compact ? "紧凑" : "舒适" }
}

/// Shared measurements for navigation, table cells, tags and editable metadata.
struct LibraryDisplayMetrics: Equatable {
  var density: LibraryDisplayDensity = .compact
  var fontSize: CGFloat = 13
  var font: Font { .system(size: fontSize) }
  var caption: Font { .system(size: max(11, fontSize - 2)) }
  // Keep primary icons at the requested size, independently of text scaling.
  var iconSize: CGFloat { 16 }
  var iconSlotSize: CGFloat { 22 }
  var toolbarControlSize: CGFloat { max(28, iconSlotSize) }
  var toolbarSpacing: CGFloat { 4 }
  var rowPadding: CGFloat { density == .compact ? 4 : 7 }
  var sidebarRowHeight: CGFloat { fontSize + 17 + (density == .comfortable ? 8 : 0) }
  var tableCellHeight: CGFloat { fontSize + (density == .compact ? 7 : 15) }
  var fieldSpacing: CGFloat { density == .compact ? 8 : 14 }
  var inspectorRowHeight: CGFloat { max(20, fontSize + 4) }
  var inspectorRowSpacing: CGFloat { density == .compact ? 4 : 8 }
  var inspectorSectionPadding: CGFloat { density == .compact ? 6 : 10 }
  var inspectorHeaderControlWidth: CGFloat { max(iconSlotSize, inspectorRowHeight) }
  var inspectorHeaderSpacing: CGFloat { 4 }
  var inspectorHeaderLabelSpacing: CGFloat { 6 }
  var inspectorNavigationRowHeight: CGFloat { inspectorRowHeight + 2 * inspectorSectionPadding }
  var metadataLabelWidth: CGFloat { max(58, fontSize * 4.5) }
  var rowInsets: EdgeInsets { EdgeInsets(top: rowPadding, leading: 8, bottom: rowPadding, trailing: 8) }

  init(density: LibraryDisplayDensity = .compact, fontSize: Double = 13) {
    self.density = density
    self.fontSize = fontSize.isFinite ? CGFloat(min(18, max(12, fontSize))) : 13
  }
}

/// Use the same SF Symbols point size and weight everywhere. Preserve optical
/// proportions so a folder with a badge does not shrink to fit a square.
struct LibraryIcon: View {
  @Environment(\.libraryDisplay) private var display
  let systemName: String

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: display.iconSize, weight: .regular))
      .imageScale(.medium)
      .symbolRenderingMode(.monochrome)
      .frame(width: display.iconSlotSize, height: display.iconSlotSize)
  }
}

private struct LibraryDisplayMetricsKey: EnvironmentKey {
  static let defaultValue = LibraryDisplayMetrics()
}
extension EnvironmentValues {
  var libraryDisplay: LibraryDisplayMetrics {
    get { self[LibraryDisplayMetricsKey.self] }
    set { self[LibraryDisplayMetricsKey.self] = newValue }
  }
}

struct LibraryDisplayStyle: ViewModifier {
  @AppStorage("libraryDisplayDensity") private var density = LibraryDisplayDensity.compact
  @AppStorage("libraryInterfaceFontSize") private var fontSize = 13.0
  func body(content: Content) -> some View {
    let metrics = LibraryDisplayMetrics(density: density, fontSize: fontSize)
    content.environment(\.libraryDisplay, metrics).font(metrics.font)
  }
}
