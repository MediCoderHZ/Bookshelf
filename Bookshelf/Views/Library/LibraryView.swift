import AppKit
import SwiftData
import SwiftUI

struct LibraryView: View {
  @Environment(\.libraryDisplay) private var display
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext
  @Environment(NoteEditingSession.self) private var noteEditing
  @AppStorage("libraryTableColumnCustomization.v1") private var savedColumns = Data()
  @State private var aiBook: Book?
  @State private var webLinkBook: Book?
  @State private var managingAttachments: AttachmentManagementTarget?
  @State private var attachmentError: String?
  @State private var attachmentItems: [UUID: AttachmentItem] = [:]
  let books: [Book]
  let notes: [NoteRecord]
  let isTrash: Bool
  @Binding var selectedBookIDs: Set<UUID>
  @Binding var selectedNoteIDs: Set<UUID>
  @Binding var selectedAttachmentIDs: Set<LibraryItemID>
  @Binding var selectedTrashItemIDs: Set<LibraryItemID>
  @Binding var expandedBookIDs: Set<UUID>
  @Binding var sortOrder: [KeyPathComparator<Book>]
  let collections: [BookCollection]
  let currentCollectionID: UUID?
  let onNewNote: (UUID) -> Void
  let onTemplateNote: (NoteRecord) -> Void
  let onEditNote: (NoteRecord) -> Void
  let onTrashNote: (NoteRecord) -> Void
  let onMoveNote: ([NoteDragBatch], NoteDropDestination) -> Void
  let canRestoreItems: (Set<LibraryItemID>) -> Bool
  let onRestoreItems: (Set<LibraryItemID>) -> Void
  let onPurgeItems: (Set<LibraryItemID>) -> Void
  let onCollection: (Set<UUID>, BookCollection, Bool) -> Void
  let onTrash: (Set<UUID>, Bool) -> Void
  let onMerge: (Set<UUID>) -> Void
  let onPurge: (Set<UUID>) -> Void

