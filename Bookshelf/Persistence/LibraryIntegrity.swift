import Foundation
import SQLite3
import SwiftData

enum LibraryStorageError: LocalizedError {
  case invalidConfiguration, unavailableDirectory, missingDatabase, occupiedDirectory, sameDirectory, invalidLibrary
  case nestedTranslatorDirectory, translatorCopyMismatch
  case sqlite(String)
  var errorDescription: String? {
    switch self {
    case .invalidConfiguration: L10n.tr("无法读取数据目录配置，已停止打开书库，原文件未改动。")
    case .unavailableDirectory: L10n.tr("数据目录不可用或没有访问权限。请连接所在磁盘并重新授权目录。")
    case .missingDatabase: L10n.tr("指定目录中未找到原数据库。应用不会创建空书库，请检查磁盘和文件位置。")
    case .occupiedDirectory: L10n.tr("请选择一个空文件夹。为避免覆盖已有数据，目标目录中的文件不会被替换。")
    case .sameDirectory: L10n.tr("所选目录就是当前数据目录。")
    case .nestedTranslatorDirectory: L10n.tr("数据目录不能位于原解析器目录内。")
    case .translatorCopyMismatch: L10n.tr("解析器文件复制校验失败，请重新尝试。")
    case .invalidLibrary: L10n.tr("书库记录或关联检查未通过，原数据已保留。")
    case .sqlite(let message): L10n.tr("数据库完整性检查未通过：\(message)")
    }
  }
}

enum LibraryIntegrity {
  /// Read-only transaction includes committed WAL pages and never repairs data.
  static func checkSQLite(at url: URL, requireLibrary: Bool = false) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryStorageError.missingDatabase }
    var database: OpaquePointer?
    defer { if let database { sqlite3_close(database) } }
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
      throw LibraryStorageError.sqlite(L10n.tr("无法读取数据库文件"))
    }
    sqlite3_busy_timeout(database, 3000)
    guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else {
      throw LibraryStorageError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
    if requireLibrary {
      for table in ["Z_METADATA", "ZBOOK", "ZPERSON", "ZCONTRIBUTION", "ZTAG", "ZBOOKTAG", "ZBOOKCOLLECTION", "ZCOLLECTIONITEM", "ZBOOKSERIES", "ZSERIESMEMBERSHIP", "ZLIBRARYNOTE"] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM \(table) LIMIT 0", -1, &statement, nil) == SQLITE_OK else { throw LibraryStorageError.invalidLibrary }
      }
    }
    for query in ["PRAGMA integrity_check", "PRAGMA foreign_key_check"] {
      var statement: OpaquePointer?
      defer { sqlite3_finalize(statement) }
      guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
        throw LibraryStorageError.sqlite(String(cString: sqlite3_errmsg(database)))
      }
      var rows = 0
      while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { break }
        guard result == SQLITE_ROW else { throw LibraryStorageError.sqlite(String(cString: sqlite3_errmsg(database))) }
        rows += 1
        guard query == "PRAGMA integrity_check", let value = sqlite3_column_text(statement, 0),
          String(cString: value) == "ok" else { throw LibraryStorageError.invalidLibrary }
      }
      if query == "PRAGMA integrity_check", rows != 1 { throw LibraryStorageError.invalidLibrary }
    }
  }

  /// Also validate identifiers and application-level links that SQLite does not
  /// represent as foreign keys. Never silently fix or discard a broken record.
  @MainActor static func checkRecords(in context: ModelContext) throws -> (books: Int, notes: Int) {
    guard !context.hasChanges else { throw AutomaticBackupError.pendingChanges }
    func unique<T: PersistentModel>(_ type: T.Type, id: KeyPath<T, UUID>) throws -> [T] {
      let records = try context.fetch(FetchDescriptor<T>())
      guard Set(records.map { $0[keyPath: id] }).count == records.count else { throw LibraryStorageError.invalidLibrary }
      return records
    }
    let books = try unique(Book.self, id: \.id)
    let people = Set(try unique(Person.self, id: \.id).map(\.id))
    let tags = Set(try unique(Tag.self, id: \.id).map(\.id))
    let collections = Set(try unique(BookCollection.self, id: \.id).map(\.id))
    let series = Set(try unique(BookSeries.self, id: \.id).map(\.id))
    let notes = try unique(LibraryNote.self, id: \.id)
    let bookIDs = Set(books.map(\.id))
    let contributions = try unique(Contribution.self, id: \.id)
    let links = try unique(BookTag.self, id: \.id)
    let items = try unique(CollectionItem.self, id: \.id)
    let memberships = try unique(SeriesMembership.self, id: \.id)
    guard contributions.allSatisfy({ $0.book.map { bookIDs.contains($0.id) } == true && $0.person.map { people.contains($0.id) } == true }),
      links.allSatisfy({ $0.book.map { bookIDs.contains($0.id) } == true && $0.tag.map { tags.contains($0.id) } == true }),
      items.allSatisfy({ $0.book.map { bookIDs.contains($0.id) } == true && $0.collection.map { collections.contains($0.id) } == true }),
      memberships.allSatisfy({ $0.book.map { bookIDs.contains($0.id) } == true && $0.series.map { series.contains($0.id) } == true })
    else { throw LibraryStorageError.invalidLibrary }
    _ = try LibraryBackupService.decode(LibraryBackupService.exportData(from: context))
    return (books.count, notes.count)
  }
}
