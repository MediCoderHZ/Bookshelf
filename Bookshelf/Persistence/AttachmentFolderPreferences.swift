import Darwin
import Foundation

/// This library's destination for new file copies. Existing attachments retain their own grants.
struct AttachmentFolderPreferences {
  let database: URL
  private var file: URL { database.deletingLastPathComponent().appendingPathComponent("AttachmentFolder.json") }

  enum FolderError: LocalizedError {
    case invalidLocation, unavailable
    var errorDescription: String? {
      switch self {
      case .invalidLocation: L10n.tr("请选择书库管理目录以外的可写文件夹。")
      case .unavailable: L10n.tr("附件文件夹无法访问。请检查磁盘连接或重新选择文件夹。")
      }
    }
  }

  private func hasConfiguration() throws -> Bool {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else { throw FolderError.unavailable }
      return true
    } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
      return false
    }
  }

  func reference() throws -> LibraryDirectoryReference? {
    guard try hasConfiguration() else { return nil }
    let data = try Data(contentsOf: file)
    guard let ref = try? JSONDecoder().decode(LibraryDirectoryReference.self, from: data),
      ref.path.hasPrefix("/"), !ref.bookmark.isEmpty else { throw FolderError.unavailable }
    return ref
  }

  static func withDirectory<T>(_ reference: LibraryDirectoryReference, _ body: (URL) throws -> T) throws -> T {
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: reference.bookmark,
      options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
    else { throw FolderError.unavailable }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    guard (try? BookAttachmentStore.requireDirectory(url)) != nil else { throw FolderError.unavailable }
    return try body(url)
  }

  func set(_ directory: URL) throws {
    let ref = try reference(for: directory)
    _ = try hasConfiguration()
    try save(ref)
  }

  /// A one-time move gets its own grant without changing the library's default.
  func reference(for directory: URL) throws -> LibraryDirectoryReference {
    let access = directory.startAccessingSecurityScopedResource()
    defer { if access { directory.stopAccessingSecurityScopedResource() } }
    try validateDestination(directory)
    let bookmark = try directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    return LibraryDirectoryReference(path: directory.standardizedFileURL.path, bookmark: bookmark)
  }

  func validateDestination(_ directory: URL) throws {
    guard directory.isFileURL else { throw FolderError.invalidLocation }
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isWritableKey, .isPackageKey])
    guard values.isDirectory == true, values.isSymbolicLink != true, values.isWritable == true,
      values.isPackage != true else { throw FolderError.invalidLocation }
    let library = database.deletingLastPathComponent()
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let reserved = [BookAttachmentStore(database: database).root, LibraryTranslatorDirectory.beside(database),
      support.appendingPathComponent("Bookshelf", isDirectory: true)]
    let path = Self.path(directory)
    guard path != Self.path(library), !reserved.contains(where: { Self.contains($0, path: path) })
    else { throw FolderError.invalidLocation }
  }

  func reset() throws {
    if try hasConfiguration() { try FileManager.default.removeItem(at: file) }
  }

  /// Migration preserves the preference even while the external volume is offline.
  func copy(to newDatabase: URL) throws {
    guard let ref = try reference() else { return }
    try AttachmentFolderPreferences(database: newDatabase).save(ref, replacing: false)
  }

  func requireOutside(_ directory: URL) throws {
    guard let ref = try reference() else { return }
    let current = (try? Self.withDirectory(ref) { $0 }) ?? URL(fileURLWithPath: ref.path)
    guard !Self.contains(current, path: Self.path(directory)) else { throw FolderError.invalidLocation }
  }

  private static func path(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
  }

  private static func contains(_ directory: URL, path: String) -> Bool {
    let parent = Self.path(directory)
    return path == parent || path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
  }

  private func save(_ ref: LibraryDirectoryReference, replacing: Bool = true) throws {
    let fm = FileManager.default
    let temporary = file.deletingLastPathComponent().appendingPathComponent(".attachment-folder-" + UUID().uuidString)
    guard fm.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(ref),
      attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    defer { try? fm.removeItem(at: temporary) }
    if replacing {
      guard rename(temporary.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } else {
      try fm.moveItem(at: temporary, to: file)
    }
  }
}
