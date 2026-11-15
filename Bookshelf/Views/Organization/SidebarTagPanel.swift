import SwiftUI

struct SidebarTagPanel: View {
  @Environment(\.libraryDisplay) private var display
  let tags: [Tag]
  let bookCounts: [UUID: Int]
  @Binding var selectedIDs: Set<UUID>
  let onRename: (UUID) -> Void
  let onDelete: (UUID) -> Void
  @State private var query = ""
  @AppStorage("showAllSidebarTags") private var showsAllTags = false

  private var matchingTags: [Tag] {
    LibraryQueries.visibleTags(tags, bookCounts: bookCounts, selectedIDs: selectedIDs,
      showAll: showsAllTags, text: query)
  }

  private var emptyMessage: String {
    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "没有匹配的标签" }
    return showsAllTags || tags.isEmpty ? "暂无标签" : "当前范围暂无标签"
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        if matchingTags.isEmpty {
          Text(emptyMessage)
            .font(display.font).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.top, 24)
        } else {
          TagFlowLayout(horizontalSpacing: 4, verticalSpacing: display.rowPadding) {
            ForEach(matchingTags) { tag in tagButton(tag) }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(10)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityLabel("标签筛选")

      Divider().padding(.horizontal, 10)
      HStack(spacing: 8) {
        HStack(spacing: 6) {
          LibraryIcon(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("筛选标签", text: $query)
            .textFieldStyle(.plain).autocorrectionDisabled()
            .accessibilityLabel("筛选标签")
          if !query.isEmpty {
            Button { query = "" } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("清除标签搜索").accessibilityLabel("清除标签搜索")
          }
        }
        .font(display.font).padding(7)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

        if !selectedIDs.isEmpty {
          Button { selectedIDs.removeAll() } label: {
            LibraryIcon(systemName: "xmark")
              .foregroundStyle(.secondary)
              .frame(width: display.toolbarControlSize, height: display.toolbarControlSize)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain).fixedSize()
          .help("清除标签筛选（已选 \(selectedIDs.count) 个标签）")
          .accessibilityLabel("清除标签筛选")
        }

        Menu {
          Toggle("显示全部标签", isOn: $showsAllTags)
          Divider()
          Button("清除标签筛选") { selectedIDs.removeAll() }.disabled(selectedIDs.isEmpty)
          Button("清除标签搜索") { query = "" }.disabled(query.isEmpty)
        } label: {
          LibraryIcon(systemName: "line.3.horizontal.decrease")
            .foregroundStyle(selectedIDs.isEmpty ? Color.secondary : Color.accentColor)
            .frame(width: display.iconSlotSize, height: display.toolbarControlSize)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help(selectedIDs.isEmpty ? "标签筛选选项" : "已选择 \(selectedIDs.count) 个标签")
        .accessibilityLabel("标签筛选选项")
      }
      .padding(10)
    }
  }

  private func tagButton(_ tag: Tag) -> some View {
    let selected = selectedIDs.contains(tag.id)
    let bookCount = bookCounts[tag.id, default: 0]
    return Button {
      if !selectedIDs.insert(tag.id).inserted { selectedIDs.remove(tag.id) }
    } label: {
      Text(tag.name)
        .font(display.font).lineLimit(1)
        .padding(.horizontal, 5).padding(.vertical, display.rowPadding)
        .foregroundStyle(selected ? Color.white : (bookCount > 0 ? Color.primary : Color.secondary))
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("\(tag.name) · 当前范围 \(bookCount) 本书")
    .accessibilityLabel(tag.name).accessibilityValue("当前范围 \(bookCount) 本书")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .contextMenu {
      Button("重命名标签…") { onRename(tag.id) }
      Divider()
      Button("删除标签…", role: .destructive) { onDelete(tag.id) }
    }
  }
}

/// Text tags wrap as the sidebar width changes, without fixed-width columns.
private struct TagFlowLayout: Layout {
  let horizontalSpacing: CGFloat
  let verticalSpacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
    for (index, frame) in result.frames.enumerated() {
      subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading, proposal: ProposedViewSize(frame.size))
    }
  }

  private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
    let naturalSizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let naturalWidth = naturalSizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, subviews.count - 1)) * horizontalSpacing
    let width = max(0, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? naturalWidth)
    var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
    for (index, naturalSize) in naturalSizes.enumerated() {
      let itemWidth = min(width, naturalSize.width)
      let size = subviews[index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
      if x > 0, x + itemWidth > width {
        x = 0; y += rowHeight + verticalSpacing; rowHeight = 0
      }
      frames.append(CGRect(x: x, y: y, width: itemWidth, height: size.height))
      x += itemWidth + horizontalSpacing
      rowHeight = max(rowHeight, size.height)
    }
    return (CGSize(width: width, height: y + rowHeight), frames)
  }
}
