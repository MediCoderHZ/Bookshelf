import AppKit
import SwiftData
import SwiftUI

/// Each person owns a complete metadata row. Controls keep their layout space
/// but are drawn only while the pointer is over that person's name area.
struct ContributorListField: View {
  @Environment(\.libraryDisplay) private var display
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Environment(\.modelContext) private var context
  @Environment(\.libraryUndoManager) private var undoManager
  @Environment(BookMetadataEditingSession.self) private var editing
  @Query private var contributions: [Contribution]
  let book: Book
  let field: BookField
  @State private var focusRowID: UUID?
  @State private var focusToken: UUID?
  @State private var hoveredRowID: UUID?
  @State private var emptyRowHovered = false
  @State private var showsAll = false

  private static let collapsedCount = 5
  private var record: BookArchive { BookArchive(book: book) }
  private var storedValue: BookMetadataValue { .read(field, from: record) }
  private var state: BookMetadataDraft? { editing.draft(book.id, field) }
  private var rows: [ContributorNameDraft] { state?.contributorRows ?? [] }
  private var visibleRows: [ContributorNameDraft] { showsAll ? rows : Array(rows.prefix(Self.collapsedCount)) }
  private var isReadOnly: Bool { book.deletedAt != nil }
  private var label: some View {
    Text(field.label).foregroundStyle(.secondary)
      .frame(width: display.metadataLabelWidth, alignment: .trailing)
  }

  var body: some View {
    let usages = contributions.compactMap(ContributorNameUsage.init)
    VStack(alignment: .leading, spacing: display.inspectorRowSpacing) {
      if isReadOnly {
        if case .contributors(let people) = storedValue {
          if people.isEmpty {
            HStack(alignment: .top, spacing: 10) { label; Spacer(minLength: 0) }
              .frame(minHeight: display.inspectorRowHeight, alignment: .top)
          }
          ForEach(Array(people.prefix(showsAll ? people.count : Self.collapsedCount).enumerated()), id: \.offset) { _, person in
            HStack(alignment: .top, spacing: 10) {
              label
              Text(person.name).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: display.inspectorRowHeight, alignment: .top)
          }
          expansionControl(count: people.count)
        }
      } else {
        if rows.isEmpty { emptyRow }
        ForEach(visibleRows) { row in nameRow(row, usages: usages) }
        expansionControl(count: rows.count)
        if let state, let message = state.errorMessage, state.isDirty {
          VStack(alignment: .leading, spacing: 6) {
            Text(message).font(display.font).foregroundStyle(.red).textSelection(.enabled)
            HStack {
              Button(L10n.tr("重试")) { finishCurrentEditing(); commit() }
              Button(L10n.tr("放弃修改")) {
                finishCurrentEditing()
                editing.discard(book.id, field: field)
                editing.prepareContributors(record, field: field)
              }
            }.font(display.font).buttonStyle(.borderless)
          }.padding(.leading, display.metadataLabelWidth + 10)
        }
      }
    }.font(display.font).frame(maxWidth: .infinity, alignment: .leading)
      .onAppear { reconcile(); if state?.isDirty == true { showsAll = true }; handleFocusRequest() }
      .onChange(of: storedValue) { _, _ in reconcile() }
      .onChange(of: editing.focusRequest?.token) { _, _ in handleFocusRequest() }
  }

