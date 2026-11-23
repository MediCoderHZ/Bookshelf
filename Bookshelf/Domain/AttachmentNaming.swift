import Foundation

enum AttachmentNaming {
  static let defaultPattern = "{author} - {year} - {title}"
  static let preference = "attachments.renamePattern"
  static let tokens = ["{author}", "{year}", "{title}", "{isbn}"]

  static func valid(_ pattern: String) -> Bool {
    let remainder = tokens.reduce(pattern) { $0.replacingOccurrences(of: $1, with: "") }
    return pattern.count <= 200 && tokens.contains(where: pattern.contains)
      && !remainder.contains("{") && !remainder.contains("}")
  }

  static func stem(book: BookArchive, pattern: String) throws -> String {
    guard valid(pattern) else { throw AttachmentError.invalidTemplate }
    let date = book.publicationDate ?? ""
    let year = date.range(of: #"[0-9]{4}"#, options: .regularExpression).map { String(date[$0]) } ?? ""
    let values = [book.contributors.filter { $0.roleRaw == "author" }.sorted { $0.displayOrder < $1.displayOrder }.first?.name ?? "",
      year, book.title, book.isbn13 ?? book.isbn10 ?? ""]
    // Substitute each token once; a title may itself contain literal braces.
    let segments = pattern.components(separatedBy: " - ").compactMap { part -> String? in
      var remaining = part[...], output = ""
      while let first = remaining.firstIndex(of: "{"), let end = remaining[first...].firstIndex(of: "}") {
        let token = String(remaining[first...end])
        guard let index = tokens.firstIndex(of: token) else { break }
        output += String(remaining[..<first]) + values[index]
        remaining = remaining[remaining.index(after: end)...]
      }
      let segment = (output + remaining).trimmingCharacters(in: .whitespacesAndNewlines)
      return segment.isEmpty ? nil : segment
    }
    let clean = (segments.isEmpty ? book.title : segments.joined(separator: " - "))
      .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
    var result = clean.isEmpty ? "Book" : clean
    while result.utf8.count > 195 { result.removeLast() }
    return result
  }

  static func validName(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix(".") && name.utf8.count <= 255 && name != ".."
      && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)) == nil
  }

  static func filename(stem: String, original: String) throws -> String {
    let stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
    let ext = (original as NSString).pathExtension
    let name = ext.isEmpty ? stem : stem + "." + ext
    guard !stem.isEmpty, validName(name) else { throw AttachmentError.invalidName }
    return name
  }
}

struct AttachmentRenameRule: Equatable {
  var pattern = AttachmentNaming.defaultPattern
  var automatic = true
  var linked = false

  static func load(from defaults: UserDefaults = .standard) -> Self {
    var rule = Self()
    rule.pattern = defaults.string(forKey: AttachmentNaming.preference) ?? rule.pattern
    rule.automatic = defaults.object(forKey: "attachments.autoRename") as? Bool ?? true
    rule.linked = defaults.bool(forKey: "attachments.renameLinked")
    return rule
  }

  func save(to defaults: UserDefaults = .standard) {
    defaults.set(pattern, forKey: AttachmentNaming.preference)
    defaults.set(automatic, forKey: "attachments.autoRename")
    defaults.set(linked, forKey: "attachments.renameLinked")
  }
}

extension AttachmentNaming {
  static func nextFilename(stem: String, original: String, occupied: Set<String>) throws -> String {
    var name = try filename(stem: stem, original: original)
    var n = 2
    while occupied.contains(name.lowercased()) {
      name = try filename(stem: stem + " (\(n))", original: original)
      n += 1
    }
    return name
  }
}
