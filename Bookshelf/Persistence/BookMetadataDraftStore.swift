import Foundation

/// Small per-field drafts contain only the edited metadata.
struct BookMetadataDraftStore {
  let directory: URL
  init(directory: URL? = nil) {
    self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Bookshelf/MetadataDraftRecovery", isDirectory: true)
  }
  func save(_ snapshot: BookMetadataDraftSnapshot) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(to: file(snapshot.id), options: .atomic)
  }
  func remove(_ key: String) throws {
    let url = file(key)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }
  func load() -> (drafts: [BookMetadataDraftSnapshot], errors: [String]) {
    guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
    do {
      var drafts: [BookMetadataDraftSnapshot] = [], errors: [String] = []
      for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "json" {
        do {
          let draft = try JSONDecoder().decode(BookMetadataDraftSnapshot.self, from: Data(contentsOf: url))
          guard BookField(rawValue: draft.fieldRaw) != nil,
            url.deletingPathExtension().lastPathComponent == draft.id else { throw CocoaError(.fileReadCorruptFile) }
          drafts.append(draft)
        } catch { errors.append(error.localizedDescription) }
      }
      return (drafts, errors)
    } catch { return ([], [error.localizedDescription]) }
  }
  private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }
}
