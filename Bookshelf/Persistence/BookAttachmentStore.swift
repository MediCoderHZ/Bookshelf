import CryptoKit
import Foundation
import SwiftData

/// External file bookmarks stay on this Mac. Web links travel with the library.
struct PortableAttachment: Codable, Equatable {
  var id: UUID
  var name: String
  var contents: Data?
  var webURL: String?

  func validate() throws {
    if let webURL {
      guard contents == nil else { throw LibraryBackupError.invalidDocument }
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        BookAttachmentStore.webURL(webURL)?.absoluteString == webURL else { throw AttachmentError.invalidWebURL }
    } else if !AttachmentNaming.validName(name) { throw AttachmentError.invalidName }
  }
}

struct AttachmentItem: Identifiable, Equatable {
  enum Kind: Equatable { case stored, linkedFile, web(URL) }
  let id: UUID
  let name: String
  let kind: Kind
}

extension Notification.Name {
  /// A file or link changed on disk without changing the book's attachment IDs.
  static let bookAttachmentFilesDidChange = Notification.Name("Bookshelf.bookAttachmentFilesDidChange")
}

private struct AttachmentLink: Codable {
  var name: String
  var bookmark: Data?
  var webURL: String?

  static func web(address: String, title: String) throws -> Self {
    guard let url = BookAttachmentStore.webURL(address) else { throw AttachmentError.invalidWebURL }
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return Self(name: title.isEmpty ? url.absoluteString : title, webURL: url.absoluteString)
  }
}

enum AttachmentError: LocalizedError {
  case invalidFile, unavailable, invalidName, duplicate, invalidTemplate, invalidWebURL, cannotOpenWebLink
  var errorDescription: String? {
    switch self {
    case .invalidFile: L10n.tr("请选择普通文件。")
    case .unavailable: L10n.tr("附件不可用。链接文件可通过“重新定位…”恢复访问。")
    case .invalidName: L10n.tr("请输入有效的文件名，不含路径分隔符。")
    case .duplicate: L10n.tr("已存在同名文件，请选择其他名称。")
    case .invalidTemplate: L10n.tr("命名格式须包含受支持的字段。")
    case .invalidWebURL: L10n.tr("请输入有效的 HTTP 或 HTTPS 网址。")
    case .cannotOpenWebLink: L10n.tr("无法打开网页链接。")
    }
  }
}

struct BookAttachmentStore {
  let root: URL
  private let fm = FileManager.default

