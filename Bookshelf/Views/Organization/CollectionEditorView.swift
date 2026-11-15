import AppKit
import SwiftData
import SwiftUI

struct CollectionMoveRequest: Identifiable {
  let id = UUID()
  let existing: ManualCollectionRecord
}

struct CollectionMoveView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @Environment(\.libraryUndoManager) private var undoManager
  @Query(sort: \BookCollection.name) private var collections: [BookCollection]
  let request: CollectionMoveRequest
  let onSave: (UUID) -> Void
  @State private var parentID: UUID?
  @State private var errorMessage: String?
  private var records: [ManualCollectionRecord] { collections.filter { !$0.isSmart }.map(ManualCollectionRecord.init) }
  private var excluded: Set<UUID> { CollectionTree.descendants(of: request.existing.id, in: records) }

  var body: some View {
    NavigationStack {
      Form {
        Picker("上级文件夹", selection: $parentID) {
          Text("顶层文件夹").tag(UUID?.none)
          ForEach(records.filter { !excluded.contains($0.id) }.sorted { CollectionTree.path($0.id, in: records) < CollectionTree.path($1.id, in: records) }) { record in
            Text(CollectionTree.path(record.id, in: records)).tag(Optional(record.id))
          }
        }
        Text("书籍可同时加入多个文件夹。上级文件夹默认只显示直接加入的内容，可在侧栏右键菜单中开启「包含子文件夹」。文件夹名称需在普通文件夹中唯一。")
          .font(.caption).foregroundStyle(.secondary)
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      }.formStyle(.grouped)
        .navigationTitle("移动文件夹")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("保存") {
              do {
                let id = try CollectionCommands(context: context, undoManager: undoManager)
                  .save(name: request.existing.name, replacing: request.existing, parentID: parentID)
                onSave(id); dismiss()
              } catch { errorMessage = error.localizedDescription }
            }.keyboardShortcut(.defaultAction)
          }
        }
    }.frame(width: 500, height: 320)
      .onAppear { parentID = request.existing.parentID }
  }
}

/// Snapshot of the existing folder: renaming must not overwrite concurrent edits.
enum InlineFolderRenameTarget {
  case folder(ManualCollectionRecord)
  case smart(SmartCollectionArchive)

  var item: CollectionOrderingItem {
    switch self {
    case .folder(let record): CollectionOrderingItem(record)
    case .smart(let record): CollectionOrderingItem(record)
    }
  }
}

/// A fresh editing-session ID rejects delayed callbacks from a previous editor.
/// The displayed row keeps the existing folder ID, hierarchy and position.
struct InlineFolderDraft: Identifiable {
  let id = UUID()
  let parentID: UUID?
  let sortOrder: Int
  let existing: InlineFolderRenameTarget?
  var name: String
  var errorMessage: String?

  init(parentID: UUID?, items: [CollectionOrderingItem]) {
    self.parentID = parentID; existing = nil
    sortOrder = CollectionOrdering.nextOrder(in: items, parentID: parentID)
    let names = Set(items.map { MetadataNormalizer.normalizedName($0.name) })
    var candidate = "新建文件夹", suffix = 2
    while names.contains(MetadataNormalizer.normalizedName(candidate)) {
      candidate = "新建文件夹 \(suffix)"; suffix += 1
    }
    name = candidate
  }
  init(renaming existing: InlineFolderRenameTarget) {
    self.existing = existing
    let item = existing.item
    parentID = item.parentID; sortOrder = item.sortOrder; name = item.name
  }
  var item: CollectionOrderingItem {
    existing?.item ?? CollectionOrderingItem(id: id, name: name, parentID: parentID,
      sortOrder: sortOrder, updatedAt: .distantPast)
  }
  var isNew: Bool { existing == nil }
  var accessibilityLabel: String { isNew ? "新建文件夹名称" : "重命名文件夹" }
}

struct InlineFolderEditorRow: View {
  @Environment(\.libraryDisplay) private var display
  let draft: InlineFolderDraft
  let onName: (String) -> Void
  let onCommit: (Bool) -> Bool
  let onCancel: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      LibraryIcon(systemName: draft.item.isSmart ? "folder.badge.gearshape" : "folder")
        .foregroundStyle(.secondary)
        .frame(width: display.iconSlotSize, height: display.iconSlotSize)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        InlineFolderNameField(text: Binding(get: { draft.name }, set: { onName($0) }), fontSize: display.fontSize,
          accessibilityLabel: draft.accessibilityLabel, onCommit: onCommit, onCancel: onCancel)
          .frame(height: max(22, display.fontSize + 7))
        if let error = draft.errorMessage {
          Text(error).font(display.caption).foregroundStyle(.red)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true).help(error)
        }
      }
    }.frame(minHeight: display.sidebarRowHeight - 2 * display.rowPadding)
  }
}

/// AppKit editing keeps Chinese composition intact and selects the proposed name
/// only once, after the row is attached to the native outline's window.
private struct InlineFolderNameField: NSViewRepresentable {
  @Binding var text: String
  let fontSize: CGFloat
  let accessibilityLabel: String
  let onCommit: (Bool) -> Bool
  let onCancel: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> MetadataTextField {
    let field = MetadataTextField(string: text)
    field.isBordered = true; field.isBezeled = true; field.bezelStyle = .roundedBezel
    field.drawsBackground = true; field.backgroundColor = .textBackgroundColor
    field.usesSingleLineMode = true; field.cell?.isScrollable = true
    field.font = .systemFont(ofSize: fontSize)
    field.setAccessibilityLabel(accessibilityLabel)
    field.delegate = context.coordinator
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.requestEditingFocus { [weak field] in field?.currentEditor()?.selectAll(nil) }
    return field
  }
  func updateNSView(_ field: MetadataTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      field.stringValue = text
    }
    field.font = .systemFont(ofSize: fontSize)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MetadataTextField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 160, height: max(22, fontSize + 7))
  }

  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: InlineFolderNameField
    private var finished = false
    init(_ parent: InlineFolderNameField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) {
      guard !finished, let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
      DispatchQueue.main.async { [weak self, weak field] in
        guard let self, !self.finished, field?.window != nil, field?.currentEditor() == nil else { return }
        self.finished = self.parent.onCommit(false)
      }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
      guard !textView.hasMarkedText() else { return false }
      switch command {
      case #selector(NSResponder.insertNewline(_:)):
        finished = parent.onCommit(true)
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        finished = true; parent.onCancel()
        return true
      default: return false
      }
    }
  }
}
