import AppKit
import SwiftData
import SwiftUI

struct SidebarView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.libraryUndoManager) private var undoManager
  @Binding var selection: LibrarySelection?
  @Binding var selectedTagIDs: Set<UUID>
  @Binding var expandedCollectionIDs: Set<UUID>
  @Environment(\.libraryDisplay) private var display
  let books: [Book]
  let collections: [BookCollection]
  let tags: [Tag]
  let tagBookCounts: [UUID: Int]
  let duplicateCount: Int
  let onNewSmart: () -> Void
  let onEditSmart: (BookCollection) -> Void
  let onEmptyTrash: () -> Void
  @Query private var notes: [LibraryNote]
  @AppStorage("includeSubcollections") private var includeSubcollections = false
  @AppStorage("showsSidebarItemCounts") private var showsItemCounts = true
  @State private var showsCollectionFinder = false
  @State private var collectionSearchText = ""
  @State private var collectionSearchFocused = false
  @State private var collectionSearchCandidate: LibrarySelection?
  @State private var searchExpandedIDs = Set<UUID>()
  @State private var collectionMoveRequest: CollectionMoveRequest?
  @State private var folderDraft: InlineFolderDraft?
  @State private var removingCollection: ManualCollectionRecord?
  @State private var tagRequest: TagEditorRequest?
  @State private var removingTag: TagRecord?
  @State private var errorMessage: String?

  private var activeBooks: [Book] { books.filter { $0.deletedAt == nil } }
  private var records: [ManualCollectionRecord] { collections.filter { !$0.isSmart }.map(ManualCollectionRecord.init) }
  private var orderingItems: [CollectionOrderingItem] { collections.map(CollectionOrderingItem.init) }
  private var activeNotes: [NoteRecord] { notes.map(NoteRecord.init).filter { !NoteQueries.isTrashed($0, books: books) } }
  private var trashItemCount: Int {
    books.filter { $0.deletedAt != nil }.count + notes.filter { NoteQueries.isTrashed(NoteRecord($0), books: books) }.count
  }
  private var expandableCollectionIDs: Set<UUID> { Set(records.compactMap(\.parentID)) }
  private var collectionSearchTree: CollectionSearchTree {
    CollectionSearchTree(items: orderingItems + (folderDraft.flatMap { $0.isNew ? [$0.item] : nil } ?? []), query: collectionSearchText)
  }
  private var isFilteringCollections: Bool {
    !collectionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  private var displayedCollectionExpansion: Binding<Set<UUID>> {
    Binding(get: { isFilteringCollections ? searchExpandedIDs : expandedCollectionIDs }, set: {
      if isFilteringCollections { searchExpandedIDs = $0 } else { expandedCollectionIDs = $0 }
    })
  }
  private var navigationListSelection: Binding<LibrarySelection?> {
    Binding(get: { collectionSearchCandidate ?? selection }, set: { target in
      // Hiding a selected row while filtering must not change the active library scope.
      guard target != nil || !isFilteringCollections else { return }
      collectionSearchCandidate = nil
      selection = target
    })
  }

  var body: some View {
    SidebarTagSplitView {
      VStack(spacing: 0) {
        libraryHeader.padding(.horizontal, 10).frame(height: 44)
          .contextMenu { navigationContextMenu(for: nil) }
        navigationList
      }
    } tags: {
      SidebarTagPanel(tags: tags, bookCounts: tagBookCounts, selectedIDs: $selectedTagIDs,
        onRename: { prepareTag($0, removing: false) },
        onDelete: { prepareTag($0, removing: true) })
    }
    .navigationTitle("书架")
    .onChange(of: selection) { _, _ in
      expandSelectedAncestors()
    }
    .onChange(of: records) { _, _ in
      expandSelectedAncestors()
    }
    .onChange(of: collectionSearchText) { _, _ in updateCollectionSearch() }
    .onChange(of: orderingItems) { _, _ in updateCollectionSearch() }
    .sheet(item: $collectionMoveRequest) { request in
      CollectionMoveView(request: request) { selection = .collection($0) }
    }
    .sheet(item: $tagRequest) { request in
      TagEditorView(source: request.source) { destinationID in
        if selectedTagIDs.remove(request.source.id) != nil { selectedTagIDs.insert(destinationID) }
      }
    }
    .confirmationDialog("删除“\(removingTag?.name ?? "")”标签？",
      isPresented: Binding(get: { removingTag != nil }, set: { if !$0 { removingTag = nil } }), titleVisibility: .visible) {
      Button("删除标签", role: .destructive) {
        guard let record = removingTag else { return }
        do {
          try TagCommands(context: modelContext, undoManager: undoManager).remove(record)
          selectedTagIDs.remove(record.id)
        } catch { errorMessage = error.localizedDescription }
        removingTag = nil
      }
    } message: {
      if let record = removingTag {
        Text("从 \(record.bookIDs.count) 本书和 \(record.noteIDs.count) 条笔记中移除此标签，包括回收站中的条目。书籍与笔记会保留。此操作可以撤销。")
      }
    }
    .confirmationDialog("移除文件夹及其所有子文件夹？", isPresented: Binding(get: { removingCollection != nil }, set: { if !$0 { removingCollection = nil } }), titleVisibility: .visible) {
      Button("移除文件夹，保留内容", role: .destructive) {
        guard let record = removingCollection else { return }
        do { try CollectionCommands(context: modelContext, undoManager: undoManager).remove(record) }
        catch { errorMessage = error.localizedDescription }
        removingCollection = nil
      }
    } message: {
      Text("只移除文件夹层级和归属，书籍与笔记仍保留在书库中。此操作可以撤销。")
    }
    .alert(
      "无法保存更改",
      isPresented: Binding(
        get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var navigationList: some View {
    ScrollViewReader { proxy in
      List(selection: navigationListSelection) {
        Group {
          SidebarNavigationRow(title: "全部书籍", systemImage: "books.vertical", count: activeBooks.count)
            .modifier(SidebarCollectionDropTarget(rowID: nil, canMove: canMoveCollection,
              onMove: moveCollection, onError: { errorMessage = $0.localizedDescription }))
            .help("全部书籍；将文件夹拖到这里可移回顶层")
            .tag(LibrarySelection.all).id(LibrarySelection.all)
          SidebarNavigationRow(title: "重复书目", systemImage: "doc.on.doc", count: duplicateCount)
            .tag(LibrarySelection.duplicates).id(LibrarySelection.duplicates)
          SidebarNavigationRow(title: "回收站", systemImage: "trash", count: trashItemCount)
            .tag(LibrarySelection.trash).id(LibrarySelection.trash)
            .help("查看已删除的书籍和笔记；右键可清空回收站")
            .overlay(alignment: .bottom) {
              if !collections.isEmpty || folderDraft != nil {
                // Draw in the existing row inset instead of allocating a full
                // native sidebar row for a decorative separator.
                Divider()
                  .padding(.horizontal, -4)
                  .offset(y: display.rowPadding)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
          SidebarCollectionRows(items: collectionSearchTree.items, parentID: nil, expanded: displayedCollectionExpansion,
            draft: folderDraft, onDraftName: updateFolderDraft, onDraftCommit: commitFolderDraft, onDraftCancel: cancelFolderDraft,
            count: collectionCount, onDrag: startCollectionDrag, canMove: canMoveCollection,
            canEnter: canEnterCollection,
            onMove: moveCollection, onBooks: addDroppedBooks, onError: { errorMessage = $0.localizedDescription })
        }
        if isFilteringCollections && collectionSearchTree.items.isEmpty {
          Text("没有匹配的文件夹").font(display.font).foregroundStyle(.secondary)
            .padding(.vertical, 8).selectionDisabled()
        }
      }
      .modifier(SidebarNavigationListStyle())
      .frame(maxHeight: .infinity)
      .accessibilityLabel("书库导航")
      .contextMenu(forSelectionType: LibrarySelection.self) { targets in
        navigationContextMenu(for: targets.first)
      }
      .onExitCommand {
        if let id = folderDraft?.id { cancelFolderDraft(id) } else { closeCollectionSearch() }
      }
      .task(id: folderDraft?.id) {
        guard let item = folderDraft?.item else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        proxy.scrollTo(item.isSmart ? LibrarySelection.smart(item.id) : .collection(item.id), anchor: .center)
      }
      .onChange(of: collectionSearchCandidate) { _, target in
        if let target { proxy.scrollTo(target) }
      }

      .task(id: SidebarScrollTarget(selection: selection, items: orderingItems)) {
        // Returning from search must not reopen a previously collapsed branch.
        // Normal navigation expands ancestors in the selection change handler.
        await Task.yield()
        guard !Task.isCancelled, folderDraft == nil, let selection else { return }
        proxy.scrollTo(selection, anchor: .center)
      }
    }
  }

  @ViewBuilder
  private func navigationContextMenu(for target: LibrarySelection?) -> some View {
    if target == .trash || target == .noteTrash {
      Button("清空回收站…", systemImage: "trash", role: .destructive, action: onEmptyTrash)
        .disabled(trashItemCount == 0)
    } else {
      collectionContextMenu(for: target)
    }
  }

  @ViewBuilder
  private func collectionContextMenu(for target: LibrarySelection?) -> some View {
    if case .collection(let id) = target, let record = records.first(where: { $0.id == id }) {
      Button("新建子文件夹", systemImage: "folder.badge.plus") { beginFolderDraft(parentID: id) }
      Button("重命名", systemImage: "pencil") { beginFolderRename(id) }
      Button("移动文件夹…", systemImage: "folder") {
        if let draft = folderDraft, !commitFolderDraft(draft.id, false) { return }
        guard let current = records.first(where: { $0.id == id }) else { return }
        collectionMoveRequest = CollectionMoveRequest(existing: current)
      }
      Button("移除文件夹及子文件夹…", systemImage: "trash", role: .destructive) { removingCollection = record }
      Divider()
    } else if case .smart(let id) = target, let collection = collections.first(where: { $0.id == id && $0.isSmart }) {
      Button("重命名", systemImage: "pencil") { beginFolderRename(id) }
      Button("编辑规则", systemImage: "slider.horizontal.3") {
        if let draft = folderDraft, !commitFolderDraft(draft.id, false) { return }
        onEditSmart(collection)
      }
      Button("移除智能文件夹", systemImage: "trash", role: .destructive) {
        do { try SmartCollectionService.remove(collection, context: modelContext, undoManager: undoManager) }
        catch { errorMessage = error.localizedDescription }
      }
      Divider()
    }
    newCollectionActions
    Divider()
    Button("查找文件夹…", systemImage: "magnifyingglass") { showsCollectionFinder = true }
      .disabled(collections.isEmpty)
    Button("展开全部文件夹", systemImage: "chevron.down") { expandedCollectionIDs = expandableCollectionIDs }
      .disabled(isFilteringCollections || expandableCollectionIDs.isEmpty || expandableCollectionIDs.isSubset(of: expandedCollectionIDs))
    Button("折叠全部文件夹", systemImage: "chevron.right") { expandedCollectionIDs.removeAll() }
      .disabled(isFilteringCollections || expandedCollectionIDs.isDisjoint(with: expandableCollectionIDs))
    Divider()
    Toggle("显示条目数量", isOn: $showsItemCounts)
    Toggle("包含子文件夹", isOn: $includeSubcollections)
  }

  @ViewBuilder
  private var newCollectionActions: some View {
    Button("新建文件夹", systemImage: "folder.badge.plus") { beginFolderDraft() }
    Button {
      if let id = folderDraft?.id, !commitFolderDraft(id, false) { return }
      onNewSmart()
    } label: { Label("新建智能文件夹", systemImage: "folder.badge.gearshape") }
  }

  private func beginFolderDraft(parentID: UUID? = nil) {
    if let existing = folderDraft, !commitFolderDraft(existing.id, false) { return }
    closeCollectionSearch()
    if let parentID, !records.contains(where: { $0.id == parentID }) { return }
    var parent = parentID, visited = Set<UUID>()
    while let id = parent, visited.insert(id).inserted {
      expandedCollectionIDs.insert(id); parent = records.first { $0.id == id }?.parentID
    }
    folderDraft = InlineFolderDraft(parentID: parentID, items: orderingItems)
  }

  private func beginFolderRename(_ id: UUID) {
    if let existing = folderDraft, !commitFolderDraft(existing.id, false) { return }
    guard let collection = collections.first(where: { $0.id == id }) else { return }
    do {
      let target: InlineFolderRenameTarget = collection.isSmart
        ? .smart(try SmartCollectionArchive(collection)) : .folder(ManualCollectionRecord(collection))
      closeCollectionSearch()
      var parent = collection.parentID, visited = Set<UUID>()
      while let id = parent, visited.insert(id).inserted {
        expandedCollectionIDs.insert(id); parent = records.first { $0.id == id }?.parentID
      }
      folderDraft = InlineFolderDraft(renaming: target)
    } catch { errorMessage = error.localizedDescription }
  }

  private func updateFolderDraft(_ id: UUID, _ name: String) {
    guard folderDraft?.id == id else { return }
    folderDraft?.name = name; folderDraft?.errorMessage = nil
  }

  @discardableResult
  private func commitFolderDraft(_ id: UUID, _ selectCreated: Bool) -> Bool {
    guard let draft = folderDraft, draft.id == id else { return true }
    if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if selectCreated { folderDraft?.errorMessage = "请输入文件夹名称"; return false }
      cancelFolderDraft(id); return true
    }
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    // Leaving an unchanged name must not create undo history or update timestamps.
    if !draft.isNew, name == draft.item.name { cancelFolderDraft(id); return true }
    do {
      let savedID: UUID
      switch draft.existing {
      case .folder(let expected):
        savedID = try CollectionCommands(context: modelContext, undoManager: undoManager)
          .save(name: name, replacing: expected)
      case .smart(let expected):
        savedID = try SmartCollectionService.save(name: name, query: expected.query, replacing: expected,
          context: modelContext, undoManager: undoManager)
      case nil:
        savedID = try CollectionCommands(context: modelContext, undoManager: undoManager)
          .save(name: name, replacing: nil, parentID: draft.parentID)
      }
      folderDraft = nil
      if selectCreated { selection = draft.item.isSmart ? .smart(savedID) : .collection(savedID) }
      return true
    } catch {
      if error is CollectionCommandError || (error as? SmartCollectionError) == .duplicateName {
        folderDraft?.errorMessage = "已有同名文件夹"
      } else { folderDraft?.errorMessage = error.localizedDescription }
      return false
    }
  }

  private func cancelFolderDraft(_ id: UUID) {
    guard folderDraft?.id == id else { return }
    folderDraft = nil
  }

  private func prepareTag(_ id: UUID, removing: Bool) {
    do {
      let record = try TagCommands(context: modelContext, undoManager: undoManager).record(id)
      if removing { removingTag = record } else { tagRequest = TagEditorRequest(source: record) }
    } catch { errorMessage = error.localizedDescription }
  }

  private var libraryHeader: some View {
    HStack(spacing: 0) {
      Menu {
        newCollectionActions
      } label: {
        LibraryToolbarLabel("新建文件夹菜单", systemImage: "folder.badge.plus")
      }
      .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
      .help("新建文件夹或智能文件夹").accessibilityLabel("新建文件夹菜单")
      if showsCollectionFinder {
        collectionSearchBar.padding(.leading, 8)
      } else {
        Spacer(minLength: 8)
        Button { showsCollectionFinder = true } label: {
          LibraryToolbarLabel("查找文件夹", systemImage: "magnifyingglass")
        }.buttonStyle(.plain).help("查找文件夹").accessibilityLabel("查找文件夹")
      }
    }
    .foregroundStyle(.secondary)
  }

  private var collectionSearchBar: some View {
    HStack(spacing: 6) {
      Button(action: closeCollectionSearch) {
        LibraryIcon(systemName: "magnifyingglass")
      }.buttonStyle(.plain).help("收起文件夹搜索（Esc）").accessibilityLabel("收起文件夹搜索")
      SidebarCollectionSearchField(text: $collectionSearchText, fontSize: display.fontSize,
        onMove: moveCollectionSearchSelection, onSubmit: openCollectionSearchSelection,
        onClose: closeCollectionSearch, onFocusChange: { collectionSearchFocused = $0 })
        .frame(maxWidth: .infinity)
      if !collectionSearchText.isEmpty {
        Button { collectionSearchText = "" } label: {
          Image(systemName: "xmark.circle.fill")
        }.buttonStyle(.plain).help("清除文件夹搜索").accessibilityLabel("清除文件夹搜索")
      }
    }
    .font(display.font).padding(.horizontal, 7)
    .frame(height: 28)
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    .background(CollectionSearchDismissalRegion(onDismiss: closeCollectionSearch))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(collectionSearchFocused ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor),
          lineWidth: collectionSearchFocused ? 2 : 0.5)
        .allowsHitTesting(false)
    }
  }

  private func closeCollectionSearch() {
    collectionSearchText = ""
    collectionSearchCandidate = nil
    searchExpandedIDs.removeAll()
    collectionSearchFocused = false
    showsCollectionFinder = false
  }

  private func updateCollectionSearch() {
    // The actual navigation tree stays mounted. Only its displayed collections
    // and temporary expansion change once the query contains text.
    searchExpandedIDs = collectionSearchTree.initialExpansion(restoring: [])
    collectionSearchCandidate = nil
  }

  private func moveCollectionSearchSelection(_ offset: Int) {
    let tree = collectionSearchTree
    let visible = tree.visibleItems(expanded: displayedCollectionExpansion.wrappedValue)
    guard !visible.isEmpty else { return }
    let current = visible.firstIndex { item in
      (item.isSmart ? LibrarySelection.smart(item.id) : .collection(item.id))
        == (collectionSearchCandidate ?? selection)
    }
    let index: Int
    if let current {
      index = min(visible.count - 1, max(0, current + offset))
    } else {
      index = offset > 0
        ? (visible.firstIndex { tree.matchedIDs.contains($0.id) } ?? 0)
        : (visible.lastIndex { tree.matchedIDs.contains($0.id) } ?? visible.count - 1)
    }
    let item = visible[index]
    collectionSearchCandidate = item.isSmart ? .smart(item.id) : .collection(item.id)
  }

  private func openCollectionSearchSelection() {
    let tree = collectionSearchTree
    let visible = tree.visibleItems(expanded: displayedCollectionExpansion.wrappedValue)
    let candidate = collectionSearchCandidate.flatMap { target in
      visible.contains { ($0.isSmart ? LibrarySelection.smart($0.id) : .collection($0.id)) == target }
        ? target : nil
    }
    let target = candidate ?? visible.first(where: { tree.matchedIDs.contains($0.id) }).map {
      $0.isSmart ? LibrarySelection.smart($0.id) : .collection($0.id)
    }
    guard let target else { return }
    selection = target
    collectionSearchCandidate = nil
  }

  private func collectionCount(_ id: UUID) -> Int {
    if let collection = collections.first(where: { $0.id == id && $0.isSmart }) {
      guard let query = collection.smartQuery else { return 0 }
      let records = activeNotes
      return activeBooks.filter { query.matches($0, notes: records) }.count + records.filter { query.matches($0) }.count
    }
    let ids = includeSubcollections ? CollectionTree.descendants(of: id, in: records) : [id]
    return activeBooks.filter { book in book.collectionItems.contains { $0.collection.map { ids.contains($0.id) } ?? false } }.count
      + activeNotes.filter { $0.parentBookID == nil && !Set($0.collectionIDs).isDisjoint(with: ids) }.count
  }

  private func addDroppedBooks(_ payloads: [BookDragPayload], to collectionID: UUID) throws {
    try LibraryCommands(context: modelContext, undoManager: undoManager).addDroppedBooks(payloads, to: collectionID)
  }

  private func startCollectionDrag(_ id: UUID) -> NSItemProvider {
    guard let item = orderingItems.first(where: { $0.id == id }) else { return NSItemProvider() }
    let services = LibraryServices.forContext(modelContext)
    let payload = CollectionDragPayload(libraryID: services.dragScopeID, item: item)
    services.collectionDrag = payload
    return CollectionDragTransfer.provider(for: payload, title: item.name)
  }

  private func canMoveCollection(to destination: CollectionDropDestination) -> Bool {
    collectionMove(to: destination).map { !$0.isEmpty } ?? false
  }

  private func canEnterCollection(_ id: UUID) -> Bool {
    // Hovering over the current parent should still reveal its other children,
    // even when dropping on that parent would leave the dragged item unchanged.
    collectionMove(to: .inside(id)) != nil
  }

  private func collectionMove(to destination: CollectionDropDestination) -> [CollectionOrderingItem]? {
    let services = LibraryServices.forContext(modelContext)
    guard let payload = services.collectionDrag, payload.libraryID == services.dragScopeID,
      let source = orderingItems.first(where: { $0.id == payload.collectionID }), payload.matches(source),
      let changes = try? CollectionOrdering.move(payload.collectionID, to: destination, in: orderingItems)
    else { return nil }
    return changes
  }

  private func moveCollection(_ payload: CollectionDragPayload, to destination: CollectionDropDestination) throws {
    defer { LibraryServices.forContext(modelContext).collectionDrag = nil }
    guard try CollectionCommands(context: modelContext, undoManager: undoManager).move(payload, to: destination) else { return }
    if let collection = collections.first(where: { $0.id == payload.collectionID }) {
      selection = collection.isSmart ? .smart(collection.id) : .collection(collection.id)
      expandSelectedAncestors()
    }
  }

  private func expandSelectedAncestors() {
    guard !isFilteringCollections else { return }
    guard case .collection(let id) = selection else { return }
    var parent = records.first { $0.id == id }?.parentID, visited = Set<UUID>()
    while let id = parent, visited.insert(id).inserted {
      expandedCollectionIDs.insert(id); parent = records.first { $0.id == id }?.parentID
    }
  }

}

private enum SidebarNavigationMetrics {
  static let spacing: CGFloat = 8
}

private struct SidebarNavigationListStyle: ViewModifier {
  @Environment(\.libraryDisplay) private var display
  func body(content: Content) -> some View {
    content
      .listStyle(.sidebar)
      // Share the same opaque surface as the tag panel, while retaining native
      // sidebar selection, disclosure rows, keyboard navigation and drag/drop.
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, display.sidebarRowHeight)
  }
}

private struct SidebarNavigationRow: View {
  @Environment(\.libraryDisplay) private var display
  @AppStorage("showsSidebarItemCounts") private var showsItemCounts = true
  let title: String
  let systemImage: String
  let count: Int

  var body: some View {
    Label {
      HStack(spacing: SidebarNavigationMetrics.spacing) {
        Text(title).font(display.font).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
        if showsItemCounts {
          Text(count, format: .number)
            .font(display.caption).monospacedDigit().foregroundStyle(.secondary)
            .fixedSize()
        }
      }
    } icon: {
      LibraryIcon(systemName: systemImage)
        .frame(width: display.iconSlotSize, height: display.iconSlotSize)
        .accessibilityHidden(true)
    }
    .labelStyle(SidebarNavigationLabelStyle())
    .frame(minHeight: display.sidebarRowHeight - 2 * display.rowPadding)
    .listRowInsets(display.rowInsets)
    .contentShape(Rectangle())
    .help(title)
  }
}

private struct SidebarNavigationLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: SidebarNavigationMetrics.spacing) {
      configuration.icon
      configuration.title
    }
  }
}

