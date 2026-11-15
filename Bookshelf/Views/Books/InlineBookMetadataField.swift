import AppKit
import SwiftData
import SwiftUI

struct InlineBookMetadataField: View {
  @Environment(\.libraryDisplay) private var display
  @Environment(\.modelContext) private var context
  @Environment(\.libraryUndoManager) private var undoManager
  @Environment(BookMetadataEditingSession.self) private var editing
  let book: Book
  let field: BookField
  var suggestions: ((String) -> [NameSuggestion])? = nil
  var isInspectorTitle = false
  @State private var isEditing = false

  private var value: String {
    if let draft = editing.draft(book.id, field), draft.isDirty { return draft.text }
    return BookMetadataValue.read(field, from: BookArchive(book: book)).text
  }
  private var focusToken: UUID? {
    // The header shares the title draft, but recovery focus belongs to the info row.
    guard !isInspectorTitle else { return nil }
    guard let request = editing.focusRequest, request.bookID == book.id, request.field == field else { return nil }
    return request.token
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Group {
        if let suggestions {
          MetadataSuggestionInput(input: nativeInput, suggestions: suggestions(value),
            noun: field.label, systemImage: "building.2")
        } else {
          nativeInput
            .padding(.horizontal, isInspectorTitle ? 4 : 0)
            .padding(.vertical, isInspectorTitle ? 2 : 0)
            .overlay {
              if isInspectorTitle && isEditing {
                RoundedRectangle(cornerRadius: 5)
                  .strokeBorder(Color.accentColor, lineWidth: 1)
                  .allowsHitTesting(false)
              }
            }
            .help(editingHelp)
        }
      }.id(BookMetadataDraft.key(book.id, field))
      if let draft = editing.draft(book.id, field), let message = draft.errorMessage, draft.isDirty {
        Text(message).font(display.font).foregroundStyle(.red).textSelection(.enabled)
        HStack {
          Button("重试") { editing.commit(book.id, field: field, context: context, undoManager: undoManager) }
          Button("放弃修改") { editing.discard(book.id, field: field) }
        }.font(display.font).buttonStyle(.borderless)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var nativeInput: NativeBookMetadataField {
    NativeBookMetadataField(value: value, label: isInspectorTitle ? "顶部标题" : field.label,
        multiline: field == .description,
        focusToken: focusToken,
        onFocus: {
          if !isInspectorTitle && editing.focusRequest?.bookID == book.id && editing.focusRequest?.field == field {
            editing.focusRequest = nil
          }
        },
        onBegin: { editing.begin(BookArchive(book: book), field: field) },
        onChange: { editing.update(book.id, field: field, text: $0) },
        onCommit: { editing.commit(book.id, field: field, context: context, undoManager: undoManager) },
        onCancel: { editing.discard(book.id, field: field); return value },
        currentValue: { value },
        onEditingChange: { isEditing = $0 }, fitsTextHeight: isInspectorTitle)
  }
  private var editingHelp: String {
    switch field {
    case .authors, .translators:
      "点击编辑；多位作者或译者用顿号、分号或换行分隔，姓名中的逗号保留。回车或离开字段自动保存。"
    case .description:
      "点击编辑，回车换行，Tab 或离开字段自动保存；Esc 取消当前修改。"
    default:
      "点击编辑，回车、Tab 或离开字段自动保存；Esc 取消当前修改。"
    }
  }
}

/// Native field-editor lifecycle: Chinese composition remains inside AppKit;
/// Return/Tab/blur commit once, Escape cancels, row changes and window close flush.
struct NativeBookMetadataField: NSViewRepresentable {
  @Environment(\.libraryDisplay) private var display
  let value: String
  let label: String
  let multiline: Bool
  let focusToken: UUID?
  let onFocus: () -> Void
  let onBegin: () -> Void
  let onChange: (String) -> Void
  let onCommit: () -> Bool
  let onCancel: () -> String
  let currentValue: () -> String
  var onMoveSuggestion: (NameSuggestionSelection.Direction) -> Bool = { _ in false }
  var selectedSuggestion: () -> String? = { nil }
  var onDismissSuggestions: () -> Bool = { false }
  var onEditingChange: (Bool) -> Void = { _ in }
  var onCompositionChange: (Bool) -> Void = { _ in }
  var replacement: MetadataFieldReplacement? = nil
  var fitsTextHeight = false
  private var resolvedFont: NSFont { .systemFont(ofSize: display.fontSize) }

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> MetadataTextField {
    let field = MetadataTextField(string: value)
    field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
    field.font = resolvedFont
    field.placeholderString = nil
    field.setAccessibilityLabel(label)
    field.isEditable = true; field.isSelectable = true
    field.usesSingleLineMode = false; field.maximumNumberOfLines = 0
    field.lineBreakMode = .byWordWrapping
    field.cell?.wraps = true; field.cell?.isScrollable = false
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.delegate = context.coordinator
    context.coordinator.field = field
    context.coordinator.observeClosing()
    return field
  }
  func updateNSView(_ field: MetadataTextField, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    if field.font != resolvedFont {
      field.font = resolvedFont
      if let editor = field.currentEditor() { editor.font = field.font }
      field.invalidateIntrinsicContentSize()
    }
    if !coordinator.isEditing && field.stringValue != value {
      field.stringValue = value; field.invalidateIntrinsicContentSize()
    }
    if let focusToken, coordinator.handledFocus != focusToken {
      coordinator.handledFocus = focusToken
      field.requestEditingFocus(onFocus)
    }
    if let replacement, coordinator.handledReplacement != replacement.id {
      coordinator.handledReplacement = replacement.id
      DispatchQueue.main.async { [weak coordinator, weak field] in
        guard let field, field.window != nil else { return }
        coordinator?.acceptSuggestion(replacement.text)
      }
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MetadataTextField, context: Context) -> CGSize? {
    let width = max(40, proposal.width ?? 180)
    let measured = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10000)).height ?? 20
    // A taller NSTextField draws at the top; size the header to its actual text
    // and let the surrounding title bar provide balanced vertical padding.
    return CGSize(width: width, height: max(fitsTextHeight ? 0 : 20, ceil(measured)))
  }
  static func dismantleNSView(_ field: MetadataTextField, coordinator: Coordinator) {
    coordinator.finish(field)
    NotificationCenter.default.removeObserver(coordinator)
    field.delegate = nil
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: NativeBookMetadataField
    weak var field: NSTextField?
    var isEditing = false
    var handledFocus: UUID?
    var handledReplacement: UUID?
    init(_ parent: NativeBookMetadataField) { self.parent = parent }
    func observeClosing() {
      NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)), name: NSWindow.willCloseNotification, object: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(applicationClosing(_:)), name: NSApplication.willTerminateNotification, object: nil)
    }
    @objc private func windowClosing(_ notification: Notification) {
      guard let field, notification.object as? NSWindow === field.window else { return }
      finish(field)
    }
    @objc private func applicationClosing(_ notification: Notification) {
      if let field { finish(field) }
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
      parent.onBegin(); isEditing = true
      parent.onEditingChange(true)
      field?.drawsBackground = true; field?.backgroundColor = .textBackgroundColor
    }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      let marked = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
      parent.onCompositionChange(marked)
      guard !marked else { return }
      parent.onChange(field.stringValue); field.invalidateIntrinsicContentSize()
    }
    func controlTextDidEndEditing(_ notification: Notification) {
      if let field = notification.object as? NSTextField { finish(field) }
    }
    func finish(_ field: NSTextField) {
      parent.onEditingChange(false)
      parent.onCompositionChange(false)
      guard isEditing else { return }
      isEditing = false
      parent.onChange(field.stringValue)
      _ = parent.onCommit()
      field.stringValue = parent.currentValue()
      field.drawsBackground = false; field.invalidateIntrinsicContentSize()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
      guard !textView.hasMarkedText(), let field else { return false }
      switch command {
      case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
        guard NSEvent.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty else { return false }
        return parent.onMoveSuggestion(command == #selector(NSResponder.moveDown(_:)) ? .down : .up)
      case #selector(NSResponder.insertNewline(_:)):
        if parent.multiline && !NSEvent.modifierFlags.contains(.command) {
          textView.insertNewlineIgnoringFieldEditor(nil)
          return true
        }
        if let name = parent.selectedSuggestion() { acceptSuggestion(name, editor: textView); return true }
        parent.onChange(textView.string)
        if parent.onCommit() {
          isEditing = false
          parent.onEditingChange(false)
          field.window?.makeFirstResponder(nil)
          field.stringValue = parent.currentValue(); field.drawsBackground = false
        }
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        if parent.onDismissSuggestions() { return true }
        isEditing = false
        parent.onEditingChange(false)
        let value = parent.onCancel()
        field.window?.makeFirstResponder(nil)
        field.stringValue = value; field.drawsBackground = false
        return true
      default: return false
      }
    }

    /// Replace the complete field, not only the word at the caret, then save once.
    func acceptSuggestion(_ name: String, editor: NSTextView? = nil) {
      guard let field else { return }
      let editor = editor ?? field.currentEditor() as? NSTextView
      guard editor?.hasMarkedText() != true else { return }
      if !isEditing { parent.onBegin(); isEditing = true }
      if let editor {
        editor.insertText(name, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
      } else { field.stringValue = name }
      parent.onChange(name)
      if parent.onCommit() {
        isEditing = false; parent.onEditingChange(false)
        field.window?.makeFirstResponder(nil)
        field.stringValue = parent.currentValue(); field.drawsBackground = false
        field.invalidateIntrinsicContentSize()
      }
    }
  }
}

struct MetadataFieldReplacement {
  let text: String
  let id = UUID()
}

/// SwiftUI may request focus before inserting a newly revealed field into its window.
final class MetadataTextField: NSTextField {
  private var wantsEditingFocus = false
  private var didFocus: (() -> Void)?
  func requestEditingFocus(_ completion: @escaping () -> Void) {
    wantsEditingFocus = true
    didFocus = completion
    focusWhenAttached()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    focusWhenAttached()
  }
  private func focusWhenAttached() {
    guard wantsEditingFocus, window != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.wantsEditingFocus, let window = self.window else { return }
      self.wantsEditingFocus = false
      self.scrollToVisible(self.bounds)
      if window.makeFirstResponder(self) { self.didFocus?() }
      self.didFocus = nil
    }
  }
}
