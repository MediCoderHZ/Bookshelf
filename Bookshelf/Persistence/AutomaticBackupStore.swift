import CryptoKit
import Foundation
import SQLite3

enum AutomaticBackupKind: String, Codable {
  case scheduled, manual, beforeUpdate, beforeMigration
  var isUpgrade: Bool { self == .beforeUpdate || self == .beforeMigration }
  var title: String {
    switch self {
    case .scheduled: "定时备份"
    case .manual: "手动备份"
    case .beforeUpdate: "升级前备份"
    case .beforeMigration: "数据库升级前快照"
    }
  }
}

struct AutomaticBackupManifest: Codable, Equatable, Identifiable {
  var formatVersion = 1
  let id: UUID
  let createdAt: TimeInterval
  let kind: AutomaticBackupKind
  let appVersion: String
  let bookCount: Int?
  let noteCount: Int?
  let files: [String: String]
  var date: Date { Date(timeIntervalSince1970: createdAt) }
  var directoryName: String { "Bookshelf-" + id.uuidString }
  var hasJSON: Bool { files["library.json"] != nil }
}

enum AutomaticBackupError: LocalizedError {
  case invalidBackup, pendingChanges, unavailable, sqlite(String)
  var errorDescription: String? {
    switch self {
    case .invalidBackup: "备份内容或校验值不完整，原文件已保留。"
    case .pendingChanges: "书库还有未提交的修改，请完成保存后再备份。"
    case .unavailable: "书库尚未正常打开，无法创建升级前备份。"
    case .sqlite(let detail): "无法创建完整的数据库快照：\(detail)"
    }
  }
}

/// Completed snapshots are immutable directories. Only a verified snapshot can
/// become visible or count toward retention; unrelated/corrupt files are preserved.
@MainActor
struct AutomaticBackupStore {
  let directory: URL
  private let fm = FileManager.default
  static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Bookshelf/Backups", isDirectory: true)
  }

  func create(kind: AutomaticBackupKind, data: Data?, storeURL: URL?, recoveryRoot: URL?,
    appVersion: String, now: Date = Date()) throws -> AutomaticBackupManifest {
    let archive = try data.map(LibraryBackupService.decode)
    guard data != nil || storeURL != nil else { throw AutomaticBackupError.unavailable }
    try fm.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let id = UUID()
    let staging = directory.appendingPathComponent(".pending-" + id.uuidString, isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: staging) }
    var files: [String: String] = [:]
    func record(_ name: String) throws {
      let url = staging.appendingPathComponent(name)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      files[name] = Self.digest(try Data(contentsOf: url))
    }
    if let data {
      try durableWrite(data, to: staging.appendingPathComponent("library.json"))
      try record("library.json")
    }
    if let storeURL {
      try Self.snapshotSQLite(from: storeURL, to: staging.appendingPathComponent("default.store"))
      try record("default.store")
    }
    if let recoveryRoot {
      for name in ["NoteDraftRecovery", "MetadataDraftRecovery"] {
        let source = recoveryRoot.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { continue }
        guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
          throw AutomaticBackupError.invalidBackup
        }
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
          let attributes = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          guard item.pathExtension == "json", attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
          let relative = "Recovery/\(name)/\(item.lastPathComponent)"
          let target = staging.appendingPathComponent(relative)
          try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          try durableWrite(Data(contentsOf: item), to: target)
          try record(relative)
        }
      }
    }
    let manifest = AutomaticBackupManifest(id: id, createdAt: now.timeIntervalSince1970, kind: kind,
      appVersion: appVersion, bookCount: archive?.books.count, noteCount: archive?.libraryNotes?.count, files: files)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try durableWrite(encoder.encode(manifest), to: staging.appendingPathComponent("manifest.json"))
    _ = try validate(at: staging, expectedName: false)
    try fm.moveItem(at: staging, to: directory.appendingPathComponent(manifest.directoryName, isDirectory: true))
    return manifest
  }

  func entries() throws -> [AutomaticBackupManifest] {
    guard fm.fileExists(atPath: directory.path) else { return [] }
    return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("Bookshelf-") }
      .compactMap { try? validate(at: $0) }
      .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
  }

  func archiveData(for entry: AutomaticBackupManifest) throws -> Data {
    let folder = directory.appendingPathComponent(entry.directoryName)
    let checked = try validate(at: folder)
    guard checked == entry, checked.hasJSON else { throw AutomaticBackupError.invalidBackup }
    let data = try Data(contentsOf: folder.appendingPathComponent("library.json"))
    _ = try LibraryBackupService.decode(data)
    return data
  }

  /// Called only after a new complete snapshot succeeds. Upgrade snapshots have
  /// a separate allowance so ordinary hourly backups cannot evict all of them.
  func prune(regularLimit: Int, upgradeLimit: Int = 10) throws {
    let valid = try entries()
    for group in [false, true] {
      let limit = max(1, group ? upgradeLimit : regularLimit)
      for entry in valid.filter({ $0.kind.isUpgrade == group }).dropFirst(limit) {
        let folder = directory.appendingPathComponent(entry.directoryName)
        guard try validate(at: folder) == entry else { throw AutomaticBackupError.invalidBackup }
        try fm.removeItem(at: folder)
      }
    }
  }

  private func validate(at folder: URL, expectedName: Bool = true) throws -> AutomaticBackupManifest {
    guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AutomaticBackupError.invalidBackup }
    let manifestURL = folder.appendingPathComponent("manifest.json")
    guard try manifestURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AutomaticBackupError.invalidBackup }
    let manifest = try JSONDecoder().decode(AutomaticBackupManifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.formatVersion == 1, manifest.createdAt.isFinite,
      !expectedName || manifest.directoryName == folder.lastPathComponent,
      manifest.files["library.json"] != nil || manifest.files["default.store"] != nil else { throw AutomaticBackupError.invalidBackup }
    for (relative, digest) in manifest.files {
      let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
      guard !relative.hasPrefix("/"), !parts.contains(".."), !parts.contains("."), !parts.contains("") else { throw AutomaticBackupError.invalidBackup }
      var url = folder
      for part in parts {
        url.appendPathComponent(String(part))
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AutomaticBackupError.invalidBackup }
      }
      guard Self.digest(try Data(contentsOf: url)) == digest else { throw AutomaticBackupError.invalidBackup }
    }
    return manifest
  }

  private func durableWrite(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }
  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  /// SQLite's backup API includes committed WAL pages without modifying the live
  /// source or relying on a non-atomic copy of default.store + its sidecars.
  static func snapshotSQLite(from source: URL, to destination: URL) throws {
    var input: OpaquePointer?, output: OpaquePointer?
    defer { if let output { sqlite3_close(output) }; if let input { sqlite3_close(input) } }
    guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
      let input, let output else { throw AutomaticBackupError.sqlite("无法打开源文件或备份目录") }
    sqlite3_busy_timeout(input, 1500); sqlite3_busy_timeout(output, 1500)
    guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
      throw AutomaticBackupError.sqlite(String(cString: sqlite3_errmsg(output)))
    }
    let result = sqlite3_backup_step(backup, -1)
    let finished = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finished == SQLITE_OK else { throw AutomaticBackupError.sqlite(String(cString: sqlite3_errmsg(output))) }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(output, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
      String(cString: text) == "ok" else { throw AutomaticBackupError.sqlite("完整性检查未通过") }
    sqlite3_finalize(statement); statement = nil
    // The backup must be standalone after the connection closes.
    guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
      throw AutomaticBackupError.sqlite("无法完成独立快照")
    }
  }
}
