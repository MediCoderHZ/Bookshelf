import Foundation

enum LibraryTranslatorDirectory {
  static func beside(_ store: URL) -> URL {
    store.deletingLastPathComponent().appendingPathComponent("translators", isDirectory: true)
  }

  static var legacy: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Bookshelf/Translators", isDirectory: true)
  }

  /// A missing directory is normal for a library from an older release.
  /// An inaccessible directory or a link must not be treated as an empty catalog.
  private static func directoryExists(_ url: URL) throws -> Bool {
    do {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
      return true
    } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
      return false
    }
  }

  static func ensure(_ url: URL) throws {
    if try !directoryExists(url) {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  static func requireOutside(_ directory: URL, source: URL) throws {
    guard try directoryExists(source) else { return }
    var relation = FileManager.URLRelationship.other
    try FileManager.default.getRelationship(&relation, ofDirectoryAt: source, toItemAt: directory)
    guard relation == .other else { throw LibraryStorageError.nestedTranslatorDirectory }
  }

  /// The caller owns the staging destination. Publish only after verifying the whole tree.
  static func snapshot(from source: URL, to staging: URL) throws -> Bool {
    guard try directoryExists(source) else { return false }
    let fm = FileManager.default
    try requireOutside(staging.deletingLastPathComponent(), source: source)
    try fm.copyItem(at: source, to: staging)
    guard fm.contentsEqual(atPath: source.path, andPath: staging.path) else { throw LibraryStorageError.translatorCopyMismatch }
    return true
  }

  /// Keep the old location for recovery. Existing names at the new location take precedence.
  static func adoptLegacy(from source: URL, into destination: URL) throws {
    guard try directoryExists(source) else { return }
    let fm = FileManager.default
    let existing = try directoryExists(destination)
    if existing {
      var relationship = FileManager.URLRelationship.other
      try fm.getRelationship(&relationship, ofDirectoryAt: source, toItemAt: destination)
      if relationship == .same { return }
      guard relationship == .other else { throw LibraryStorageError.nestedTranslatorDirectory }
    }
    let staging = destination.deletingLastPathComponent().appendingPathComponent(".bookshelf-translators-" + UUID().uuidString)
    defer { try? fm.removeItem(at: staging) }
    guard try snapshot(from: source, to: staging) else { return }
    if existing {
      try mergeMissing(from: staging, into: destination)
    } else {
      try fm.moveItem(at: staging, to: destination)
    }
  }

  private static func mergeMissing(from staging: URL, into destination: URL) throws {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    let existing = try fm.contentsOfDirectory(atPath: destination.path)
    for item in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: Array(keys)) {
      let target = destination.appendingPathComponent(item.lastPathComponent)
      if !existing.contains(item.lastPathComponent), !fm.fileExists(atPath: target.path) {
        try fm.moveItem(at: item, to: target)
      } else {
        let sourceType = try item.resourceValues(forKeys: keys), targetType = try target.resourceValues(forKeys: keys)
        if sourceType.isDirectory == true, sourceType.isSymbolicLink != true,
          targetType.isDirectory == true, targetType.isSymbolicLink != true {
          try mergeMissing(from: item, into: target)
        }
      }
    }
  }
}
