import AppKit
import SwiftData
import SwiftUI

struct LibraryView: View {
  @Environment(\.libraryDisplay) private var display
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext
  @AppStorage("libraryTableColumnCustomization.v1") private var savedColumns = Data()
  let books: [Book]
  let notes: [NoteRecord]
  let isTrash: Bool
  @Binding var selectedBookIDs: Set<UUID>
  @Binding var selectedNoteID: UUID?
  @Binding var selectedTrashItemIDs: Set<LibraryItemID>
  @Binding var expandedBookIDs: Set<UUID>
  @Binding var sortOrder: [KeyPathComparator<Book>]
  let layoutStyle: LibraryLayoutStyle
  let libraryIsEmpty: Bool
  let hasFilters: Bool
  let collections: [BookCollection]
  let currentCollectionID: UUID?
  let onNewBook: () -> Void
  let onNewNote: (UUID) -> Void
  let onEditNote: (NoteRecord) -> Void
  let onTrashNote: (NoteRecord) -> Void
  let canRestoreItems: (Set<LibraryItemID>) -> Bool
  let onRestoreItems: (Set<LibraryItemID>) -> Void
  let onPurgeItems: (Set<LibraryItemID>) -> Void
  let onClearFilters: () -> Void
  let onFavorite: (Set<UUID>, Bool) -> Void
  let onCollection: (Set<UUID>, BookCollection, Bool) -> Void
  let onBatchEdit: (Set<UUID>) -> Void
  let onTrash: (Set<UUID>, Bool) -> Void
  let onMerge: (Set<UUID>) -> Void
  let onPurge: (Set<UUID>) -> Void