  var body: some View {
    // Keep the same native table and column state when there are no rows.
    table.sheet(item: $aiBook) { AIBookCompletionView(book: $0) }
      .sheet(item: $webLinkBook) { WebAttachmentEditor(book: $0) }
      .sheet(item: $managingAttachments) { target in
        BookAttachmentView(book: target.book, initialAttachmentID: target.attachmentID)
      }
      .onChange(of: visibleAttachmentRows, initial: true) { _, visible in
        selectedAttachmentIDs.formIntersection(visible)
        refreshAttachmentItems(for: visible)
      }
      .onReceive(NotificationCenter.default.publisher(for: .bookAttachmentFilesDidChange)) { notification in
        if let id = notification.object as? UUID {
          refreshAttachmentItems(for: visibleAttachmentRows, reloading: [id])
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        refreshAttachmentItems(for: visibleAttachmentRows, reloading: Set(attachmentItems.keys))
      }
      .alert(L10n.tr("附件"), isPresented: Binding(get: { attachmentError != nil },
        set: { if !$0 { attachmentError = nil } })) {
        Button(L10n.tr("好"), role: .cancel) {}
      } message: { Text(attachmentError ?? "") }
  }

  private var rows: [LibraryItemRow] {
    LibraryItemTree.rows(books: books, notes: notes, inTrash: isTrash, attachmentItems: attachmentItems)
      .sorted(using: sortOrder.map { LibraryItemSort(bookComparator: $0) })
  }

  private var visibleAttachmentRows: Set<LibraryItemID> {
    guard !isTrash else { return [] }
    var visible: Set<LibraryItemID> = []
    for book in books where book.deletedAt == nil && expandedBookIDs.contains(book.id) {
      for id in book.attachmentIDs ?? [] { visible.insert(.attachment(bookID: book.id, id: id)) }
    }
    return visible
  }

  private func refreshAttachmentItems(for visible: Set<LibraryItemID>, reloading: Set<UUID> = []) {
    let ids = Set(visible.compactMap { $0.attachmentReference?.id })
    var items = attachmentItems.filter { ids.contains($0.key) && !reloading.contains($0.key) }
    if let store = try? BookAttachmentStore(context: modelContext) {
      for id in ids where items[id] == nil { items[id] = try? store.item(id) }
    }
    if items != attachmentItems { attachmentItems = items }
  }

  private var selectedItemIDs: Set<LibraryItemID> {
    Set(selectedBookIDs.map(LibraryItemID.book)).union(selectedNoteIDs.map(LibraryItemID.note))
      .union(selectedAttachmentIDs)
  }
  private var tableSelection: Binding<Set<LibraryItemID>> {
    if isTrash { return $selectedTrashItemIDs }
    return Binding(get: { selectedItemIDs }, set: { proposed in
      let value = LibraryItemTree.selection(proposed, previous: selectedItemIDs)
      selectedBookIDs = value.books; selectedNoteIDs = value.notes
      selectedAttachmentIDs = value.attachments
    })
  }
  private var tableSortOrder: Binding<[LibraryItemSort]> {
    Binding(get: { sortOrder.map { LibraryItemSort(bookComparator: $0) } },
      set: { sortOrder = $0.map(\.bookComparator) })
  }
  private func expansion(for row: LibraryItemRow) -> Binding<Bool> {
    Binding(get: { row.book.map { expandedBookIDs.contains($0.id) } ?? false }, set: { expanded in
      guard let book = row.book else { return }
      if expanded { expandedBookIDs.insert(book.id) }
      else {
        expandedBookIDs.remove(book.id)
        if isTrash {
          selectedTrashItemIDs.subtract(row.children.map(\.id))
        } else {
          let hidden = Set(row.children.compactMap { $0.note?.id })
          if !selectedNoteIDs.isDisjoint(with: hidden) {
            selectedNoteIDs.subtract(hidden)
            if selectedNoteIDs.isEmpty { selectedBookIDs = [book.id] }
          }
          if selectedAttachmentIDs.contains(where: { $0.attachmentReference?.bookID == book.id }) {
            selectedAttachmentIDs = selectedAttachmentIDs.filter { $0.attachmentReference?.bookID != book.id }
            if selectedAttachmentIDs.isEmpty { selectedBookIDs = [book.id] }
          }
        }
      }
    })
  }

  // Native column customization persists widths together with visibility and order.
  // Keep stable IDs so resizing survives sorting, filtering, and relaunching.
  private var columnCustomization: Binding<TableColumnCustomization<LibraryItemRow>> {
    Binding(get: {
      (try? JSONDecoder().decode(TableColumnCustomization<LibraryItemRow>.self, from: savedColumns)) ?? .init()
    }, set: { value in
      if let data = try? JSONEncoder().encode(value), data != savedColumns { savedColumns = data }
    })
  }

  private var table: some View {
    Table(of: LibraryItemRow.self, selection: tableSelection, sortOrder: tableSortOrder, columnCustomization: columnCustomization) {
      TableColumn(LibraryTableColumn.title.title, sortUsing: LibraryItemSort(bookComparator: KeyPathComparator(\Book.title))) { row in
        HStack(spacing: 8) {
          LibraryIcon(systemName: row.symbolName)
            .foregroundStyle(row.note == nil ? Color.secondary : Color.orange)
          Text(row.title).lineLimit(1)
        }.frame(minHeight: display.tableCellHeight).help(row.title)
      }.width(min: 80, ideal: 270, max: .infinity)
        .customizationID(LibraryTableColumn.title.rawValue)
        .disabledCustomizationBehavior([.visibility, .reorder])
      metadataColumn(.subtitle, ideal: 180, visibility: .visible)
      TableColumn(L10n.tr("作者"), sortUsing: LibraryItemSort(bookComparator: KeyPathComparator(\Book.authorDisplayName))) { row in
        Text(row.book?.authorDisplayName ?? "").lineLimit(1).help(row.book?.authorDisplayName ?? "")
      }.width(min: 40, ideal: 130, max: .infinity).customizationID(LibraryTableColumn.author.rawValue)
      TableColumn(L10n.tr("出版社"), sortUsing: LibraryItemSort(bookComparator: KeyPathComparator(\Book.publisherSortText))) { row in
        Text(row.book?.publisherSortText ?? "").lineLimit(1).help(row.book?.publisherSortText ?? "")
      }.width(min: 40, ideal: 150, max: .infinity).customizationID(LibraryTableColumn.publisher.rawValue)
      TableColumn(L10n.tr("出版日期"), sortUsing: LibraryItemSort(bookComparator: KeyPathComparator(\Book.publicationSortText))) { row in
        Text(row.book?.publicationSortText ?? "").lineLimit(1).help(row.book?.publicationSortText ?? "")
      }.width(min: 40, ideal: 100, max: .infinity).customizationID(LibraryTableColumn.publicationDate.rawValue)
      optionalColumns
    } rows: {
      if isTrash {
        ForEach(rows) { row in itemRow(row) }
      } else {
        ForEach(rows) { row in
          if let book = row.book, book.deletedAt == nil {
            itemRow(row).dropDestination(for: LibraryBookDrop.self) { receive($0, on: book) }
          } else { itemRow(row) }
        }.dropDestination(for: NoteDragBatch.self) { _, payloads in
          // Insertion targets mean library root placement; column sorting still
          // determines the final order, rather than persisting a manual row index.
          onMoveNote(payloads, .topLevel(collectionID: currentCollectionID))
        }
      }
    }
    .font(display.font)
    .background(LibraryColumnAutoFitBridge(fontSize: display.fontSize, primarySort: sortOrder.first) { column, indentation in
      LibraryColumnAutoFit.width(for: column, rows: rows, expandedBookIDs: expandedBookIDs,
        fontSize: display.fontSize, indentation: indentation)
    })
    .contextMenu(forSelectionType: LibraryItemID.self) { ids in
      if isTrash {
        if !ids.isEmpty {
          TrashSelectionActions(canRestore: canRestoreItems(ids),
            onRestore: { onRestoreItems(ids) }, onPurge: { onPurgeItems(ids) })
        }
      } else if ids.count == 1, let ref = ids.first?.attachmentReference,
        let book = books.first(where: { $0.id == ref.bookID && $0.deletedAt == nil }) {
        Button(L10n.tr("打开附件")) { openAttachment(ref.id, of: book) }
        Button(L10n.tr("管理附件…")) {
          managingAttachments = AttachmentManagementTarget(book: book, attachmentID: ref.id)
        }
      } else if ids.count == 1, let id = ids.first?.noteID, let note = notes.first(where: { $0.id == id }) {
        Button(L10n.tr("查看笔记")) { selectedBookIDs.removeAll(); selectedNoteIDs = [id] }
        if books.first(where: { $0.id == note.parentBookID })?.deletedAt == nil {
          Button(L10n.tr("编辑笔记")) { onEditNote(note) }
          Divider()
          Button(L10n.tr("移入回收站"), role: .destructive) { onTrashNote(note) }
        }
      } else if ids.allSatisfy({ $0.bookID != nil }) {
        actions(for: Set(ids.compactMap(\.bookID)))
      }
    } primaryAction: { ids in
      if isTrash { selectedTrashItemIDs = ids }
      else if ids.count == 1, let id = ids.first {
        if let ref = id.attachmentReference, let book = books.first(where: { $0.id == ref.bookID }) {
          openAttachment(ref.id, of: book)
        } else if let noteID = id.noteID, let note = notes.first(where: { $0.id == noteID }) {
          selectedBookIDs.removeAll(); selectedNoteIDs = [noteID]
          if !isTrash, books.first(where: { $0.id == note.parentBookID })?.deletedAt == nil { onEditNote(note) }
        } else if let book = books.first(where: { $0.id == id.bookID }), book.deletedAt == nil {
          appState.presentEditor(for: book)
        }
      }
    }
  }

  @TableRowBuilder<LibraryItemRow>
  private func itemRow(_ row: LibraryItemRow) -> some TableRowContent<LibraryItemRow> {
    if row.note != nil {
      noteRow(row)
    } else if row.children.isEmpty {
      TableRow(row).itemProvider { dragProvider(for: row) }
    } else {
      DisclosureTableRow(row, isExpanded: expansion(for: row)) {
        ForEach(row.children) { child in
          if child.id.attachmentReference != nil { TableRow(child) }
          else { noteRow(child) }
        }
      }.itemProvider { dragProvider(for: row) }
    }
  }

  private func receive(_ items: [LibraryBookDrop], on book: Book) {
    guard !isTrash, book.deletedAt == nil, !items.isEmpty else { return }
    var urls: [URL] = []
    var batches: [NoteDragBatch] = []
    for item in items {
      switch item {
      case .file(let file): urls.append(file.url)
      case .notes(let batch): batches.append(batch)
      }
    }
    if urls.isEmpty {
      onMoveNote(batches, .book(book.id))
      return
    }
    do {
      guard batches.isEmpty else { throw LibraryOperationError.invalidSelection }
      let previous = Set(book.attachmentIDs ?? [])
      try BookAttachmentCommands(book: book, context: modelContext).add(urls, linked: false, rule: .load())
      expandedBookIDs.insert(book.id)
      selectedBookIDs.removeAll()
      selectedNoteIDs.removeAll()
      let added = Set(book.attachmentIDs ?? []).subtracting(previous)
      selectedAttachmentIDs = Set(added.map { .attachment(bookID: book.id, id: $0) })
    } catch { attachmentError = error.localizedDescription }
  }

  private func openAttachment(_ id: UUID, of book: Book) {
    guard !isTrash, book.deletedAt == nil, book.attachmentIDs?.contains(id) == true else { return }
    do { try openBookAttachment(id, context: modelContext) }
    catch { attachmentError = error.localizedDescription }
  }

  @TableRowBuilder<LibraryItemRow>
  private func noteRow(_ row: LibraryItemRow) -> some TableRowContent<LibraryItemRow> {
    if !isTrash, let note = row.note, note.deletedAt == nil,
      canDragNote(note) {
      TableRow(row).draggable(NoteDragBatch.selection(
        libraryID: LibraryServices.forContext(modelContext).dragScopeID, dragging: note,
        selected: selectedNoteIDs, available: draggableNotes))
    } else { TableRow(row) }
  }

  private var draggableNotes: [NoteRecord] {
    rows.flatMap { row in
      row.note.map { [$0] } ?? (row.book.map { expandedBookIDs.contains($0.id) } == true
        ? row.children.compactMap(\.note) : [])
    }
  }

  private func canDragNote(_ note: NoteRecord) -> Bool {
    let ids: Set<UUID> = selectedNoteIDs.contains(note.id) ? selectedNoteIDs : [note.id]
    return ids.allSatisfy { noteEditing.drafts[$0]?.hasUnsavedChanges != true }
  }

  private func dragProvider(for row: LibraryItemRow) -> NSItemProvider? {
    guard !isTrash, let book = row.book, book.deletedAt == nil else { return nil }
    guard let payload = BookDragPayload.selection(
      libraryID: LibraryServices.forContext(modelContext).dragScopeID, dragging: book.id,
      selected: selectedBookIDs, available: Set(books.filter { $0.deletedAt == nil }.map(\.id))) else { return nil }
    return BookDragTransfer.provider(for: payload, title: book.title)
  }

  @TableColumnBuilder<LibraryItemRow, LibraryItemSort>
  private var optionalColumns: some TableColumnContent<LibraryItemRow, LibraryItemSort> {
    metadataColumn(.translator, ideal: 130)
    metadataColumn(.bookType, ideal: 120)
    metadataColumn(.publicationYear, ideal: 85)
    metadataColumn(.isbn, ideal: 145)
    metadataColumn(.language, ideal: 80)
    metadataColumn(.pageCount, ideal: 70)
    metadataColumn(.addedAt, ideal: 180)
    metadataColumn(.updatedAt, ideal: 180)
  }

  private func metadataColumn(_ column: LibraryTableColumn, ideal: CGFloat, visibility: Visibility = .hidden)
    -> some TableColumnContent<LibraryItemRow, LibraryItemSort> {
    TableColumn(column.title, sortUsing: LibraryItemSort(bookComparator: column.comparator)) { row in
      Text(column.text(for: row)).lineLimit(1).help(column.text(for: row))
    }.width(min: 40, ideal: ideal, max: .infinity)
      .customizationID(column.rawValue).defaultVisibility(visibility)
  }

  @ViewBuilder private func actions(for ids: Set<UUID>) -> some View {
    let selected = books.filter { ids.contains($0.id) }
    if selected.count == 1, let book = selected.first, book.deletedAt == nil {
      Button(L10n.tr("编辑书籍…")) { appState.presentEditor(for: book) }
      Button(L10n.tr("用 AI 补全元信息…")) { aiBook = book }
      Menu(L10n.tr("新建笔记")) {
        Button(L10n.tr("空白笔记")) { onNewNote(book.id) }
        let templates = PluginStore.shared.enabledTemplates
        if !templates.isEmpty {
          Divider()
          Menu(L10n.tr("从模板新建笔记")) {
            ForEach(templates) { template in
              Button(template.displayName) {
                guard let current = PluginStore.shared.enabledTemplates.first(where: { $0.id == template.id })
                else { return }
                onTemplateNote(current.draft(for: book, language: InterfaceLanguagePreferences.shared.language))
              }
            }
          }
        }
      }
      AddAttachmentMenu(commands: BookAttachmentCommands(book: book, context: modelContext),
        onWebLink: { webLinkBook = book }, onFileError: { attachmentError = $0 })
      Divider()
    }
    if !selected.isEmpty {
      if selected.allSatisfy({ $0.deletedAt != nil }) {
        Button(L10n.tr("恢复书籍")) { onTrash(ids, false) }
        Button(L10n.tr("永久删除…"), role: .destructive) { onPurge(ids) }
      } else {
      BookSelectionActions(
        books: selected, collections: collections, currentCollectionID: currentCollectionID,
        onCollection: onCollection)
        Divider()
        if selected.count >= 2 { Button(L10n.tr("合并所选书籍…")) { onMerge(ids) } }
        Button(L10n.tr("移入回收站"), role: .destructive) { onTrash(ids, true) }
      }
    }
  }
}

private struct AttachmentManagementTarget: Identifiable {
  let book: Book
  let attachmentID: UUID
  var id: LibraryItemID { .attachment(bookID: book.id, id: attachmentID) }
}

/// All trash entry points share the same two actions and parent-restoration rule.
struct TrashSelectionActions: View {
  let canRestore: Bool
  let onRestore: () -> Void
  let onPurge: () -> Void
  var body: some View {
    Button(L10n.tr("恢复所选条目"), action: onRestore).disabled(!canRestore)
      .help(canRestore ? L10n.tr("恢复所选书籍和笔记") : L10n.tr("请同时选择所属书籍，或先恢复所属书籍"))
    Divider()
    Button(L10n.tr("永久删除所选条目…"), role: .destructive, action: onPurge)
  }
}

struct BookSelectionActions: View {
  let books: [Book]
  let collections: [BookCollection]
  let currentCollectionID: UUID?
  let onCollection: (Set<UUID>, BookCollection, Bool) -> Void
  var onBatchEdit: ((Set<UUID>) -> Void)? = nil
  private var ids: Set<UUID> { Set(books.map(\.id)) }

