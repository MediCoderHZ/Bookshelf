import SwiftData
import SwiftUI

struct BookBatchEditRequest: Identifiable {
  let id = UUID()
  let records: [BookArchive]
  let tagNames: [String]
}

struct BookBatchEditView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @Environment(\.libraryUndoManager) private var undoManager
  let request: BookBatchEditRequest
  @State private var draft = BookBatchEditDraft()
  @State private var selectedID: UUID?
  @State private var errorMessage: String?

  init(request: BookBatchEditRequest) {
    self.request = request
    _selectedID = State(initialValue: request.records.first?.id)
  }
  private var plan: BookBatchEditPlan? {
    try? BookBatchEditing.prepare(request.records, draft: draft, knownTagNames: request.tagNames)
  }
  private var selectedTags: [String] {
    var seen = Set<String>()
    return request.records.flatMap(\.tags).sorted().filter { seen.insert(MetadataNormalizer.normalizedName($0)).inserted }
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 0) {
        Text(L10n.tr("已选择 \(request.records.count) 本书。默认保持原样；先设置需要修改的项，再逐本核对右侧预览。应用后可撤销整次修改。"))
          .font(.callout).foregroundStyle(.secondary).padding(18)
        Divider()
        GeometryReader { geometry in
          HSplitView {
            editForm.frame(minWidth: 300, idealWidth: 320, maxWidth: 380)
              .frame(height: geometry.size.height)
            preview.frame(minWidth: 480, maxWidth: .infinity)
              .frame(height: geometry.size.height, alignment: .top)
          }.frame(width: geometry.size.width, height: geometry.size.height)
        }.clipped()
        Divider()
        HStack {
          if let message = draft.validationMessage ?? errorMessage {
            Text(message).foregroundStyle(.red)
          } else {
            Text(L10n.tr("将修改 \(plan?.changedItems.count ?? 0) 本，保持 \(request.records.count - (plan?.changedItems.count ?? 0)) 本不变。"))
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(L10n.tr("重置修改项")) { draft = BookBatchEditDraft(); errorMessage = nil }
        }.font(.callout).padding(16)
      }
      .navigationTitle(L10n.tr("批量编辑书籍"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("取消")) { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.tr("应用到 \(plan?.changedItems.count ?? 0) 本书")) { apply() }
            .disabled(plan?.changedItems.isEmpty ?? true)
        }
      }
    }.frame(width: 960, height: 690)
      .onChange(of: draft) { _, _ in errorMessage = nil }
  }

  private var editForm: some View {
    Form {
      Section(L10n.tr("标签")) {
        TextField(L10n.tr("添加标签"), text: $draft.tagsToAdd, prompt: Text(L10n.tr("逗号或顿号分隔")), axis: .vertical)
          .lineLimit(1...3).accessibilityLabel(L10n.tr("批量添加标签"))
        if !request.tagNames.isEmpty {
          Menu(L10n.tr("选择已有标签")) {
            ForEach(request.tagNames, id: \.self) { tag in
              Button(tag) { draft.tagsToAdd += draft.tagsToAdd.isEmpty ? tag : "、" + tag }
            }
          }
        }
        if !selectedTags.isEmpty {
          Text(L10n.tr("勾选要从所选书籍移除的标签")).font(.caption).foregroundStyle(.secondary)
          ForEach(selectedTags, id: \.self) { tag in
            let key = MetadataNormalizer.normalizedName(tag)
            let count = request.records.filter { $0.tags.contains { MetadataNormalizer.normalizedName($0) == key } }.count
            Toggle(L10n.tr("\(tag)（\(count)/\(request.records.count) 本）"), isOn: Binding(
              get: { draft.tagsToRemove.contains(key) },
              set: { if $0 { draft.tagsToRemove.insert(key) } else { draft.tagsToRemove.remove(key) } }
            )).toggleStyle(.checkbox).accessibilityLabel(L10n.tr("移除标签 \(tag)，\(count) 本"))
          }
        }
      }
      Section(L10n.tr("出版信息")) {
        ForEach(BatchMetadataField.allCases) { field in
          BatchMetadataRow(field: field, change: Binding(
            get: { draft.metadata[field] ?? BatchTextChange() },
            set: { draft.metadata[field] = $0 }
          ))
        }
        Text(L10n.tr("实际修改的出版字段会标记为手动编辑。"))
          .font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped)
  }

  @ViewBuilder private var preview: some View {
    if let plan {
      VStack(alignment: .leading, spacing: 0) {
        Text(L10n.tr("逐本预览")).font(.headline).padding(14)
        List(plan.items, selection: $selectedID) { item in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(item.before.title).lineLimit(1)
              Text(BookField.authors.value(in: item.before).isEmpty ? L10n.tr("未知作者") : BookField.authors.value(in: item.before))
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.hasChanges ? L10n.tr("\(item.differences.count) 项修改") : L10n.tr("无需修改"))
              .font(.caption).foregroundStyle(item.hasChanges ? Color.accentColor : .secondary)
          }.tag(item.id)
        }.frame(minHeight: 100, idealHeight: 180, maxHeight: 220)
        Divider()
        if let item = plan.items.first(where: { $0.id == selectedID }) {
          if item.differences.isEmpty {
            ContentUnavailableView(L10n.tr("此书无需修改"), systemImage: "checkmark.circle",
              description: Text(L10n.tr("未启用修改项，或已有内容符合设置。")))
          } else {
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                ForEach(item.differences) { difference in
                  VStack(alignment: .leading, spacing: 6) {
                    HStack {
                      Text(difference.label).font(.headline)
                      if difference.isMetadata { Text(L10n.tr("来源 → 手动编辑")).font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack(alignment: .top, spacing: 12) {
                      valueColumn(L10n.tr("当前"), value: difference.oldValue)
                      Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 20)
                      valueColumn(L10n.tr("修改后"), value: difference.newValue)
                    }
                  }
                }
              }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        } else { ContentUnavailableView(L10n.tr("选择一本书核对差异"), systemImage: "doc.text.magnifyingglass") }
      }
    } else {
      ContentUnavailableView(L10n.tr("请先完善修改项"), systemImage: "square.and.pencil",
        description: Text(draft.validationMessage ?? L10n.tr("无法预览所选书籍，请关闭后重新选择。")))
    }
  }

  private func valueColumn(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value.isEmpty ? L10n.tr("（空）") : value).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func apply() {
    guard let plan, !plan.changedItems.isEmpty else { return }
    do {
      try BookBatchEditing.apply(plan, context: context, undoManager: undoManager)
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
}

private struct BatchMetadataRow: View {
  let field: BatchMetadataField
  @Binding var change: BatchTextChange
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(field.field.label, selection: $change.mode) {
        ForEach(BatchValueMode.allCases) { Text($0.title).tag($0) }
      }
      if change.mode.needsValue {
        TextField(field.placeholder, text: $change.value)
          .accessibilityLabel(L10n.tr("批量\(field.field.label)"))
      }
      if change.mode == .clear { Text(L10n.tr("清除所选书籍的\(field.field.label)")).font(.caption).foregroundStyle(.orange) }
    }
  }
}
