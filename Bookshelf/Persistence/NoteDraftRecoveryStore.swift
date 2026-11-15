import Foundation

struct NoteDraftSnapshot: Codable {
  var baseline: NoteRecord
  var draft: NoteRecord
  var tagsText: String
}

/// Only failed saves need a recovery file; successful edits already live in SwiftData.
struct NoteDraftRecoveryStore {
  let directory: URL
  init(directory: URL? = nil) {
    self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Bookshelf/NoteDraftRecovery", isDirectory: true)
  }
  func save(_ snapshot: NoteDraftSnapshot) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(to: file(snapshot.draft.id), options: .atomic)
  }
  func remove(_ id: UUID) throws {
    let url = file(id)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }
  func load() -> (drafts: [NoteDraftSnapshot], errors: [String]) {
    guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
    do {
      var drafts: [NoteDraftSnapshot] = [], errors: [String] = []
      for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "json" {
        do {
          let draft = try JSONDecoder().decode(NoteDraftSnapshot.self, from: Data(contentsOf: url))
          guard draft.draft.id == draft.baseline.id, url.deletingPathExtension().lastPathComponent == draft.draft.id.uuidString
          else { throw CocoaError(.fileReadCorruptFile) }
          drafts.append(draft)
        } catch { errors.append(error.localizedDescription) }
      }
      return (drafts, errors)
    } catch { return ([], [error.localizedDescription]) }
  }
  private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
