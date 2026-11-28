import AppKit
import SwiftData
import SwiftUI

enum AttachmentFileAction {
  case renameAndMove, rename, move

  var title: String {
    switch self {
    case .renameAndMove: L10n.tr("重命名并移动附件")
    case .rename: L10n.tr("重命名附件")
    case .move: L10n.tr("移动附件")
    }
  }

  var renames: Bool { self != .move }
  var moves: Bool { self != .rename }
}

struct AttachmentActionRequest: Identifiable {
  let id = UUID()
  let book: Book
  let action: AttachmentFileAction
  let files: [AttachmentItem]
}

struct AttachmentManagementMenu: View {
  let commands: BookAttachmentCommands
  let onAction: (AttachmentActionRequest) -> Void
  let onError: (String) -> Void
  let onAdded: () -> Void

  var body: some View {
    Menu(L10n.tr("附件管理")) {
      Button(L10n.tr("添加新文件")) {
        chooseBookAttachmentFiles(commands, linked: false, onError: onError, onAdded: onAdded)
      }
      let files = fileAttachments
      actionButton(.renameAndMove, files: files)
      Divider()
      actionButton(.rename, files: files)
      actionButton(.move, files: files)
    }
  }

  private var fileAttachments: [AttachmentItem] {
    guard let store = try? BookAttachmentStore(context: commands.context) else { return [] }
    return (commands.book.attachmentIDs ?? []).compactMap { id in
      guard let item = try? store.item(id) else { return nil }
      if case .web = item.kind { return nil }
      return item
    }
  }

  private func actionButton(_ action: AttachmentFileAction, files: [AttachmentItem]) -> some View {
    Button(action.title) {
      onAction(AttachmentActionRequest(book: commands.book, action: action, files: files))
    }.disabled(files.isEmpty)
  }
}

struct AttachmentFileActionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  let request: AttachmentActionRequest
  @State private var selectedID: UUID?
  @State private var sourcePath: String?
  @State private var stem = ""
  @State private var destination: LibraryDirectoryReference?
  @State private var errorMessage: String?

  private var item: AttachmentItem? { request.files.first { $0.id == selectedID } }
  private var filename: String? {
    guard let item else { return nil }
    return request.action.renames ? try? AttachmentNaming.filename(stem: stem, original: item.name) : item.name
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(request.action.title).font(.title2.weight(.semibold))
      if request.files.count > 1 {
        Picker(L10n.tr("附件"), selection: $selectedID) {
          ForEach(request.files) { file in Text(verbatim: file.name).tag(Optional(file.id)) }
        }
        if let sourcePath { Text(verbatim: sourcePath).font(.caption).textSelection(.enabled) }
      } else if let item { Text(verbatim: item.name).textSelection(.enabled) }
      if request.action.renames {
        TextField(L10n.tr("新文件名（保留扩展名）"), text: $stem)
        if let filename { Text(verbatim: filename).foregroundStyle(.secondary).textSelection(.enabled) }
      }
      if request.action.moves {
        HStack {
          Text(L10n.tr("目标文件夹"))
          if let destination {
            Text(verbatim: destination.path).lineLimit(2).truncationMode(.middle).help(destination.path)
          }
          Spacer()
          Button(L10n.tr("选择目录"), action: chooseDestination)
        }
      }
      if item?.kind == .linkedFile {
        Text(L10n.tr("此操作会更改磁盘上的原文件。")).foregroundStyle(.secondary)
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Spacer()
        Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(request.action.title, action: apply)
          .keyboardShortcut(.defaultAction)
          .disabled(filename == nil || (request.action.moves && destination == nil))
      }
    }
    .padding(20).frame(width: 500)
    .onAppear {
      selectedID = request.files.first?.id
      if request.action.moves {
        do {
          if var folder = try BookAttachmentStore(context: context).folderPreferences.reference() {
            folder.path = (try? AttachmentFolderPreferences.withDirectory(folder) { $0.path }) ?? folder.path
            destination = folder
          }
        }
        catch { errorMessage = error.localizedDescription }
      }
      if request.action.renames {
        do { stem = try AttachmentNaming.stem(book: BookArchive(book: request.book), pattern: AttachmentRenameRule.load().pattern) }
        catch { errorMessage = error.localizedDescription }
      }
    }
    .onChange(of: selectedID) { _, id in
      guard request.files.count > 1, let id else { return }
      sourcePath = try? BookAttachmentStore(context: context).withFile(id) { $0.path }
    }
  }

  private func chooseDestination() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = L10n.tr("选择目录")
    if let destination { panel.directoryURL = URL(fileURLWithPath: destination.path, isDirectory: true) }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      destination = try BookAttachmentStore(context: context).folderPreferences.reference(for: url)
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func apply() {
    guard let item, filename != nil else { return }
    do {
      var grant: URL?
      if item.kind == .linkedFile {
        let parent = try BookAttachmentStore(context: context).withFile(item.id) { $0.deletingLastPathComponent() }
        guard let authorized = chooseAttachmentDirectory(parent, moving: request.action.moves) else { return }
        grant = authorized
      }
      try BookAttachmentCommands(book: request.book, context: context).organize(item,
        stem: request.action.renames ? stem : nil, destination: destination, grantedParent: grant)
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
}