  private var emptyRow: some View {
    HStack(alignment: .top, spacing: 10) {
      label
      HStack(spacing: 4) {
        Button { add(after: nil) } label: {
          Color.clear.frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: display.inspectorRowHeight).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L10n.tr("填写") + field.label)
        Button { add(after: nil) } label: { actionIcon("plus.circle") }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .accessibilityLabel(L10n.tr("添加") + field.label).help(L10n.tr("添加一位") + field.label)
          .opacity(emptyRowHovered || voiceOverEnabled ? 1 : 0)
          .allowsHitTesting(emptyRowHovered || voiceOverEnabled)
          .accessibilityHidden(!emptyRowHovered && !voiceOverEnabled)
      }.contentShape(Rectangle())
        .background(ContributorNameHoverRegion { emptyRowHovered = $0 })
    }
  }

  private func nameRow(_ row: ContributorNameDraft, usages: [ContributorNameUsage]) -> some View {
    let showsActions = hoveredRowID == row.id || voiceOverEnabled
    return HStack(alignment: .top, spacing: 10) {
      label
      HStack(alignment: .top, spacing: 4) {
        ContributorNameInput(value: row.name, field: field,
          usages: usages,
          focusToken: focusRowID == row.id ? focusToken : nil,
          onFocus: {
            focusRowID = nil; focusToken = nil
            if editing.focusRequest?.bookID == book.id && editing.focusRequest?.field == field {
              editing.focusRequest = nil
            }
          },
          onBegin: { editing.prepareContributors(record, field: field) },
          onChange: { editing.updateContributor(book.id, field: field, rowID: row.id, name: $0) },
          onCommit: { commit() },
          onCancel: {
            editing.cancelContributor(book.id, field: field, rowID: row.id)
            editing.prepareContributors(record, field: field)
            return name(for: row.id)
          }, currentValue: { name(for: row.id) })
          .id(row.id).frame(maxWidth: .infinity)
        ContributorRowActions(field: field, name: row.name,
          index: rows.firstIndex { $0.id == row.id } ?? 0, count: rows.count,
          onRemove: {
            finishCurrentEditing()
            hoveredRowID = nil
            editing.removeContributor(book.id, field: field, rowID: row.id, context: context, undoManager: undoManager)
          }, onAdd: { add(after: row.id) }, onMove: { move(row.id, to: $0) },
          rowHeight: display.inspectorRowHeight)
          .opacity(showsActions ? 1 : 0)
          .allowsHitTesting(showsActions)
          .accessibilityHidden(!showsActions)
      }
      .contentShape(Rectangle())
      .background(ContributorNameHoverRegion { inside in
        if inside { hoveredRowID = row.id }
        else if hoveredRowID == row.id { hoveredRowID = nil }
      })
    }
  }

  private func actionIcon(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.system(size: min(18, display.fontSize + 2)))
      .frame(width: 20, height: display.inspectorRowHeight).contentShape(Rectangle())
  }

  @ViewBuilder private func expansionControl(count: Int) -> some View {
    if count > Self.collapsedCount {
      Button(showsAll ? L10n.tr("收起") : L10n.tr("还有 \(count - Self.collapsedCount) 位") + field.label + "…") {
        finishCurrentEditing()
        guard isReadOnly || commit() else { return }
        showsAll.toggle()
      }.buttonStyle(.plain).font(display.font).foregroundStyle(.secondary)
        .padding(.leading, display.metadataLabelWidth + 10)
    }
  }

  private func add(after rowID: UUID?) {
    finishCurrentEditing()
    guard commit() else { return }
    showsAll = true
    focusRowID = editing.addContributor(record, field: field, after: rowID)
    focusToken = UUID()
  }
  private func name(for id: UUID) -> String { rows.first { $0.id == id }?.name ?? "" }
  private func reconcile() {
    if !isReadOnly { editing.prepareContributors(record, field: field) }
  }
  private func finishCurrentEditing() { NSApp.keyWindow?.makeFirstResponder(nil) }
  @discardableResult private func commit() -> Bool {
    editing.commit(book.id, field: field, context: context, undoManager: undoManager)
  }
  private func handleFocusRequest() {
    guard !isReadOnly, let request = editing.focusRequest, request.bookID == book.id, request.field == field else { return }
    reconcile()
    showsAll = true
    focusRowID = rows.first?.id ?? editing.addContributor(record, field: field)
    focusToken = request.token
  }
  private func move(_ id: UUID, to destination: Int) {
    finishCurrentEditing()
    showsAll = true
    editing.moveContributor(book.id, field: field, rowID: id, to: destination, context: context, undoManager: undoManager)
  }
}

/// Shared row actions keep the sheet and inspector consistent.
private struct ContributorRowActions: View {
  @Environment(\.libraryDisplay) private var display
  let field: BookField
  let name: String
  let index: Int
  let count: Int
  let onRemove: () -> Void
  let onAdd: () -> Void
  let onMove: (Int) -> Void
  var rowHeight: CGFloat? = nil

  var body: some View {
    HStack(spacing: 2) {
      Button(action: onRemove) { icon("minus.circle") }
        .buttonStyle(.plain).accessibilityLabel(L10n.tr("删除") + field.label + " " + name)
        .help(L10n.tr("删除此") + field.label)
      Button(action: onAdd) { icon("plus.circle") }
        .buttonStyle(.plain).accessibilityLabel(L10n.tr("在") + name + L10n.tr("下方添加") + field.label)
        .help(L10n.tr("在此行下方添加") + field.label)
      Menu {
        Button(L10n.tr("上移")) { onMove(index - 1) }.disabled(index == 0)
        Button(L10n.tr("下移")) { onMove(index + 1) }.disabled(index == count - 1)
        Divider()
        Button(L10n.tr("移至首位")) { onMove(0) }.disabled(index == 0)
        Button(L10n.tr("移至末位")) { onMove(count - 1) }.disabled(index == count - 1)
      } label: { icon("ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(L10n.tr("调整") + field.label + L10n.tr("顺序 ") + name).help(L10n.tr("调整") + field.label + L10n.tr("顺序"))
    }.foregroundStyle(.secondary)
  }

  private func icon(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.system(size: min(18, display.fontSize + 2)))
      .frame(width: 20, height: rowHeight ?? max(22, display.fontSize + 4)).contentShape(Rectangle())
  }
}

/// Reuses native completion and row actions, while all changes stay in the
/// enclosing book sheet's draft until its Save button is pressed.
struct DraftContributorListField: View {
  @Environment(\.libraryDisplay) private var display
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Query private var contributions: [Contribution]
  @Binding var draft: ContributorListDraft
  let field: BookField
  @State private var focusRowID: UUID?
  @State private var focusToken: UUID?
  @State private var hoveredRowID: UUID?
  @State private var errorMessage: String?

