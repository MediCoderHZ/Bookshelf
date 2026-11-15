import SwiftData
import SwiftUI

struct BookInspectorView: View {
  @Environment(\.libraryDisplay) private var display
  @Environment(AppState.self) private var appState
  @Environment(BookMetadataEditingSession.self) private var metadataEditing
  @Environment(\.modelContext) private var modelContext
  @Environment(\.noteNavigation) private var noteNavigation
  @Environment(\.libraryUndoManager) private var undoManager
  @Query(sort: \BookCollection.name) private var storedCollections: [BookCollection]
  private var collections: [BookCollection] { storedCollections.filter { !$0.isSmart } }
  @Query(sort: \Tag.name) private var tags: [Tag]
  @Query(sort: \LibraryNote.createdAt) private var storedNotes: [LibraryNote]
  let book: Book
  var onRestore: (() -> Void)? = nil
  var onPurge: (() -> Void)? = nil
  var onRevealLocation: ((UUID?) -> Void)? = nil
  private var isReadOnly: Bool { book.deletedAt != nil }
  @Binding var activePanel: InspectorPanel
  @Binding var expandedPanels: Set<InspectorPanel>
  var navigationRequest: InspectorNavigationRequest? = nil
  @State private var newTag = ""
  @State private var showsTagInput = false
  @State private var tagFocusToken: UUID?
  @State private var isConfirmingDeletion = false
  @State private var errorMessage: String?

