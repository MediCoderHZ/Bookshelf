import SwiftData
import SwiftUI

struct TagEditorRequest: Identifiable {
  let id = UUID()
  let source: TagRecord
}

struct TagEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @Environment(\.libraryUndoManager) private var undoManager
  @Query(sort: \Tag.name) private var tags: [Tag]
  @Query private var notes: [LibraryNote]
  let source: TagRecord
  let onSave: (UUID) -> Void
  @State private var name = ""
  @State private var errorMessage: String?
  @FocusState private var focused: Bool

  private var target: TagRecord? {
    tags.first { $0.id != source.id && $0.normalizedName == MetadataNormalizer.normalizedName(name) }
      .map { TagRecord($0, notes: notes) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("重命名标签").font(.headline)
      TextField("标签名称", text: $name).textFieldStyle(.roundedBorder).focused($focused)
        .accessibilityLabel("标签名称")
      if let target {
        Label("合并到已有标签“\(target.name)”", systemImage: "arrow.triangle.merge").font(.callout.weight(.medium))
        Text("合并后共关联 \(source.bookIDs.union(target.bookIDs).count) 本书和 \(source.noteIDs.union(target.noteIDs).count) 条笔记。重复关联只保留一次，原标签“\(source.name)”将移除。")
          .font(.callout).foregroundStyle(.secondary)
      } else {
        Text("同步更新使用“\(source.name)”的 \(source.bookIDs.count) 本书和 \(source.noteIDs.count) 条笔记。")
          .font(.callout).foregroundStyle(.secondary)
      }
      Text("范围包括回收站中的条目。此操作可以撤销。")
        .font(.caption).foregroundStyle(.secondary)
      if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(target == nil ? "重命名" : "合并标签") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(MetadataNormalizer.normalizedName(name).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines) == source.name)
      }
    }
    .padding(24).frame(width: 420)
    .onAppear { name = source.name; focused = true }
    .onChange(of: name) { _, _ in errorMessage = nil }
  }

  private func save() {
    do {
      let id = try TagCommands(context: context, undoManager: undoManager).rename(source, to: name, merging: target)
      onSave(id); dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
}
