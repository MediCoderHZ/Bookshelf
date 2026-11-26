import SwiftUI
import SwiftData

@MainActor
enum LibraryUndoLabel {
  static func title(_ manager: UndoManager?, redo: Bool = false) -> String {
    let name = redo ? manager?.redoActionName : manager?.undoActionName
    guard let name, !name.isEmpty else { return redo ? L10n.tr("重做") : L10n.tr("撤销") }
    return redo ? L10n.tr("重做\(name)") : L10n.tr("撤销\(name)")
  }
}

struct LibraryUndoButtons: View {
  @Environment(\.modelContext) private var context
  @Environment(\.libraryUndoManager) private var manager
  private var history: LibraryHistory { LibraryServices.forContext(context).history }
  var body: some View {
    HStack(spacing: 6) {
      Button(L10n.tr("撤销"), systemImage: "arrow.uturn.backward") { manager?.undo() }
        .disabled(!(manager?.canUndo ?? false))
        .help(LibraryUndoLabel.title(manager))
        .accessibilityLabel(LibraryUndoLabel.title(manager))
      Button(L10n.tr("重做"), systemImage: "arrow.uturn.forward") { manager?.redo() }
        .disabled(!(manager?.canRedo ?? false))
        .help(LibraryUndoLabel.title(manager, redo: true))
        .accessibilityLabel(LibraryUndoLabel.title(manager, redo: true))
    }.id(history.revision)
  }
}

struct LibraryUndoMenuItems: View {
  @Environment(\.modelContext) private var context
  @Environment(\.libraryUndoManager) private var manager
  private var history: LibraryHistory { LibraryServices.forContext(context).history }
  var body: some View {
    Group {
      Button(LibraryUndoLabel.title(manager), systemImage: "arrow.uturn.backward") { manager?.undo() }
        .disabled(!(manager?.canUndo ?? false))
      Button(LibraryUndoLabel.title(manager, redo: true), systemImage: "arrow.uturn.forward") { manager?.redo() }
        .disabled(!(manager?.canRedo ?? false))
    }.id(history.revision)
  }
}

struct DuplicateReviewPanel: View {
  @Environment(\.libraryDisplay) private var display
  let hasDuplicates: Bool
  var body: some View {
    Text(hasDuplicates ? L10n.tr("点击一本重复书籍，查看整组合并预览。") : L10n.tr("未发现重复书目"))
      .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      .font(display.font).padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("重复书目合并面板"))
  }
}

struct MetadataOriginView: View {
  let field: BookField
  let record: BookArchive
  private var origin: MetadataFieldOrigin? { BookRecordMerge.origins(record)[field.rawValue] }
  private var legacy: Bool { origin?.inferred == true || (record.metadataFieldSourcesJSON == nil && record.metadataSourceName != nil) }
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      if let origin {
        if let value = origin.url, let url = URL(string: value), url.scheme == "https", url.host != nil {
          Link(origin.displayName, destination: url)
        } else { Text(origin.displayName) }
        if legacy { Text(L10n.tr("历史来源，未逐字段记录")) }
        if let date = origin.retrievedAt { Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))) }
      } else { Text(L10n.tr("手动录入或未记录来源")) }
    }.font(.caption).foregroundStyle(.secondary)
  }
}

struct BookMergeRequest: Identifiable {
  let id = UUID()
  let records: [BookArchive]
  var bookIDs: Set<UUID> { Set(records.map(\.id)) }
}

/// A preview only: field choices stay local until the explicit confirmation.
struct BookMergePanel: View {
  @Environment(\.modelContext) private var context
  @Environment(\.libraryUndoManager) private var undoManager
  @Environment(\.libraryDisplay) private var display
  let request: BookMergeRequest
  let onCancel: () -> Void
  let onMerged: (UUID) -> Void
  @State private var primaryID: UUID
  @State private var choices: [BookField: UUID] = [:]
  @State private var errorMessage: String?

