import AppKit
import SwiftUI

/// Local presentation state; the library remains responsible for creating and assigning tags.
struct TagSuggestionSelection {
  enum Direction { case up, down }
  private(set) var selectedID: String?
  private(set) var isDismissed = false

  mutating func reset() {
    selectedID = nil
    isDismissed = false
  }

  mutating func dismiss() {
    selectedID = nil
    isDismissed = true
  }

  @discardableResult
  mutating func move(_ direction: Direction, in suggestions: [TagSuggestion]) -> Bool {
    guard !suggestions.isEmpty else { return false }
    isDismissed = false
    let available = suggestions.filter { !$0.isAssigned }
    if let index = available.firstIndex(where: { $0.id == selectedID }) {
      let next = direction == .down ? min(index + 1, available.count - 1) : max(index - 1, 0)
      selectedID = available[next].id
    } else {
      selectedID = (direction == .down ? available.first : available.last)?.id
    }
    return true
  }

  func selected(in suggestions: [TagSuggestion]) -> TagSuggestion? {
    guard !isDismissed else { return nil }
    return suggestions.first { $0.id == selectedID && !$0.isAssigned }
  }
}

struct TagInputView: View {
  @Environment(\.libraryDisplay) private var display
  @Binding var text: String
  let suggestions: [TagSuggestion]
  let onAdd: (String) -> Void
  var focusToken: UUID? = nil
  var onCancel: (() -> Void)? = nil
  @State private var selection = TagSuggestionSelection()

  private var isShowingSuggestions: Bool { !selection.isDismissed && !suggestions.isEmpty }
  private var alreadyAssigned: Bool {
    suggestions.contains { $0.id == MetadataNormalizer.normalizedName(text) && $0.isAssigned }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        NativeTagTextField(text: Binding(get: { text }, set: { text = $0; selection.reset() }),
          onMove: { selection.move($0, in: suggestions) },
          onSubmit: { onAdd(selection.selected(in: suggestions)?.name ?? text) },
          onDismiss: {
            let wasVisible = isShowingSuggestions
            selection.dismiss()
            if wasVisible { return true }
            guard let onCancel else { return false }
            onCancel()
            return true
          },
          onFocusChange: { focused in
            if focused { selection.reset() } else { selection.dismiss() }
          }, focusToken: focusToken)
        Button { onAdd(text) } label: { Image(systemName: "plus.circle") }
          .buttonStyle(.borderless).help(alreadyAssigned ? L10n.tr("此书已包含该标签") : L10n.tr("添加标签"))
          .disabled(MetadataNormalizer.normalizedName(text).isEmpty || alreadyAssigned)
      }
      if isShowingSuggestions {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(suggestions) { suggestion in
                suggestionRow(suggestion).id(suggestion.id)
              }
            }
          }
          .frame(height: CGFloat(min(suggestions.count, 5)) * display.sidebarRowHeight)
          .onChange(of: selection.selectedID, initial: true) { _, id in
            if let id = id ?? suggestions.first?.id { proxy.scrollTo(id) }
          }
          .onChange(of: suggestions) { _, _ in
            if let id = selection.selected(in: suggestions)?.id ?? suggestions.first?.id { proxy.scrollTo(id) }
          }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
      }
    }
    .onChange(of: text) { _, _ in selection.reset() }
  }

  private func suggestionRow(_ suggestion: TagSuggestion) -> some View {
    let selected = selection.selected(in: suggestions)?.id == suggestion.id
    return Button { onAdd(suggestion.name) } label: {
      HStack(spacing: 6) {
        Image(systemName: "tag")
        Text(suggestion.name).lineLimit(1)
        Spacer(minLength: 4)
        if suggestion.isAssigned { Text(L10n.tr("已添加")).font(display.font).foregroundStyle(.secondary) }
      }
      .padding(.horizontal, 8).frame(height: display.sidebarRowHeight)
      .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
      .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain).disabled(suggestion.isAssigned)
    .help(suggestion.isAssigned ? L10n.tr("此书已包含标签 \(suggestion.name)") : L10n.tr("添加已有标签 \(suggestion.name)"))
    .accessibilityLabel("\(suggestion.name)\(suggestion.isAssigned ? L10n.tr("，已添加") : L10n.tr("，添加已有标签"))")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// Handle field-editor commands after the input method has had a chance to consume the key.
struct NativeTagTextField: NSViewRepresentable {
  @Environment(\.locale) private var locale
  @Environment(\.libraryDisplay) private var display
  @Binding var text: String
  var onMove: (TagSuggestionSelection.Direction) -> Bool
  var onSubmit: () -> Void
  var onDismiss: () -> Bool
  var onFocusChange: (Bool) -> Void
  var focusToken: UUID? = nil

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> MetadataTextField {
    let field = MetadataTextField(string: text)
    field.placeholderString = L10n.tr("添加标签")
    field.setAccessibilityLabel(L10n.tr("添加标签"))
    field.bezelStyle = .roundedBezel
    field.font = .systemFont(ofSize: display.fontSize)
    field.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ field: MetadataTextField, context: Context) {
    let _ = locale
    field.placeholderString = L10n.tr("添加标签")
    field.setAccessibilityLabel(L10n.tr("添加标签"))
    context.coordinator.parent = self
    if field.font?.pointSize != display.fontSize {
      field.font = .systemFont(ofSize: display.fontSize)
      field.currentEditor()?.font = field.font
      field.invalidateIntrinsicContentSize()
    }
    if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      field.stringValue = text
    }
    if let focusToken, context.coordinator.handledFocus != focusToken {
      context.coordinator.handledFocus = focusToken
      field.requestEditingFocus({})
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MetadataTextField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 180, height: nsView.intrinsicContentSize.height)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: NativeTagTextField
    var handledFocus: UUID?
    init(_ parent: NativeTagTextField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func controlTextDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
    func controlTextDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
      guard !textView.hasMarkedText() else { return false }
      switch command {
      case #selector(NSResponder.moveDown(_:)): return parent.onMove(.down)
      case #selector(NSResponder.moveUp(_:)): return parent.onMove(.up)
      case #selector(NSResponder.insertNewline(_:)):
        parent.onSubmit()
        return true
      case #selector(NSResponder.cancelOperation(_:)): return parent.onDismiss()
      default: return false
      }
    }
  }
}