  var body: some View {
    Group {
      if rows.isEmpty {
        ContentUnavailableView {
          Label(isTrash ? (hasFilters ? "没有匹配的条目" : "回收站为空") : (libraryIsEmpty ? "建立你的书库" : "没有匹配的书籍"),
            systemImage: isTrash ? "trash" : "books.vertical")
        } description: {
          Text(
            isTrash ? (hasFilters ? "试试其他关键词，或清除筛选。" : "移入回收站的书籍和笔记会显示在这里。") : libraryIsEmpty
              ? "添加第一本书，开始整理你的阅读收藏。" : (hasFilters ? "试试其他关键词，或清除标签筛选。" : "这个分类下还没有书籍。"))
        } actions: {
          if hasFilters { Button("清除筛选", action: onClearFilters) }
          if !isTrash { Button("添加书籍", action: onNewBook).buttonStyle(.borderedProminent) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if layoutStyle == .grid && !isTrash {
        grid
      } else {
        table
      }
    }
  }

  private var rows: [LibraryItemRow] { LibraryItemTree.rows(books: books, notes: notes, inTrash: isTrash) }
  private var selectedItemIDs: Set<LibraryItemID> {
    Set(selectedBookIDs.map(LibraryItemID.book)).union(selectedNoteID.map { [.note($0)] } ?? [])
  }
  private var tableSelection: Binding<Set<LibraryItemID>> {
    if isTrash { return $selectedTrashItemIDs }
    return Binding(get: { selectedItemIDs }, set: { proposed in
      let value = LibraryItemTree.selection(proposed, previous: selectedItemIDs)
      selectedBookIDs = value.books; selectedNoteID = value.note
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
        } else if row.children.contains(where: { $0.note?.id == selectedNoteID }) {
          selectedNoteID = nil; selectedBookIDs = [book.id]
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
          Image(systemName: row.note == nil ? "book.closed" : "note.text")
            .foregroundStyle(row.note == nil ? Color.secondary : Color.orange)
          Text(row.title).lineLimit(1)
          if row.book?.isFavorite == true {
            Image(systemName: "star.fill").font(display.caption).foregroundStyle(.orange)
          }
        }.frame(minHeight: display.tableCellHeight).help(row.title)
      }.width(min: 80, ideal: 270, max: .infinity)
        .customizationID(LibraryTableColumn.title.rawValue)
        .disabledCustomizationBehavior([.visibility, .reorder])
      metadataColumn(.subtitle, ideal: 180, visibility: .visible)
      TableColumn("作者", sortUsing: LibraryItemSort(bookComparator: KeyPathComparator(\Book.authorDisplayName))) { row in
        Text(row.book?.authorDisplayName ?? "").lineLimit(1).help(row.book?.authorDisplayName ?? "")
      }.width(min: 40, ideal: 130, max: .infinity).customizationID(LibraryTableColumn.author.rawValue)
      TableColumn("出版社", sortUsing: LibraryItemSort(bookComparator: KeyPathComparator(\Book.publisherSortText))) { row in
        Text(row.book?.publisherSortText ?? "").lineLimit(1).help(row.book?.publisherSortText ?? "")
      }.width(min: 40, ideal: 150, max: .infinity).customizationID(LibraryTableColumn.publisher.rawValue)
      TableColumn("出版日期", sortUsing: LibraryItemSort(bookComparator: KeyPathComparator(\Book.publicationSortText))) { row in
        Text(row.book?.publicationSortText ?? "").lineLimit(1).help(row.book?.publicationSortText ?? "")
      }.width(min: 40, ideal: 100, max: .infinity).customizationID(LibraryTableColumn.publicationDate.rawValue)
      optionalColumns
    } rows: {
      ForEach(rows) { row in
        if row.children.isEmpty { TableRow(row).itemProvider { dragProvider(for: row) } }
        else {
          DisclosureTableRow(row, isExpanded: expansion(for: row)) {
            ForEach(row.children) { TableRow($0) }
          }.itemProvider { dragProvider(for: row) }
        }
      }
    }
    .font(display.font)
    .background(LibraryColumnAutoFitBridge { column, indentation in
      LibraryColumnAutoFit.width(for: column, rows: rows, expandedBookIDs: expandedBookIDs,
        fontSize: display.fontSize, indentation: indentation)
    })
    .contextMenu(forSelectionType: LibraryItemID.self) { ids in
      if isTrash {
        if !ids.isEmpty {
          TrashSelectionActions(canRestore: canRestoreItems(ids),
            onRestore: { onRestoreItems(ids) }, onPurge: { onPurgeItems(ids) })
        }
      } else if ids.count == 1, let id = ids.first?.noteID, let note = notes.first(where: { $0.id == id }) {
        Button("查看笔记") { selectedBookIDs.removeAll(); selectedNoteID = id }
        if books.first(where: { $0.id == note.parentBookID })?.deletedAt == nil {
          Button("编辑笔记") { onEditNote(note) }
          Divider()
          Button("移入回收站", role: .destructive) { onTrashNote(note) }
        }
      } else if ids.allSatisfy({ $0.bookID != nil }) {
        actions(for: Set(ids.compactMap(\.bookID)))
      }
    } primaryAction: { ids in
      if isTrash { selectedTrashItemIDs = ids }
      else if ids.count == 1, let id = ids.first {
        if let noteID = id.noteID, let note = notes.first(where: { $0.id == noteID }) {
          selectedBookIDs.removeAll(); selectedNoteID = noteID
          if !isTrash, books.first(where: { $0.id == note.parentBookID })?.deletedAt == nil { onEditNote(note) }
        } else if let book = books.first(where: { $0.id == id.bookID }), book.deletedAt == nil {
          appState.presentEditor(for: book)
        }
      }
    }
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

  private var grid: some View {
    ScrollView {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 128, maximum: 176), spacing: 24)],
        alignment: .leading, spacing: 28
      ) {
        ForEach(books) { book in
          Button {
            selectedNoteID = nil
            if NSEvent.modifierFlags.contains(.command) {
              if !selectedBookIDs.insert(book.id).inserted { selectedBookIDs.remove(book.id) }
            } else {
              selectedBookIDs = [book.id]
            }
          } label: {
            BookCardView(book: book, isSelected: selectedBookIDs.contains(book.id))
          }
          .buttonStyle(.plain)
          .contextMenu {
            actions(for: selectedBookIDs.contains(book.id) ? selectedBookIDs : [book.id])
          }
          .accessibilityAddTraits(selectedBookIDs.contains(book.id) ? [.isSelected] : [])
        }
      }.padding(24)
    }
  }

  @ViewBuilder private func actions(for ids: Set<UUID>) -> some View {
    let selected = books.filter { ids.contains($0.id) }
    if selected.count == 1, let book = selected.first, book.deletedAt == nil {
      Button("编辑书籍…") { appState.presentEditor(for: book) }
      Button("新建笔记…") { onNewNote(book.id) }
      Divider()
    }
    if !selected.isEmpty {
      if selected.allSatisfy({ $0.deletedAt != nil }) {
        Button("恢复书籍") { onTrash(ids, false) }
        Button("永久删除…", role: .destructive) { onPurge(ids) }
      } else {
      BookSelectionActions(
        books: selected, collections: collections, currentCollectionID: currentCollectionID,
        onFavorite: onFavorite, onCollection: onCollection, onBatchEdit: onBatchEdit)
        Divider()
        if selected.count >= 2 { Button("合并所选书籍…") { onMerge(ids) } }
        Button("移入回收站", role: .destructive) { onTrash(ids, true) }
      }
    }
  }
}