  init(request: BookMergeRequest, onCancel: @escaping () -> Void, onMerged: @escaping (UUID) -> Void) {
    self.request = request
    self.onCancel = onCancel
    self.onMerged = onMerged
    _primaryID = State(initialValue: request.records[0].id)
  }
  private var primary: BookArchive { request.records.first { $0.id == primaryID } ?? request.records[0] }
  private var differentVersions: Bool {
    Set(request.records.compactMap { ISBN.identity($0.isbn13) ?? ISBN.identity($0.isbn10) }).count > 1
  }
  private var combined: BookArchive {
    BookRecordMerge.combine(primary: primary, others: request.records.filter { $0.id != primaryID }, choices: choices)
  }
  private var fields: [BookField] {
    // Empty in every record means there is no value to compare or choose.
    BookField.allCases.filter { !fieldCandidates($0).isEmpty }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(L10n.tr("合并 \(request.records.count) 本书"))
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: display.fieldSpacing) {
          Text(L10n.tr("保留主记录")).foregroundStyle(.secondary)
          Menu {
            Picker(L10n.tr("保留主记录"), selection: $primaryID) {
              ForEach(request.records, id: \.id) { record in
                Text(recordLabel(record)).tag(record.id)
              }
            }.pickerStyle(.inline)
          } label: {
            valueLabel(recordLabel(primary))
          }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel(L10n.tr("保留主记录")).accessibilityValue(recordLabel(primary))
          Text(L10n.tr("添加日期：\(primary.addedAt.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(L10n.locale)))"))
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if differentVersions {
            Text(L10n.tr("有效 ISBN 不同，这些记录应作为不同版本保留，不能合并。"))
              .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
          }
          Divider()
          Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: display.inspectorRowSpacing) {
            ForEach(fields) { field in
              GridRow(alignment: .top) {
                fieldLabel(field.label)
                let candidates = fieldCandidates(field)
                if candidates.count > 1 {
                  fieldMenu(field, candidates: candidates)
                } else {
                  resultValue(field.value(in: combined)).textSelection(.enabled)
                }
              }
            }
          }
          if !combined.tags.isEmpty || !combined.collections.isEmpty {
            Divider()
            if !combined.tags.isEmpty { summaryRow(L10n.tr("标签"), combined.tags.joined(separator: "、")) }
            if !combined.collections.isEmpty { summaryRow(L10n.tr("文件夹"), combined.collections.joined(separator: "、")) }
          }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      VStack(alignment: .leading, spacing: display.fieldSpacing) {
        Text(L10n.tr("标签、文件夹与笔记会汇总；其余记录移入回收站，合并后可撤销。"))
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let errorMessage {
          Text(errorMessage).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
          Button(L10n.tr("取消"), action: onCancel)
          Spacer(minLength: 8)
          Button(L10n.tr("确认合并"), action: merge).buttonStyle(.borderedProminent).disabled(differentVersions)
        }
      }.padding(12)
    }.font(display.font).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("书籍合并预览"))
      .onChange(of: primaryID) { _, _ in errorMessage = nil }
  }

  private func fieldCandidates(_ field: BookField) -> [BookArchive] {
    BookRecordMerge.fieldCandidates(field, in: [primary] + request.records.filter { $0.id != primaryID },
      preferredID: choices[field])
  }

  private func fieldMenu(_ field: BookField, candidates: [BookArchive]) -> some View {
    let value = field.value(in: combined)
    return Menu {
      Section(L10n.tr("保留\(field.label)")) {
        ForEach(candidates, id: \.id) { record in
          // Every menu action is an explicit, exclusive choice, including a
          // click on the checked default. Keep the native menu checkmark.
          Toggle(L10n.tr("\(field.value(in: record)) · 记录 \(recordNumber(record))"), isOn: Binding(
            get: { record.id == (choices[field] ?? candidates[0].id) },
            set: { _ in choices[field] = record.id }
          ))
        }
      }
    } label: {
      valueLabel(value)
    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel(L10n.tr("选择\(field.label)")).accessibilityValue(value)
      .help(L10n.tr("选择要保留的\(field.label)"))
  }

  private func resultValue(_ value: String) -> some View {
    Text(value).fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, minHeight: display.inspectorRowHeight, alignment: .topLeading)
  }

  private func valueLabel(_ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(value).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }.frame(minHeight: display.inspectorRowHeight, alignment: .topLeading).contentShape(Rectangle())
  }

  private func fieldLabel(_ label: String) -> some View {
    Text(label).foregroundStyle(.secondary)
      .frame(width: display.metadataLabelWidth, alignment: .trailing)
      .frame(minHeight: display.inspectorRowHeight, alignment: .topTrailing)
  }

  private func summaryRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      fieldLabel(label)
      Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func merge() {
    do {
      let id = try LibraryOperations.merge(request.records, primaryID: primaryID, choices: choices,
        context: context, undoManager: undoManager)
      onMerged(id)
    } catch { errorMessage = error.localizedDescription }
  }

  private func recordNumber(_ record: BookArchive) -> Int {
    (request.records.firstIndex(where: { $0.id == record.id }) ?? 0) + 1
  }
  private func recordLabel(_ record: BookArchive) -> String {
    "\(recordNumber(record)). \(record.title) · \(record.publisher ?? L10n.tr("未知出版社"))"
  }
}

