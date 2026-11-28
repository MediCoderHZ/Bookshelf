import SwiftUI

struct MetadataUpdateView: View {
  @Environment(\.dismiss) private var dismiss
  let proposal: MetadataUpdateProposal
  let onApply: (Set<BookField>) throws -> Void

  @State private var selected: Set<BookField>
  @State private var showsAll = false
  @State private var versionConfirmed = false
  @State private var applyError: String?

  init(proposal: MetadataUpdateProposal, onApply: @escaping (Set<BookField>) throws -> Void) {
    self.proposal = proposal
    self.onApply = onApply
    _selected = State(initialValue: proposal.defaultSelection)
  }

  private var fields: [BookField] { showsAll ? BookField.metadataUpdateFields : proposal.changedFields }
  private var versionChanged: Bool { BookRecordMerge.differentEditions(proposal.current, proposal.incoming) }
  private var source: String { proposal.incoming.metadataSourceName.map(MetadataFieldOrigin.displayName(for:)) ?? L10n.tr("导入") }

  private var bookTitle: String {
    let current = proposal.current.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return current.isEmpty ? proposal.incoming.title : current
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(L10n.tr("核对元信息")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
        HStack(spacing: 8) {
          if !bookTitle.isEmpty {
            Text(bookTitle).lineLimit(1).truncationMode(.tail)
            Text("·").accessibilityHidden(true)
          }
          Text(L10n.tr("来源：\(source)")).lineLimit(1).layoutPriority(1)
        }.foregroundStyle(.secondary)
      }
      .padding(.horizontal, 22).padding(.top, 18)

      HStack {
        Picker(L10n.tr("显示字段"), selection: $showsAll) {
          Text(L10n.tr("有变化（\(proposal.changedFields.count)）")).tag(false)
          Text(L10n.tr("全部字段")).tag(true)
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
        Spacer()
        if !fields.isEmpty {
          Menu(L10n.tr("批量选择")) {
            Button(L10n.tr("仅补全空白")) { selected = proposal.defaultSelection }
            Button(L10n.tr("选中本页可用字段")) {
              selected.formUnion(showsAll ? proposal.suppliedFields : proposal.changedFields)
            }
            Button(L10n.tr("清除选择")) { selected.removeAll() }.disabled(selected.isEmpty)
          }.menuStyle(.borderlessButton).fixedSize()
        }
      }
      .padding(.horizontal, 22).padding(.vertical, 14)

      if versionChanged {
        VStack(alignment: .leading, spacing: 6) {
          Label(L10n.tr("ISBN 不同，可能是另一个版本。"), systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.semibold)).foregroundStyle(.primary)
            .symbolRenderingMode(.multicolor)
          Toggle(L10n.tr("我已核对并确认要更新此版本"), isOn: $versionConfirmed).toggleStyle(.checkbox)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 22).padding(.bottom, 12)
      }

      Divider()
      if fields.isEmpty {
        ContentUnavailableView(L10n.tr("没有待更新的字段"), systemImage: "checkmark.circle",
          description: Text(L10n.tr("可在“全部字段”中查看书籍和来源提供的信息。")))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(spacing: 14) {
          Text(L10n.tr("字段")).frame(width: 154, alignment: .leading)
          Text(L10n.tr("当前值")).frame(maxWidth: .infinity, alignment: .leading)
          Text(L10n.tr("新值")).frame(maxWidth: .infinity, alignment: .leading)
          Color.clear.frame(width: 20, height: 1).accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 22).padding(.vertical, 8)
        .background(.quaternary.opacity(0.35))
        Divider()
        ScrollView {
          VStack(spacing: 0) {
            ForEach(fields) { field in
              MetadataReviewRow(field: field, proposal: proposal, selection: $selected)
              Divider().padding(.horizontal, 22)
            }
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      Divider()
      HStack(spacing: 10) {
        if !fields.isEmpty || !selected.isEmpty {
          Text(L10n.tr("已选 \(selected.count) 项")).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        if proposal.changedFields.isEmpty && selected.isEmpty {
          Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
        } else {
          Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
          Button(L10n.tr("应用所选字段")) {
            do { try onApply(selected); dismiss() }
            catch { applyError = error.localizedDescription }
          }.keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty || (versionChanged && !versionConfirmed))
        }
      }.padding(.horizontal, 22).padding(.vertical, 12)
    }
    .frame(minWidth: 660, idealWidth: 740, maxWidth: .infinity,
           minHeight: 410, idealHeight: 510, maxHeight: .infinity)
    .onExitCommand { dismiss() }
    .alert(L10n.tr("书籍信息"), isPresented: Binding(get: { applyError != nil }, set: { if !$0 { applyError = nil } })) {
      Button(L10n.tr("好"), role: .cancel) {}
    } message: { Text(applyError ?? "") }
  }
}

private struct MetadataReviewRow: View {
  let field: BookField
  let proposal: MetadataUpdateProposal
  @Binding var selection: Set<BookField>
  @State private var showsDetails = false

  private var isSelectable: Bool { proposal.suppliedFields.contains(field) }
  private var isSelected: Bool { selection.contains(field) }
  private var current: String { displayValue(in: proposal.current) }
  private var incoming: String { displayValue(in: proposal.incoming) }

  private func displayValue(in record: BookArchive) -> String {
    if field == .isbn {
      let pair = [record.isbn13, record.isbn10].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      return pair.joined(separator: "\n")
    }
    return BookMetadataValue.read(field, from: record).text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      HStack(spacing: 7) {
        if isSelectable {
          Toggle(field.label, isOn: Binding(get: { isSelected }, set: { value in
            if value { selection.insert(field) } else { selection.remove(field) }
          })).toggleStyle(.checkbox)
        } else {
          Text(field.label).foregroundStyle(.secondary).padding(.leading, 21)
        }
      }.frame(width: 154, alignment: .leading)

      Text(current.isEmpty ? "—" : current)
        .foregroundStyle(.secondary)
        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      Text(incoming.isEmpty ? "—" : incoming)
        .foregroundStyle(isSelectable ? .primary : .secondary)
        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)

      Button { showsDetails.toggle() } label: {
        Image(systemName: "info.circle").foregroundStyle(.secondary)
          .frame(width: 20, height: 20)
      }.buttonStyle(.plain)
        .help(L10n.tr("查看\(field.label)详情")).accessibilityLabel(L10n.tr("查看\(field.label)详情"))
        .popover(isPresented: $showsDetails) {
          ScrollView {
            VStack(alignment: .leading, spacing: 14) {
              Text(field.label).font(.headline)
              detail(L10n.tr("当前值"), value: current, record: proposal.current)
              Divider()
              detail(L10n.tr("新值"), value: incoming, record: proposal.incoming)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
          }.frame(width: 340).frame(maxHeight: 350).fixedSize(horizontal: false, vertical: true)
        }
    }
    .padding(.horizontal, 22).padding(.vertical, 8)
    .background(isSelected ? Color.accentColor.opacity(0.06) : .clear)
  }

  private func detail(_ title: String, value: String, record: BookArchive) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      Text(value.isEmpty ? "—" : value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if !value.isEmpty { MetadataOriginView(field: field, record: record) }
    }
  }
}
