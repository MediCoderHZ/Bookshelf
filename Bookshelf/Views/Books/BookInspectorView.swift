import AppKit
import SwiftData
import SwiftUI

struct BookInspectorView: View {
  @Environment(\.libraryDisplay) private var display
  @Environment(BookMetadataEditingSession.self) private var metadataEditing
  @Environment(\.modelContext) private var modelContext
  @Environment(\.noteNavigation) private var noteNavigation
  @Environment(\.libraryUndoManager) private var undoManager
  @Query(sort: \BookCollection.name) private var storedCollections: [BookCollection]
  private var collections: [BookCollection] { storedCollections.filter { !$0.isSmart } }
  @Query(sort: \Tag.name) private var tags: [Tag]
  @Query(sort: \LibraryNote.createdAt) private var storedNotes: [LibraryNote]
  let book: Book
  var onRevealLocation: ((UUID?) -> Void)? = nil
  private var isReadOnly: Bool { book.deletedAt != nil }
  @Binding var activePanel: InspectorPanel
  @Binding var expandedPanels: Set<InspectorPanel>
  var navigationRequest: InspectorNavigationRequest? = nil
  let readingPositions: InspectorReadingPositionStore
  @State private var newTag = ""
  @State private var showsTagInput = false
  @State private var tagFocusToken: UUID?
  @State private var errorMessage: String?
  @Namespace private var scrollCoordinateSpace
  @State private var scrollTracking = InspectorScrollTracking()
  @State private var hasRestoredPosition = false
  @State private var isOnScreen = true
  @State private var skipsPositionRestoration = false
  @State private var positionRestoration: InspectorPositionRestoration?
  @State private var positionRestorationID: UUID?

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
                .background {
                  GeometryReader { geometry in
                    Color.clear.preference(key: InspectorScrollGeometryKey.self,
                      value: InspectorScrollGeometry(sections: [section: geometry.frame(in: .named(scrollCoordinateSpace))]))
                  }
                }
              Divider()
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
            .id(InspectorScrollAnchor.content)
            .background {
              GeometryReader { geometry in
                Color.clear.preference(key: InspectorScrollGeometryKey.self,
                  value: InspectorScrollGeometry(content: geometry.frame(in: .named(scrollCoordinateSpace)),
                    expandedPanels: expandedPanels))
              }
            }
        }
        .coordinateSpace(name: scrollCoordinateSpace)
        .background {
          GeometryReader { geometry in
            Color.clear.preference(key: InspectorScrollGeometryKey.self,
              value: InspectorScrollGeometry(viewportHeight: geometry.size.height))
          }
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(InspectorScrollGeometryKey.self) { geometry in
          observeScroll(geometry, proxy: proxy)
        }
        .task(id: navigationRequest) {
          guard let request = navigationRequest, request.bookID == book.id,
            readingPositions.consumeNavigation(request.id) else { return }
          cancelPositionRestoration()
          hasRestoredPosition = true
          scrollTracking.beginNavigation(request.id)
          activePanel = request.panel
          expandedPanels.insert(request.panel)
          // Wait for an expanded section (or a reopened inspector) to enter layout.
          await Task.yield()
          guard !Task.isCancelled else { return }
          withAnimation(.easeInOut(duration: 0.18), completionCriteria: .removed) {
            proxy.scrollTo(request.panel, anchor: .top)
          } completion: {
            guard isOnScreen, scrollTracking.finishNavigation(request.id) else { return }
            rememberPosition()
          }
        }
    }
    .font(display.font)
    .onChange(of: metadataEditing.focusRequest?.token) { _, _ in revealRequestedField() }
    .onAppear {
      isOnScreen = true
      revealRequestedField()
    }
    .onDisappear {
      isOnScreen = false
      readingPositions.flush()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
      readingPositions.flush()
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

  private func observeScroll(_ geometry: InspectorScrollGeometry, proxy: ScrollViewProxy) {
    guard isOnScreen, geometry.isValid else { return }
    if !hasRestoredPosition && positionRestoration == nil {
      // A new explicit navigation takes priority; an old request must not replay on return.
      if let request = navigationRequest, request.bookID == book.id,
        !readingPositions.hasHandledNavigation(request.id) { return }
      if !skipsPositionRestoration, let position = readingPositions[book.id] {
        // Wait for the saved expansion state to be reflected in actual layout measurements.
        guard geometry.expandedPanels == position.expandedPanels else {
          expandedPanels = position.expandedPanels
          return
        }
        positionRestoration = InspectorPositionRestoration(position: position)
        activePanel = position.activePanel
      } else {
        hasRestoredPosition = true
      }
    }
    if var restoration = positionRestoration {
      let update = restoration.update(geometry)
      positionRestoration = restoration
      switch update {
      case .scroll(let offset):
        let id = positionRestorationID ?? UUID()
        positionRestorationID = id
        scrollTracking.beginNavigation(id)
        _ = scrollTracking.update(geometry, activePanel: activePanel)
        // Equal fractional points align at fraction * (content - viewport).
        let fraction = offset / max(1, geometry.maximumOffset)
        withAnimation(nil) {
          proxy.scrollTo(InspectorScrollAnchor.content, anchor: UnitPoint(x: 0, y: fraction))
        }
        return
      case .settled(let panel):
        _ = scrollTracking.update(geometry, activePanel: activePanel)
        if let id = positionRestorationID { scrollTracking.finishNavigation(id) }
        positionRestorationID = nil
        hasRestoredPosition = true
        activePanel = panel
        rememberPosition()
        return
      case .userScrolled:
        cancelPositionRestoration()
      }
    }
    if let panel = scrollTracking.update(geometry, activePanel: activePanel), panel != activePanel {
      activePanel = panel
    }
    rememberPosition()
  }

  private func cancelPositionRestoration() {
    if let id = positionRestorationID { scrollTracking.finishNavigation(id) }
    positionRestorationID = nil
    positionRestoration = nil
  }

  private func rememberPosition() {
    guard isOnScreen, hasRestoredPosition, !scrollTracking.isNavigating,
      let position = InspectorReadingPosition(geometry: scrollTracking.geometry,
        activePanel: activePanel, expandedPanels: expandedPanels) else { return }
    readingPositions.remember(position, for: book.id)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: display.inspectorRowSpacing) {
      if isReadOnly {
        Text(book.title).font(display.font)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
      } else {
        InlineBookMetadataField(book: book, field: .title, isInspectorTitle: true)
      }
      if isReadOnly {
        Label("回收站 · 只读", systemImage: "trash").font(display.font).foregroundStyle(.secondary)
        if book.mergedIntoID != nil {
          Text("合并时保留的原记录。恢复副本不会回退主记录；回退整次合并请使用撤销。")
            .font(display.font).foregroundStyle(.secondary)
        }
      }
    }.padding(.horizontal, 14).padding(.vertical, display.inspectorSectionPadding)
      // Match the library toolbar for a single line, while allowing long titles to wrap.
      .frame(minHeight: 44, alignment: .leading)
  }

  private func inspectorSection(_ section: InspectorPanel) -> some View {
    let expanded = expandedPanels.contains(section)
    let count: Int? = switch section {
    case .notes: noteCount
    case .tags: assignedTags.count
    default: nil
    }
    return VStack(alignment: .leading, spacing: display.inspectorRowSpacing) {
      HStack(alignment: .center, spacing: display.inspectorHeaderSpacing) {
        Button { togglePanel(section) } label: {
          HStack(alignment: .center, spacing: display.inspectorHeaderLabelSpacing) {
            inspectorHeaderIcon(section.systemImage)
            Text(section.rawValue).font(display.font).lineLimit(1)
            if let count {
              Text(count, format: .number).font(display.font).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 0)
          }.foregroundStyle(.secondary).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(section.rawValue)
        .accessibilityValue((expanded ? "已展开" : "已折叠") +
          (count.map { "，\($0) " + (section == .notes ? "条笔记" : "个标签") } ?? ""))
        .help(expanded ? "折叠" + section.rawValue : "展开" + section.rawValue)
        Group {
          if section == .collections && !isReadOnly { membershipMenu }
          else if section == .notes && !isReadOnly {
            Button {
              cancelPositionRestoration()
              activePanel = .notes
              expandedPanels.insert(.notes)
              noteNavigation.create(book.id)
            } label: {
              inspectorHeaderIcon("plus")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
              .accessibilityLabel("新建书籍笔记").help("新建笔记")
          } else if section == .tags && !isReadOnly {
            Button {
              cancelPositionRestoration()
              activePanel = .tags
              expandedPanels.insert(.tags)
              showsTagInput = true
              tagFocusToken = UUID()
            } label: {
              inspectorHeaderIcon("plus")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
              .accessibilityLabel("添加标签").help("添加标签")
          } else {
            Color.clear.allowsHitTesting(false).accessibilityHidden(true)
          }
        }
        .frame(width: display.inspectorHeaderControlWidth, height: display.inspectorRowHeight)
        Button { togglePanel(section) } label: {
          inspectorHeaderIcon(expanded ? "chevron.up" : "chevron.down")
        }.buttonStyle(.plain).foregroundStyle(.secondary)
          .accessibilityLabel((expanded ? "折叠" : "展开") + section.rawValue)
      }.frame(minHeight: display.inspectorRowHeight)
      if expanded && (section != .notes || noteCount > 0) &&
        (section != .collections || !membershipIDs.isEmpty) &&
        (section != .tags || !assignedTags.isEmpty || (!isReadOnly && showsTagInput)) {
        switch section {
        case .info: information
        case .notes: notes
        case .collections: collectionLocations
        case .tags: tagDetails
        }
      }
    }.padding(.horizontal, 14).padding(.vertical, display.inspectorSectionPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func inspectorHeaderIcon(_ symbol: String) -> some View {
    LibraryIcon(systemName: symbol)
      .frame(width: display.inspectorHeaderControlWidth, height: display.inspectorRowHeight)
      .contentShape(Rectangle())
  }

  private func togglePanel(_ section: InspectorPanel) {
    cancelPositionRestoration()
    activePanel = section
    withAnimation(.easeInOut(duration: 0.18)) {
      if expandedPanels.contains(section) { expandedPanels.remove(section) }
      else { expandedPanels.insert(section) }
    }
  }

  private var information: some View {
    VStack(alignment: .leading, spacing: display.inspectorRowSpacing) {
      HStack(alignment: .top, spacing: 10) {
        fieldLabel("条目类型")
        if isReadOnly {
          Text(book.bookType?.title ?? "").frame(maxWidth: .infinity, alignment: .leading)
        } else {
          BookTypePicker(selection: Binding(get: { book.bookType }, set: { type in
            guard let type else { return }
            do {
              let expected = BookMetadataValue.read(.bookType, from: BookArchive(book: book))
              try BookMetadataCommands(context: modelContext, undoManager: undoManager)
                .save(bookID: book.id, field: .bookType, text: type.rawValue, expected: expected)
            } catch { errorMessage = error.localizedDescription }
          }), emptyLabel: "")
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }.font(display.font).frame(minHeight: display.inspectorRowHeight, alignment: .top)
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
    VStack(alignment: .leading, spacing: display.inspectorRowSpacing) {
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
    return VStack(alignment: .leading, spacing: display.inspectorRowSpacing) {
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
                  .accessibilityLabel("从文件夹移除：" + CollectionTree.path(location.id, in: records))
                  .help("从“\(location.record.name)”移除，书籍仍保留在书库中")
              }
            }
          } else {
            Label(location.record.name, systemImage: "folder")
              .foregroundStyle(.secondary).lineLimit(2)
              .help(CollectionTree.path(location.id, in: records))
          }
        }.frame(minHeight: display.inspectorRowHeight, alignment: .top)
          .padding(.leading, CGFloat(min(location.depth, 5)) * 18)
      }
    }.font(display.font).frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func locationLink(_ title: String, systemImage: String, collectionID: UUID) -> some View {
    if isReadOnly || onRevealLocation == nil {
      Label(title, systemImage: systemImage).lineLimit(2)
    } else {
      Button { onRevealLocation?(collectionID) } label: {
        Label(title, systemImage: systemImage).lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel("在左侧定位：" + title)
    }
  }

  private var membershipMenu: some View {
    Menu {
      if collections.isEmpty {
        Text("暂无普通文件夹，请先在左侧新建")
      }
      CollectionHierarchyMenuItems(nodes: CollectionTree.nodes(collectionRecords)) { record in
        Toggle(isOn: Binding(
          get: { membershipIDs.contains(record.id) },
          set: { included in
            guard let collection = collections.first(where: { $0.id == record.id }) else { return }
            setMembership(collection, included: included)
          }
        )) { Label(record.name, systemImage: "folder") }
      }
    } label: {
      inspectorHeaderIcon("plus")
    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
      .foregroundStyle(.secondary)
      .accessibilityLabel("添加到文件夹").help("选择文件夹加入；取消勾选可移除归属")
  }

  private func setMembership(_ collection: BookCollection, included: Bool) {
    guard !isReadOnly else { return }
    cancelPositionRestoration()
    do {
      try commands.setMembership([book], collection: collection, included: included)
      activePanel = .collections
      expandedPanels.insert(.collections)
    } catch { errorMessage = error.localizedDescription }
  }

  private var tagDetails: some View {
    VStack(alignment: .leading, spacing: display.inspectorRowSpacing) {
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
        }.frame(minHeight: display.inspectorRowHeight, alignment: .top)
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
        .frame(maxWidth: .infinity, minHeight: display.inspectorRowHeight, alignment: .topLeading).textSelection(.enabled)
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
          Text(field.value(in: BookArchive(book: book)))
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        } else if field == .publisher {
          PublisherMetadataField(book: book)
        } else {
          InlineBookMetadataField(book: book, field: field)
        }
      }.font(display.font).frame(minHeight: display.inspectorRowHeight, alignment: .top)
    }
  }
  private func revealRequestedField() {
    guard let request = metadataEditing.focusRequest, request.bookID == book.id else { return }
    cancelPositionRestoration()
    skipsPositionRestoration = true
    expandedPanels.insert(.info); activePanel = .info
  }

  private func fieldLabel(_ label: String) -> some View {
    Text(label).foregroundStyle(.secondary).frame(width: display.metadataLabelWidth, alignment: .trailing)
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(display.font)
  }

  private var commands: LibraryCommands { LibraryCommands(context: modelContext, undoManager: undoManager) }
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
  case collections = "文件夹"
  case tags = "标签"
  // Decode the old preference label so changing the UI terminology does not
  // reset the saved selection, folder expansion or inspector sections.
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    let normalized = ["书库与书单", "书库与文件夹"].contains(value) ? "文件夹" : value
    guard let panel = Self(rawValue: normalized) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown inspector panel")
    }
    self = panel
  }
  var id: String { rawValue }
  var systemImage: String {
    switch self {
    case .info: "info.circle"
    case .notes: "note.text"
    case .collections: "folder"
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

private enum InspectorScrollAnchor: Hashable { case content }

/// Measured in the inspector's own viewport, independent of the main library scroll view.
struct InspectorScrollGeometry: Equatable {
  var sections: [InspectorPanel: CGRect] = [:]
  var content: CGRect = .zero
  var viewportHeight: CGFloat = 0
  var expandedPanels: Set<InspectorPanel>?

  var isValid: Bool {
    viewportHeight.isFinite && viewportHeight > 0 && content.height.isFinite && content.height > 0 &&
      content.minY.isFinite && InspectorPanel.allCases.allSatisfy {
        guard let frame = sections[$0] else { return false }
        return frame.minY.isFinite && frame.height.isFinite && frame.height > 0
      }
  }
  var maximumOffset: CGFloat { max(0, content.height - viewportHeight) }
  var offset: CGFloat { min(maximumOffset, max(0, -content.minY)) }

  func hasSameLayout(as other: Self) -> Bool {
    guard abs(viewportHeight - other.viewportHeight) <= 0.5,
      abs(content.width - other.content.width) <= 0.5,
      abs(content.height - other.content.height) <= 0.5,
      expandedPanels == other.expandedPanels else { return false }
    return InspectorPanel.allCases.allSatisfy { panel in
      guard let frame = sections[panel], let previous = other.sections[panel] else { return false }
      return abs(frame.height - previous.height) <= 0.5 &&
        abs((frame.minY - content.minY) - (previous.minY - other.content.minY)) <= 0.5
    }
  }

  func isVisible(_ panel: InspectorPanel) -> Bool {
    guard let frame = sections[panel] else { return false }
    return frame.maxY > 0 && frame.minY < viewportHeight
  }

  var visiblePanel: InspectorPanel {
    // Rubber-banding and a short inspector must not select the last section at the top.
    if offset <= 1 { return .info }
    if maximumOffset > 1 && maximumOffset - offset <= 1 { return .tags }
    let activationLine = min(24, viewportHeight / 4)
    let visible = InspectorPanel.allCases.filter(isVisible)
    return visible.last { (sections[$0]?.minY ?? .infinity) <= activationLine }
      ?? visible.first ?? .info
  }
}

private struct InspectorScrollGeometryKey: PreferenceKey {
  static var defaultValue: InspectorScrollGeometry { InspectorScrollGeometry() }
  static func reduce(value: inout InspectorScrollGeometry, nextValue: () -> InspectorScrollGeometry) {
    let next = nextValue()
    value.sections.merge(next.sections) { _, new in new }
    if next.content.height > 0 { value.content = next.content }
    if next.viewportHeight > 0 { value.viewportHeight = next.viewportHeight }
    if let expanded = next.expandedPanels { value.expandedPanels = expanded }
  }
}

struct InspectorScrollTracking {
  private(set) var geometry = InspectorScrollGeometry()
  private var navigationID: UUID?
  var isNavigating: Bool { navigationID != nil }

  mutating func beginNavigation(_ id: UUID) { navigationID = id }
  @discardableResult mutating func finishNavigation(_ id: UUID) -> Bool {
    guard navigationID == id else { return false }
    navigationID = nil
    return true
  }

  mutating func update(_ next: InspectorScrollGeometry, activePanel: InspectorPanel) -> InspectorPanel? {
    guard next.isValid else { return nil }
    let previous = geometry
    geometry = next
    // Record animated positions without highlighting every section passed on the way.
    guard navigationID == nil else { return nil }
    guard previous.isValid else { return next.visiblePanel }
    let resized = previous.viewportHeight != next.viewportHeight || previous.content.height != next.content.height
    // Expansion, editing and resizing preserve an explicitly selected section while visible.
    if resized && next.isVisible(activePanel) { return nil }
    if abs(next.offset - previous.offset) > 0.01 || !next.isVisible(activePanel) {
      return next.visiblePanel
    }
    return nil
  }
}

/// Kept outside the inspector and its scroll views so the rail never disappears.
struct InspectorNavigationRail: View {
  @Environment(\.libraryDisplay) private var display
  static let width: CGFloat = 42
  let isPresented: Bool
  let activePanel: InspectorPanel?
  let availablePanels: Set<InspectorPanel>
  let onToggle: () -> Void
  let onSelect: (InspectorPanel) -> Void

  var body: some View {
    VStack(spacing: display.inspectorHeaderSpacing) {
      Button(action: onToggle) {
        LibraryIcon(systemName: "sidebar.right")
      }
      .buttonStyle(InspectorNavigationButtonStyle())
      .accessibilityLabel(isPresented ? "隐藏详情面板" : "显示详情面板")
      .help(isPresented ? "隐藏详情面板（⌥⌘I）" : "显示详情面板（⌥⌘I）")
      .keyboardShortcut("i", modifiers: [.command, .option])
      Divider().padding(.horizontal, 8)
      ForEach(InspectorPanel.allCases) { section in
        let enabled = availablePanels.contains(section)
        let selected = isPresented && enabled && activePanel == section
        Button { onSelect(section) } label: {
          LibraryIcon(systemName: section.systemImage)
        }
        .buttonStyle(InspectorNavigationButtonStyle(isSelected: selected))
        .disabled(!enabled).help(section.rawValue)
        .accessibilityLabel("前往" + section.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
      Spacer(minLength: 0)
    }
    .padding(.top, display.inspectorSectionPadding).frame(width: Self.width)
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain).accessibilityLabel("详情导航")
  }
}

private struct InspectorNavigationButtonStyle: ButtonStyle {
  @Environment(\.libraryDisplay) private var display
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false
  var isSelected = false

  func makeBody(configuration: Configuration) -> some View {
    let selected = isEnabled && isSelected
    let highlighted = isEnabled && (isHovered || configuration.isPressed)
    configuration.label
      .foregroundStyle(selected ? Color.accentColor : Color.secondary)
      .frame(width: InspectorNavigationRail.width, height: display.inspectorNavigationRowHeight)
      .background {
        RoundedRectangle(cornerRadius: 4)
          .fill(selected ? Color.accentColor.opacity(highlighted ? 0.16 : 0.10)
            : Color.primary.opacity(highlighted ? 0.06 : 0))
          .padding(.horizontal, 4)
      }
      .overlay(alignment: .leading) {
        if selected {
          Capsule().fill(Color.accentColor)
            .frame(width: 2, height: display.inspectorRowHeight)
        }
      }
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
  }
}

private extension String { var nilIfEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self } }