struct MetadataUpdateProposal: Identifiable {
  let id = UUID()
  let current: BookArchive
  let incoming: BookArchive
}

struct MetadataUpdateView: View {
  @Environment(\.dismiss) private var dismiss
  let proposal: MetadataUpdateProposal
  let onApply: (Set<BookField>) throws -> Void
  @State private var applyError: String?
  @State private var selected = Set<BookField>()
  @State private var versionConfirmed = false
  private var versionChanged: Bool { BookRecordMerge.differentEditions(proposal.current, proposal.incoming) }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 14) {
        Text(L10n.tr("逐字段核对后填入，默认只补全空白。没有提供的新值不会清空已有内容。"))
          .foregroundStyle(.secondary)
        HStack {
          Button(L10n.tr("仅补全空白")) { selectEmpty() }
          Button(L10n.tr("选择全部新值")) {
            selected = Set(BookField.allCases.filter { !$0.value(in: proposal.incoming).isEmpty })
          }
          Button(L10n.tr("全部保留当前值")) { selected = [] }
          Spacer()
          Text(L10n.tr("来源：\(proposal.incoming.metadataSourceName.map(MetadataFieldOrigin.displayName(for:)) ?? L10n.tr("导入"))")).font(.caption)
        }
        if versionChanged {
          Text(L10n.tr("新旧 ISBN 不同。请特别核对作者、译者、出版社和出版日期，避免混合不同版本。")).foregroundStyle(.orange)
          Toggle(L10n.tr("我已核对并确认要更新此版本"), isOn: $versionConfirmed)
        }
        ScrollView {
          Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow { Text(L10n.tr("采用新值")); Text(L10n.tr("字段")); Text(L10n.tr("当前值")).bold(); Text(L10n.tr("新值")).bold() }
            Divider()
            ForEach(BookField.allCases) { field in
              GridRow {
                Toggle(field.label, isOn: Binding(get: { selected.contains(field) }, set: {
                  if $0 { selected.insert(field) } else { selected.remove(field) }
                })).labelsHidden().disabled(field.value(in: proposal.incoming).isEmpty)
                  .accessibilityLabel(L10n.tr("采用新\(field.label)"))
                Text(field.label).foregroundStyle(.secondary)
                FieldValueView(field: field, record: proposal.current, showsOrigin: true)
                FieldValueView(field: field, record: proposal.incoming, showsOrigin: true)
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }.padding(22)
      .navigationTitle(L10n.tr("确认元信息更新"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("取消")) { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.tr("应用所选字段")) {
            do { try onApply(selected); dismiss() }
            catch { applyError = error.localizedDescription }
          }
            .disabled(selected.isEmpty || (versionChanged && !versionConfirmed)).keyboardShortcut(.defaultAction)
        }
      }
    }.frame(width: 850, height: 650).onAppear(perform: selectEmpty)
      .alert(L10n.tr("书籍信息"), isPresented: Binding(get: { applyError != nil }, set: { if !$0 { applyError = nil } })) {
        Button(L10n.tr("好"), role: .cancel) {}
      } message: { Text(applyError ?? "") }
  }
  private func selectEmpty() {
    selected = BookRecordMerge.defaultMetadataFields(current: proposal.current, incoming: proposal.incoming)
  }
}