  var body: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 0) {
        header
        Divider()
        ScrollView {
          VStack(spacing: 0) {
            ForEach(InspectorPanel.allCases) { section in
              inspectorSection(section)
                .id(section)
              Divider()
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: navigationRequest) {
          guard let request = navigationRequest, request.bookID == book.id else { return }
          activePanel = request.panel
          expandedPanels.insert(request.panel)
          // Wait for an expanded section (or a reopened inspector) to enter layout.
          await Task.yield()
          guard !Task.isCancelled else { return }
          withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(request.panel, anchor: .top)
          }
        }
    }
    .onChange(of: metadataEditing.focusRequest?.token) { _, _ in revealRequestedField() }
    .onAppear {
      if let request = navigationRequest, request.bookID == book.id { activePanel = request.panel }
      revealRequestedField()
    }
    .confirmationDialog(
      "将《\(book.title)》移入回收站？", isPresented: $isConfirmingDeletion,
      titleVisibility: .visible
    ) {
      Button("移入回收站", role: .destructive) {
        do {
          try LibraryOperations.setTrashed(true, books: [book], context: modelContext, undoManager: undoManager)
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    } message: {
      Text("元信息、笔记和封面会保留，可从回收站恢复或撤销本次操作。")
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

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        Text(book.title).font(.system(size: display.fontSize + 3, weight: .semibold))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        Menu {
          if isReadOnly {
            Button("恢复书籍", systemImage: "arrow.uturn.backward") { onRestore?() }
              .disabled(onRestore == nil)
            Button("永久删除…", systemImage: "trash", role: .destructive) { onPurge?() }
              .disabled(onPurge == nil)
          } else {
            Button("更多编辑选项…", systemImage: "pencil") { appState.presentEditor(for: book) }
            Button(book.isFavorite ? "取消收藏" : "加入收藏", systemImage: book.isFavorite ? "star.slash" : "star") {
              persist { $0.isFavorite.toggle() }
            }
            Divider()
            Button("移入回收站…", systemImage: "trash", role: .destructive) { isConfirmingDeletion = true }
          }
        } label: {
          Image(systemName: "ellipsis").font(.system(size: 15)).frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("书籍操作").help("书籍操作")
      }
      if isReadOnly {
        Label("回收站 · 只读", systemImage: "trash").font(display.caption).foregroundStyle(.secondary)
        if book.mergedIntoID != nil {
          Text("合并时保留的原记录。恢复副本不会回退主记录；回退整次合并请使用撤销。")
            .font(display.caption).foregroundStyle(.secondary)
        }
      }
    }.padding(.horizontal, 14).padding(.vertical, 14)
  }

  private func inspectorSection(_ section: InspectorPanel) -> some View {
    let expanded = expandedPanels.contains(section)
    let count: Int? = switch section {
    case .notes: noteCount
    case .tags: assignedTags.count
    default: nil
    }
    return VStack(alignment: .leading, spacing: display.fieldSpacing) {
      HStack(spacing: 8) {
        Button { togglePanel(section) } label: {
          HStack(spacing: 8) {
            Image(systemName: section.systemImage).font(.system(size: 15)).frame(width: 18)
            Text(section.rawValue).font(display.font.weight(.semibold))
            if let count {
              Text(count, format: .number).font(display.caption).monospacedDigit()
            }
            Spacer()
          }.foregroundStyle(.secondary).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(section.rawValue)
        .accessibilityValue((expanded ? "已展开" : "已折叠") +
          (count.map { "，\($0) " + (section == .notes ? "条笔记" : "个标签") } ?? ""))
        .help(expanded ? "折叠" + section.rawValue : "展开" + section.rawValue)
        if section == .collections && !isReadOnly { membershipMenu }
        if section == .notes && !isReadOnly {
          Button {
            activePanel = .notes
            expandedPanels.insert(.notes)
            noteNavigation.create(book.id)
          } label: {
            Image(systemName: "plus").font(.system(size: 13)).frame(width: 20, height: 20)
          }.buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("新建书籍笔记").help("新建笔记")
        }
        if section == .tags && !isReadOnly {
          Button {
            activePanel = .tags
            expandedPanels.insert(.tags)
            showsTagInput = true
            tagFocusToken = UUID()
          } label: {
            Image(systemName: "plus").font(.system(size: 13)).frame(width: 20, height: 20)
          }.buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("添加标签").help("添加标签")
        }
        Button { togglePanel(section) } label: {
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 10, weight: .medium)).frame(width: 16, height: 20)
        }.buttonStyle(.plain).foregroundStyle(.secondary)
          .accessibilityLabel((expanded ? "折叠" : "展开") + section.rawValue)
      }
      if expanded && (section != .notes || noteCount > 0) {
        switch section {
        case .info: information
        case .notes: notes
        case .collections: collectionLocations
        case .tags: tagDetails
        }
      }
    }.padding(.horizontal, 14).padding(.vertical, display.sectionPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func togglePanel(_ section: InspectorPanel) {
    activePanel = section
    withAnimation(.easeInOut(duration: 0.18)) {
      if expandedPanels.contains(section) { expandedPanels.remove(section) }
      else { expandedPanels.insert(section) }
    }
  }

  private var information: some View {
    VStack(alignment: .leading, spacing: display.fieldSpacing) {
      HStack(alignment: .top, spacing: 10) {
        fieldLabel("条目类型")
        if isReadOnly {
          Text(book.bookType?.title ?? "").frame(maxWidth: .infinity, alignment: .leading)
        } else {
          BookTypePicker(selection: Binding(get: { book.bookType }, set: { type in
            guard let type else { return }
            do {
              let expected = BookMetadataValue.read(.bookType, from: BookArchive(book: book, includeCover: false))
              try BookMetadataCommands(context: modelContext, undoManager: undoManager)
                .save(bookID: book.id, field: .bookType, text: type.rawValue, expected: expected)
            } catch { errorMessage = error.localizedDescription }
          }), emptyLabel: "")
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }.font(display.font)
      ForEach(informationFields) { field in metadataRow(field) }
      detailRow("添加日期", book.addedAt.formatted(date: .numeric, time: .standard))
      detailRow("修改日期", book.updatedAt.formatted(date: .numeric, time: .standard))
    }
  }

  private var childNotes: [NoteRecord] {
    storedNotes.filter { $0.parentBookID == book.id && $0.deletedAt == nil }.map(NoteRecord.init)
  }
  private var legacyNote: String? { book.notes?.nilIfEmpty }
  private var noteCount: Int { childNotes.count + (legacyNote == nil ? 0 : 1) }

  private var notes: some View {
    VStack(alignment: .leading, spacing: display.fieldSpacing) {
      if !childNotes.isEmpty { ChildNotesView(notes: childNotes, isReadOnly: isReadOnly) }
      if let legacy = legacyNote {
        if !childNotes.isEmpty { Divider() }
        sectionTitle("书籍备注")
        Text(legacy).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        if !isReadOnly {
          Button("转为书籍笔记并编辑") {
            do {
              let note = try NoteCommands(context: modelContext, undoManager: undoManager).convertLegacyNote(BookArchive(book: book))
              noteNavigation.open(note.id)
            }
            catch { errorMessage = error.localizedDescription }
          }.help("将原有备注移到一条子笔记中，内容完整保留，可以撤销。")
        }
      }
    }
  }

  private var collectionRecords: [ManualCollectionRecord] { collections.map(ManualCollectionRecord.init) }
  private var membershipIDs: Set<UUID> { Set(book.collectionItems.compactMap(\.collection?.id)) }

  private var collectionLocations: some View {
    let records = collectionRecords
    let locations = CollectionTree.locations(for: membershipIDs, in: records)
    return VStack(alignment: .leading, spacing: 10) {
      locationLink("我的书库", systemImage: "books.vertical", collectionID: nil)
      ForEach(locations) { location in
        Group {
          if location.isDirectMember {
            HStack(spacing: 8) {
              locationLink(location.record.name, systemImage: "folder", collectionID: location.id)
                .help("在左侧定位：" + CollectionTree.path(location.id, in: records))
              if !isReadOnly, let collection = collections.first(where: { $0.id == location.id }) {
                Button { setMembership(collection, included: false) } label: {
                  Image(systemName: "minus.circle").font(.system(size: 13))
                    .frame(width: 20, height: 20)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                  .accessibilityLabel("从书单移除：" + CollectionTree.path(location.id, in: records))
                  .help("从“\(location.record.name)”移除，书籍仍保留在书库中")
              }
            }
          } else {
            Label(location.record.name, systemImage: "folder")
              .foregroundStyle(.secondary).lineLimit(2)
              .help(CollectionTree.path(location.id, in: records))
          }
        }.padding(.leading, CGFloat(min(location.depth + 1, 6)) * 18)
      }
    }.font(display.font).frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func locationLink(_ title: String, systemImage: String, collectionID: UUID?) -> some View {
    if isReadOnly || onRevealLocation == nil {
      Label(title, systemImage: systemImage).lineLimit(2)
    } else {
      Button { onRevealLocation?(collectionID) } label: {
        Label(title, systemImage: systemImage).fontWeight(.medium).lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel(collectionID == nil ? "在左侧定位：我的书库" : "在左侧定位：" + title)
    }
  }

  private var membershipMenu: some View {
    Menu {
      if collections.isEmpty {
        Text("暂无普通书单，请先在左侧新建")
      }
      ForEach(collections) { collection in
        Toggle(CollectionTree.path(collection.id, in: collectionRecords), isOn: Binding(
          get: { membershipIDs.contains(collection.id) },
          set: { included in setMembership(collection, included: included) }
        ))
      }
    } label: {
      Image(systemName: "plus").font(.system(size: 13)).frame(width: 20, height: 20)
    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .foregroundStyle(.secondary)
      .accessibilityLabel("添加到书单").help("选择书单加入；取消勾选可移除归属")
  }

  private func setMembership(_ collection: BookCollection, included: Bool) {
    guard !isReadOnly else { return }
    do {
      try commands.setMembership([book], collection: collection, included: included)
      activePanel = .collections
      expandedPanels.insert(.collections)
    } catch { errorMessage = error.localizedDescription }
  }

  private var tagDetails: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(assignedTags) { tag in
        HStack {
          Text(tag.name).textSelection(.enabled)
          Spacer()
          if !isReadOnly {
            Button {
              do { try commands.setTag(tag.name, included: false, book: book) }
              catch { errorMessage = error.localizedDescription }
            } label: { Image(systemName: "minus.circle") }
              .buttonStyle(.plain).foregroundStyle(.secondary).help("移除标签 \(tag.name)")
          }
        }
      }
      if !isReadOnly && showsTagInput { tagInput }
    }
  }

  private var assignedTags: [Tag] { book.tagLinks.compactMap(\.tag).sorted { $0.name < $1.name } }

  private var tagSuggestions: [TagSuggestion] {
    TagSuggestions.matches(newTag, names: tags.map(\.name),
      assignedNames: book.tagLinks.compactMap(\.tag?.name))
  }

  private var tagInput: some View {
    TagInputView(text: $newTag, suggestions: tagSuggestions, onAdd: insertTag,
      focusToken: tagFocusToken, onCancel: dismissTagInput)
  }

  private func dismissTagInput() {
    showsTagInput = false
    newTag = ""
    tagFocusToken = nil
  }

  private func detailRow(_ label: String, _ value: String?) -> some View {
    HStack(alignment: .top, spacing: 10) {
      fieldLabel(label)
      Text(value?.nilIfEmpty ?? "")
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading).textSelection(.enabled)
    }.font(display.font)
  }

  private var informationFields: [BookField] {
    [.title, .subtitle, .originalTitle, .originalLanguage, .authors, .translators, .publisher, .publicationDate,
      .isbn, .edition, .pageCount, .language].filter(showsMetadataField)
  }
  private func showsMetadataField(_ field: BookField) -> Bool {
    let allowed = BookMetadataLayout.allows(field, type: book.bookType)
    // Original-work drafts remain recoverable without exposing translation-only
    // fields on an original edition after changing its type.
    if field == .originalTitle || field == .originalLanguage { return allowed }
    return allowed || metadataEditing.draft(book.id, field)?.isDirty == true
  }
  @ViewBuilder private func metadataRow(_ field: BookField) -> some View {
    if field == .authors || field == .translators {
      ContributorListField(book: book, field: field)
    } else {
      HStack(alignment: .top, spacing: 10) {
        fieldLabel(field.label)
        if isReadOnly {
          Text(field.value(in: BookArchive(book: book, includeCover: false)))
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        } else if field == .publisher {
          PublisherMetadataField(book: book)
        } else {
          InlineBookMetadataField(book: book, field: field)
        }
      }.font(display.font)
    }
  }
  private func revealRequestedField() {
    guard let request = metadataEditing.focusRequest, request.bookID == book.id else { return }
    expandedPanels.insert(.info); activePanel = .info
  }

  private func fieldLabel(_ label: String) -> some View {
    Text(label).foregroundStyle(.secondary).frame(width: display.metadataLabelWidth, alignment: .trailing)
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(display.font.weight(.semibold))
  }

  private var commands: LibraryCommands { LibraryCommands(context: modelContext, undoManager: undoManager) }
  private func persist(_ change: (inout BookArchive) -> Void) {
    do { try commands.update([book], change: change) }
    catch { errorMessage = error.localizedDescription }
  }

  private func insertTag(_ name: String) {
    let key = MetadataNormalizer.normalizedName(name)
    guard !isReadOnly, !key.isEmpty else { return }
    let canonicalName = tags.first { MetadataNormalizer.normalizedName($0.name) == key }?.name ?? name
    do { try commands.setTag(canonicalName, included: true, book: book); dismissTagInput() }
    catch { errorMessage = error.localizedDescription }
  }

}

enum InspectorPanel: String, CaseIterable, Identifiable, Codable {
  case info = "信息"
  case notes = "笔记"
  case collections = "书库与书单"
  case tags = "标签"
  var id: String { rawValue }
  var systemImage: String {
    switch self {
    case .info: "info.circle"
    case .notes: "note.text"
    case .collections: "books.vertical"
    case .tags: "tag"
    }
  }
}

/// Each click has its own identity, so clicking the active section scrolls back to it.
struct InspectorNavigationRequest: Equatable {
  let id = UUID()
  let bookID: UUID
  let panel: InspectorPanel
}

/// Kept outside the inspector and its scroll views so the rail never disappears.
struct InspectorNavigationRail: View {
  static let width: CGFloat = 42
  let isPresented: Bool
  let activePanel: InspectorPanel?
  let availablePanels: Set<InspectorPanel>
  let onToggle: () -> Void
  let onSelect: (InspectorPanel) -> Void

  var body: some View {
    VStack(spacing: 8) {
      Button(action: onToggle) {
        Image(systemName: "sidebar.right")
          .font(.system(size: 17, weight: .regular))
          .frame(width: 36, height: 34).contentShape(Rectangle())
      }
      .buttonStyle(.plain).foregroundStyle(.secondary)
      .accessibilityLabel(isPresented ? "隐藏详情面板" : "显示详情面板")
      .help(isPresented ? "隐藏详情面板（⌥⌘I）" : "显示详情面板（⌥⌘I）")
      .keyboardShortcut("i", modifiers: [.command, .option])
      Divider().padding(.horizontal, 8)
      ForEach(InspectorPanel.allCases) { section in
        let enabled = availablePanels.contains(section)
        let selected = isPresented && enabled && activePanel == section
        Button { onSelect(section) } label: {
          Image(systemName: section.systemImage)
            .font(.system(size: 17, weight: .regular))
            .frame(width: 36, height: 34)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
              if selected { Rectangle().fill(Color.accentColor).frame(width: 2, height: 18) }
            }
        }
        .buttonStyle(.plain).disabled(!enabled).help(section.rawValue)
        .accessibilityLabel("前往" + section.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 12).frame(width: Self.width)
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain).accessibilityLabel("详情导航")
  }
}

private extension String { var nilIfEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self } }