  init(database: URL) {
    root = database.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)
  }

  @MainActor init(context: ModelContext) throws {
    guard let config = context.container.configurations.first, !config.isStoredInMemoryOnly else {
      throw AttachmentError.unavailable
    }
    self.init(database: config.url)
  }

  private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
  private func marker(_ id: UUID) -> URL { folder(id).appendingPathComponent("link.json") }

  static func webURL(_ address: String) -> URL? {
    let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
      let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
      let host = url.host(), !host.isEmpty, url.user() == nil, url.password() == nil else { return nil }
    return url
  }

  static func requireFile(_ url: URL) throws {
    guard url.isFileURL else { throw AttachmentError.invalidFile }
    let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
    guard value.isRegularFile == true, value.isSymbolicLink != true, value.isPackage != true else { throw AttachmentError.invalidFile }
  }
  static func requireDirectory(_ url: URL) throws {
    let value = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard value.isDirectory == true, value.isSymbolicLink != true else { throw AttachmentError.unavailable }
  }

  private func link(_ id: UUID) throws -> AttachmentLink? {
    try Self.requireDirectory(root)
    try Self.requireDirectory(folder(id))
    let url = marker(id)
    guard fm.fileExists(atPath: url.path) else { return nil }
    try Self.requireFile(url)
    let record = try JSONDecoder().decode(AttachmentLink.self, from: Data(contentsOf: url))
    if let address = record.webURL {
      guard record.bookmark == nil, Self.webURL(address) != nil else { throw AttachmentError.invalidWebURL }
    }
    return record
  }

  private func managedFile(_ id: UUID) throws -> URL {
    let dir = folder(id).appendingPathComponent("file", isDirectory: true)
    try Self.requireDirectory(dir)
    let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != ".DS_Store" }
    guard files.count == 1, let file = files.first else { throw AttachmentError.unavailable }
    try Self.requireFile(file)
    return file
  }

  func item(_ id: UUID) throws -> AttachmentItem {
    if let link = try link(id) {
      if let address = link.webURL, let url = Self.webURL(address) {
        return AttachmentItem(id: id, name: link.name, kind: .web(url))
      }
      return AttachmentItem(id: id, name: link.name, kind: .linkedFile)
    }
    return AttachmentItem(id: id, name: try managedFile(id).lastPathComponent, kind: .stored)
  }

  private func writeLink(_ link: AttachmentLink, at url: URL) throws {
    try JSONEncoder().encode(link).write(to: url, options: .atomic)
  }
  private func bookmark(_ url: URL) throws -> AttachmentLink {
    try Self.requireFile(url)
    guard AttachmentNaming.validName(url.lastPathComponent) else { throw AttachmentError.invalidName }
    return AttachmentLink(name: url.lastPathComponent, bookmark: try url.bookmarkData(options: .withSecurityScope,
      includingResourceValuesForKeys: nil, relativeTo: nil))
  }

  func withFile<T>(_ id: UUID, perform: (URL) throws -> T) throws -> T {
    guard let link = try link(id) else { return try perform(managedFile(id)) }
    guard let bookmark = link.bookmark else { throw AttachmentError.unavailable }
    var stale = false
    let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    try Self.requireFile(url)
    if stale || link.name != url.lastPathComponent { try writeLink(self.bookmark(url), at: marker(id)) }
    return try perform(url)
  }

  private func create(_ id: UUID, write: (URL) throws -> Void) throws {
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try Self.requireDirectory(root)
    let staging = root.appendingPathComponent(".pending-" + UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: staging) }
    try write(staging)
    try fm.moveItem(at: staging, to: folder(id))
  }

  func add(_ url: URL, linked: Bool, name: String) throws -> UUID {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    try Self.requireFile(url)
    guard !linked || AttachmentNaming.validName(url.lastPathComponent) else { throw AttachmentError.invalidName }
    let id = UUID()
    try create(id) { dir in
      if linked { try writeLink(bookmark(url), at: dir.appendingPathComponent("link.json")) }
      else {
        guard AttachmentNaming.validName(name) else { throw AttachmentError.invalidName }
        let files = dir.appendingPathComponent("file")
        try fm.createDirectory(at: files, withIntermediateDirectories: false)
        try fm.copyItem(at: url, to: files.appendingPathComponent(name))
      }
    }
    return id
  }

  func addWebLink(address: String, title: String) throws -> UUID {
    let link = try AttachmentLink.web(address: address, title: title)
    let id = UUID()
    try create(id) { try writeLink(link, at: $0.appendingPathComponent("link.json")) }
    return id
  }

  func updateWebLink(_ id: UUID, address: String, title: String) throws {
    guard try link(id)?.webURL != nil else { throw AttachmentError.unavailable }
    try writeLink(AttachmentLink.web(address: address, title: title), at: marker(id))
    NotificationCenter.default.post(name: .bookAttachmentFilesDidChange, object: id)
  }

  func rename(_ id: UUID, stem: String, grantedParent: URL? = nil) throws {
    let isLinked = try link(id) != nil
    let access = grantedParent?.startAccessingSecurityScopedResource() == true
    defer { if access { grantedParent?.stopAccessingSecurityScopedResource() } }
    try withFile(id) { old in
      let name = try AttachmentNaming.filename(stem: stem, original: old.lastPathComponent)
      guard old.lastPathComponent != name else { return }
      let parent = old.deletingLastPathComponent()
      if isLinked {
        guard let grantedParent, grantedParent.standardizedFileURL.path == parent.standardizedFileURL.path else { throw AttachmentError.unavailable }
      }
      let target = parent.appendingPathComponent(name)
      if fm.fileExists(atPath: target.path) {
        guard old.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame,
          !(try fm.contentsOfDirectory(atPath: parent.path)).contains(name) else { throw AttachmentError.duplicate }
        let temporary = parent.appendingPathComponent(".bookshelf-rename-" + UUID().uuidString)
        try fm.moveItem(at: old, to: temporary)
        do { try fm.moveItem(at: temporary, to: target) }
        catch { try fm.moveItem(at: temporary, to: old); throw error }
      } else { try fm.moveItem(at: old, to: target) }
      if isLinked {
        do { try writeLink(bookmark(target), at: marker(id)) }
        catch { try fm.moveItem(at: target, to: old); throw error }
      }
      NotificationCenter.default.post(name: .bookAttachmentFilesDidChange, object: id)
    }
  }

  func relink(_ id: UUID, to url: URL) throws {
    guard let existing = try link(id), existing.webURL == nil else { throw AttachmentError.unavailable }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    try writeLink(bookmark(url), at: marker(id))
    NotificationCenter.default.post(name: .bookAttachmentFilesDidChange, object: id)
  }

  func remove(_ id: UUID) throws {
    try Self.requireDirectory(root)
    try Self.requireDirectory(folder(id))
    try fm.removeItem(at: folder(id))
  }

  func portable(_ id: UUID) throws -> PortableAttachment {
    let item = try item(id)
    switch item.kind {
    case .stored: return PortableAttachment(id: id, name: item.name, contents: try Data(contentsOf: managedFile(id)))
    case .linkedFile: return PortableAttachment(id: id, name: item.name)
    case .web(let url): return PortableAttachment(id: id, name: item.name, webURL: url.absoluteString)
    }
  }

  /// Restore to a fresh ID on a conflict, preserving both versions and all
  /// existing local bookmarks. Retries reuse identical objects.
  func importFile(_ file: PortableAttachment, created: inout [UUID]) throws -> UUID {
    try file.validate()
    var id = file.id
    while fm.fileExists(atPath: folder(id).path) {
      let existing = try portable(id)
      if existing.name == file.name && existing.contents == file.contents && existing.webURL == file.webURL { return id }
      // Derive a stable alternative so restoring the same backup twice can
      // find the first restored copy, even after the original was edited.
      var digest = SHA256()
      digest.update(data: Data((id.uuidString + "/" + file.name).utf8))
      if let bytes = file.contents { digest.update(data: bytes) }
      if let address = file.webURL { digest.update(data: Data(address.utf8)) }
      let prefix = Array(digest.finalize().prefix(16))
      id = prefix.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
    try create(id) { dir in
      if let bytes = file.contents {
        let files = dir.appendingPathComponent("file")
        try fm.createDirectory(at: files, withIntermediateDirectories: false)
        try bytes.write(to: files.appendingPathComponent(file.name), options: .withoutOverwriting)
      } else {
        try writeLink(AttachmentLink(name: file.name, webURL: file.webURL), at: dir.appendingPathComponent("link.json"))
      }
    }
    created.append(id)
    return id
  }
}

