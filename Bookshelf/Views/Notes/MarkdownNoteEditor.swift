import AppKit
import SwiftUI

struct MarkdownNoteEditor: View {
  @Environment(\.libraryDisplay) private var display
  @Binding var text: String
  let focusToken: UUID?
  let noteID: UUID
  let positions: NoteEditorPositionStore
  @State private var controller = RichNoteEditorController()
  @State private var showingLink = false
  @State private var linkRange = NSRange(location: 0, length: 0)
  @State private var linkLabel = ""
  @State private var linkURL = ""
  private var toolbarItemSize: CGFloat { display.toolbarControlSize }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: display.toolbarSpacing) {
        Menu {
          Button("正文") { controller.apply(.heading(0)) }
          ForEach(1...6, id: \.self) { level in Button("\(level) 级标题") { controller.apply(.heading(level)) } }
        } label: {
          Text("Aa").font(.system(size: display.iconSize, weight: .regular))
            .frame(width: toolbarItemSize, height: toolbarItemSize)
        }.help("段落格式")
          .accessibilityLabel("段落格式").menuStyle(.button).buttonStyle(.plain)
          .menuIndicator(.hidden).frame(width: toolbarItemSize, height: toolbarItemSize)
        formatButton("加粗（⌘B）", "bold", .bold)
        formatButton("斜体（⌘I）", "italic", .italic)
        formatButton("删除线", "strikethrough", .strike)
        Menu {
          Button("无序列表") { controller.apply(.bullet) }
          Button("有序列表") { controller.apply(.ordered) }
          Button("任务列表") { controller.apply(.task) }
        } label: { toolbarIcon("list.bullet") }.help("列表")
          .accessibilityLabel("列表").menuStyle(.button).buttonStyle(.plain)
          .menuIndicator(.hidden).frame(width: toolbarItemSize, height: toolbarItemSize)
        formatButton("引用", "text.quote", .quote)
        Button {
          guard let view = controller.textView else { return }
          linkRange = view.selectedRange()
          linkLabel = (view.string as NSString).substring(with: linkRange)
          linkURL = linkRange.location < view.attributedString().length
            ? (view.attributedString().attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)?.absoluteString ?? "https://"
            : "https://"
          showingLink = true
        } label: { toolbarIcon("link") }
          .frame(width: toolbarItemSize, height: toolbarItemSize)
          .help("编辑链接").accessibilityLabel("编辑链接")
          .popover(isPresented: $showingLink) { linkEditor }
        Menu {
          Button("行内代码") { controller.apply(.code) }
          Button("代码块") { controller.apply(.codeBlock) }
        } label: { toolbarIcon("chevron.left.forwardslash.chevron.right") }.help("代码")
          .accessibilityLabel("代码").menuStyle(.button).buttonStyle(.plain)
          .menuIndicator(.hidden).frame(width: toolbarItemSize, height: toolbarItemSize)
        Spacer(minLength: 0)
      }.buttonStyle(.plain).labelStyle(.iconOnly)
        .padding(.horizontal, 10).padding(.vertical, 8)
      Divider()
      NativeRichNoteEditor(text: $text, controller: controller, focusToken: focusToken,
        noteID: noteID, positions: positions)
        .frame(minHeight: 160, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
  }
  private var linkEditor: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("编辑链接").font(.headline)
      TextField("显示文字", text: $linkLabel).disabled(linkRange.length > 0)
      TextField("https://…", text: $linkURL).accessibilityLabel("链接网址")
      HStack {
        Button("移除链接") { controller.textView?.setLink(nil, range: linkRange, label: linkLabel); showingLink = false }
          .disabled(linkRange.length == 0)
        Spacer()
        Button("应用") {
          controller.textView?.setLink(linkURL, range: linkRange, label: linkLabel)
          showingLink = false
          if let view = controller.textView { view.window?.makeFirstResponder(view) }
        }.disabled(RichNoteCodec.safeLink(linkURL) == nil).keyboardShortcut(.defaultAction)
      }
    }.textFieldStyle(.roundedBorder).padding(14).frame(width: 280)
  }
  private func formatButton(_ label: String, _ symbol: String, _ action: NoteMarkdownFormat) -> some View {
    Button { controller.apply(action) } label: { toolbarIcon(symbol) }
      .frame(width: toolbarItemSize, height: toolbarItemSize)
      .help(label).accessibilityLabel(label)
  }
  private func toolbarIcon(_ symbol: String) -> some View {
    LibraryIcon(systemName: symbol)
      .foregroundStyle(Color(nsColor: .secondaryLabelColor))
      .frame(width: toolbarItemSize, height: toolbarItemSize)
      .contentShape(Rectangle())
  }
}

@MainActor
final class RichNoteEditorController {
  weak var textView: RichNoteTextView?
  func apply(_ format: NoteMarkdownFormat) { textView?.apply(format) }
}

private struct NativeRichNoteEditor: NSViewRepresentable {
  @Binding var text: String
  let controller: RichNoteEditorController
  let focusToken: UUID?
  let noteID: UUID
  let positions: NoteEditorPositionStore
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NoteEditorScrollView {
    let scroll = NoteEditorScrollView()
    scroll.hasVerticalScroller = true; scroll.drawsBackground = false
    let view = RichNoteTextView(frame: .zero)
    view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    view.load(text)
    view.onChange = { [weak coordinator = context.coordinator] source in coordinator?.parent.text = source }
    controller.textView = view; scroll.documentView = view
    context.coordinator.tracker = NoteEditorPositionTracker(noteID: noteID, store: positions, scroll: scroll, view: view)
    return scroll
  }
  func updateNSView(_ scroll: NoteEditorScrollView, context: Context) {
    context.coordinator.parent = self
    guard let view = scroll.documentView as? RichNoteTextView else { return }
    if view.source != text && !view.hasMarkedText() {
      context.coordinator.tracker?.reload(text)
    }
    if let focusToken, positions.consumeFocus(focusToken) {
      DispatchQueue.main.async { [weak coordinator = context.coordinator] in
        coordinator?.tracker?.focus()
      }
    }
  }
  static func dismantleNSView(_ scroll: NoteEditorScrollView, coordinator: Coordinator) {
    coordinator.tracker?.stop(); coordinator.tracker = nil
    (scroll.documentView as? RichNoteTextView)?.onChange = nil
  }
  final class Coordinator {
    var parent: NativeRichNoteEditor
    var tracker: NoteEditorPositionTracker?
    init(_ parent: NativeRichNoteEditor) { self.parent = parent }
  }
}

struct MarkdownNotePreview: View {
  let source: String
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("暂无正文").foregroundStyle(.secondary)
        }
        ForEach(Array(NoteMarkdown.blocks(from: source).enumerated()), id: \.offset) { _, block in
          if block.rule { Divider() }
          else {
            HStack(alignment: .top, spacing: 8) {
              if block.quoteDepth > 0 { Rectangle().fill(.quaternary).frame(width: 3) }
              if let marker = block.marker { Text(marker).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing) }
              Text(block.text).font(block.code ? .system(.body, design: .monospaced) :
                block.heading.map { .system(size: $0 == 1 ? 24 : $0 == 2 ? 20 : 16, weight: .semibold) } ?? .body)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(block.code ? 10 : 0)
            .background(block.code ? Color(nsColor: .quaternaryLabelColor).opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .padding(.leading, CGFloat(max(0, block.listDepth - 1) * 18))
          }
        }
      }.textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }.background(Color(nsColor: .textBackgroundColor)).accessibilityLabel("Markdown 预览")
  }
}

