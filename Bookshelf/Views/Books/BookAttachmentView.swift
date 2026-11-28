import AppKit
import SwiftData
import SwiftUI

struct AddAttachmentMenu: View {
  let commands: BookAttachmentCommands
  let onWebLink: () -> Void
  let onFileError: (String) -> Void

  var body: some View {
    Menu(L10n.tr("添加附件")) {
      Button(L10n.tr("文件")) { chooseFiles(linked: false) }
      Button(L10n.tr("链接文件")) { chooseFiles(linked: true) }
      Button(L10n.tr("网页链接"), action: onWebLink)
    }
  }

  private func chooseFiles(linked: Bool) {
    let panel = NSOpenPanel()
    panel.title = linked ? L10n.tr("链接文件") : L10n.tr("添加附件")
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    do {
      let result = try commands.add(panel.urls, linked: linked, rule: .load(), authorize: chooseAttachmentDirectory)
      if result.skipped > 0 { onFileError(L10n.tr("链接文件已添加。") + result.message) }
    } catch { onFileError(error.localizedDescription) }
  }
}

struct WebAttachmentEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  let book: Book
  let item: AttachmentItem?
  @State private var address: String
  @State private var title: String
  @State private var errorMessage: String?

  init(book: Book, item: AttachmentItem? = nil) {
    self.book = book
    self.item = item
    if case let .web(url) = item?.kind {
      _address = State(initialValue: url.absoluteString)
      _title = State(initialValue: item?.name == url.absoluteString ? "" : item?.name ?? "")
    } else {
      _address = State(initialValue: "")
      _title = State(initialValue: "")
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(item == nil ? L10n.tr("添加网页链接") : L10n.tr("编辑网页链接")).font(.headline)
      Grid(alignment: .leading) {
        GridRow {
          Text(L10n.tr("网址"))
          TextField("https://…", text: $address).accessibilityLabel(L10n.tr("网址"))
        }
        GridRow {
          Text(L10n.tr("标题"))
          TextField(L10n.tr("可选"), text: $title).accessibilityLabel(L10n.tr("标题"))
        }
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(item == nil ? L10n.tr("添加网页链接") : L10n.tr("保存")) { save() }
          .keyboardShortcut(.defaultAction).disabled(BookAttachmentStore.webURL(address) == nil)
      }
    }.padding(20).frame(width: 440)
  }

  private func save() {
    do {
      if let item {
        guard book.modelContext === context, book.deletedAt == nil, book.attachmentIDs?.contains(item.id) == true
        else { throw LibraryOperationError.invalidSelection }
        try BookAttachmentStore(context: context).updateWebLink(item.id, address: address, title: title)
      } else {
        try BookAttachmentCommands(book: book, context: context).addWebLink(address: address, title: title)
      }
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
}

struct BookAttachmentView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @AppStorage(AttachmentNaming.preference) private var pattern = AttachmentNaming.defaultPattern
  let book: Book
  var initialAttachmentID: UUID? = nil
  @State private var rows: [AttachmentItem] = []
  @State private var selectedAttachmentID: UUID?
  @State private var revealedInitialAttachment = false
  @State private var errorMessage: String?
  @State private var renaming: AttachmentItem?
  @State private var removing: AttachmentItem?
  @State private var proposedStem = ""
  @State private var editingLink: AttachmentItem?
  @State private var showsWebEditor = false
  @State private var isDropTarget = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading) {
          Text(L10n.tr("附件")).font(.title2)
          Text(book.title).lineLimit(1).foregroundStyle(.secondary)
        }
        Spacer()
        if book.deletedAt == nil {
          AddAttachmentMenu(commands: BookAttachmentCommands(book: book, context: context),
            onWebLink: { editingLink = nil; showsWebEditor = true }, onFileError: { errorMessage = $0 })
            .fixedSize()
        }
      }
      if book.deletedAt == nil {
        attachmentList
          .dropDestination(for: DroppedAttachmentFile.self) { files, _ in
            do {
              try BookAttachmentCommands(book: book, context: context).add(files.map(\.url), linked: false, rule: .load())
              errorMessage = nil
              return true
            } catch { errorMessage = error.localizedDescription; return false }
          } isTargeted: { isDropTarget = $0 }
          .overlay {
            if isDropTarget {
              RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
            }
          }
      } else {
        attachmentList
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
      HStack { Spacer(); Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction) }
    }.padding(20).frame(minWidth: 510, idealWidth: 590, minHeight: 320)
      .onAppear { reload() }
      .onChange(of: book.attachmentIDs) { _, _ in reload() }
      .onReceive(NotificationCenter.default.publisher(for: .bookAttachmentFilesDidChange)) { change in
        if let id = change.object as? UUID, book.attachmentIDs?.contains(id) == true { reload() }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
      .sheet(isPresented: $showsWebEditor, onDismiss: reload) { WebAttachmentEditor(book: book, item: editingLink) }
      .sheet(item: $renaming) { item in
        VStack(alignment: .leading, spacing: 14) {
          Text(item.kind == .linkedFile ? L10n.tr("重命名磁盘上的原文件") : L10n.tr("重命名附件")).font(.headline)
          Text(item.name).foregroundStyle(.secondary)
          TextField(L10n.tr("新文件名（保留扩展名）"), text: $proposedStem)
          if let name = try? AttachmentNaming.filename(stem: proposedStem, original: item.name) {
            Text(name).font(.caption).foregroundStyle(.secondary)
          }
          HStack {
            Button(L10n.tr("使用书籍信息")) { perform { proposedStem = try AttachmentNaming.stem(book: BookArchive(book: book), pattern: pattern) } }
            Spacer()
            Button(L10n.tr("取消")) { renaming = nil }.keyboardShortcut(.cancelAction)
            Button(L10n.tr("重命名")) { rename(item) }.keyboardShortcut(.defaultAction)
              .disabled((try? AttachmentNaming.filename(stem: proposedStem, original: item.name)) == nil)
          }
        }.padding(20).frame(minWidth: 430)
      }
      .alert(L10n.tr("移除附件？"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
        Button(L10n.tr("移除"), role: .destructive) {
          perform { try BookAttachmentCommands(book: book, context: context).detach(item.id) }; reload()
        }
        Button(L10n.tr("取消"), role: .cancel) {}
      } message: { item in
        switch item.kind {
        case .web: Text(item.name)
        case .linkedFile, .externalFile: Text(L10n.tr("移除书籍中的链接，原文件将保留。"))
        case .stored: Text(L10n.tr("此操作会移除书籍中的附件及其未被其他书籍引用的副本。"))
        }
      }
  }

  private var attachmentList: some View {
    ScrollViewReader { scroll in
      List(rows, selection: $selectedAttachmentID) { item in
        HStack {
          Image(systemName: item.kind.symbolName).accessibilityLabel(item.kind.label).foregroundStyle(.secondary)
          Button(item.name) { open(item) }.buttonStyle(.plain).lineLimit(2)
            .help({ if case let .web(url) = item.kind { return url.absoluteString }; return L10n.tr("打开附件") }())
          Spacer()
          Menu { actions(item) } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L10n.tr("附件操作"))
        }
        .contextMenu { actions(item) }
        .tag(item.id).id(item.id)
      }
      .onChange(of: rows.map(\.id), initial: true) { _, ids in
        guard !revealedInitialAttachment, let initialAttachmentID, ids.contains(initialAttachmentID) else { return }
        revealedInitialAttachment = true
        selectedAttachmentID = initialAttachmentID
        scroll.scrollTo(initialAttachmentID, anchor: .center)
      }
    }.overlay {
      if rows.isEmpty && errorMessage == nil {
        Text(book.deletedAt == nil ? L10n.tr("将文件拖到此处以添加附件") : L10n.tr("暂无附件"))
          .foregroundStyle(.secondary).allowsHitTesting(false)
      }
    }
  }

  @ViewBuilder private func actions(_ item: AttachmentItem) -> some View {
    Button(L10n.tr("打开附件")) { open(item) }
    ShowAttachmentInFinderButton(item: item, context: context, errorMessage: $errorMessage)
    if case .web = item.kind {
      if book.deletedAt == nil {
        Button(L10n.tr("编辑网页链接…")) { editingLink = item; showsWebEditor = true }
      }
    } else { fileActions(item) }
    if book.deletedAt == nil {
      Divider()
      Button(L10n.tr("移除附件…"), role: .destructive) { removing = item }
    }
  }

  @ViewBuilder private func fileActions(_ item: AttachmentItem) -> some View {
    if book.deletedAt == nil {
      Divider()
      Button(L10n.tr("重命名附件…")) { proposedStem = (item.name as NSString).deletingPathExtension; renaming = item }
      Button(L10n.tr("按书籍信息重命名…")) { perform {
        proposedStem = try AttachmentNaming.stem(book: BookArchive(book: book), pattern: pattern); renaming = item
      } }
      if item.kind == .linkedFile {
        Button(L10n.tr("重新定位…")) {
          let panel = NSOpenPanel()
          guard panel.runModal() == .OK, let url = panel.url else { return }
          perform {
            guard book.deletedAt == nil, book.attachmentIDs?.contains(item.id) == true else { throw LibraryOperationError.invalidSelection }
            try BookAttachmentStore(context: context).relink(item.id, to: url)
          }; reload()
        }
      }
    }
  }

  private func rename(_ item: AttachmentItem) {
    renaming = nil
    perform {
      guard book.deletedAt == nil, book.attachmentIDs?.contains(item.id) == true else { throw LibraryOperationError.invalidSelection }
      let store = try BookAttachmentStore(context: context)
      var parent: URL?
      if item.kind == .linkedFile {
        let folder = try store.withFile(item.id) { $0.deletingLastPathComponent() }
        guard let granted = chooseAttachmentDirectory(folder) else { return }
        parent = granted
      }
      try store.rename(item.id, stem: proposedStem, grantedParent: parent)
    }
    reload()
  }

  private func open(_ item: AttachmentItem) {
    perform { try openBookAttachment(item.id, context: context) }
  }

  private func reload() {
    do {
      let store = try BookAttachmentStore(context: context)
      rows = (book.attachmentIDs ?? []).map { id in
        do { return try store.item(id) }
        catch {
          errorMessage = error.localizedDescription
          return AttachmentItem(id: id, name: L10n.tr("找不到附件"), kind: .stored)
        }
      }
    } catch { errorMessage = error.localizedDescription }
  }

  private func perform(_ action: () throws -> Void) {
    errorMessage = nil
    do { try action() } catch { errorMessage = error.localizedDescription }
  }
}