  var body: some View {
    let usages = contributions.compactMap(ContributorNameUsage.init)
    VStack(alignment: .leading, spacing: display.fieldSpacing) {
      ForEach(draft.rows) { row in
        HStack(alignment: .top, spacing: 10) {
          Text(field.label).foregroundStyle(.secondary)
            .frame(width: display.metadataLabelWidth, alignment: .trailing)
          HStack(alignment: .top, spacing: 4) {
            ContributorNameInput(value: row.name, field: field, usages: usages,
              focusToken: focusRowID == row.id ? focusToken : nil,
              onFocus: { focusRowID = nil; focusToken = nil }, onBegin: {},
              onChange: { draft.update(row.id, name: $0); errorMessage = nil },
              onCommit: { commit(row.id) },
              onCancel: { draft.cancel(row.id); errorMessage = nil; return name(for: row.id) },
              currentValue: { name(for: row.id) })
              .id(row.id).frame(maxWidth: .infinity)
            let showsActions = hoveredRowID == row.id || voiceOverEnabled
            ContributorRowActions(field: field, name: row.name,
              index: draft.rows.firstIndex { $0.id == row.id } ?? 0, count: draft.rows.count,
              onRemove: {
                finishCurrentEditing()
                hoveredRowID = nil; errorMessage = nil
                draft.remove(row.id)
              }, onAdd: { add(after: row.id) }, onMove: { destination in
                finishCurrentEditing()
                guard validate() else { return }
                draft.move(row.id, to: destination)
              })
              .opacity(showsActions ? 1 : 0)
              .allowsHitTesting(showsActions)
              .accessibilityHidden(!showsActions)
          }.contentShape(Rectangle())
            .background(ContributorNameHoverRegion { inside in
              if inside { hoveredRowID = row.id }
              else if hoveredRowID == row.id { hoveredRowID = nil }
            })
        }
      }
      if let errorMessage {
        Text(errorMessage).font(display.caption).foregroundStyle(.red)
          .padding(.leading, display.metadataLabelWidth + 10)
      }
    }.font(display.font).frame(maxWidth: .infinity, alignment: .leading)
  }

  private func name(for id: UUID) -> String { draft.rows.first { $0.id == id }?.name ?? "" }
  private func finishCurrentEditing() { NSApp.keyWindow?.makeFirstResponder(nil) }
  private func commit(_ id: UUID) -> Bool {
    do { try draft.commit(id); errorMessage = nil; return true }
    catch { errorMessage = error.localizedDescription; return false }
  }
  private func validate() -> Bool {
    do { try draft.validate(); errorMessage = nil; return true }
    catch { errorMessage = error.localizedDescription; return false }
  }
  private func add(after id: UUID) {
    finishCurrentEditing()
    guard validate() else { return }
    focusRowID = draft.add(after: id)
    focusToken = UUID()
  }
}

/// Track the full name-and-actions area without intercepting native field-editor
/// events. AppKit tracking also works when a NSTextField occupies the whole row.
private struct ContributorNameHoverRegion: NSViewRepresentable {
  let onHover: (Bool) -> Void
  func makeNSView(context: Context) -> HoverView { HoverView(onHover: onHover) }
  func updateNSView(_ view: HoverView, context: Context) { view.onHover = onHover }
  static func dismantleNSView(_ view: HoverView, coordinator: ()) { view.stopMonitoring() }

  final class HoverView: NSView {
    var onHover: (Bool) -> Void
    private var isInside = false
    private var eventMonitor: Any?
    init(onHover: @escaping (Bool) -> Void) { self.onHover = onHover; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDown]) { [weak self] event in
        guard let self else { return event }
        self.refreshHover(event: event)
        return event
      }
    }
    func stopMonitoring() {
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      for area in trackingAreas { removeTrackingArea(area) }
      addTrackingArea(NSTrackingArea(rect: bounds,
        options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { refreshHover(event: event) }
    override func mouseMoved(with event: NSEvent) { refreshHover(event: event) }
    override func mouseExited(with event: NSEvent) { refreshHover(event: event) }
    private func refreshHover(event: NSEvent) {
      guard let window, event.window === window else { setInside(false); return }
      let point = convert(event.locationInWindow, from: nil)
      setInside(!isHiddenOrHasHiddenAncestor && bounds.intersection(visibleRect).contains(point))
    }
    private func setInside(_ value: Bool) {
      guard value != isInside else { return }
      isInside = value
      onHover(value)
    }
  }
}