extension BookAttachmentStore {
  @MainActor static func commitImport(_ records: [BookArchive], files: [PortableAttachment], context: ModelContext,
    commit: ([BookArchive]) throws -> Void) throws {
    let ids = Set(records.flatMap { $0.attachmentIDs ?? [] })
    let needed = files.filter { ids.contains($0.id) }
    guard !needed.isEmpty else { return try commit(records) }
    let store = try Self(context: context)
    var created: [UUID] = [], mapping: [UUID: UUID] = [:]
    do {
      for file in needed { mapping[file.id] = try store.importFile(file, created: &created) }
      let local = try LibraryRepository.snapshots(in: context, ids: Set(records.map(\.id)))
      try commit(records.map { record in
        var result = record
        if let original = record.attachmentIDs {
          var seen = Set<UUID>()
          let previous = Set(local[record.id]?.attachmentIDs ?? [])
          result.attachmentIDs = original.flatMap { id -> [UUID] in
            guard let restored = mapping[id], restored != id else { return [id] }
            return previous.contains(id) ? [id, restored] : [restored]
          }.filter { seen.insert($0).inserted }
        }
        return result
      })
    } catch {
      for id in created { try? store.remove(id) }
      throw error
    }
  }

  /// Copy only regular files under attachment object directories. Never follow a
  /// symlink out of the library, or follow a bookmark to its external document.
  func snapshot(to destination: URL) throws -> [String] {
    guard fm.fileExists(atPath: root.path) else { return [] }
    try Self.requireDirectory(root)
    var paths: [String] = []
    for dir in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
      let attachment = try item(id)
      let relative = id.uuidString + (attachment.kind == .stored ? "/file/" + attachment.name : "/link.json")
      let source = root.appendingPathComponent(relative)
      let target = destination.appendingPathComponent(relative)
      try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: source, to: target)
      guard fm.contentsEqual(atPath: source.path, andPath: target.path) else { throw AutomaticBackupError.invalidBackup }
      paths.append(relative)
    }
    return paths
  }
}

