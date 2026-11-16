import Foundation

/// Markdown remains plain source in storage; presentation is derived, never written back.
enum NoteMarkdown {
  static func title(from source: String) -> String {
    for raw in source.split(whereSeparator: \.isNewline) {
      var line = String(raw).trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.range(of: #"^(?:#{1,6}|>|[-+*]|\d+[.)])\s*$"#, options: .regularExpression) != nil || line.hasPrefix("```") || line.hasPrefix("~~~") ||
        line.range(of: #"^(?:[-*_]\s*){3,}$|^=+$"#, options: .regularExpression) != nil { continue }
      line = line.replacingOccurrences(of: #"^(?:>\s*)*(?:#{1,6}\s+|[-+*]\s+|\d+[.)]\s+)?(?:\[[ xX]\]\s+)?"#,
        with: "", options: .regularExpression)
      let parsed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
      let plain = (parsed.map { String($0.characters) } ?? line).trimmingCharacters(in: .whitespacesAndNewlines)
      if !plain.isEmpty { return String(plain.prefix(80)) }
    }
    return L10n.tr("新笔记")
  }

  struct Block: Identifiable {
    let id: Int
    var text: AttributedString
    var heading: Int?
    var code = false
    var rule = false
    var quoteDepth = 0
    var listDepth = 0
    var marker: String?
  }

  static func blocks(from source: String) -> [Block] {
    guard let parsed = try? AttributedString(markdown: source) else {
      return [Block(id: 0, text: AttributedString(source))]
    }
    var result: [Block] = [], seenItems = Set<Int>()
    for run in parsed.runs {
      let components = run.presentationIntent?.components ?? []
      let id = components.first?.identity ?? -1
      var text = AttributedString(parsed[run.range])
      text.presentationIntent = nil
      // No HTML renderer, attachment loading, or executable/custom-scheme links.
      text.imageURL = nil
      if let url = run.link, !["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { text.link = nil }
      if result.last?.id == id { result[result.count - 1].text.append(text); continue }
      var block = Block(id: id, text: text)
      var ordinal: Int?, itemID: Int?, ordered: Bool?
      for component in components {
        switch component.kind {
        case .header(let level): block.heading = level
        case .codeBlock: block.code = true
        case .thematicBreak: block.rule = true
        case .blockQuote: block.quoteDepth += 1
        case .listItem(let number):
          if ordinal == nil { ordinal = number; itemID = component.identity }
        case .orderedList: block.listDepth += 1; if ordered == nil { ordered = true }
        case .unorderedList: block.listDepth += 1; if ordered == nil { ordered = false }
        default: break
        }
      }
      if let itemID, seenItems.insert(itemID).inserted { block.marker = ordered == true ? "\(ordinal ?? 1)." : "•" }
      result.append(block)
    }
    for index in result.indices where result[index].listDepth > 0 {
      let plain = String(result[index].text.characters)
      if plain.hasPrefix("[ ] ") || plain.hasPrefix("[x] ") || plain.hasPrefix("[X] ") {
        result[index].marker = plain.hasPrefix("[ ]") ? "☐" : "☑"
        result[index].text.removeSubrange(result[index].text.startIndex..<result[index].text.index(result[index].text.startIndex, offsetByCharacters: 4))
      }
    }
    return result
  }
}

enum NoteMarkdownFormat {
  case bold, italic, strike, code, link, heading(Int), bullet, ordered, task, quote, codeBlock
}