private struct SidebarScrollTarget: Equatable {
  let selection: LibrarySelection?
  let items: [CollectionOrderingItem]
}

private struct SidebarCollectionRows: View {
  @Environment(\.libraryDisplay) private var display
  let items: [CollectionOrderingItem]
  let parentID: UUID?
  @Binding var expanded: Set<UUID>
  let draft: InlineFolderDraft?
  let onDraftName: (UUID, String) -> Void
  let onDraftCommit: (UUID, Bool) -> Bool
  let onDraftCancel: (UUID) -> Void
  let count: (UUID) -> Int
  let onDrag: (UUID) -> NSItemProvider
  let canMove: (CollectionDropDestination) -> Bool
  let canEnter: (UUID) -> Bool
  let onMove: (CollectionDragPayload, CollectionDropDestination) throws -> Void
  let onBooks: ([BookDragPayload], UUID) throws -> Void
  let onError: (Error) -> Void
  var body: some View {
    ForEach(items.filter { $0.parentID == parentID }.sorted(by: CollectionOrdering.precedes)) { item in
      if let draft, draft.isNew, item.id == draft.item.id {
        InlineFolderEditorRow(draft: draft,
          onName: { onDraftName(draft.id, $0) },
          onCommit: { onDraftCommit(draft.id, $0) }, onCancel: { onDraftCancel(draft.id) })
          .id(LibrarySelection.collection(draft.id))
          .listRowInsets(display.rowInsets)
          .selectionDisabled()
      } else {
        Group {
          if !item.isSmart && items.contains(where: { $0.parentID == item.id }) {
            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(item.id) }, set: {
              if $0 { expanded.insert(item.id) } else { expanded.remove(item.id) }
            })) {
              SidebarCollectionRows(items: items, parentID: item.id, expanded: $expanded,
                draft: draft, onDraftName: onDraftName, onDraftCommit: onDraftCommit, onDraftCancel: onDraftCancel, count: count,
                onDrag: onDrag, canMove: canMove, canEnter: canEnter, onMove: onMove, onBooks: onBooks, onError: onError)
            } label: { label(item) }
          } else { label(item) }
        }
        .tag(item.isSmart ? LibrarySelection.smart(item.id) : .collection(item.id))
        .id(item.isSmart ? LibrarySelection.smart(item.id) : .collection(item.id))
        // Supply the native List row, including DisclosureGroup children. Attaching
        // onDrag to only the label does not make nested outline rows draggable.
        .itemProvider { draft?.item.id == item.id ? nil : onDrag(item.id) }
        .listRowInsets(display.rowInsets)
      }
    }
  }
  @ViewBuilder
  private func label(_ item: CollectionOrderingItem) -> some View {
    if let draft, item.id == draft.item.id {
      InlineFolderEditorRow(draft: draft,
        onName: { onDraftName(draft.id, $0) },
        onCommit: { onDraftCommit(draft.id, $0) }, onCancel: { onDraftCancel(draft.id) })
        .id(draft.id)
    } else {
      SidebarNavigationRow(title: item.name, systemImage: item.isSmart ? "folder.badge.gearshape" : "folder", count: count(item.id))
      .modifier(SidebarCollectionDropTarget(rowID: item.id, canContainCollections: !item.isSmart,
        canMove: canMove, onMove: onMove,
        onBooks: item.isSmart ? nil : { try onBooks($0, item.id) }, onError: onError,
        expansion: !item.isSmart && items.contains(where: { $0.parentID == item.id })
          ? Binding(get: { expanded.contains(item.id) }, set: { if $0 { expanded.insert(item.id) } else { expanded.remove(item.id) } }) : nil,
        canExpandCollection: { canEnter(item.id) }))
    }
  }
}