struct FieldValueView: View {
  let field: BookField
  let record: BookArchive
  var showsOrigin = false
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(field.value(in: record).isEmpty ? "—" : field.value(in: record))
        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      if showsOrigin && !field.value(in: record).isEmpty {
        MetadataOriginView(field: field, record: record)
      }
    }
  }
}

struct ImportPreviewView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @Environment(\.libraryUndoManager) private var undoManager
  let plan: LibraryImportPlan
  let onComplete: (LibraryImportSummary) -> Void
  @State private var choices: [UUID: ImportChoice] = [:]
  @State private var selection: UUID?
  @State private var errorMessage: String?
  @State private var includeSmartCollections = true
  @State private var includeOrganization = true

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 12) {
        Text(L10n.tr("共 \(plan.items.count) 条。冲突默认跳过；“合并补全”保留已有值，“采用导入”替换提供的出版字段。两种更新均保留并汇总笔记、标签和文件夹。"))
          .font(.callout).foregroundStyle(.secondary)
        if !plan.smartCollections.isEmpty {
          Toggle(L10n.tr("同时导入 \(plan.smartCollections.count) 个智能文件夹（同 ID 或同名保留本地）"), isOn: $includeSmartCollections)
            .toggleStyle(.checkbox)
          DisclosureGroup(L10n.tr("查看智能文件夹")) {
            ScrollView {
              VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.smartCollections) { record in
                  VStack(alignment: .leading, spacing: 4) {
                    Text("\(record.name) · \(record.query.mode.title) · \(plan.existingSmartIDs.contains(record.id) ? L10n.tr("已有或重复，跳过") : L10n.tr("新增"))")
                    Text(record.query.rules.map(\.summary).joined(separator: "；"))
                      .font(.caption).foregroundStyle(.secondary)
                  }
                    .font(.caption)
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 120)
          }
        }
        if !plan.manualCollections.isEmpty || !plan.notes.isEmpty {
          Toggle(L10n.tr("导入文件夹层级（\(plan.manualCollections.count) 个）与笔记（\(plan.notes.count) 条）"), isOn: $includeOrganization)
            .toggleStyle(.checkbox)
          DisclosureGroup(L10n.tr("查看文件夹与笔记处理方式")) {
            ScrollView {
              VStack(alignment: .leading, spacing: 7) {
                Text(L10n.tr("同 ID 或同名文件夹沿用本地位置；同 ID 笔记保留本地。未导入且不在本地的所属书籍，其子笔记会跳过。取消勾选时，图书仍按原有名称恢复普通文件夹归属。"))
                  .foregroundStyle(.secondary)
                ForEach(plan.manualCollections) { record in
                  let existing = plan.collectionBaseline[record.id] != nil || plan.collectionBaseline.values.contains {
                    MetadataNormalizer.normalizedName($0.name) == MetadataNormalizer.normalizedName(record.name)
                  }
                  Text("\(CollectionTree.path(record.id, in: plan.manualCollections)) · \(!includeOrganization ? L10n.tr("未选择导入") : existing ? L10n.tr("沿用本地") : L10n.tr("新增"))")
                }
                ForEach(plan.notes) { note in
                  VStack(alignment: .leading, spacing: 2) {
                    Text("\(note.displayTitle) · \(note.parentBookID == nil ? L10n.tr("独立笔记") : L10n.tr("书籍子笔记")) · \(willImport(note) ? L10n.tr("新增") : L10n.tr("跳过"))")
                    Text(note.body).foregroundStyle(.secondary).lineLimit(2)
                  }
                }
              }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140)
          }
        }
        HSplitView {
          List(plan.items, selection: $selection) { item in
            VStack(alignment: .leading, spacing: 5) {
              Text(item.record.title).bold()
              Text((choices[item.id] ?? item.defaultChoice).action.title).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 5).tag(item.id)
          }.frame(minWidth: 220, idealWidth: 260)
          if let item = plan.items.first(where: { $0.id == selection }) {
            // macOS selectable grid text can retain the previous record's contents.
            // Recreate the comparison when switching the incoming record.
            itemDetail(item).id(item.id).padding(.leading, 14).frame(minWidth: 540)
          } else {
            ContentUnavailableView(plan.items.isEmpty ? L10n.tr("请核对上方文件夹与笔记") : L10n.tr("选择记录以核对"), systemImage: "doc.text.magnifyingglass")
          }
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        Text(L10n.tr("应用前不会改动书库。完成后可撤销本次导入。备份中的回收站状态会保留。"))
          .font(.caption).foregroundStyle(.secondary)
      }.padding(20)
      .navigationTitle(L10n.tr("导入冲突预览"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("取消")) { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.tr("执行所选操作")) {
            do {
              let summary = try LibraryImportPlanner.apply(plan, choices: choices, context: context, undoManager: undoManager,
                includeSmartCollections: includeSmartCollections, includeOrganization: includeOrganization)
              onComplete(summary); dismiss()
            } catch { errorMessage = error.localizedDescription }
          }.disabled(plan.items.isEmpty && (plan.smartCollections.isEmpty || !includeSmartCollections) &&
            (!includeOrganization || (plan.manualCollections.isEmpty && plan.notes.isEmpty))).keyboardShortcut(.defaultAction)
        }
      }
    }.frame(width: 980, height: 690)
      .onAppear { selection = plan.items.first?.id }
  }

  private func itemDetail(_ item: ImportPreviewItem) -> some View {
    let choice = choices[item.id] ?? item.defaultChoice
    let target = item.matches.first { $0.id == choice.targetID }
    let canUpdate = target.map { !BookRecordMerge.differentEditions(item.record, $0) } ?? false
    return VStack(alignment: .leading, spacing: 12) {
      Text(item.explanation).foregroundStyle(.secondary)
      if !item.matches.isEmpty {
        Picker(L10n.tr("对应的本地记录"), selection: Binding(get: { choice.targetID ?? item.matches[0].id }, set: {
          choices[item.id] = ImportChoice(action: .skip, targetID: $0)
        })) {
          ForEach(item.matches, id: \.id) { match in
            Text("\((item.matches.firstIndex(where: { $0.id == match.id }) ?? 0) + 1). \(match.title) · \(match.publisher ?? L10n.tr("未知出版社")) · \(match.isbn13 ?? match.isbn10 ?? L10n.tr("无 ISBN"))\(match.deletedAt == nil ? "" : L10n.tr(" · 回收站"))")
              .tag(match.id)
          }
        }
      }
      Picker(L10n.tr("处理方式"), selection: Binding(get: { choice.action }, set: {
        choices[item.id] = ImportChoice(action: $0, targetID: choice.targetID)
      })) {
        Text(ImportAction.skip.title).tag(ImportAction.skip)
        Text(ImportAction.add.title).tag(ImportAction.add)
        if canUpdate {
          Text(ImportAction.fill.title).tag(ImportAction.fill)
          Text(ImportAction.update.title).tag(ImportAction.update)
        }
      }
      ScrollView {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 12) {
          GridRow { Text(L10n.tr("字段")); Text(L10n.tr("本地")).bold(); Text(L10n.tr("备份")).bold() }
          ForEach(BookField.allCases) { field in
            GridRow {
              Text(field.label).foregroundStyle(.secondary)
              if let target { FieldValueView(field: field, record: target) } else { Text("—") }
              FieldValueView(field: field, record: item.record)
            }
          }
          GridRow { Text(L10n.tr("笔记")); Text(target?.notes ?? "—"); Text(item.record.notes ?? "—") }
          GridRow { Text(L10n.tr("标签")); Text(target?.tags.joined(separator: "、") ?? "—"); Text(item.record.tags.joined(separator: "、")) }
          GridRow { Text(L10n.tr("文件夹")); Text(target?.collections.joined(separator: "、") ?? "—"); Text(item.record.collections.joined(separator: "、")) }
        }.textSelection(.enabled).id(choice.targetID)
      }
    }
  }

  private func willImport(_ note: NoteRecord) -> Bool {
    guard includeOrganization, plan.noteBaseline[note.id] == nil else { return false }
    guard let parent = note.parentBookID else { return true }
    guard let item = plan.items.first(where: { $0.id == parent }) else { return false }
    let choice = choices[item.id] ?? item.defaultChoice
    return choice.action != .skip || item.matches.contains { $0.id == parent && !BookRecordMerge.differentEditions(item.record, $0) }
  }
}
