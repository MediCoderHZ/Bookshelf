import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext
  @Environment(\.libraryUndoManager) private var undoManager
  @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
  @Query(sort: \BookCollection.name) private var collections: [BookCollection]
  @Query(sort: \Tag.name) private var tags: [Tag]
  @Query private var libraryNotes: [LibraryNote]
  @AppStorage("includeSubcollections") private var includeSubcollections = false
  @State private var noteEditing = NoteEditingSession()
  @State private var metadataEditing = BookMetadataEditingSession()
  @State private var activeInspectorPanel = InspectorPanel.info
  @State private var expandedInspectorPanels: Set<InspectorPanel> = [.info]
  @State private var expandedCollectionIDs = Set<UUID>()
  @State private var isRestoringWorkspace = true
  @State private var inspectorNavigationRequest: InspectorNavigationRequest?
  @AppStorage("defaultLayout") private var layoutStyle = LibraryLayoutStyle.list
  @AppStorage("showsBookInspector") private var showsInspector = true
  @AppStorage("librarySidebarWidth") private var savedSidebarWidth = 225.0
  @AppStorage("libraryInspectorWidth") private var savedInspectorWidth = 330.0
  @State private var navigationSelection: LibrarySelection? = .all
  @State private var pendingMetadataNavigation: BookMetadataFocusRequest?
  @State private var pendingLocationBookID: UUID?
  @State private var selectedBookIDs = Set<UUID>()
  @State private var selectedNoteID: UUID?
  @State private var selectedTrashItemIDs = Set<LibraryItemID>()
  @State private var expandedBookIDs = Set<UUID>()
  @State private var selectedTagIDs = Set<UUID>()
  @State private var searchText = ""
  @AppStorage("librarySearchScope") private var searchScope = LibrarySearchScope.allFields
  @State private var searchFocusRequest: UUID?
  @State private var exchangePresentation = BibliographicExchangePresentation()
  @State private var sortOrder = [KeyPathComparator(\Book.addedAt, order: .reverse)]
  @State private var errorMessage: String?
  init() {
    let saved = LibraryWorkspaceState.load()
    _navigationSelection = State(initialValue: saved.selection)
    _selectedBookIDs = State(initialValue: saved.bookIDs)
    _selectedNoteID = State(initialValue: saved.noteID)
    _selectedTrashItemIDs = State(initialValue: Set(saved.trashBookIDs.map(LibraryItemID.book))
      .union(saved.trashNoteIDs.map(LibraryItemID.note)))
    _expandedBookIDs = State(initialValue: saved.expandedBookIDs)
    _expandedCollectionIDs = State(initialValue: saved.expandedCollectionIDs)
    _expandedInspectorPanels = State(initialValue: saved.expandedPanels)
    _activeInspectorPanel = State(initialValue: saved.activePanel)
  }

  private var workspaceState: LibraryWorkspaceState {
    LibraryWorkspaceState(selection: navigationSelection ?? .all, bookIDs: selectedBookIDs,
      noteID: selectedNoteID, trashBookIDs: Set(selectedTrashItemIDs.compactMap(\.bookID)),
      trashNoteIDs: Set(selectedTrashItemIDs.compactMap(\.noteID)), expandedBookIDs: expandedBookIDs,
      expandedCollectionIDs: expandedCollectionIDs, expandedPanels: expandedInspectorPanels,
      activePanel: activeInspectorPanel)
  }

  private func restoreWorkspace() async {
    guard isRestoringWorkspace else { return }
    let saved = workspaceState.validated(books: books, collections: collections,
      notes: libraryNotes.map(NoteRecord.init), includeSubcollections: includeSubcollections)
    navigationSelection = saved.selection
    selectedBookIDs = saved.bookIDs; selectedNoteID = saved.noteID
    selectedTrashItemIDs = Set(saved.trashBookIDs.map(LibraryItemID.book)).union(saved.trashNoteIDs.map(LibraryItemID.note))
    expandedBookIDs = saved.expandedBookIDs; expandedCollectionIDs = saved.expandedCollectionIDs
    // Let selection observers settle before enabling persistence/user navigation cleanup.
    await Task.yield()
    guard !Task.isCancelled else { return }
    isRestoringWorkspace = false
    workspaceState.save()
  }

  private var history: LibraryHistory { LibraryServices.forContext(modelContext).history }
  @State private var mergeRequest: BookMergeRequest?
  @State private var batchEditRequest: BookBatchEditRequest?
  @State private var purgePlan: TrashPlan?
  @State private var isConfirmingPurge = false
  @State private var duplicateGroupID: UUID?
  @State private var advancedQuery = AdvancedBookQuery()
  @State private var showsAdvancedSearch = false
  @State private var advancedDraft = AdvancedBookQuery(rules: [BookSearchRule()])
  @State private var smartRuleEdit: SmartRuleEdit?
  private var isCreatingSmartCollection: Bool {
    guard let edit = smartRuleEdit else { return false }
    return edit.original == nil
  }
  private var effectiveSmartQuery: AdvancedBookQuery? {
    smartRuleEdit?.preview ?? currentSmartCollection?.smartQuery
  }
  private var inlineQuery: Binding<AdvancedBookQuery> {
    Binding(get: { smartRuleEdit?.query ?? advancedDraft }, set: { query in
      if smartRuleEdit != nil { smartRuleEdit?.query = query; smartRuleEdit?.errorMessage = nil }
      else { advancedDraft = query }
    })
  }
  private var inlineSmartName: Binding<String>? {
    guard smartRuleEdit != nil else { return nil }
    return Binding(get: { smartRuleEdit?.name ?? "" }, set: { smartRuleEdit?.name = $0; smartRuleEdit?.errorMessage = nil })
  }
  private var manualCollections: [BookCollection] { collections.filter { !$0.isSmart } }
  private var currentSmartCollection: BookCollection? {
    guard case .smart(let id) = navigationSelection else { return nil }
    return collections.first { $0.id == id && $0.isSmart }
  }
  private var activeBooks: [Book] { books.filter { $0.deletedAt == nil } }
  private var isTrashScope: Bool { navigationSelection == .trash || navigationSelection == .noteTrash }
  private var trashCommands: TrashCommands { TrashCommands(context: modelContext, undoManager: undoManager) }
  private var isNotesScope: Bool { [.notes, .standaloneNotes].contains(navigationSelection ?? .all) }
  private var showsOnlyNotes: Bool {
    guard !isTrashScope && visibleBooks.isEmpty && selectedTagIDs.isEmpty && !advancedQuery.hasConditions else { return false }
    if let preview = smartRuleEdit?.preview {
      return libraryNotes.map(NoteRecord.init).contains {
        preview.matches($0) && NoteQueries.matches($0, text: searchText, searchScope: searchScope)
      }
    }
    return !NoteQueries.results(libraryNotes.map(NoteRecord.init), books: books,
        collections: manualCollections.map(ManualCollectionRecord.init), scope: navigationSelection ?? .all,
        text: searchText, searchScope: searchScope, includeSubcollections: includeSubcollections, smartQuery: effectiveSmartQuery).isEmpty
  }
  private var duplicateGroups: [DuplicateGroup] { DuplicateDetector.groups(in: activeBooks) }

  private var visibleBooks: [Book] {
    let _ = LibraryNotifier.forContext(modelContext).revision
    return LibraryQueries.results(books, collections: collections, request: LibraryQueryRequest(
      selection: smartRuleEdit?.preview == nil ? navigationSelection ?? .all : .all,
      tagIDs: selectedTagIDs, text: searchText, searchScope: searchScope,
      advanced: smartRuleEdit?.preview ?? advancedQuery, duplicateGroupID: duplicateGroupID, includeSubcollections: includeSubcollections,
      noteMatchedBookIDs: Set(libraryNotes.filter {
        (navigationSelection == .trash || $0.deletedAt == nil) && NoteQueries.matches(NoteRecord($0), text: searchText, searchScope: searchScope)
      }.compactMap(\.parentBookID))), notes: libraryNotes.map(NoteRecord.init)).sorted(using: sortOrder)
  }

  private var selectedBooks: [Book] {
    visibleBooks.filter { isTrashScope ? selectedTrashItemIDs.contains(.book($0.id)) : selectedBookIDs.contains($0.id) }
  }
  private var childNotes: [NoteRecord] {
    let parents = Set(visibleBooks.map(\.id))
    return libraryNotes.filter { $0.deletedAt == nil && $0.parentBookID.map(parents.contains) == true }.map(NoteRecord.init)
  }
  private var trashNotes: [NoteRecord] {
    let _ = LibraryNotifier.forContext(modelContext).revision
    return NoteQueries.results(libraryNotes.map(NoteRecord.init), books: books,
      collections: [], scope: .trash, text: searchText, searchScope: searchScope)
  }
  private var visibleTrashItemIDs: Set<LibraryItemID> {
    Set(visibleBooks.map { .book($0.id) }).union(trashNotes.map { .note($0.id) })
  }
  private var inspectorNoteID: UUID? {
    isTrashScope ? (selectedTrashItemIDs.count == 1 ? selectedTrashItemIDs.first?.noteID : nil) : selectedNoteID
  }
  private var selectedNote: NoteRecord? {
    libraryNotes.first { $0.id == inspectorNoteID }.map(NoteRecord.init) ?? inspectorNoteID.flatMap {
      guard let draft = noteEditing.drafts[$0], draft.hasUnsavedChanges else { return nil }
      return draft.value
    }
  }
  private var sidebarSelection: Binding<LibrarySelection?> {
    Binding(get: { navigationSelection }, set: { value in
      selectedBookIDs.removeAll(); selectedNoteID = nil; selectedTrashItemIDs.removeAll(); navigationSelection = value
    })
  }

  private var currentCollectionID: UUID? {
    if case .collection(let id) = navigationSelection { return id }
    return nil
  }

  private var sidebarWidth: CGFloat {
    savedSidebarWidth.isFinite ? min(400, max(200, savedSidebarWidth)) : 225
  }
  private var inspectorWidth: CGFloat {
    savedInspectorWidth.isFinite ? min(600, max(290, savedInspectorWidth)) : 330
  }

  private var toolbarActions: LibraryToolbarActions {
    var actions = LibraryToolbarActions(lookupBook: { presentNewBook(search: true) })
    if !isNotesScope && !isTrashScope { actions.advancedSearch = { presentAdvancedSearch() } }
    return actions
  }

  private var navigationContent: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        navigationColumns(availableWidth: max(0, geometry.size.width - InspectorNavigationRail.width - 1),
          availableHeight: geometry.size.height)
        Divider()
        InspectorNavigationRail(isPresented: showsInspector,
          activePanel: selectedNote != nil ? .notes : (selectedBooks.count == 1 ? activeInspectorPanel : nil),
          availablePanels: availableInspectorPanels,
          onToggle: { showsInspector.toggle() }, onSelect: navigateInspector)
      }
    }
    .navigationTitle((navigationSelection ?? .all).title(collections: collections))
    .focusedSceneValue(\.librarySearchAction, { closeAdvancedSearch(); searchFocusRequest = UUID() })
    .focusedSceneValue(\.libraryToolbarActions, toolbarActions)
    .toolbarBackground(.visible, for: .windowToolbar)
    .modifier(BibliographicExchangePresenter(presentation: exchangePresentation))
  }

  private func navigationColumns(availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
    let notesOnly = isNotesScope || showsOnlyNotes
    let contentMinimum: CGFloat = notesOnly && !showsAdvancedSearch ? 230 : 360
    let inspectorIsVisible = showsInspector
    let sidebarMaximum = min(400, max(200, availableWidth - contentMinimum - (inspectorIsVisible ? 290 : 0) - 2))
    let currentSidebarWidth = min(sidebarWidth, sidebarMaximum)
    let inspectorMaximum = min(600, max(290, availableWidth - contentMinimum - currentSidebarWidth - 2))
    let currentInspectorWidth = min(inspectorWidth, inspectorMaximum)
    let layoutState = PanelLayoutState(width: availableWidth, inspectorVisible: inspectorIsVisible)
    // A native split pane keeps navigation visible at every window width and
    // supports resizing without NavigationSplitView's sidebar-collapse behavior.
    return HSplitView {
      SidebarView(
        selection: sidebarSelection, selectedTagIDs: $selectedTagIDs, expandedCollectionIDs: $expandedCollectionIDs,
        books: books, collections: collections, tags: tags,
        tagBookCounts: LibraryQueries.tagBookCounts(in: visibleBooks),
        duplicateCount: Set(duplicateGroups.flatMap { $0.books.map(\.id) }).count,
        onNewSmart: createSmartCollection,
        onEditSmart: editSmartCollection, onEmptyTrash: confirmEmptyTrash
      )
      .frame(minWidth: 200, idealWidth: currentSidebarWidth, maxWidth: sidebarMaximum,
        maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      .clipped()
      .background(PanelWidthPersistence(edge: .leading, initialWidth: currentSidebarWidth,
        restorationID: layoutState) { savedSidebarWidth = $0 })
      // All three panes share one split view, so restoring the sidebar width
      // does not subsequently resize a nested inspector split.
      VStack(spacing: 0) {
      libraryListToolbar
      Divider()
      if showsAdvancedSearch && !isNotesScope && !isTrashScope {
        inlineAdvancedSearchPanel(availableHeight: availableHeight)
        Divider()
      }
      // Notes use the same right-hand inspector, keeping this search field in a
      // stable list pane even when a query switches between book and note results.
      if isNotesScope {
        NotesWorkspaceView(scope: navigationSelection ?? .notes, searchText: searchText, searchScope: searchScope, selection: $selectedNoteID)
      } else {
      VStack(spacing: 0) {
        if hasLibraryContext {
          libraryContextHeader
          Divider()
        }
        if showsOnlyNotes {
          NotesWorkspaceView(scope: navigationSelection ?? .all, searchText: searchText, searchScope: searchScope,
            selection: $selectedNoteID, smartQueryOverride: smartRuleEdit?.preview)
        } else {
        LibraryView(
          books: visibleBooks, notes: isTrashScope ? trashNotes : childNotes,
          isTrash: isTrashScope, selectedBookIDs: $selectedBookIDs,
          selectedNoteID: $selectedNoteID, selectedTrashItemIDs: $selectedTrashItemIDs, expandedBookIDs: $expandedBookIDs, sortOrder: $sortOrder,
          layoutStyle: layoutStyle, libraryIsEmpty: activeBooks.isEmpty,
          hasFilters: !searchText.isEmpty || !selectedTagIDs.isEmpty || advancedQuery.hasConditions || smartRuleEdit?.preview?.hasConditions == true,
          collections: manualCollections, currentCollectionID: currentCollectionID,
          onNewBook: { presentNewBook() },
          onNewNote: { createNote(parentID: $0) },
          onEditNote: { openNote($0.id) },
          onTrashNote: { note in
            changeNoteTrash(note, true)
          },
          canRestoreItems: canRestoreTrashItems, onRestoreItems: restoreTrashItems,
          onPurgeItems: { confirmTrashPurge($0) },
          onClearFilters: {
            searchText = ""
            selectedTagIDs.removeAll()
            advancedQuery = AdvancedBookQuery()
            smartRuleEdit?.preview = nil
          },
          onFavorite: { ids, value in update(ids) { $0.isFavorite = value } },
          onCollection: changeCollection, onBatchEdit: openBatchEdit, onTrash: changeTrash, onMerge: openMerge, onPurge: confirmPurge
        )
        if (navigationSelection == .all || currentCollectionID != nil || effectiveSmartQuery?.savedSearch != nil) && selectedTagIDs.isEmpty && !advancedQuery.hasConditions {
          StandaloneNotesStrip(collectionID: currentCollectionID, includeSubcollections: includeSubcollections,
            searchText: searchText, searchScope: searchScope, smartQuery: effectiveSmartQuery) { openNote($0.id) }
        }
        Divider()
        HStack {
          Text("\(visibleBooks.count) 本书")
          if isTrashScope { Text("· \(trashNotes.count) 条笔记") }
          if isTrashScope && !selectedTrashItemIDs.isEmpty {
            Text("· 已选择 \(selectedTrashItemIDs.count) 个条目")
          } else if !isTrashScope {
            if !selectedBookIDs.isEmpty { Text("· 已选择 \(selectedBookIDs.count) 本") }
            if selectedNoteID != nil { Text("· 已选择 1 条笔记") }
          }
          Spacer()
          Text(isTrashScope || layoutStyle == .list ? "⌘ 点选多项 · ⇧ 连续选择" : "⌘ 点选多本")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
        }
      }
      }
      }
      .frame(minWidth: contentMinimum, maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor))
      .clipped()
      if inspectorIsVisible {
        VStack(spacing: 0) { inspector }
          .frame(minWidth: 290, idealWidth: currentInspectorWidth, maxWidth: inspectorMaximum,
            maxHeight: .infinity)
          .background(Color(nsColor: .windowBackgroundColor))
          .clipped()
          .background(PanelWidthPersistence(edge: .trailing, initialWidth: currentInspectorWidth,
            restorationID: layoutState) { savedInspectorWidth = $0 })
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func inlineAdvancedSearchPanel(availableHeight: CGFloat) -> some View {
    let cancel: (() -> Void)? = smartRuleEdit == nil ? nil : { closeAdvancedSearch() }
    return InlineAdvancedSearchPanel(query: inlineQuery,
      maximumRulesHeight: min(170, max(84, availableHeight * 0.45)),
      onSearch: searchInlineQuery, onClear: clearInlineSearch, onSave: saveInlineQuery,
      smartName: inlineSmartName, errorMessage: smartRuleEdit?.errorMessage, onCancel: cancel,
      isCreatingSmartCollection: isCreatingSmartCollection)
      .id(smartRuleEdit?.id)
  }

  private var libraryListToolbar: some View {
    GeometryReader { geometry in
      let mode = LibraryToolbarMode(width: geometry.size.width)
      HStack(spacing: 0) {
        libraryToolbarControls(mode)
        Spacer(minLength: 8)
        // Keep this native field at the same view identity when buttons collapse,
        // preserving the insertion point and marked text during a divider drag.
        if showsAdvancedSearch {
          HStack(spacing: 10) {
            Text(isCreatingSmartCollection ? "新建智能书单" : "高级筛选").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Button(action: closeAdvancedSearch) {
              Image(systemName: "xmark").frame(width: 24, height: 28)
            }.help(smartRuleEdit == nil ? "收起条件面板，保留当前筛选结果" : isCreatingSmartCollection ? "取消新建，不创建书单" : "取消编辑，保留书单原有规则")
              .accessibilityLabel(smartRuleEdit == nil ? "关闭高级筛选" : isCreatingSmartCollection ? "取消新建智能书单" : "取消编辑智能书单")
          }.buttonStyle(.plain).foregroundStyle(.secondary)
        } else {
          LibrarySearchField(text: $searchText, scope: $searchScope, focusRequest: searchFocusRequest,
            canSaveSearch: canSaveCurrentSearch, onSaveSearch: saveCurrentSearch,
            canShowAdvancedSearch: !isNotesScope && !isTrashScope,
            hasAdvancedSearch: advancedQuery.hasConditions, onAdvancedSearch: presentAdvancedSearch)
            .frame(minWidth: 140, maxWidth: 360).frame(height: 28)
        }
      }
      .padding(.horizontal, 10).frame(height: 44)
    }
    .frame(height: 44)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func libraryToolbarControls(_ mode: LibraryToolbarMode) -> some View {
    HStack(spacing: 6) {
      if mode.showsAdd {
        Menu { newBookMenuItems } label: { LibraryToolbarLabel("添加书籍", systemImage: "plus") }
          .help("添加书籍：手动录入（⌘N）或从网页提取").frame(width: 32, height: 32)
        Button { presentNewBook(search: true) } label: {
          LibraryToolbarLabel("按书名或 ISBN 添加", systemImage: "wand.and.stars")
        }.help("搜索书名或 ISBN，填充书籍信息（⇧⌘I）")
      }
      if mode.showsNotes {
        Menu { newNoteMenuItems } label: { LibraryToolbarLabel("新建笔记", systemImage: "square.and.pencil") }
          .help("新建独立笔记或书籍子笔记").frame(width: 32, height: 32)
      }
      if mode.showsAll {
        BibliographicExchangeMenu(books: visibleBooks, selectedBooks: selectedBooks, iconOnly: true,
          presentation: exchangePresentation).disabled(isNotesScope).frame(width: 32, height: 32)
      }
      libraryMoreMenu(mode).frame(width: 32, height: 32)
    }
    .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden)
    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    .fixedSize().frame(height: 32)
  }

  private var newBookMenuItems: some View {
    Group {
      Button("手动添加书籍…", systemImage: "plus") { presentNewBook() }
      Button("从网页添加…", systemImage: "link.badge.plus") {
        appState.presentNewBook(collectionID: currentCollectionID, startWithWebImport: true)
      }
    }
  }

  private var newNoteMenuItems: some View {
    Group {
      Button("新建独立笔记") { createNote(parentID: nil) }
      Button("为所选书籍新建笔记") { createNote(parentID: selectedBooks.first?.id) }
        .disabled(selectedBooks.count != 1 || selectedBooks.first?.deletedAt != nil)
    }
  }

  private var canSaveCurrentSearch: Bool {
    !isTrashScope && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func saveCurrentSearch() {
    guard canSaveCurrentSearch else { return }
    let query = AdvancedBookQuery.savingSearch(scope: searchScope, text: searchText)
    beginSmartCollection(query: query, preview: query)
  }

  private func presentAdvancedSearch() {
    guard !isNotesScope && !isTrashScope else { return }
    showsAdvancedSearch = true
  }

  private func closeAdvancedSearch() {
    smartRuleEdit = nil
    showsAdvancedSearch = false
  }

  private func createSmartCollection() {
    beginSmartCollection(query: AdvancedBookQuery(rules: [BookSearchRule()]))
  }

  private func beginSmartCollection(query: AdvancedBookQuery, preview: AdvancedBookQuery? = nil) {
    smartRuleEdit = SmartRuleEdit(original: nil, name: "", query: query, preview: preview)
    searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
    selectedBookIDs.removeAll(); selectedNoteID = nil; selectedTrashItemIDs.removeAll()
    navigationSelection = .all
    showsAdvancedSearch = true
  }

  private func searchInlineQuery() {
    guard let edit = smartRuleEdit else { applyAdvancedSearch(advancedDraft); return }
    guard edit.query.validationMessage == nil else { return }
    // Preview against the whole library, not the intersection with the saved
    // collection's previous rules. Keep its sidebar selection and identity.
    smartRuleEdit?.preview = edit.query
    searchText = ""; selectedTagIDs.removeAll(); selectedBookIDs.removeAll(); selectedNoteID = nil
  }

  private func beginSavingAdvancedSearch(_ query: AdvancedBookQuery) {
    guard query.hasConditions, query.validationMessage == nil else { return }
    // Keep the composed query intact, including any unapplied rule edits.
    // Both the panel and the collapsed results summary use this inline flow.
    beginSmartCollection(query: query, preview: query)
  }

  private func saveInlineQuery() {
    guard let edit = smartRuleEdit else {
      beginSavingAdvancedSearch(advancedDraft); return
    }
    do {
      let id = try SmartCollectionService.save(name: edit.name, query: edit.query, replacing: edit.original,
        context: modelContext, undoManager: undoManager)
      smartRuleEdit = nil
      applyAdvancedSearch(edit.query, savedID: id)
    } catch { smartRuleEdit?.errorMessage = error.localizedDescription }
  }

  private func applyAdvancedSearch(_ query: AdvancedBookQuery, savedID: UUID? = nil) {
    guard query.validationMessage == nil else { return }
    searchText = ""; selectedTagIDs.removeAll(); selectedBookIDs.removeAll(); selectedNoteID = nil
    advancedQuery = savedID == nil ? query : AdvancedBookQuery()
    if let savedID {
      showsAdvancedSearch = false
      navigationSelection = .smart(savedID)
    } else {
      advancedDraft = query.rules.isEmpty && query.savedSearch == nil
        ? AdvancedBookQuery(rules: [BookSearchRule()]) : query
      navigationSelection = .all
    }
  }

  private func clearInlineSearch() {
    if smartRuleEdit != nil {
      if let saved = smartRuleEdit?.query.savedSearch {
        smartRuleEdit?.query = .savingSearch(scope: saved.scope, text: "")
      } else { smartRuleEdit?.query = AdvancedBookQuery(rules: [BookSearchRule()]) }
      smartRuleEdit?.preview = nil; smartRuleEdit?.errorMessage = nil
      return
    }
    advancedDraft = AdvancedBookQuery(rules: [BookSearchRule()])
    applyAdvancedSearch(AdvancedBookQuery())
  }

  private var contentWithSheets: some View {
    @Bindable var appState = appState
    return navigationContent
    .sheet(item: $appState.editorDestination) { destination in
      BookEditorView(
        book: destination.book, initialCollectionID: destination.collectionID,
        startWithSearch: destination.startWithSearch, startWithWebImport: destination.startWithWebImport
      )
      .frame(minWidth: 650, minHeight: 640)
    }
    .sheet(item: $mergeRequest) { BookMergeView(request: $0) }
    .sheet(item: $batchEditRequest) { BookBatchEditView(request: $0) }
    .confirmationDialog(purgePlan?.confirmationTitle ?? "永久删除？", isPresented: $isConfirmingPurge, titleVisibility: .visible) {
      Button(purgePlan?.emptiesTrash == true ? "清空回收站" : "永久删除", role: .destructive) { purgeSelection() }
      Button("取消", role: .cancel) { purgePlan = nil }
    } message: { Text(purgePlan?.confirmationMessage ?? "") }
  }

  private var contentWithNoteRouting: some View {
    contentWithSheets
    .environment(noteEditing)
    .environment(metadataEditing)
    .environment(\.noteNavigation, NoteNavigationActions(create: { createNote(parentID: $0) }, open: openNote))
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 0) { recoveryBanner; metadataRecoveryBanner }
    }
    .onChange(of: libraryNotes.map(\.id)) { _, ids in
      if let selectedNoteID, !ids.contains(selectedNoteID), noteEditing.drafts[selectedNoteID]?.hasUnsavedChanges != true {
        self.selectedNoteID = nil
      }
    }
    .onChange(of: visibleBooks.map(\.id)) { _, ids in selectedBookIDs.formIntersection(ids) }
    .onChange(of: childNotes, updateChildNotes)
    .onChange(of: visibleTrashItemIDs) { _, ids in
      if isTrashScope { selectedTrashItemIDs.formIntersection(ids) }
    }
    .onChange(of: selectedTrashItemIDs) { _, ids in if !isRestoringWorkspace && !ids.isEmpty { showsInspector = true } }
    .onChange(of: searchText) { _, _ in expandSearchMatches() }
    .onChange(of: searchScope) { _, _ in expandSearchMatches() }
    .onChange(of: selectedNoteID) { _, id in if !isRestoringWorkspace && id != nil { showsInspector = true } }
    .onChange(of: selectedBookIDs) { _, ids in if !ids.isEmpty { selectedNoteID = nil } }
    .onChange(of: layoutStyle) { _, layout in
      if !isTrashScope, layout == .grid, let parent = selectedNote?.parentBookID { selectedBookIDs = [parent]; selectedNoteID = nil }
    }
  }

  var body: some View {
    contentWithNoteRouting
    .modifier(LibraryDisplayStyle())
    .task { await restoreWorkspace() }
    .onChange(of: workspaceState) { _, state in
      if !isRestoringWorkspace { state.save() }
    }
    .onChange(of: tags.map(\.id)) { _, ids in selectedTagIDs.formIntersection(ids) }
    .onChange(of: collections.map(\.id)) { _, ids in
      if case .collection(let id) = navigationSelection, !ids.contains(id) { navigationSelection = .all }
      if case .smart(let id) = navigationSelection, !ids.contains(id) { navigationSelection = .all }
    }
    .onChange(of: navigationSelection) { _, value in
      guard !isRestoringWorkspace else { return }
      selectedBookIDs.removeAll(); selectedNoteID = nil; selectedTrashItemIDs.removeAll()
      selectedTagIDs.removeAll()
      if case .smart = value { advancedQuery = AdvancedBookQuery(); searchText = "" }
      if value == .trash || value == .noteTrash { advancedQuery = AdvancedBookQuery(); searchText = "" }
      if let edit = smartRuleEdit, value != edit.selection { closeAdvancedSearch() }
      if case .smart = value, smartRuleEdit == nil { showsAdvancedSearch = false }
      if isNotesScope || isTrashScope { showsAdvancedSearch = false }
      if let bookID = pendingLocationBookID {
        pendingLocationBookID = nil
        if visibleBooks.contains(where: { $0.id == bookID }) { selectedBookIDs = [bookID] }
      }
      if let request = pendingMetadataNavigation {
        pendingMetadataNavigation = nil
        selectMetadataField(request)
      }
    }
    .onChange(of: duplicateGroups.map(\.id)) { _, ids in
      if let duplicateGroupID, !ids.contains(duplicateGroupID) { self.duplicateGroupID = nil }
    }
    .alert(
      "无法保存更改",
      isPresented: Binding(
        get: { errorMessage != nil || history.errorMessage != nil }, set: { if !$0 { errorMessage = nil; history.errorMessage = nil } }
      )
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(errorMessage ?? history.errorMessage ?? "")
    }
  }

  private var hasLibraryContext: Bool {
    (currentSmartCollection != nil && smartRuleEdit == nil) || (advancedQuery.hasConditions && !showsAdvancedSearch) || currentCollectionID != nil ||
      navigationSelection == .duplicates || !selectedTagIDs.isEmpty
  }

  private func libraryMoreMenu(_ mode: LibraryToolbarMode) -> some View {
    Menu {
      if !mode.showsAll {
        if !mode.showsAdd {
          Menu("添加书籍", systemImage: "plus") { newBookMenuItems }
          Button("按书名或 ISBN 添加…", systemImage: "wand.and.stars") { presentNewBook(search: true) }
        }
        if !mode.showsNotes {
          Menu("新建笔记", systemImage: "square.and.pencil") { newNoteMenuItems }
        }
        BibliographicExchangeMenu(books: visibleBooks, selectedBooks: selectedBooks,
          presentation: exchangePresentation).disabled(isNotesScope)
        Divider()
      }
      LibraryUndoMenuItems()
      if !isNotesScope && !showsOnlyNotes {
        Divider()
        Picker("显示方式", selection: $layoutStyle) {
          Label("列表", systemImage: "list.bullet").tag(LibraryLayoutStyle.list)
          Label("封面墙", systemImage: "square.grid.2x2").tag(LibraryLayoutStyle.grid)
        }.pickerStyle(.inline).disabled(isTrashScope)
        Divider()
        Menu("整理所选", systemImage: "ellipsis.circle") { selectionActions }
          .disabled(isTrashScope ? selectedTrashItemIDs.isEmpty : selectedBooks.isEmpty)
        Menu("排序", systemImage: "arrow.up.arrow.down") {
          ForEach(BookSortOption.allCases) { option in
            Button(option.title) { sortOrder = [option.comparator] }
          }
        }
        if isTrashScope {
          Divider()
          Button("清空回收站…", role: .destructive, action: confirmEmptyTrash)
            .disabled(!books.contains { $0.deletedAt != nil } && !libraryNotes.contains { $0.deletedAt != nil })
        }
      }
    } label: { LibraryToolbarLabel("更多操作", systemImage: "ellipsis") }
      .help("撤销、重做、显示方式、整理所选与排序")
  }

  private var libraryContextHeader: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let smart = currentSmartCollection, smartRuleEdit == nil {
        HStack {
          Text(smart.smartQuery.map { "智能书单 · " + $0.summary } ?? "智能书单规则不可用，请从备份恢复。")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("编辑规则") { editSmartCollection(smart) }
        }
      } else if advancedQuery.hasConditions && !showsAdvancedSearch {
        HStack {
          Text("高级筛选 · \(advancedQuery.mode.title) · \(advancedQuery.rules.count) 条条件").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("保存为智能书单…") { beginSavingAdvancedSearch(advancedQuery) }
          Button("清除高级筛选") { advancedQuery = AdvancedBookQuery() }
        }
      }
      if let id = currentCollectionID {
        HStack {
          Text(CollectionTree.path(id, in: manualCollections.map(ManualCollectionRecord.init)))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          Spacer()
          Toggle("包含子书单", isOn: $includeSubcollections).toggleStyle(.checkbox).font(.caption)
        }
      }
      if navigationSelection == .duplicates {
        DuplicateGroupSelector(groups: duplicateGroups, selection: duplicateGroupID,
          visibleIDs: Set(visibleBooks.map(\.id)), onSelect: selectDuplicateGroup,
          onMerge: openMerge)
      }
      if !selectedTagIDs.isEmpty {
        HStack {
          Label("已选 \(selectedTagIDs.count) 个标签，匹配全部", systemImage: "line.3.horizontal.decrease")
          Spacer()
          Button("清除标签") { selectedTagIDs.removeAll() }.buttonStyle(.plain)
        }
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
  }

  private var selectionActions: some View {
    Group {
    if isTrashScope {
      TrashSelectionActions(canRestore: canRestoreTrashItems(selectedTrashItemIDs),
        onRestore: { restoreTrashItems(selectedTrashItemIDs) }, onPurge: { confirmTrashPurge(selectedTrashItemIDs) })
    } else {
    BookSelectionActions(
      books: selectedBooks, collections: manualCollections, currentCollectionID: currentCollectionID,
      onFavorite: { ids, value in update(ids) { $0.isFavorite = value } },
      onCollection: changeCollection, onBatchEdit: openBatchEdit)
      Divider()
      Button("合并所选书籍…") { openMerge(selectedBookIDs) }.disabled(selectedBooks.count < 2)
      Button("移入回收站", role: .destructive) { changeTrash(selectedBookIDs, true) }
    }
    }
  }

  private var availableInspectorPanels: Set<InspectorPanel> {
    if selectedNote != nil { return [.notes] }
    if selectedBooks.count == 1 && (!isTrashScope || selectedTrashItemIDs.count == 1) {
      return Set(InspectorPanel.allCases)
    }
    return []
  }

  private func navigateInspector(_ panel: InspectorPanel) {
    guard availableInspectorPanels.contains(panel) else { return }
    showsInspector = true
    if selectedNote != nil { return }
    guard let book = selectedBooks.first else { return }
    activeInspectorPanel = panel
    inspectorNavigationRequest = InspectorNavigationRequest(bookID: book.id, panel: panel)
  }

  @ViewBuilder private var inspector: some View {
    if isTrashScope && selectedTrashItemIDs.count > 1 {
      VStack(spacing: 16) {
        Image(systemName: "trash").font(.system(size: 36)).foregroundStyle(.secondary)
        Text("已选择 \(selectedTrashItemIDs.count) 个条目").font(.title3.weight(.semibold))
        Text("\(selectedTrashItemIDs.compactMap(\.bookID).count) 本书 · \(selectedTrashItemIDs.compactMap(\.noteID).count) 条笔记")
          .foregroundStyle(.secondary)
        if !canRestoreTrashItems(selectedTrashItemIDs) {
          Text("部分笔记的所属书籍仍在回收站中，请同时选择这些书籍，或先恢复书籍。")
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        TrashSelectionActions(canRestore: canRestoreTrashItems(selectedTrashItemIDs),
          onRestore: { restoreTrashItems(selectedTrashItemIDs) }, onPurge: { confirmTrashPurge(selectedTrashItemIDs) })
      }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let note = selectedNote {
      NoteDetailView(note: note, onRestore: { restoreTrashItems([.note(note.id)]) },
        onPurge: { confirmTrashPurge([.note(note.id)]) }).id(note.id)
    } else if selectedBooks.count == 1, let book = selectedBooks.first {
      BookInspectorView(book: book, onRestore: { restoreTrashItems([.book(book.id)]) },
        onPurge: { confirmPurge([book.id]) },
        onRevealLocation: { revealLocation(of: book, collectionID: $0) },
        activePanel: $activeInspectorPanel, expandedPanels: $expandedInspectorPanels, navigationRequest: inspectorNavigationRequest).id(book.id)
    } else if selectedBooks.count > 1 {
      VStack(spacing: 18) {
        Image(systemName: "books.vertical").font(.system(size: 42)).foregroundStyle(.secondary)
        Text("已选择 \(selectedBooks.count) 本书").font(.title3.weight(.semibold))
        Text("统一设置标签与出版信息，或加入书单。")
          .foregroundStyle(.secondary).multilineTextAlignment(.center)
        if selectedBooks.allSatisfy({ $0.deletedAt == nil }) {
          Button("批量编辑…") { openBatchEdit(selectedBookIDs) }.buttonStyle(.borderedProminent)
        }
        Menu("整理所选书籍") { selectionActions }.fixedSize()
      }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView(
        "条目信息", systemImage: "sidebar.right",
        description: Text("选择书籍查看出版信息，或展开书籍并选择下方笔记。"))
    }
  }

  private func revealLocation(of book: Book, collectionID: UUID?) {
    guard book.deletedAt == nil else { return }
    if let id = collectionID {
      guard manualCollections.contains(where: { $0.id == id }),
        book.collectionItems.contains(where: { $0.collection?.id == id }) else { return }
    }
    let destination: LibrarySelection = collectionID.map(LibrarySelection.collection) ?? .all
    searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery(); duplicateGroupID = nil
    selectedNoteID = nil; selectedTrashItemIDs.removeAll()
    showsInspector = true
    if navigationSelection == destination { selectedBookIDs = [book.id] }
    else { pendingLocationBookID = book.id; navigationSelection = destination }
  }

  private func presentNewBook(search: Bool = false) {
    appState.presentNewBook(collectionID: currentCollectionID, startWithSearch: search)
  }

  private func changeNoteTrash(_ note: NoteRecord, _ trashed: Bool) {
    do {
      try NoteCommands(context: modelContext, undoManager: undoManager).setTrashed(trashed, expected: note)
      if selectedNoteID == note.id { selectedNoteID = nil }
    } catch { errorMessage = error.localizedDescription }
  }

  private func createNote(parentID: UUID?) {
    do {
      var note = NoteRecord(parentBookID: parentID)
      if parentID == nil, let id = currentCollectionID { note.collectionIDs = [id] }
      let saved = try NoteCommands(context: modelContext, undoManager: undoManager).save(note, expected: nil)
      _ = noteEditing.open(saved)
      searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
      if navigationSelection == .noteTrash { navigationSelection = .notes }
      openNote(saved.id)
    } catch { errorMessage = error.localizedDescription }
  }

  private func openNote(_ id: UUID) {
    guard let note = libraryNotes.first(where: { $0.id == id }).map(NoteRecord.init) ?? noteEditing.drafts[id]?.value
      ?? (try? OrganizationStore.notes(in: modelContext, ids: [id])[id]) else { return }
    if let parent = note.parentBookID {
      if !isNotesScope && !visibleBooks.contains(where: { $0.id == parent }) {
        navigationSelection = .all; searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
      }
      expandedBookIDs.insert(parent)
    } else if !isNotesScope && navigationSelection != .all && currentCollectionID == nil {
      navigationSelection = .standaloneNotes
    }
    selectedBookIDs.removeAll(); selectedNoteID = id; showsInspector = true
    noteEditing.requestFocus(id)
  }

  @ViewBuilder private var recoveryBanner: some View {
    if !noteEditing.pendingDrafts.isEmpty || noteEditing.recoveryIssue != nil {
      HStack {
        if !noteEditing.pendingDrafts.isEmpty {
          Menu("未保存草稿（\(noteEditing.pendingDrafts.count)）") {
            ForEach(noteEditing.pendingDrafts, id: \.value.id) { draft in
              Button(draft.value.displayTitle) {
                navigationSelection = .notes; openNote(draft.value.id)
              }
            }
          }
          Text("保存失败的内容已保留，可打开重试或另存。")
        }
        if let issue = noteEditing.recoveryIssue { Text(issue).textSelection(.enabled) }
        Spacer()
      }.font(.caption).padding(10).background(.bar)
    }
  }

  @ViewBuilder private var metadataRecoveryBanner: some View {
    if !metadataEditing.pendingDrafts.isEmpty || metadataEditing.recoveryIssue != nil {
      HStack {
        if !metadataEditing.pendingDrafts.isEmpty {
          Menu("未保存的元信息（\(metadataEditing.pendingDrafts.count)）") {
            ForEach(metadataEditing.pendingDrafts) { draft in
              Menu("\(draft.bookTitle) · \(draft.field.label)") {
                Button("前往字段") {
                  guard let book = books.first(where: { $0.id == draft.bookID }) else { return }
                  searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
                  let request = BookMetadataFocusRequest(bookID: book.id, field: draft.field)
                  let scope: LibrarySelection = book.deletedAt == nil ? .all : .trash
                  if navigationSelection == scope { selectMetadataField(request) }
                  else { pendingMetadataNavigation = request; navigationSelection = scope }
                }.disabled(!books.contains { $0.id == draft.bookID })
                Button("复制未保存内容") {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(draft.text, forType: .string)
                }
                Button("放弃此字段修改") { metadataEditing.discard(draft.bookID, field: draft.field) }
              }
            }
          }
          Text("输入已保留，可继续修改或重试保存。")
        }
        if let issue = metadataEditing.recoveryIssue { Text(issue).textSelection(.enabled) }
        Spacer()
      }.font(.caption).padding(10).background(.bar)
    }
  }

  private func selectMetadataField(_ request: BookMetadataFocusRequest) {
    guard let book = books.first(where: { $0.id == request.bookID }) else { return }
    selectedNoteID = nil; showsInspector = true
    if book.deletedAt == nil { selectedBookIDs = [book.id] }
    else { selectedTrashItemIDs = [.book(book.id)] }
    metadataEditing.requestFocus(book.id, field: request.field)
  }

  private func expandSearchMatches() {
    guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    expandedBookIDs.formUnion(childNotes.filter { NoteQueries.matches($0, text: searchText, searchScope: searchScope) }.compactMap(\.parentBookID))
  }

  private func updateChildNotes(_ old: [NoteRecord], _ new: [NoteRecord]) {
    let previous = Dictionary(uniqueKeysWithValues: old.compactMap { note in
      note.parentBookID.map { (note.id, $0) }
    })
    for note in new where previous[note.id] != note.parentBookID {
      if let parent = note.parentBookID { expandedBookIDs.insert(parent) }
    }
    expandSearchMatches()
  }

  private func selectDuplicateGroup(_ id: UUID?) {
    duplicateGroupID = id
    searchText = ""
    advancedQuery = AdvancedBookQuery()
    selectedTagIDs.removeAll()
    selectedBookIDs = duplicateGroups.first { $0.id == id }?.bookIDs ?? []
  }

  private func editSmartCollection(_ collection: BookCollection) {
    do {
      let archive = try SmartCollectionArchive(collection)
      smartRuleEdit = SmartRuleEdit(original: archive, name: archive.name, query: archive.query)
      searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
      navigationSelection = .smart(archive.id)
      showsAdvancedSearch = true
    } catch { errorMessage = error.localizedDescription }
  }

  private func changeTrash(_ ids: Set<UUID>, _ trashed: Bool) {
    do { try LibraryOperations.setTrashed(trashed, books: books.filter { ids.contains($0.id) }, context: modelContext, undoManager: undoManager) }
    catch { errorMessage = error.localizedDescription }
  }
  private func canRestoreTrashItems(_ ids: Set<LibraryItemID>) -> Bool {
    guard !ids.isEmpty else { return false }
    let parentIDs = Set(libraryNotes.filter { ids.contains(.note($0.id)) }.compactMap(\.parentBookID))
    return !books.contains { parentIDs.contains($0.id) && $0.deletedAt != nil && !ids.contains(.book($0.id)) }
  }
  private func restoreTrashItems(_ ids: Set<LibraryItemID>) {
    do {
      try trashCommands.restore(trashCommands.preview(ids))
      selectedTrashItemIDs.subtract(ids)
    } catch { errorMessage = error.localizedDescription }
  }
  private func confirmPurge(_ ids: Set<UUID>) { confirmTrashPurge(Set(ids.map(LibraryItemID.book))) }
  private func confirmTrashPurge(_ ids: Set<LibraryItemID>) {
    do { try presentPurge(trashCommands.preview(ids)) }
    catch { errorMessage = error.localizedDescription }
  }
  private func confirmEmptyTrash() {
    do { try presentPurge(trashCommands.previewEmptyTrash()) }
    catch { errorMessage = error.localizedDescription }
  }
  private func presentPurge(_ plan: TrashPlan) throws {
    guard !plan.notes.keys.contains(where: { noteEditing.drafts[$0]?.hasUnsavedChanges == true }) else {
      errorMessage = "所选笔记仍有未保存的草稿，请先保存或另存草稿，再永久删除。"
      return
    }
    purgePlan = plan; isConfirmingPurge = true
  }
  private func purgeSelection() {
    guard let plan = purgePlan else { return }
    defer { purgePlan = nil }
    do {
      try trashCommands.purge(plan)
      selectedTrashItemIDs.subtract(Set(plan.books.keys.map(LibraryItemID.book)).union(plan.notes.keys.map(LibraryItemID.note)))
    } catch { errorMessage = error.localizedDescription }
  }
  private func openMerge(_ ids: Set<UUID>) {
    let selected = activeBooks.filter { ids.contains($0.id) }
    guard selected.count >= 2 else { return }
    mergeRequest = BookMergeRequest(records: selected.map { BookArchive(book: $0) })
  }

  private func openBatchEdit(_ ids: Set<UUID>) {
    let selected = visibleBooks.filter { ids.contains($0.id) && $0.deletedAt == nil }
    guard !selected.isEmpty else { return }
    batchEditRequest = BookBatchEditRequest(records: selected.map { BookArchive(book: $0) }, tagNames: tags.map(\.name))
  }

  private func update(_ ids: Set<UUID>, change: (inout BookArchive) -> Void) {
    do {
      try LibraryCommands(context: modelContext, undoManager: undoManager)
        .update(activeBooks.filter { ids.contains($0.id) }, change: change)
    } catch { errorMessage = error.localizedDescription }
  }

  private func changeCollection(_ ids: Set<UUID>, _ collection: BookCollection, _ included: Bool) {
    do {
      try LibraryCommands(context: modelContext, undoManager: undoManager)
        .setMembership(activeBooks.filter { ids.contains($0.id) }, collection: collection, included: included)
    } catch { errorMessage = error.localizedDescription }
  }

}

/// Use fixed-size template images so native menu labels and SwiftUI buttons
/// share the same symbol dimensions instead of using different control fonts.
struct LibraryToolbarLabel: View {
  let title: String
  let systemImage: String
  init(_ title: String, systemImage: String) {
    self.title = title; self.systemImage = systemImage
  }
  var body: some View {
    Label { Text(title) } icon: {
      Image(nsImage: symbolImage).renderingMode(.template)
    }.labelStyle(.iconOnly).frame(width: 32, height: 32).contentShape(Rectangle())
  }
  private var symbolImage: NSImage {
    let size: CGFloat = 18
    guard let symbol = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) else { return NSImage() }
    let scale = size / max(symbol.size.width, symbol.size.height)
    let width = symbol.size.width * scale, height = symbol.size.height * scale
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
      symbol.draw(in: NSRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
      return true
    }
    image.isTemplate = true
    return image
  }
}

enum LibraryLayoutStyle: String, CaseIterable, Identifiable {
  case grid, list
  var id: String { rawValue }
}

enum BookSortOption: String, CaseIterable, Identifiable {
  case addedNewest, title, author, publicationDate
  var id: String { rawValue }
  var title: String {
    switch self {
    case .addedNewest: "最近添加"
    case .title: "书名"
    case .author: "作者"
    case .publicationDate: "出版日期"
    }
  }
  var comparator: KeyPathComparator<Book> {
    switch self {
    case .addedNewest: KeyPathComparator(\Book.addedAt, order: .reverse)
    case .title: KeyPathComparator(\Book.title)
    case .author: KeyPathComparator(\Book.authorDisplayName)
    case .publicationDate: KeyPathComparator(\Book.publicationSortText, order: .reverse)
    }
  }
}


/// New and existing smart collections share detached drafts. Only Save writes
/// a definition; existing definitions also retain their conflict-check snapshot.
private struct SmartRuleEdit {
  let id = UUID()
  let original: SmartCollectionArchive?
  var name: String
  var query: AdvancedBookQuery
  var preview: AdvancedBookQuery?
  var errorMessage: String?
  var selection: LibrarySelection { original.map { .smart($0.id) } ?? .all }
}

private struct PanelLayoutState: Hashable {
  let width: CGFloat
  let inspectorVisible: Bool
}

/// Width thresholds reserve at least 140 points for search, including padding and gaps.
private struct LibraryToolbarMode {
  let width: CGFloat
  var showsAll: Bool { width >= 520 }
  var showsNotes: Bool { width >= 420 }
  var showsAdd: Bool { width >= 300 }
}

private struct LibrarySearchField: NSViewRepresentable {
  @Binding var text: String
  @Binding var scope: LibrarySearchScope
  let focusRequest: UUID?
  let canSaveSearch: Bool
  let onSaveSearch: () -> Void
  let canShowAdvancedSearch: Bool
  let hasAdvancedSearch: Bool
  let onAdvancedSearch: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> FilterSearchField {
    let field = FilterSearchField()
    field.maximumRecents = 0
    field.identifier = NSUserInterfaceItemIdentifier("librarySearchField")
    field.font = .systemFont(ofSize: 13)
    field.sendsWholeSearchString = false
    field.sendsSearchStringImmediately = true
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.searchChanged(_:))
    context.coordinator.field = field
    context.coordinator.updateScopeMenu()
    field.filterButton.target = context.coordinator
    field.filterButton.action = #selector(Coordinator.showAdvancedSearch(_:))
    updateFilterButton(field)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateNSView(_ field: FilterSearchField, context: Context) {
    context.coordinator.parent = self
    context.coordinator.updateScopeMenu()
    updateFilterButton(field)
    let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
    if !composing && field.stringValue != text { field.stringValue = text }
    if let focusRequest, context.coordinator.lastFocusRequest != focusRequest {
      context.coordinator.lastFocusRequest = focusRequest
      DispatchQueue.main.async { [weak field] in
        guard let field, let window = field.window, window.isKeyWindow else { return }
        window.makeFirstResponder(field)
        field.selectText(nil)
      }
    }
  }

  private func updateFilterButton(_ field: FilterSearchField) {
    field.filterButton.isEnabled = canShowAdvancedSearch
    field.filterButton.contentTintColor = hasAdvancedSearch ? .controlAccentColor : .secondaryLabelColor
    field.filterButton.toolTip = hasAdvancedSearch ? "编辑当前高级筛选（⌥⌘F）" : "高级筛选（⌥⌘F）"
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: FilterSearchField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 300, height: 28)
  }

  @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate, NSMenuItemValidation {
    var parent: LibrarySearchField
    weak var field: NSSearchField?
    var displayedScope: LibrarySearchScope?
    var displayedCanSaveSearch: Bool?
    var lastFocusRequest: UUID?
    init(_ parent: LibrarySearchField) { self.parent = parent }

    @objc func showAdvancedSearch(_ sender: NSButton) {
      guard parent.canShowAdvancedSearch else { return }
      field?.window?.makeFirstResponder(nil)
      parent.onAdvancedSearch()
    }

    func updateScopeMenu() {
      guard let field, displayedScope != parent.scope || displayedCanSaveSearch != parent.canSaveSearch else { return }
      displayedScope = parent.scope
      displayedCanSaveSearch = parent.canSaveSearch
      field.placeholderString = "搜索：" + parent.scope.title
      field.setAccessibilityLabel("搜索：" + parent.scope.title)
      field.toolTip = "搜索范围：" + parent.scope.title + "。点击放大镜旁的箭头切换范围（⌘F 聚焦）。"
      let menu = NSMenu(title: "搜索范围")
      menu.autoenablesItems = false
      for scope in LibrarySearchScope.allCases {
        let item = NSMenuItem(title: scope.title, action: #selector(selectScope(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = scope.rawValue
        item.state = scope == parent.scope ? .on : .off
        menu.addItem(item)
      }
      menu.addItem(.separator())
      let save = NSMenuItem(title: "保存搜索为智能书单…", action: #selector(saveSearch(_:)), keyEquivalent: "")
      save.target = self; save.isEnabled = parent.canSaveSearch
      menu.addItem(save)
      field.searchMenuTemplate = menu
    }

    @objc func saveSearch(_ sender: NSMenuItem) {
      guard parent.canSaveSearch else { return }
      parent.onSaveSearch()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
      // NSSearchField builds its own menu from the template and can revalidate
      // copied items. Keep the displayed availability tied to the live search.
      menuItem.action == #selector(saveSearch(_:)) ? parent.canSaveSearch : true
    }

    @objc func selectScope(_ sender: NSMenuItem) {
      guard let raw = sender.representedObject as? String, let scope = LibrarySearchScope(rawValue: raw) else { return }
      parent.scope = scope
      updateScopeMenu()
      if let field { field.window?.makeFirstResponder(field) }
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      searchChanged(field)
    }

    @objc func searchChanged(_ field: NSSearchField) {
      guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
      if parent.text != field.stringValue { parent.text = field.stringValue }
    }
  }
}

/// Reserve a separate trailing slot for the funnel, leaving the native search
/// scope menu, clear button and IME field editor intact.
private final class FilterSearchField: NSSearchField {
  override class var cellClass: AnyClass? {
    get { FilterSearchFieldCell.self }
    set { }
  }
  let filterButton = NSButton()
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    filterButton.isBordered = false
    filterButton.imagePosition = .imageOnly
    filterButton.bezelStyle = .regularSquare
    filterButton.setAccessibilityLabel("高级筛选")
    filterButton.image = Self.funnelImage
    addSubview(filterButton)
  }
  required init?(coder: NSCoder) { nil }
  override func accessibilityChildren() -> [Any]? {
    var children = super.accessibilityChildren() ?? []
    if !children.contains(where: { ($0 as? NSButton) === filterButton }) { children.append(filterButton) }
    return children
  }
  override func layout() {
    super.layout()
    filterButton.frame = NSRect(x: bounds.maxX - 30, y: (bounds.height - 24) / 2, width: 26, height: 24)
  }
  private static var funnelImage: NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
      let path = NSBezierPath()
      path.move(to: NSPoint(x: 2, y: 2))
      for point in [NSPoint(x: 16, y: 2), NSPoint(x: 11, y: 8), NSPoint(x: 11, y: 14),
                    NSPoint(x: 7, y: 17), NSPoint(x: 7, y: 8)] { path.line(to: point) }
      path.close(); path.lineWidth = 1.3; path.lineJoinStyle = .round
      NSColor.labelColor.setStroke(); path.stroke()
      return true
    }
    image.isTemplate = true
    return image
  }
}

private final class FilterSearchFieldCell: NSSearchFieldCell {
  override func searchTextRect(forBounds rect: NSRect) -> NSRect {
    var text = super.searchTextRect(forBounds: rect)
    text.size.width = max(0, text.width - 28)
    return text
  }
  override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
    super.cancelButtonRect(forBounds: rect).offsetBy(dx: -28, dy: 0)
  }
}
