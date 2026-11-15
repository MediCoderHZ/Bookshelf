import Foundation

/// Retires reading status and rating at storage/import boundaries. Current
/// models, exports and undo records contain neither field.
enum RetiredReadingData {
  private static let retiredFields: Set<String> = ["status", "rating"]

  static func cleanQuery(_ object: [String: Any]) -> [String: Any]? {
    guard let rules = object["rules"] as? [Any] else { return object }
    let retained = rules.filter { !retiredFields.contains(($0 as? [String: Any])?["field"] as? String ?? "") }
    guard retained.count != rules.count else { return object }
    let hasSavedSearch = object["savedSearch"] != nil && !(object["savedSearch"] is NSNull)
    guard !retained.isEmpty || hasSavedSearch else { return nil }
    var result = object; result["rules"] = retained
    return result
  }

  static func cleanSmartCollections(_ items: [Any]) -> [Any] {
    items.compactMap { item in
      guard var record = item as? [String: Any], let query = record["query"] as? [String: Any] else { return item }
      guard let cleaned = cleanQuery(query) else { return nil }
      record["query"] = cleaned
      return record
    }
  }

  static func cleanBackup(_ data: Data) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LibraryBackupError.invalidDocument
    }
    if let books = object["books"] as? [Any] {
      object["books"] = books.map { item -> Any in
        guard var book = item as? [String: Any] else { return item }
        for key in ["readingStatusRaw", "startedAt", "finishedAt", "personalRating"] { book.removeValue(forKey: key) }
        return book
      }
    }
    if let items = object["smartCollections"] as? [Any] { object["smartCollections"] = cleanSmartCollections(items) }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static func cleanPreferences(_ preferences: UserDefaults) {
    rewrite("libraryWorkspaceState.v1", in: preferences) { object in
      guard var state = object as? [String: Any], let selection = state["selection"] as? [String: Any],
        selection["status"] != nil else { return object }
      state["selection"] = ["all": [:]] as [String: Any]
      return state
    }
    rewrite("libraryTableColumnCustomization.v1", in: preferences) { object in
      guard var columns = object as? [String: Any] else { return object }
      func isRetiredColumn(_ item: Any) -> Bool {
        let id = item as? [String: Any], base = id?["base"] as? [String: Any]
        return retiredFields.contains((base?["explicit"] as? [String: Any])?["_0"] as? String ?? "")
      }
      if let order = columns["columnOrder"] as? [Any] { columns["columnOrder"] = order.filter { !isRetiredColumn($0) } }
      if let pairs = columns["perColumnState"] as? [Any], pairs.count.isMultiple(of: 2) {
        columns["perColumnState"] = stride(from: 0, to: pairs.count, by: 2).flatMap { index -> [Any] in
          isRetiredColumn(pairs[index]) ? [] : [pairs[index], pairs[index + 1]]
        }
      }
      return columns
    }
    // These are app-owned snapshots of retired presets, not user-exported files.
    for key in preferences.dictionaryRepresentation().keys
      where key.hasPrefix("bookTypeSmartCollectionsRetired.v1.") && key.hasSuffix(".backup") {
      rewrite(key, in: preferences) { object in
        guard let items = object as? [Any] else { return object }
        return cleanSmartCollections(items)
      }
    }
  }

  private static func rewrite(_ key: String, in preferences: UserDefaults, transform: (Any) -> Any) {
    guard let data = preferences.data(forKey: key), let original = try? JSONSerialization.jsonObject(with: data) else { return }
    let cleaned = transform(original)
    guard let result = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]), result != data else { return }
    preferences.set(result, forKey: key)
  }
}