  var body: some View {
    if let onBatchEdit {
      Button(L10n.tr("批量编辑标签与信息…")) { onBatchEdit(ids) }
      Divider()
    }
    Menu(L10n.tr("加入文件夹")) {
      if collections.isEmpty { Text(L10n.tr("请先在侧栏新建文件夹")) }
      CollectionHierarchyMenuItems(nodes: CollectionTree.nodes(collections.map(ManualCollectionRecord.init))) { record in
        Button {
          guard let collection = collections.first(where: { $0.id == record.id }) else { return }
          onCollection(ids, collection, true)
        } label: { Label(record.name, systemImage: "folder") }
      }
    }
    if let collection = collections.first(where: { $0.id == currentCollectionID }) {
      Button(L10n.tr("从当前文件夹移除")) { onCollection(ids, collection, false) }
    }
  }
}


/// A parent folder is both a destination and the container for its children.
/// Keep its own action first in the submenu, followed by the nested destinations.
struct CollectionHierarchyMenuItems<Destination: View>: View {
  let nodes: [CollectionNode]
  @ViewBuilder let destination: (ManualCollectionRecord) -> Destination

  var body: some View {
    ForEach(nodes) { node in
      if let children = node.children, !children.isEmpty {
        Menu {
          destination(node.record)
          Divider()
          CollectionHierarchyMenuItems(nodes: children, destination: destination)
        } label: { Label(node.record.name, systemImage: "folder") }
      } else {
        destination(node.record)
      }
    }
  }
}
