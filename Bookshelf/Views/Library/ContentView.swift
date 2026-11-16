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
  @State private var noteEditorPositions = NoteEditorPositionStore()
  @State private var metadataEditing = BookMetadataEditingSession()
  @State private var activeInspectorPanel = InspectorPanel.info
  @State private var expandedInspectorPanels: Set<InspectorPanel> = [.info]
  @State private var expandedCollectionIDs = Set<UUID>()
  @State private var isRestoringWorkspace = true
  @State private var inspectorNavigationRequest: InspectorNavigationRequest?
  @State private var inspectorReadingPositions = InspectorReadingPositionStore()
  @AppStorage("showsBookInspector") private var showsInspector = true
  @AppStorage("librarySidebarWidth") private var savedSidebarWidth = 225.0
  @AppStorage("libraryInspectorWidth") private var savedInspectorWidth = 330.0
  @State private var navigationSelection: LibrarySelection? = .all
  @State private var pendingMetadataNavigation: BookMetadataFocusRequest?
  @State private var pendingLocationBookID: UUID?
  @State private var pendingMovedNoteIDs: Set<UUID>?
  @State private var selectedBookIDs = Set<UUID>()
  @State private var selectedNoteIDs = Set<UUID>()
  // Single-note routing and workspace restoration keep using the focused note;
  // a batch has no editable inspector, avoiding edits to an arbitrary member.
  private var selectedNoteID: UUID? {
    get { selectedNoteIDs.count == 1 ? selectedNoteIDs.first : nil }
    nonmutating set { selectedNoteIDs = newValue.map { [$0] } ?? [] }
  }
  @State private var selectedTrashItemIDs = Set<LibraryItemID>()
  @State private var expandedBookIDs = Set<UUID>()
  @State private var selectedTagIDs = Set<UUID>()
  @State private var searchText = ""
  @AppStorage("librarySearchScope") private var searchScope = LibrarySearchScope.fieldsAndTags
  @State private var searchFocusRequest: UUID?
  @State private var sortOrder = [KeyPathComparator(\Book.addedAt, order: .reverse)]
  @State private var errorMessage: String?
  init() {
    let saved = LibraryWorkspaceState.load()
    _navigationSelection = State(initialValue: saved.selection)
    _selectedBookIDs = State(initialValue: saved.bookIDs)
    _selectedNoteIDs = State(initialValue: saved.noteID.map { [$0] } ?? [])
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
    if navigationSelection == .duplicates {
      showsInspector = true
      selectLibraryBooks(selectedBookIDs)
    }
    inspectorReadingPositions.retain(bookIDs: Set(books.map(\.id)))
    noteEditorPositions.retain(noteIDs: Set(libraryNotes.map(\.id)).union(noteEditing.pendingDrafts.map(\.value.id)))
    workspaceState.save()
  }

  private var history: LibraryHistory { LibraryServices.forContext(modelContext).history }
  @State private var mergeRequest: BookMergeRequest?
  @State private var batchEditRequest: BookBatchEditRequest?
  @State private var purgePlan: TrashPlan?
  @State private var isConfirmingPurge = false
  @State private var advancedQuery = AdvancedBookQuery()
  @State private var showsAdvancedSearch = false
  @State private var isAdvancedSearchCollapsed = false
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
  private var standaloneNotes: [NoteRecord] {
    let _ = LibraryNotifier.forContext(modelContext).revision
    return filteredStandaloneNotes(libraryNotes.map(NoteRecord.init))
  }
  private func filteredStandaloneNotes(_ notes: [NoteRecord]) -> [NoteRecord] {
    guard !isTrashScope, selectedTagIDs.isEmpty else { return [] }
    return NoteQueries.results(notes, books: books,
      collections: manualCollections.map(ManualCollectionRecord.init),
      scope: smartRuleEdit?.preview == nil ? navigationSelection ?? .all : .all,
      text: searchText, searchScope: searchScope, includeSubcollections: includeSubcollections,
      smartQuery: effectiveSmartQuery).filter {
        !advancedQuery.hasConditions || advancedQuery.matches($0)
      }
  }
  private var listNotes: [NoteRecord] { isTrashScope ? trashNotes : childNotes + standaloneNotes }
  private var duplicateGroups: [DuplicateGroup] { DuplicateDetector.groups(in: activeBooks) }
  private var libraryBookSelection: Binding<Set<UUID>> {
    Binding(get: { selectedBookIDs }, set: selectLibraryBooks)
  }

  private var visibleBooks: [Book] {
    let _ = LibraryNotifier.forContext(modelContext).revision
    return LibraryQueries.results(books, collections: collections, request: LibraryQueryRequest(
      selection: smartRuleEdit?.preview == nil ? navigationSelection ?? .all : .all,
      tagIDs: selectedTagIDs, text: searchText, searchScope: searchScope,
      advanced: smartRuleEdit?.preview ?? advancedQuery, includeSubcollections: includeSubcollections,
      noteMatchedBookIDs: searchScope.usesSearchTerms ? [] : Set(libraryNotes.filter {
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
      mergeRequest = nil
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
    if !isTrashScope { actions.advancedSearch = { presentAdvancedSearch() } }
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
  }

  private func navigationColumns(availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
    let contentMinimum: CGFloat = 360
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
      if showsAdvancedSearch && !isAdvancedSearchCollapsed && !isTrashScope {
        inlineAdvancedSearchPanel(availableHeight: availableHeight)
        Divider()
      }
      // Books and standalone notes share one table, including note-only results.
      VStack(spacing: 0) {
        LibraryView(
          books: visibleBooks, notes: listNotes,
          isTrash: isTrashScope, selectedBookIDs: libraryBookSelection,
          selectedNoteIDs: $selectedNoteIDs, selectedTrashItemIDs: $selectedTrashItemIDs, expandedBookIDs: $expandedBookIDs, sortOrder: $sortOrder,
          collections: manualCollections, currentCollectionID: currentCollectionID,
          onNewNote: { createNote(parentID: $0) },
          onEditNote: { openNote($0.id) },
          onTrashNote: { note in
            changeNoteTrash(note, true)
          },
          onMoveNote: moveNote,
          canRestoreItems: canRestoreTrashItems, onRestoreItems: restoreTrashItems,
          onPurgeItems: { confirmTrashPurge($0) },
          onCollection: changeCollection, onTrash: changeTrash, onMerge: openMerge, onPurge: confirmPurge
        )
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
      // Track the middle pane itself, including changes to either divider.
      // Keep enough room for the input and controls at the minimum window size.
      libraryToolbarContent(searchWidth: max(140, geometry.size.width / 3))
    }.frame(height: 44)
  }

  private func libraryToolbarContent(searchWidth: CGFloat) -> some View {
    HStack(spacing: 0) {
      Menu {
        Button(L10n.tr("添加书籍…"), systemImage: "book") { presentNewBook() }
        Button(L10n.tr("新建笔记"), systemImage: "note.text") { createNoteFromSelection() }
          .disabled(newNoteTarget == .unavailable).help(newNoteHelp)
      } label: { LibraryToolbarLabel(L10n.tr("添加"), systemImage: "plus") }
        .buttonStyle(.plain).menuStyle(.button).menuIndicator(.hidden)
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .help(L10n.tr("添加书籍或新建笔记")).fixedSize().frame(width: 32, height: 32)
      Spacer(minLength: 8)
      // Search keeps the same view identity across pane resizing.
      if showsAdvancedSearch {
        HStack(spacing: 10) {
          Text(isCreatingSmartCollection ? L10n.tr("新建智能文件夹") : L10n.tr("高级筛选")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          Button {
            isAdvancedSearchCollapsed.toggle()
          } label: {
            Image(systemName: isAdvancedSearchCollapsed
              ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
              .font(.system(size: 13)).frame(width: 24, height: 24)
          }
          .help(isAdvancedSearchCollapsed ? L10n.tr("展开高级筛选") : L10n.tr("收起条件编辑区，保留筛选条件和当前结果"))
          .accessibilityLabel(isAdvancedSearchCollapsed ? L10n.tr("展开高级筛选") : L10n.tr("收起高级筛选"))
          .accessibilityValue(isAdvancedSearchCollapsed ? L10n.tr("已收起") : L10n.tr("已展开"))
          Button(action: closeAdvancedSearch) {
            Image(systemName: "xmark").frame(width: 24, height: 28)
          }.help(smartRuleEdit == nil ? L10n.tr("收起条件面板，保留当前筛选结果") : isCreatingSmartCollection ? L10n.tr("取消新建，不创建文件夹") : L10n.tr("取消编辑，保留文件夹原有规则"))
            .accessibilityLabel(smartRuleEdit == nil ? L10n.tr("关闭高级筛选") : isCreatingSmartCollection ? L10n.tr("取消新建智能文件夹") : L10n.tr("取消编辑智能文件夹"))
        }.buttonStyle(.plain).foregroundStyle(.secondary)
      } else {
        LibrarySearchField(text: $searchText, scope: $searchScope, focusRequest: searchFocusRequest,
          canSaveSearch: canSaveCurrentSearch, onSaveSearch: saveCurrentSearch,
          canShowAdvancedSearch: !isTrashScope,
          hasAdvancedSearch: advancedQuery.hasConditions, onAdvancedSearch: presentAdvancedSearch)
          .frame(width: searchWidth, height: 32)
      }
    }
    .padding(.horizontal, 10).frame(height: 44)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var canSaveCurrentSearch: Bool {
    !isTrashScope && SavedLibrarySearch(scope: searchScope, text: searchText).validationMessage == nil
  }

  private func saveCurrentSearch() {
    guard canSaveCurrentSearch else { return }
    let query = AdvancedBookQuery.savingSearch(scope: searchScope, text: searchText)
    beginSmartCollection(query: query, preview: query)
  }

  private func presentAdvancedSearch() {
    guard !isTrashScope else { return }
    isAdvancedSearchCollapsed = false
    showsAdvancedSearch = true
  }

  private func closeAdvancedSearch() {
    smartRuleEdit = nil
    isAdvancedSearchCollapsed = false
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
    isAdvancedSearchCollapsed = false
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
    // Saving stays in the panel; collapsed results have no separate action row.
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
        startWithSearch: destination.startWithSearch
      )
      .frame(minWidth: 600, idealWidth: 620, minHeight: 440, idealHeight: 480)
    }
    .sheet(item: $batchEditRequest) { BookBatchEditView(request: $0) }
    .confirmationDialog(purgePlan?.confirmationTitle ?? L10n.tr("永久删除？"), isPresented: $isConfirmingPurge, titleVisibility: .visible) {
      Button(purgePlan?.emptiesTrash == true ? L10n.tr("清空回收站") : L10n.tr("永久删除"), role: .destructive) { purgeSelection() }
      Button(L10n.tr("取消"), role: .cancel) { purgePlan = nil }
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
      if !isRestoringWorkspace {
        noteEditorPositions.retain(noteIDs: Set(ids).union(noteEditing.pendingDrafts.map(\.value.id)))
      }
      selectedNoteIDs = selectedNoteIDs.filter { ids.contains($0) || noteEditing.drafts[$0]?.hasUnsavedChanges == true }
    }
    .onChange(of: listNotes.map(\.id)) { _, ids in
      if !isTrashScope {
        selectedNoteIDs = selectedNoteIDs.filter { ids.contains($0) || noteEditing.drafts[$0]?.hasUnsavedChanges == true }
      }
    }
    .onChange(of: visibleBooks.map(\.id)) { _, ids in
      if navigationSelection == .duplicates && !selectedBookIDs.isSubset(of: Set(ids)) {
        // Never leave a partially selected duplicate group. An already selected
        // native row would not send a new selection event when clicked again.
        selectedBookIDs.removeAll()
      } else { selectedBookIDs.formIntersection(ids) }
    }
    .onChange(of: childNotes, updateChildNotes)
    .onChange(of: visibleTrashItemIDs) { _, ids in
      if isTrashScope { selectedTrashItemIDs.formIntersection(ids) }
    }
    .onChange(of: selectedTrashItemIDs) { _, ids in if !isRestoringWorkspace && !ids.isEmpty { showsInspector = true } }
    .onChange(of: searchText) { _, _ in expandSearchMatches() }
    .onChange(of: searchScope) { _, _ in expandSearchMatches() }
    .onChange(of: selectedNoteIDs) { _, ids in
      if !ids.isEmpty {
        mergeRequest = nil
        if !isRestoringWorkspace { showsInspector = true }
      }
    }
    .onChange(of: selectedBookIDs) { _, ids in
      if !ids.isEmpty { selectedNoteID = nil }
      if let request = mergeRequest, request.bookIDs != ids { mergeRequest = nil }
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
    .onChange(of: books.map(\.id)) { _, ids in
      if !isRestoringWorkspace { inspectorReadingPositions.retain(bookIDs: Set(ids)) }
    }
    .onChange(of: collections.map(\.id)) { _, ids in
      if case .collection(let id) = navigationSelection, !ids.contains(id) { navigationSelection = .all }
      if case .smart(let id) = navigationSelection, !ids.contains(id) { navigationSelection = .all }
    }
    .onChange(of: navigationSelection) { _, value in
      guard !isRestoringWorkspace else { return }
      mergeRequest = nil
      selectedBookIDs.removeAll(); selectedNoteID = nil; selectedTrashItemIDs.removeAll()
      selectedTagIDs.removeAll()
      if case .smart = value { advancedQuery = AdvancedBookQuery(); searchText = "" }
      if value == .trash || value == .noteTrash { advancedQuery = AdvancedBookQuery(); searchText = "" }
      if let edit = smartRuleEdit, value != edit.selection { closeAdvancedSearch() }
      if case .smart = value, smartRuleEdit == nil { showsAdvancedSearch = false }
      if isTrashScope { showsAdvancedSearch = false }
      if value == .duplicates { showsInspector = true }
      if let bookID = pendingLocationBookID {
        pendingLocationBookID = nil
        if visibleBooks.contains(where: { $0.id == bookID }) { selectedBookIDs = [bookID] }
      }
      if let request = pendingMetadataNavigation {
        pendingMetadataNavigation = nil
        selectMetadataField(request)
      }
      if let ids = pendingMovedNoteIDs {
        pendingMovedNoteIDs = nil; selectedNoteIDs = ids; showsInspector = true
      }
    }
    .onChange(of: duplicateGroups.map(\.bookIDs)) { _, groups in
      guard !isRestoringWorkspace, navigationSelection == .duplicates, !selectedBookIDs.isEmpty else { return }
      if !groups.contains(selectedBookIDs) { selectedBookIDs.removeAll() }
    }
    .alert(
      L10n.tr("无法保存更改"),
      isPresented: Binding(
        get: { errorMessage != nil || history.errorMessage != nil }, set: { if !$0 { errorMessage = nil; history.errorMessage = nil } }
      )
    ) {
      Button(L10n.tr("好"), role: .cancel) {}
    } message: {
      Text(errorMessage ?? history.errorMessage ?? "")
    }
  }

  private var selectionActions: some View {
    Group {
    if isTrashScope {
      TrashSelectionActions(canRestore: canRestoreTrashItems(selectedTrashItemIDs),
        onRestore: { restoreTrashItems(selectedTrashItemIDs) }, onPurge: { confirmTrashPurge(selectedTrashItemIDs) })
    } else {
    BookSelectionActions(
      books: selectedBooks, collections: manualCollections, currentCollectionID: currentCollectionID,
      onCollection: changeCollection, onBatchEdit: openBatchEdit)
      Divider()
      Button(L10n.tr("合并所选书籍…")) { openMerge(selectedBookIDs) }.disabled(selectedBooks.count < 2)
      Button(L10n.tr("移入回收站"), role: .destructive) { changeTrash(selectedBookIDs, true) }
    }
    }
  }

  private var availableInspectorPanels: Set<InspectorPanel> {
    if mergeRequest != nil { return [] }
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
    if let request = mergeRequest, request.bookIDs == selectedBookIDs, selectedNoteIDs.isEmpty, !isTrashScope {
      BookMergePanel(request: request, onCancel: {
        mergeRequest = nil
        // An already selected native row does not emit another selection event.
        // Clear it so a click can open a fresh preview after cancellation.
        if navigationSelection == .duplicates { selectedBookIDs.removeAll() }
      }, onMerged: { primaryID in
        mergeRequest = nil
        selectedBookIDs = visibleBooks.contains { $0.id == primaryID } ? [primaryID] : []
      }).id(request.id)
    } else if navigationSelection == .duplicates && !selectedBooks.isEmpty && selectedNoteIDs.isEmpty {
      VStack(spacing: 0) {
        DuplicateReviewPanel(hasDuplicates: !duplicateGroups.isEmpty)
        if selectedBooks.count == 1, let book = selectedBooks.first {
          Divider()
          bookInspector(book)
        } else {
          Spacer(minLength: 0)
        }
      }
    } else {
      standardInspector
    }
  }

  private func bookInspector(_ book: Book) -> some View {
    BookInspectorView(book: book,
      onRevealLocation: { revealLocation(of: book, collectionID: $0) },
      activePanel: $activeInspectorPanel, expandedPanels: $expandedInspectorPanels,
      navigationRequest: inspectorNavigationRequest, readingPositions: inspectorReadingPositions).id(book.id)
  }

  @ViewBuilder private var standardInspector: some View {
    if isTrashScope && selectedTrashItemIDs.count > 1 {
      VStack(spacing: 16) {
        Image(systemName: "trash").font(.system(size: 36)).foregroundStyle(.secondary)
        Text(L10n.tr("已选择 \(selectedTrashItemIDs.count) 个条目"))
        Text(L10n.tr("\(selectedTrashItemIDs.compactMap(\.bookID).count) 本书 · \(selectedTrashItemIDs.compactMap(\.noteID).count) 条笔记"))
          .foregroundStyle(.secondary)
        if !canRestoreTrashItems(selectedTrashItemIDs) {
          Text(L10n.tr("部分笔记的所属书籍仍在回收站中，请同时选择这些书籍，或先恢复书籍。"))
            .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        TrashSelectionActions(canRestore: canRestoreTrashItems(selectedTrashItemIDs),
          onRestore: { restoreTrashItems(selectedTrashItemIDs) }, onPurge: { confirmTrashPurge(selectedTrashItemIDs) })
      }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if !isTrashScope && selectedNoteIDs.count > 1 {
      VStack(spacing: 16) {
        Image(systemName: "note.text").font(.system(size: 36)).foregroundStyle(.secondary)
        Text(L10n.tr("已选择 \(selectedNoteIDs.count) 条笔记"))
      }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let note = selectedNote {
      NoteDetailView(note: note, positions: noteEditorPositions, onRestore: { restoreTrashItems([.note(note.id)]) },
        onPurge: { confirmTrashPurge([.note(note.id)]) }).id(note.id)
    } else if selectedBooks.count == 1, let book = selectedBooks.first {
      bookInspector(book)
    } else if selectedBooks.count > 1 {
      VStack(spacing: 18) {
        Image(systemName: "books.vertical").font(.system(size: 42)).foregroundStyle(.secondary)
        Text(L10n.tr("已选择 \(selectedBooks.count) 本书"))
        Text(L10n.tr("统一设置标签与出版信息，或加入文件夹。"))
          .foregroundStyle(.secondary).multilineTextAlignment(.center)
        if selectedBooks.allSatisfy({ $0.deletedAt == nil }) {
          Button(L10n.tr("批量编辑…")) { openBatchEdit(selectedBookIDs) }.buttonStyle(.borderedProminent)
        }
        Menu(L10n.tr("整理所选书籍")) { selectionActions }.fixedSize()
      }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      // Use the same root items as the table, independent of child-note expansion.
      let itemCount = LibraryItemTree.rows(books: visibleBooks, notes: listNotes, inTrash: isTrashScope).count
      Text(L10n.tr("此视图中有 \(itemCount.formatted()) 个条目"))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(L10n.tr("统计当前筛选结果中的书籍与独立显示的笔记，不重复计入书籍下的笔记。"))
        .accessibilityIdentifier("libraryViewItemCount")
    }
  }

  private func revealLocation(of book: Book, collectionID: UUID?) {
    guard book.deletedAt == nil else { return }
    if let id = collectionID {
      guard manualCollections.contains(where: { $0.id == id }),
        book.collectionItems.contains(where: { $0.collection?.id == id }) else { return }
    }
    let destination: LibrarySelection = collectionID.map(LibrarySelection.collection) ?? .all
    searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
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

  private func moveNote(_ batches: [NoteDragBatch], to destination: NoteDropDestination) {
    do {
      guard !isTrashScope else { throw NoteMoveError.invalidDrag }
      let payloads = try NoteDragBatch.references(in: batches)
      guard payloads.allSatisfy({ noteEditing.drafts[$0.noteID]?.hasUnsavedChanges != true })
      else { throw NoteMoveError.unsavedDraft }
      let moved = try NoteCommands(context: modelContext, undoManager: undoManager).move(payloads, to: destination)
      for note in moved { _ = noteEditing.open(note) }
      expandedBookIDs.formUnion(moved.compactMap(\.parentBookID))
      let ids = Set(moved.map(\.id)), standalone = moved.filter { $0.parentBookID == nil }
      if filteredStandaloneNotes(standalone).count != standalone.count {
        searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
        if filteredStandaloneNotes(standalone).count != standalone.count {
          pendingMovedNoteIDs = ids; navigationSelection = .all
        }
      }
      selectedBookIDs.removeAll(); selectedNoteIDs = ids; showsInspector = true
    } catch { errorMessage = error.localizedDescription }
  }

  private func createNote(parentID: UUID?) {
    let target = parentID.map(NoteCreationTarget.child) ?? .standalone
    guard let draft = target.draft(collectionID: currentCollectionID) else { return }
    createNote(draft)
  }

  private var newNoteTarget: NoteCreationTarget {
    .resolve(selectedBookIDs: Set(selectedBooks.map(\.id)),
      hasSelectedNote: !selectedNoteIDs.isEmpty, inTrash: isTrashScope)
  }

  private var newNoteHelp: String {
    switch newNoteTarget {
    case .standalone: L10n.tr("新建独立笔记")
    case .child: L10n.tr("在所选书籍下新建子笔记")
    case .unavailable: isTrashScope ? L10n.tr("回收站中不能新建笔记") : L10n.tr("请选择一本书籍来新建子笔记")
    }
  }

  private func createNoteFromSelection() {
    guard let draft = newNoteTarget.draft(collectionID: currentCollectionID) else { return }
    createNote(draft)
  }

  private func createNote(_ note: NoteRecord) {
    do {
      let saved = try NoteCommands(context: modelContext, undoManager: undoManager).save(note, expected: nil)
      _ = noteEditing.open(saved)
      searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
      if navigationSelection == .noteTrash { navigationSelection = .all }
      openNote(saved.id)
    } catch { errorMessage = error.localizedDescription }
  }

  private func openNote(_ id: UUID) {
    guard let note = libraryNotes.first(where: { $0.id == id }).map(NoteRecord.init) ?? noteEditing.drafts[id]?.value
      ?? (try? OrganizationStore.notes(in: modelContext, ids: [id])[id]) else { return }
    if let parent = note.parentBookID {
      if !visibleBooks.contains(where: { $0.id == parent }) {
        navigationSelection = .all; searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
      }
      expandedBookIDs.insert(parent)
    } else if navigationSelection != .all && currentCollectionID == nil && !standaloneNotes.contains(where: { $0.id == id }) {
      navigationSelection = .all
    }
    selectedBookIDs.removeAll(); selectedNoteID = id; showsInspector = true
    noteEditing.requestFocus(id)
  }

  @ViewBuilder private var recoveryBanner: some View {
    if !noteEditing.pendingDrafts.isEmpty || noteEditing.recoveryIssue != nil {
      HStack {
        if !noteEditing.pendingDrafts.isEmpty {
          Menu(L10n.tr("未保存草稿（\(noteEditing.pendingDrafts.count)）")) {
            ForEach(noteEditing.pendingDrafts, id: \.value.id) { draft in
              Button(draft.value.displayTitle) {
                navigationSelection = .all; openNote(draft.value.id)
              }
            }
          }
          Text(L10n.tr("保存失败的内容已保留，可打开重试或另存。"))
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
          Menu(L10n.tr("未保存的元信息（\(metadataEditing.pendingDrafts.count)）")) {
            ForEach(metadataEditing.pendingDrafts) { draft in
              Menu("\(draft.bookTitle) · \(draft.field.label)") {
                Button(L10n.tr("前往字段")) {
                  guard let book = books.first(where: { $0.id == draft.bookID }) else { return }
                  searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
                  let request = BookMetadataFocusRequest(bookID: book.id, field: draft.field)
                  let scope: LibrarySelection = book.deletedAt == nil ? .all : .trash
                  if navigationSelection == scope { selectMetadataField(request) }
                  else { pendingMetadataNavigation = request; navigationSelection = scope }
                }.disabled(!books.contains { $0.id == draft.bookID })
                Button(L10n.tr("复制未保存内容")) {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(draft.text, forType: .string)
                }
                Button(L10n.tr("放弃此字段修改")) { metadataEditing.discard(draft.bookID, field: draft.field) }
              }
            }
          }
          Text(L10n.tr("输入已保留，可继续修改或重试保存。"))
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
    guard SavedLibrarySearch(scope: searchScope, text: searchText).validationMessage == nil else { return }
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

  private func selectLibraryBooks(_ proposed: Set<UUID>) {
    guard !isRestoringWorkspace, navigationSelection == .duplicates,
      let group = DuplicateSelection.group(for: proposed, previous: selectedBookIDs, in: duplicateGroups) else {
      selectedBookIDs = proposed
      return
    }
    // Reveal hidden group members before selecting them. Keep the complete
    // duplicate list available, so another group is one click away.
    if !group.bookIDs.isSubset(of: Set(visibleBooks.map(\.id))) {
      searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
    }
    selectedNoteIDs.removeAll()
    selectedBookIDs = group.bookIDs
    showsInspector = true
    // Keep local field choices when the same group is reselected. A different
    // group gets a new snapshot and a fresh panel, including version conflicts.
    if mergeRequest?.bookIDs != group.bookIDs { openMerge(group.bookIDs) }
  }

  private func editSmartCollection(_ collection: BookCollection) {
    do {
      let archive = try SmartCollectionArchive(collection)
      smartRuleEdit = SmartRuleEdit(original: archive, name: archive.name, query: archive.query)
      searchText = ""; selectedTagIDs.removeAll(); advancedQuery = AdvancedBookQuery()
      navigationSelection = .smart(archive.id)
      isAdvancedSearchCollapsed = false
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
      errorMessage = L10n.tr("所选笔记仍有未保存的草稿，请先保存或另存草稿，再永久删除。")
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
    selectedNoteIDs.removeAll()
    selectedBookIDs = Set(selected.map(\.id))
    mergeRequest = BookMergeRequest(records: selected.map { BookArchive(book: $0) })
    showsInspector = true
  }

  private func openBatchEdit(_ ids: Set<UUID>) {
    let selected = visibleBooks.filter { ids.contains($0.id) && $0.deletedAt == nil }
    guard !selected.isEmpty else { return }
    batchEditRequest = BookBatchEditRequest(records: selected.map { BookArchive(book: $0) }, tagNames: tags.map(\.name))
  }

  private func changeCollection(_ ids: Set<UUID>, _ collection: BookCollection, _ included: Bool) {
    do {
      try LibraryCommands(context: modelContext, undoManager: undoManager)
        .setMembership(activeBooks.filter { ids.contains($0.id) }, collection: collection, included: included)
    } catch { errorMessage = error.localizedDescription }
  }

}

/// Menus use `.menuStyle(.button)` with plain buttons to retain this label's
/// actual size; `.borderlessButton` substitutes a smaller native menu image.
struct LibraryToolbarLabel: View {
  @Environment(\.libraryDisplay) private var display
  let title: String
  let systemImage: String
  init(_ title: String, systemImage: String) {
    self.title = title; self.systemImage = systemImage
  }
  var body: some View {
    LibraryIcon(systemName: systemImage)
      .frame(width: display.toolbarControlSize, height: display.toolbarControlSize)
      .contentShape(Rectangle()).accessibilityElement(children: .ignore).accessibilityLabel(title)
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

private struct LibrarySearchField: NSViewRepresentable {
  @Environment(\.locale) private var locale
  @Environment(\.libraryDisplay) private var display
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
    field.font = .systemFont(ofSize: display.fontSize)
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
    let _ = locale
    field.filterButton.setAccessibilityLabel(L10n.tr("高级筛选"))
    context.coordinator.parent = self
    field.font = .systemFont(ofSize: display.fontSize)
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
    field.applyDisplayMetrics(display)
    field.filterButton.isEnabled = canShowAdvancedSearch
    field.filterButton.contentTintColor = hasAdvancedSearch ? .controlAccentColor : .secondaryLabelColor
    field.filterButton.toolTip = hasAdvancedSearch ? L10n.tr("编辑当前高级筛选（⌥⌘F）") : L10n.tr("高级筛选（⌥⌘F）")
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: FilterSearchField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 300, height: 32)
  }

  @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate, NSMenuItemValidation {
    var parent: LibrarySearchField
    weak var field: NSSearchField?
    var displayedLanguage: InterfaceLanguage?
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
      let language = InterfaceLanguagePreferences.shared.language
      guard let field, displayedScope != parent.scope || displayedCanSaveSearch != parent.canSaveSearch || displayedLanguage != language else { return }
      displayedLanguage = language
      displayedScope = parent.scope
      displayedCanSaveSearch = parent.canSaveSearch
      field.placeholderString = parent.scope.title
      field.setAccessibilityLabel(L10n.tr("搜索：") + parent.scope.title)
      field.toolTip = parent.scope.help + L10n.tr(" 空格表示同时匹配，大写 OR 表示任选条件；双引号匹配连续短语，- 排除词、短语或括号组。括号优先，例如 (经济 OR 金融) -教材。支持嵌套和中文括号。点击放大镜旁的箭头切换范围（⌘F 聚焦）。")
      let menu = NSMenu(title: L10n.tr("搜索范围"))
      menu.autoenablesItems = false
      for scope in LibrarySearchScope.quickSearchScopes {
        let item = NSMenuItem(title: scope.title, action: #selector(selectScope(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = scope.rawValue
        item.state = scope == parent.scope ? .on : .off
        item.toolTip = scope.help
        menu.addItem(item)
      }
      menu.addItem(.separator())
      let save = NSMenuItem(title: L10n.tr("保存搜索为智能文件夹…"), action: #selector(saveSearch(_:)), keyEquivalent: "")
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
final class FilterSearchField: NSSearchField {
  override class var cellClass: AnyClass? {
    get { FilterSearchFieldCell.self }
    set { }
  }
  let filterButton = NSButton()
  private var display = LibraryDisplayMetrics()
  private var configuredDisplay: LibraryDisplayMetrics?
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // NSSearchField uses its bezel flag to inset the field editor. Drawing is
    // customized by the cell, but keep native editing geometry enabled.
    isBezeled = true
    drawsBackground = false
    focusRingType = .exterior
    filterButton.isBordered = false
    filterButton.imagePosition = .imageOnly
    filterButton.bezelStyle = .regularSquare
    filterButton.setAccessibilityLabel(L10n.tr("高级筛选"))
    filterButton.imageScaling = .scaleNone
    addSubview(filterButton)
  }
  required init?(coder: NSCoder) { nil }
  func applyDisplayMetrics(_ metrics: LibraryDisplayMetrics) {
    display = metrics
    if configuredDisplay != metrics {
      filterButton.image = Self.funnelImage(metrics: metrics)
      configuredDisplay = metrics
      needsLayout = true
    }
    // Setting the native scope menu can replace its image. Reapply the shared
    // size afterwards without replacing the cell, its target or menu action.
    (cell as? FilterSearchFieldCell)?.applyDisplayMetrics(metrics)
  }
  override func accessibilityChildren() -> [Any]? {
    var children = super.accessibilityChildren() ?? []
    if !children.contains(where: { ($0 as? NSButton) === filterButton }) { children.append(filterButton) }
    return children
  }
  override func layout() {
    super.layout()
    filterButton.frame = FilterSearchFieldCell.filterButtonRect(forBounds: bounds, metrics: display)
  }
  private static func funnelImage(metrics: LibraryDisplayMetrics) -> NSImage {
    let canvas = metrics.iconSlotSize
    let size = metrics.iconSize
    let inset = (canvas - size) / 2
    let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: true) { _ in
      func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: inset + x * size, y: inset + y * size)
      }
      let path = NSBezierPath()
      path.move(to: point(0, 0))
      for vertex in [point(1, 0), point(0.64, 0.4), point(0.64, 0.8),
                     point(0.36, 1), point(0.36, 0.4)] { path.line(to: vertex) }
      path.close(); path.lineWidth = size / 14; path.lineJoinStyle = .round
      NSColor.labelColor.setStroke(); path.stroke()
      return true
    }
    image.isTemplate = true
    return image
  }
}

final class FilterSearchFieldCell: NSSearchFieldCell {
  private var display = LibraryDisplayMetrics()
  private var configuredDisplay: LibraryDisplayMetrics?
  private var scopeImage: NSImage?

  func applyDisplayMetrics(_ metrics: LibraryDisplayMetrics) {
    display = metrics
    if configuredDisplay != metrics {
      let nativeImage = searchButtonCell?.image
      scopeImage = Self.makeScopeImage(metrics: metrics) ?? nativeImage
      configuredDisplay = metrics
    }
    searchButtonCell?.image = scopeImage
    searchButtonCell?.alternateImage = scopeImage
    searchButtonCell?.imageScaling = .scaleNone
  }

  private static func makeScopeImage(metrics: LibraryDisplayMetrics) -> NSImage? {
    guard let magnifier = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: metrics.iconSize, weight: .regular)),
      let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 8, weight: .regular)) else { return nil }
    // The native combined symbol has almost no gap. Compose the two glyphs
    // with explicit spacing while retaining the native cell and scope menu.
    let gap: CGFloat = 6
    let height = metrics.toolbarControlSize
    let image = NSImage(size: NSSize(width: magnifier.size.width + gap + chevron.size.width,
      height: height), flipped: false) { _ in
      magnifier.draw(in: NSRect(x: 0, y: (height - magnifier.size.height) / 2,
        width: magnifier.size.width, height: magnifier.size.height))
      chevron.draw(in: NSRect(x: magnifier.size.width + gap, y: (height - chevron.size.height) / 2,
        width: chevron.size.width, height: chevron.size.height))
      return true
    }
    image.isTemplate = true
    return image
  }

  // Use the same rounded rectangle for the background and the native focus ring.
  // Keep all geometry derived from bounds so resizing never overlaps the editor,
  // clear control or advanced-search control.
  override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
    let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
    NSColor.controlBackgroundColor.setFill(); path.fill()
    NSColor.separatorColor.setStroke()
    path.lineWidth = 1; path.stroke()
    drawInterior(withFrame: cellFrame, in: controlView)
  }

  override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
    NSBezierPath(roundedRect: cellFrame, xRadius: 6, yRadius: 6).fill()
  }

  static func filterButtonRect(forBounds rect: NSRect, metrics: LibraryDisplayMetrics = .init()) -> NSRect {
    let size = metrics.toolbarControlSize
    return NSRect(x: rect.maxX - size - 4, y: rect.midY - size / 2, width: size, height: size)
  }

  override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
    let size = display.toolbarControlSize
    return NSRect(x: rect.minX + 4, y: rect.midY - size / 2, width: size + 10, height: size)
  }

  override func searchTextRect(forBounds rect: NSRect) -> NSRect {
    let height = ceil((font?.ascender ?? 13) - (font?.descender ?? -3)) + 2
    let start = searchButtonRect(forBounds: rect).maxX + 4
    let end = stringValue.isEmpty ? Self.filterButtonRect(forBounds: rect, metrics: display).minX - 4
      : cancelButtonRect(forBounds: rect).minX - 4
    return NSRect(x: start, y: rect.midY - height / 2, width: max(0, end - start), height: height)
  }
  override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
    NSRect(x: Self.filterButtonRect(forBounds: rect, metrics: display).minX - 22, y: rect.midY - 9, width: 18, height: 18)
  }
}