/// Native editing preserves input-method composition while arrow keys navigate results.
private struct SidebarCollectionSearchField: NSViewRepresentable {
  @Binding var text: String
  let fontSize: CGFloat
  let onMove: (Int) -> Void
  let onSubmit: () -> Void
  let onClose: () -> Void
  let onFocusChange: (Bool) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> MetadataTextField {
    let field = MetadataTextField(string: text)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.placeholderString = "筛选文件夹"
    field.setAccessibilityLabel("文件夹搜索")
    field.toolTip = "按文件夹名称或层级路径查找；↑/↓ 选择，回车定位，Esc 关闭"
    field.font = .systemFont(ofSize: fontSize)
    field.delegate = context.coordinator
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.requestEditingFocus { [weak coordinator = context.coordinator] in
      coordinator?.parent.onFocusChange(true)
    }
    return field
  }
  func updateNSView(_ field: MetadataTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      field.stringValue = text
    }
    if field.font?.pointSize != fontSize {
      field.font = .systemFont(ofSize: fontSize)
      field.currentEditor()?.font = field.font
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MetadataTextField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 160, height: nsView.intrinsicContentSize.height)
  }

  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: SidebarCollectionSearchField
    init(_ parent: SidebarCollectionSearchField) { self.parent = parent }
    func controlTextDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
    func controlTextDidEndEditing(_ notification: Notification) {
      parent.onFocusChange(false)
      // Mouse dismissal is handled by the whole search bar, so its clear button
      // stays usable and the clicked result receives its event before removal.
      guard NSApp.currentEvent?.type == .keyDown,
        let field = notification.object as? NSTextField else { return }
      DispatchQueue.main.async { [weak self, weak field] in
        guard let field, field.window != nil, field.currentEditor() == nil else { return }
        self?.parent.onClose()
      }
    }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
      guard !textView.hasMarkedText() else { return false }
      switch command {
      case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
      case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
      case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
      case #selector(NSResponder.cancelOperation(_:)): parent.onClose()
      default: return false
      }
      return true
    }
  }
}

