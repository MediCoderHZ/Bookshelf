import Foundation

/// Include references in the snapshot so preview and undo cannot silently discard new uses.
struct TagRecord: Equatable, Identifiable {
  var id: UUID
  var name: String
  var createdAt: Date
  var bookIDs: Set<UUID>
  var noteIDs: Set<UUID>

  init(_ tag: Tag, notes: [LibraryNote]) {
    id = tag.id; name = tag.name; createdAt = tag.createdAt
    bookIDs = Set(tag.bookLinks.compactMap(\.book?.id))
    let key = MetadataNormalizer.normalizedName(tag.name)
    noteIDs = Set(notes.filter { $0.tags.contains { MetadataNormalizer.normalizedName($0) == key } }.map(\.id))
  }

  static func replacing(_ names: [String], source: String, destination: String?) -> [String] {
    let sourceKey = MetadataNormalizer.normalizedName(source)
    let destinationKey = destination.map(MetadataNormalizer.normalizedName)
    var included = false
    return names.compactMap { name in
      let key = MetadataNormalizer.normalizedName(name)
      guard key == sourceKey || key == destinationKey else { return name }
      guard let destination, !included else { return nil }
      included = true
      return destination
    }
  }
}

enum TagCommandError: LocalizedError {
  case invalidName, mergeRequired
  var errorDescription: String? {
    switch self {
    case .invalidName: L10n.tr("标签名称不能为空，也不能产生重复标签。")
    case .mergeRequired: L10n.tr("已有同名标签，请重新打开重命名窗口，确认合并后再保存。")
    }
  }
}
