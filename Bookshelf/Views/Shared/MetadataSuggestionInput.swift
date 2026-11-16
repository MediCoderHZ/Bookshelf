import AppKit
import SwiftUI

/// A single interaction for name and publisher completion, including IME-safe keyboard handling.
struct MetadataSuggestionInput: View {
  @Environment(\.libraryDisplay) private var display
  let input: NativeBookMetadataField
  let suggestions: [NameSuggestion]
  let noun: String
  let systemImage: String
  @State private var selection = NameSuggestionSelection()
  @State private var isEditing = false
  @State private var isComposing = false
  @State private var replacement: MetadataFieldReplacement?

  private var isShowingSuggestions: Bool {
    isEditing && !isComposing && !selection.isDismissed && !suggestions.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      NativeBookMetadataField(value: input.value, label: input.label, multiline: false,
        focusToken: input.focusToken, onFocus: input.onFocus,
        onBegin: { selection.reset(); input.onBegin() },
        onChange: { selection.reset(); input.onChange($0) },
        onCommit: { selection.dismiss(); return input.onCommit() },
        onCancel: input.onCancel, currentValue: input.currentValue,
        onMoveSuggestion: { direction in
          guard isEditing && !isComposing else { return false }
          return selection.move(direction, in: suggestions)
        },
        selectedSuggestion: { isShowingSuggestions ? selection.selected(in: suggestions)?.name : nil },
        onDismissSuggestions: {
          guard isShowingSuggestions else { return false }
          selection.dismiss(); return true
        },
        onEditingChange: { active in
          isEditing = active
          if !active { selection.dismiss() }
        },
        onCompositionChange: { isComposing = $0 }, replacement: replacement)
        .help(L10n.tr("输入") + noun + L10n.tr("匹配书库；↑/↓ 选择，回车填入并保存。Esc 关闭候选，再按一次取消当前修改。"))
      if isShowingSuggestions {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(suggestions) { suggestion in
                suggestionRow(suggestion).id(suggestion.id)
              }
            }
          }.frame(height: CGFloat(min(suggestions.count, 5)) * display.sidebarRowHeight)
            .onAppear {
              if let id = selection.selected(in: suggestions)?.id { proxy.scrollTo(id) }
            }
            .onChange(of: selection.selectedID) { _, id in
              if let id { proxy.scrollTo(id) }
            }
            .onChange(of: suggestions) { _, _ in
              if let id = selection.selected(in: suggestions)?.id ?? suggestions.first?.id { proxy.scrollTo(id) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .accessibilityLabel(L10n.tr("已有") + noun + L10n.tr("候选"))
      }
    }
  }

  private func suggestionRow(_ suggestion: NameSuggestion) -> some View {
    let selected = selection.selected(in: suggestions)?.id == suggestion.id
    return Button {
      // Keep AppKit's field editor alive until it applies the complete value and commits.
      replacement = MetadataFieldReplacement(text: suggestion.name)
      selection.dismiss()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: systemImage).font(.system(size: 11))
        Text(suggestion.name).lineLimit(1)
        Spacer(minLength: 0)
      }.font(display.font).padding(.horizontal, 6).frame(height: display.sidebarRowHeight)
        .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
        .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
        .contentShape(Rectangle())
    }.buttonStyle(.plain).help(L10n.tr("填入已有") + noun + "：" + suggestion.name)
      .accessibilityLabel(L10n.tr("填入") + noun + " " + suggestion.name)
      .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