struct ShowAttachmentInFinderButton: View {
  let item: AttachmentItem
  let context: ModelContext
  @Binding var errorMessage: String?

  var body: some View {
    switch item.kind {
    case .stored, .linkedFile, .externalFile:
      Button(L10n.tr("在访达中显示")) {
        do {
          try BookAttachmentStore(context: context).withFile(item.id) { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
          errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
      }
    case .web:
      EmptyView()
    }
  }
}

@MainActor
func openBookAttachment(_ id: UUID, context: ModelContext) throws {
  let store = try BookAttachmentStore(context: context)
  if case let .web(url) = try store.item(id).kind {
    guard NSWorkspace.shared.open(url) else { throw AttachmentError.cannotOpenWebLink }
  } else {
    try store.withFile(id) { url in
      guard NSWorkspace.shared.open(url) else { throw AttachmentError.unavailable }
    }
  }
}

struct BookAttachmentInspector: View {
  @Environment(\.modelContext) private var context
  let book: Book
  let attachmentID: UUID
  @State private var item: AttachmentItem?
  @State private var errorMessage: String?
  @State private var managesAttachments = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let item {
        Label(item.kind.label, systemImage: item.kind.symbolName).foregroundStyle(.secondary)
        Text(item.name).font(.title3.bold()).textSelection(.enabled)
      }
      Text(book.title).foregroundStyle(.secondary)
      Divider()
      if item != nil {
        Button(L10n.tr("打开附件")) {
          do { try openBookAttachment(attachmentID, context: context); errorMessage = nil }
          catch { errorMessage = error.localizedDescription }
        }
      }
      Button(L10n.tr("管理附件…")) { managesAttachments = true }
      if let errorMessage { Text(errorMessage).foregroundStyle(.secondary).textSelection(.enabled) }
      Spacer()
    }
    .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear(perform: reload)
    .onReceive(NotificationCenter.default.publisher(for: .bookAttachmentFilesDidChange)) { change in
      if change.object as? UUID == attachmentID { reload() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    .sheet(isPresented: $managesAttachments) { BookAttachmentView(book: book, initialAttachmentID: attachmentID) }
  }

  private func reload() {
    do { item = try BookAttachmentStore(context: context).item(attachmentID); errorMessage = nil }
    catch { item = nil; errorMessage = error.localizedDescription }
  }
}

@MainActor
func chooseAttachmentDirectory(_ folder: URL) -> URL? {
  let panel = NSOpenPanel()
  panel.canChooseFiles = false
  panel.canChooseDirectories = true
  panel.directoryURL = folder
  panel.message = L10n.tr("请选择原文件所在的文件夹，以允许重命名。")
  return panel.runModal() == .OK ? panel.url : nil
}
