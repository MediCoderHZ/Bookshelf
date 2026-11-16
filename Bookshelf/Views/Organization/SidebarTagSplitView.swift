import AppKit
import SwiftUI

struct SidebarTagSplitView<Navigation: View, Tags: View>: View {
  @ViewBuilder let navigation: () -> Navigation
  @ViewBuilder let tags: () -> Tags
  @AppStorage("sidebarTagPanelHeight") private var preferredHeight = 280.0
  @GestureState private var dragTranslation: CGFloat = 0
  @GestureState private var isDragging = false

  var body: some View {
    GeometryReader { geometry in
      let baseHeight = SidebarTagPanelLayout.height(preferredHeight, available: geometry.size.height)
      let tagHeight = SidebarTagPanelLayout.height(baseHeight - dragTranslation, available: geometry.size.height)
      VStack(spacing: 0) {
        navigation()
          .frame(height: max(0, geometry.size.height - SidebarTagPanelLayout.dividerHeight - tagHeight))
        TagPanelResizeHandle(isDragging: isDragging)
          .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
              .updating($dragTranslation) { value, translation, _ in translation = value.translation.height }
              .updating($isDragging) { _, dragging, _ in dragging = true }
              .onEnded { value in
                preferredHeight = SidebarTagPanelLayout.height(baseHeight - value.translation.height,
                  available: geometry.size.height)
              }
          )
          .accessibilityElement()
          .accessibilityLabel(L10n.tr("标签面板高度"))
          .accessibilityValue(L10n.tr("\(Int(tagHeight)) 点"))
          .accessibilityHint(L10n.tr("上下拖动调整高度"))
          .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
              preferredHeight = SidebarTagPanelLayout.height(baseHeight + 20, available: geometry.size.height)
            case .decrement:
              preferredHeight = SidebarTagPanelLayout.height(baseHeight - 20, available: geometry.size.height)
            @unknown default: break
            }
          }
        tags().frame(height: tagHeight).clipped()
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private enum SidebarTagPanelLayout {
  static let dividerHeight: CGFloat = 7
  static func height(_ preferred: CGFloat, available: CGFloat) -> CGFloat {
    let usable = max(0, available - dividerHeight)
    let minimum = min(140, usable)
    let maximum = max(minimum, usable - 180)
    return min(maximum, max(minimum, preferred.isFinite ? preferred : 280))
  }
}

private struct TagPanelResizeHandle: View {
  let isDragging: Bool
  @State private var isHovering = false
  @State private var ownsCursor = false

  var body: some View {
    Color.clear
      .frame(height: SidebarTagPanelLayout.dividerHeight)
      .overlay { Divider() }
      .contentShape(Rectangle())
      .help(L10n.tr("上下拖动调整标签面板高度"))
      .onHover { hovering in isHovering = hovering; updateCursor() }
      .onChange(of: isDragging) { _, _ in updateCursor() }
      .onDisappear {
        if ownsCursor { NSCursor.pop(); ownsCursor = false }
      }
  }

  private func updateCursor() {
    let needsCursor = isHovering || isDragging
    if needsCursor && !ownsCursor { NSCursor.resizeUpDown.push(); ownsCursor = true }
    if !needsCursor && ownsCursor { NSCursor.pop(); ownsCursor = false }
  }
}
