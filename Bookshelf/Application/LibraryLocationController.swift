import Combine
import Darwin
import Foundation
import SwiftData

struct LibraryDirectoryReference: Codable, Equatable {
  var path: String
  var bookmark: Data
}

struct LibraryLocationConfiguration: Codable {
  var formatVersion = 1
  var initialized: Bool?
  var active: LibraryDirectoryReference?
  var pending: LibraryDirectoryReference?
}

@MainActor
final class LibraryLocationController: ObservableObject {
  @Published private(set) var currentStoreURL: URL
  @Published private(set) var pendingDirectory: URL?
  @Published private(set) var locationError: String?
  @Published private(set) var integrityMessage: String?
  @Published private(set) var integrityPassed = false
  @Published private(set) var isChecking = false
  private(set) var isOpen = false
  private var configuration = LibraryLocationConfiguration()
  private let configurationURL: URL
  private let defaultStoreURL: URL
  private let recoveryRoot: URL
  private let makeBookmark: (URL) throws -> Data
  private let resolveBookmark: (Data) throws -> URL
  private let startAccess: (URL) -> Bool
  private var accessedURLs: [URL] = []
  private var context: ModelContext?

  init(defaultStoreURL: URL, configurationURL: URL, recoveryRoot: URL,
    makeBookmark: @escaping (URL) throws -> Data = { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) },
    resolveBookmark: @escaping (Data) throws -> URL = {
      var stale = false
      return try URL(resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }, startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }) {
    self.defaultStoreURL = defaultStoreURL; currentStoreURL = defaultStoreURL
    self.configurationURL = configurationURL; self.recoveryRoot = recoveryRoot
    self.makeBookmark = makeBookmark; self.resolveBookmark = resolveBookmark; self.startAccess = startAccess
  }
  deinit { for url in accessedURLs { url.stopAccessingSecurityScopedResource() } }

  func openLibrary(backups: AutomaticBackupController) throws -> ModelContainer {
    if FileManager.default.fileExists(atPath: configurationURL.path) {
      do { configuration = try JSONDecoder().decode(LibraryLocationConfiguration.self, from: Data(contentsOf: configurationURL)) }
      catch { throw LibraryStorageError.invalidConfiguration }
      guard configuration.formatVersion == 1 else { throw LibraryStorageError.invalidConfiguration }
    }
    pendingDirectory = configuration.pending.map { URL(fileURLWithPath: $0.path) }
    if configuration.active == nil, (configuration.initialized == true || configuration.pending != nil),
      !FileManager.default.fileExists(atPath: currentStoreURL.path) { throw LibraryStorageError.missingDatabase }
    if let active = configuration.active {
      currentStoreURL = try access(active).appendingPathComponent("default.store")
      guard FileManager.default.fileExists(atPath: currentStoreURL.path) else { throw LibraryStorageError.missingDatabase }
      try LibraryIntegrity.checkSQLite(at: currentStoreURL, requireLibrary: true)
      // Refresh bookmarks (including renamed directories) while access is held.
      var refreshed = configuration
      refreshed.active = try reference(currentStoreURL.deletingLastPathComponent())
      try save(refreshed)
    }
    try backups.prepareToOpenStore(at: currentStoreURL)
    if let pending = configuration.pending {
      do { return try relocate(to: pending, backups: backups) }
      catch { locationError = L10n.tr("目录切换未完成，仍使用原数据目录：\(error.localizedDescription)") }
    }
    let container = try LibraryDatabase.open(at: currentStoreURL)
    if configuration.initialized != true {
      var next = configuration; next.initialized = true
      try save(next)
    }
    attach(container, backups: backups)
    return container
  }

  /// Choosing a location only stages a request. The final snapshot happens at
  /// next launch, after the original process has closed all editing windows.
  func requestDirectory(_ directory: URL) throws {
    let granted = startAccess(directory)
    defer { if granted { directory.stopAccessingSecurityScopedResource() } }
    guard granted else { throw LibraryStorageError.unavailableDirectory }
    guard directory.resolvingSymlinksInPath().standardizedFileURL != currentStoreURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL else {
      throw LibraryStorageError.sameDirectory
    }
    try requireEmptyDirectory(directory)
    var next = configuration
    next.pending = try reference(directory)
    try save(next)
    pendingDirectory = directory; locationError = nil
  }

  func cancelDirectoryChange() throws {
    var next = configuration; next.pending = nil
    try save(next)
    pendingDirectory = nil; locationError = nil
  }

  /// Regrant access to the active directory without selecting a different library.
  func reauthorize(_ directory: URL) throws {
    guard let active = configuration.active,
      directory.standardizedFileURL.path == URL(fileURLWithPath: active.path).standardizedFileURL.path else {
      throw LibraryStorageError.unavailableDirectory
    }
    let granted = startAccess(directory)
    defer { if granted { directory.stopAccessingSecurityScopedResource() } }
    guard granted else { throw LibraryStorageError.unavailableDirectory }
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("default.store").path) else { throw LibraryStorageError.missingDatabase }
    var next = configuration; next.active = try reference(directory)
    try save(next)
  }
  var canReauthorize: Bool { configuration.active != nil }
  var configuredDirectory: URL { configuration.active.map { URL(fileURLWithPath: $0.path) } ?? defaultStoreURL.deletingLastPathComponent() }

  func checkIntegrity() async {
    guard !isChecking, let context else { return }
    isChecking = true; integrityMessage = nil; integrityPassed = false
    defer { isChecking = false }
    do {
      let url = currentStoreURL
      try await Task.detached { try LibraryIntegrity.checkSQLite(at: url, requireLibrary: true) }.value
      let counts = try LibraryIntegrity.checkRecords(in: context)
      integrityPassed = true
      integrityMessage = L10n.tr("检查通过：数据库结构和书库关联正常，共 \(counts.books) 本书籍、\(counts.notes) 条笔记（含回收站）。")
    } catch { integrityMessage = error.localizedDescription }
  }

  private func relocate(to target: LibraryDirectoryReference, backups: AutomaticBackupController) throws -> ModelContainer {
    let directory = try access(target)
    try requireEmptyDirectory(directory)
    try LibraryIntegrity.checkSQLite(at: currentStoreURL, requireLibrary: true)
    _ = try backups.store.create(kind: .beforeMigration, data: nil, storeURL: currentStoreURL,
      recoveryRoot: recoveryRoot, appVersion: "\(AppReleaseInfo.version) (\(AppReleaseInfo.build))")
    backups.refresh()
    let staging = directory.appendingPathComponent(".bookshelf-migration-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: staging) }
    try AutomaticBackupStore.snapshotSQLite(from: currentStoreURL, to: staging)
    try LibraryIntegrity.checkSQLite(at: staging)
    let destination = directory.appendingPathComponent("default.store")
    // moveItem never overwrites a destination that appeared after selection.
    try FileManager.default.moveItem(at: staging, to: destination)
    let container = try LibraryDatabase.open(at: destination)
    _ = try LibraryIntegrity.checkRecords(in: container.mainContext)
    var next = configuration; next.active = try reference(directory); next.pending = nil; next.initialized = true
    // Publish the location only after the copied library opens and validates.
    // Any failure preserves the source and the copied destination for recovery.
    try save(next)
    currentStoreURL = destination; pendingDirectory = nil; locationError = nil
    attach(container, backups: backups)
    return container
  }

  private func attach(_ container: ModelContainer, backups: AutomaticBackupController) {
    context = container.mainContext; isOpen = true
    backups.attach(context: container.mainContext, storeURL: currentStoreURL)
  }
  private func access(_ record: LibraryDirectoryReference) throws -> URL {
    do {
      let url = try resolveBookmark(record.bookmark)
      guard startAccess(url) else { throw LibraryStorageError.unavailableDirectory }
      accessedURLs.append(url)
      guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LibraryStorageError.unavailableDirectory }
      return url
    } catch { throw LibraryStorageError.unavailableDirectory }
  }
  private func reference(_ url: URL) throws -> LibraryDirectoryReference {
    LibraryDirectoryReference(path: url.path, bookmark: try makeBookmark(url))
  }
  private func requireEmptyDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isWritableKey])
    guard values.isDirectory == true, values.isSymbolicLink != true, values.isWritable == true else { throw LibraryStorageError.unavailableDirectory }
    let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    guard files.allSatisfy({ $0.lastPathComponent == ".DS_Store" }) else { throw LibraryStorageError.occupiedDirectory }
  }
  private func save(_ value: LibraryLocationConfiguration) throws {
    try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = configurationURL.deletingLastPathComponent().appendingPathComponent(".location-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try JSONEncoder().encode(value).write(to: temporary)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    let handle = try FileHandle(forWritingTo: temporary)
    defer { try? handle.close() }
    try handle.synchronize()
    guard rename(temporary.path, configurationURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    configuration = value
  }
}
