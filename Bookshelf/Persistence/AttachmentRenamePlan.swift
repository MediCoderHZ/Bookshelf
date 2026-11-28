import Foundation
import SwiftData

/// A preview retains the identity and old name that the user reviewed.
struct AttachmentRenameChange: Identifiable {
  let book: Book
  let item: AttachmentItem
  let filename: String
  var id: UUID { item.id }
}

@MainActor
enum AttachmentRenamePlan {
  static func changes(for books: [Book], rule: AttachmentRenameRule, store: BookAttachmentStore) throws -> [AttachmentRenameChange] {
    var changes: [AttachmentRenameChange] = []
    var seen = Set<UUID>()
    var occupiedByFolder: [URL: Set<String>] = [:]
    for book in books where book.deletedAt == nil {
      let files = try (book.attachmentIDs ?? []).map(store.item).filter {
        if case .web = $0.kind { return false }
        return true
      }
      guard !files.isEmpty else { continue }
      let candidates = files.filter { ($0.kind != .linkedFile || rule.linked) && seen.insert($0.id).inserted }
      guard !candidates.isEmpty else { continue }
      let ids = Set(candidates.map(\.id))
      var occupied = Set(files.filter { !ids.contains($0.id) }.map { $0.name.lowercased() })
      let stem = try AttachmentNaming.stem(book: BookArchive(book: book), pattern: rule.pattern)
      for item in candidates {
        var unavailable = occupied
        var externalFolder: URL?
        if item.kind == .externalFile {
          externalFolder = try store.withFile(item.id) { url in
            let directory = url.deletingLastPathComponent().standardizedFileURL
            if occupiedByFolder[directory] == nil {
              occupiedByFolder[directory] = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).map { $0.lowercased() })
            }
            return directory
          }
          if let externalFolder, var names = occupiedByFolder[externalFolder] {
            names.remove(item.name.lowercased())
            unavailable.formUnion(names)
          }
        }
        let name = try AttachmentNaming.nextFilename(stem: stem, original: item.name, occupied: unavailable)
        if let externalFolder { occupiedByFolder[externalFolder, default: []].insert(name.lowercased()) }
        occupied.insert(name.lowercased())
        if name != item.name { changes.append(AttachmentRenameChange(book: book, item: item, filename: name)) }
      }
    }
    return changes
  }

  struct Result {
    var renamed = 0
    var skipped = 0
    var failures: [String] = []

    var message: String {
      ([L10n.tr("已重命名 \(renamed) 个文件，跳过 \(skipped) 个。")] + failures).joined(separator: "\n")
    }
  }

  static func apply(_ changes: [AttachmentRenameChange], store: BookAttachmentStore,
    authorize: (URL) -> URL?) -> Result {
    var result = Result()
    var grants: [URL: URL] = [:]
    var declined = Set<URL>()
    for change in changes {
      do {
        let item = change.item
        guard change.book.modelContext != nil, !change.book.isDeleted, change.book.deletedAt == nil,
          change.book.attachmentIDs?.contains(item.id) == true,
          try store.item(item.id) == item else { throw LibraryOperationError.changedSincePreview }
        var parent: URL?
        if item.kind == .linkedFile {
          let url = try store.withFile(item.id) { $0 }
          guard url.lastPathComponent == item.name else { throw LibraryOperationError.changedSincePreview }
          let folder = url.deletingLastPathComponent().standardizedFileURL
          if grants[folder] == nil && !declined.contains(folder) {
            if let granted = authorize(folder) { grants[folder] = granted }
            else { declined.insert(folder) }
          }
          guard let granted = grants[folder] else { result.skipped += 1; continue }
          parent = granted
        }
        let stem = (item.name as NSString).pathExtension.isEmpty ? change.filename : (change.filename as NSString).deletingPathExtension
        try store.rename(item.id, stem: stem, grantedParent: parent)
        result.renamed += 1
      } catch {
        result.skipped += 1
        result.failures.append("\(change.item.name) — \(error.localizedDescription)")
      }
    }
    return result
  }
}