@MainActor
struct BookAttachmentCommands {
  let book: Book
  let context: ModelContext

  @discardableResult
  func add(_ urls: [URL], linked: Bool, rule: AttachmentRenameRule,
    authorize: (URL) -> URL? = { _ in nil }) throws -> AttachmentRenamePlan.Result {
    guard !urls.isEmpty else { throw AttachmentError.invalidFile }
    var linkedChanges: [AttachmentRenameChange] = []
    try append { store, created in
      var names = Set(try (book.attachmentIDs ?? []).compactMap { id -> String? in
        let item = try store.item(id)
        if case .web = item.kind { return nil }
        return item.name.lowercased()
      })
      var base: String?
      for url in urls {
        let original = url.lastPathComponent
        var name = original
        if rule.automatic && (!linked || rule.linked) {
          let stem = try base ?? AttachmentNaming.stem(book: BookArchive(book: book), pattern: rule.pattern)
          base = stem
          name = try AttachmentNaming.nextFilename(stem: stem, original: original, occupied: names)
        }
        let id = try store.add(url, linked: linked, name: name)
        created.append(id)
        names.insert(name.lowercased())
        if linked && name != original {
          linkedChanges.append(AttachmentRenameChange(book: book, item: AttachmentItem(id: id, name: original, kind: .linkedFile), filename: name))
        }
      }
    }
    // Once the links are durable, a declined grant or a file conflict can leave
    // the corresponding link usable under its original name.
    guard !linkedChanges.isEmpty else { return AttachmentRenamePlan.Result() }
    return try AttachmentRenamePlan.apply(linkedChanges, store: BookAttachmentStore(context: context), authorize: authorize)
  }

  func addWebLink(address: String, title: String) throws {
    try append { store, created in created.append(try store.addWebLink(address: address, title: title)) }
  }

  private func append(_ create: (BookAttachmentStore, inout [UUID]) throws -> Void) throws {
    guard book.modelContext === context, !book.isDeleted, book.deletedAt == nil else { throw LibraryOperationError.invalidSelection }
    let store = try BookAttachmentStore(context: context)
    var created: [UUID] = []
    do {
      try create(store, &created)
      var record = BookArchive(book: book)
      record.attachmentIDs = (record.attachmentIDs ?? []) + created
      record.updatedAt = Date()
      try LibraryRepository.apply([record], into: context)
    } catch {
      for id in created { try? store.remove(id) }
      throw error
    }
  }

  func detach(_ id: UUID) throws {
    guard book.modelContext === context, book.deletedAt == nil, book.attachmentIDs?.contains(id) == true
    else { throw LibraryOperationError.invalidSelection }
    var record = BookArchive(book: book)
    let kept = (record.attachmentIDs ?? []).filter { $0 != id }
    record.attachmentIDs = kept.isEmpty ? nil : kept
    record.updatedAt = Date()
    try LibraryRepository.apply([record], into: context)
    try Self.cleanUnreferenced([id], context: context)
  }

  static func cleanUnreferenced(_ ids: Set<UUID>, context: ModelContext) throws {
    guard !ids.isEmpty else { return }
    let used = Set(try context.fetch(FetchDescriptor<Book>()).flatMap { $0.attachmentIDs ?? [] })
    let store = try BookAttachmentStore(context: context)
    for id in ids.subtracting(used) { try store.remove(id) }
  }
}

extension BookAttachmentStore {
  func requireOutside(_ directory: URL) throws {
    let source = root.resolvingSymlinksInPath().standardizedFileURL.path
    let target = directory.resolvingSymlinksInPath().standardizedFileURL.path
    guard target != source, !target.hasPrefix(source + "/") else { throw LibraryStorageError.occupiedDirectory }
  }
}