/// All trash entry points share the same two actions and parent-restoration rule.
struct TrashSelectionActions: View {
  let canRestore: Bool
  let onRestore: () -> Void
  let onPurge: () -> Void
  var body: some View {
    Button("恢复所选条目", action: onRestore).disabled(!canRestore)
      .help(canRestore ? "恢复所选书籍和笔记" : "请同时选择所属书籍，或先恢复所属书籍")
    Divider()
    Button("永久删除所选条目…", role: .destructive, action: onPurge)
  }
}

struct BookSelectionActions: View {
  let books: [Book]
  let collections: [BookCollection]
  let currentCollectionID: UUID?
  let onFavorite: (Set<UUID>, Bool) -> Void
  let onCollection: (Set<UUID>, BookCollection, Bool) -> Void
  let onBatchEdit: (Set<UUID>) -> Void
  private var ids: Set<UUID> { Set(books.map(\.id)) }

  var body: some View {
    Button("批量编辑标签与信息…") { onBatchEdit(ids) }
    Divider()
    Button(books.allSatisfy(\.isFavorite) ? "取消收藏" : "加入收藏") {
      onFavorite(ids, !books.allSatisfy(\.isFavorite))
    }
    Menu("加入书单") {
      if collections.isEmpty { Text("请先在侧栏新建书单") }
      ForEach(collections) { collection in
        Button(CollectionTree.path(collection.id, in: collections.map(ManualCollectionRecord.init))) { onCollection(ids, collection, true) }
      }
    }
    if let collection = collections.first(where: { $0.id == currentCollectionID }) {
      Button("从当前书单移除") { onCollection(ids, collection, false) }
    }
  }
}

struct BookCardView: View {
  @Environment(\.libraryDisplay) private var display
  let book: Book
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      CoverImageView(book: book)
        .aspectRatio(5 / 7, contentMode: .fit)
        .overlay {
          RoundedRectangle(cornerRadius: 5)
            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .shadow(color: .black.opacity(0.18), radius: 7, y: 4)

      Text(book.title)
        .font(display.font)
        .fontWeight(.medium)
        .lineLimit(2)

      Text(book.authorDisplayName)
        .font(display.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(book.title)，\(book.authorDisplayName)")
  }
}

struct CoverImageView: View {
  @Environment(\.libraryDisplay) private var display
  let book: Book

  var body: some View {
    Group {
      if let image = CoverStore.image(for: book.coverFileName) {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        ZStack {
          LinearGradient(
            colors: placeholderColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )

          VStack(spacing: 12) {
            Text(book.title)
              .font(.headline)
              .multilineTextAlignment(.center)
              .lineLimit(4)
            Text(book.authorDisplayName)
              .font(display.caption)
              .opacity(0.75)
              .lineLimit(2)
          }
          .foregroundStyle(.white)
          .padding(14)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 5))
  }

  private var placeholderColors: [Color] {
    let hue = Double(abs(book.title.hashValue % 100)) / 100
    return [
      Color(hue: hue, saturation: 0.58, brightness: 0.72),
      Color(hue: min(hue + 0.09, 1), saturation: 0.70, brightness: 0.42),
    ]
  }
}