/// Observes clicks without intercepting them, including clicks on non-focusable
/// blank space. Wait for mouse-up before restoring the unfiltered navigation.
private struct CollectionSearchDismissalRegion: NSViewRepresentable {
  let onDismiss: () -> Void
  func makeNSView(context: Context) -> DismissalView { DismissalView(onDismiss: onDismiss) }
  func updateNSView(_ view: DismissalView, context: Context) { view.onDismiss = onDismiss }
  static func dismantleNSView(_ view: DismissalView, coordinator: ()) { view.stopObserving() }

  final class DismissalView: NSView {
    var onDismiss: () -> Void
    private var mouseMonitor: Any?
    private var completionTimer: Timer?
    private var clickedOutside = false
    private var isObserving = false
    private var dismissalScheduled = false
    private var openingEventTime: TimeInterval = 0
    private var clickStartedAt: TimeInterval = 0

    init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      guard let window else { return }
      isObserving = true
      openingEventTime = NSApp.currentEvent?.timestamp ?? 0
      NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
        name: NSWindow.didResignKeyNotification, object: window)
      mouseMonitor = NSEvent.addLocalMonitorForEvents(matching:
        [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp]
      ) { [weak self] event in
        self?.observe(event)
        return event
      }
    }

    func stopObserving() {
      isObserving = false
      if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
      mouseMonitor = nil
      NotificationCenter.default.removeObserver(self)
      completionTimer?.invalidate(); completionTimer = nil
      clickedOutside = false; dismissalScheduled = false
    }

    private func observe(_ event: NSEvent) {
      guard isObserving, let window else { return }
      switch event.type {
      case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        guard event.timestamp > openingEventTime, !bounds.isEmpty else { return }
        clickedOutside = event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil))
        completionTimer?.invalidate(); completionTimer = nil
        guard clickedOutside else { return }
        clickStartedAt = ProcessInfo.processInfo.systemUptime
        // Native controls and menus can consume mouse-up in a tracking loop.
        // Poll only during this click/drag, then remove the temporary timer.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            if NSEvent.pressedMouseButtons == 0,
              ProcessInfo.processInfo.systemUptime - self.clickStartedAt >= 0.25 { self.finishClick() }
          }
        }
        completionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
      case .leftMouseUp, .rightMouseUp, .otherMouseUp:
        finishClick()
      default: break
      }
    }

    private func finishClick() {
      completionTimer?.invalidate(); completionTimer = nil
      guard clickedOutside else { return }
      clickedOutside = false
      scheduleDismissal()
    }

    @objc private func windowResignedKey() { scheduleDismissal() }

    private func scheduleDismissal() {
      guard isObserving, !dismissalScheduled else { return }
      dismissalScheduled = true
      // SwiftUI's native List can commit selection after AppKit delivers mouse-up.
      // Let that commit settle before changing the row positions underneath it.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self, self.isObserving, self.window != nil else { return }
        self.onDismiss()
      }
    }
  }
}

