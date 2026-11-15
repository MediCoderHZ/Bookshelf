import AppKit
import Foundation

extension NSAttributedString.Key {
  static let noteBlock = Self("Bookshelf.noteBlock")
  static let noteBold = Self("Bookshelf.noteBold")
  static let noteItalic = Self("Bookshelf.noteItalic")
  static let noteStrike = Self("Bookshelf.noteStrike")
  static let noteInlineCode = Self("Bookshelf.noteInlineCode")
  static let noteImage = Self("Bookshelf.noteImage")
  static let noteLinkDestination = Self("Bookshelf.noteLinkDestination")
}

struct RichNoteBlock: Equatable {
  var kind = "plain"
  var level = 1
  var depth = 0
  var ordinal = 1
  var checked = false
  var language = ""
  var value: String { [kind, String(level), String(depth), String(ordinal), checked ? "1" : "0", language].joined(separator: "|") }
  init(_ kind: String = "plain") { self.kind = kind }
  init(attributes: [NSAttributedString.Key: Any]) {
    guard let value = attributes[.noteBlock] as? String else { return }
    let parts = value.components(separatedBy: "|")
    guard parts.count == 6 else { return }
    kind = parts[0]; level = Int(parts[1]) ?? 1; depth = Int(parts[2]) ?? 0
    ordinal = Int(parts[3]) ?? 1; checked = parts[4] == "1"; language = parts[5]
  }
  var prefix: String {
    switch kind {
    case "bullet": "•\t"
    case "ordered": "\(ordinal).\t"
    case "task": checked ? "☑\t" : "☐\t"
    case "quote": "│\t"
    default: ""
    }
  }
  var isList: Bool { ["bullet", "ordered", "task"].contains(kind) }
}

/// Converts the editable native attributed document to portable Markdown. Unknown
/// syntax is retained as literal text; opening a note never writes this projection.
@MainActor
enum RichNoteCodec {
  struct Document {
    let text: NSAttributedString
    let trailingAttributes: [NSAttributedString.Key: Any]
  }
  static func attributes(_ block: RichNoteBlock = RichNoteBlock(), inline: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
    var result = inline
    result[.noteBlock] = block.value
    let code = block.kind == "code" || inline[.noteInlineCode] as? Bool == true
    let size: CGFloat = block.kind == "heading" ? (block.level == 1 ? 24 : block.level == 2 ? 20 : 16) : 14
    var font = code ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: size)
    if block.kind == "heading" || inline[.noteBold] as? Bool == true { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    if inline[.noteItalic] as? Bool == true { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    result[.font] = font
    result[.foregroundColor] = inline[.link] == nil ? NSColor.textColor : NSColor.linkColor
    if inline[.noteStrike] as? Bool == true { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    else { result.removeValue(forKey: .strikethroughStyle) }
    if code { result[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.10) }
    else { result.removeValue(forKey: .backgroundColor) }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 4; paragraph.paragraphSpacing = block.kind == "heading" ? 8 : 4
    paragraph.firstLineHeadIndent = CGFloat(block.depth * 20)
    paragraph.headIndent = paragraph.firstLineHeadIndent + (block.prefix.isEmpty ? 0 : 24)
    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
    result[.paragraphStyle] = paragraph
    return result
  }
  static func safeLink(_ value: String) -> URL? {
    guard let url = URL(string: value), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    if url.scheme?.lowercased() == "mailto" { guard !url.path.isEmpty else { return nil } }
    else { guard let host = url.host, !host.isEmpty else { return nil } }
    return url
  }
  static func inline(_ source: String, block: RichNoteBlock) -> NSAttributedString {
    guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
      return NSAttributedString(string: source, attributes: attributes(block))
    }
    let result = NSMutableAttributedString(string: "")
    for run in parsed.runs {
      var semantic: [NSAttributedString.Key: Any] = [:]
      let intent = run.inlinePresentationIntent
      if intent?.contains(.stronglyEmphasized) == true { semantic[.noteBold] = true }
      if intent?.contains(.emphasized) == true { semantic[.noteItalic] = true }
      if intent?.contains(.strikethrough) == true { semantic[.noteStrike] = true }
      if intent?.contains(.code) == true { semantic[.noteInlineCode] = true }
      if let link = run.link {
        semantic[.noteLinkDestination] = link.absoluteString
        if let safe = safeLink(link.absoluteString) { semantic[.link] = safe }
      }
      // Keep the image destination for backup without loading or displaying an attachment.
      if let image = run.imageURL { semantic[.noteImage] = image.absoluteString }
      result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes(block, inline: semantic)))
    }
    return result
  }
  static func decode(_ source: String) -> Document {
    let lines = source.components(separatedBy: "\n")
    let result = NSMutableAttributedString(string: "")
    var last = attributes(), emitted = false, index = 0
    func append(_ text: NSAttributedString, block: RichNoteBlock) {
      if emitted { result.append(NSAttributedString(string: "\n", attributes: last)) }
      last = attributes(block); result.append(text); emitted = true
    }
    while index < lines.count {
      let line = lines[index]
      if let match = captures(#"^ {0,3}(`{3,}|~{3,})([^`~]*)$"#, line) {
        let fence = match[1]; var block = RichNoteBlock("code"); block.language = match[2].trimmingCharacters(in: .whitespaces)
        index += 1; var count = 0
        while index < lines.count {
          let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
          if trimmed.count >= fence.count && trimmed.allSatisfy({ $0 == fence.first! }) { index += 1; break }
          append(NSAttributedString(string: lines[index], attributes: attributes(block)), block: block)
          index += 1; count += 1
        }
        if count == 0 { append(NSAttributedString(string: ""), block: block) }
        continue
      }
      let (block, content) = parseLine(line)
      let rendered = NSMutableAttributedString(string: block.prefix, attributes: attributes(block))
      rendered.append(block.kind == "rule" ? NSAttributedString(string: "────────", attributes: attributes(block)) : inline(content, block: block))
      append(rendered, block: block); index += 1
    }
    return Document(text: result, trailingAttributes: last)
  }
  static func parseLine(_ source: String) -> (RichNoteBlock, String) {
    if let match = captures(#"^(#{1,6})[ \t]+(.*)$"#, source) {
      var block = RichNoteBlock("heading"); block.level = match[1].count
      return (block, match[2].replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression))
    }
    if let match = captures(#"^( *)[-+*] +\[([ xX])\] +(.*)$"#, source) {
      var block = RichNoteBlock("task"); block.depth = match[1].count / 2; block.checked = match[2].lowercased() == "x"
      return (block, match[3])
    }
    if source.range(of: #"^ {0,3}(?:[-*_] *){3,}$"#, options: .regularExpression) != nil { return (RichNoteBlock("rule"), "") }
    if let match = captures(#"^( *)[-+*][ \t]+(.*)$"#, source) {
      var block = RichNoteBlock("bullet"); block.depth = match[1].count / 2; return (block, match[2])
    }
    if let match = captures(#"^( *)(\d+)[.)][ \t]+(.*)$"#, source) {
      var block = RichNoteBlock("ordered"); block.depth = match[1].count / 2; block.ordinal = Int(match[2]) ?? 1
      return (block, match[3])
    }
    if let match = captures(#"^>[ \t]?(.*)$"#, source) { return (RichNoteBlock("quote"), match[1]) }
    return (RichNoteBlock(), source)
  }
  static func markdown(_ text: NSAttributedString, trailing: [NSAttributedString.Key: Any]) -> String {
    let source = text.string as NSString
    var lines: [(RichNoteBlock, String)] = [], start = 0
    for line in text.string.components(separatedBy: "\n") {
      let length = (line as NSString).length
      let attrs = start < text.length ? text.attributes(at: start, effectiveRange: nil) : trailing
      var block = RichNoteBlock(attributes: attrs)
      let prefix = block.prefix
      var offset = 0
      if !prefix.isEmpty {
        if line.hasPrefix(prefix) { offset = (prefix as NSString).length }
        else { block = RichNoteBlock() }
      }
      let range = NSRange(location: start + offset, length: max(0, length - offset))
      let content = block.kind == "code" ? source.substring(with: range) : encodeInline(text.attributedSubstring(from: range))
      lines.append((block, content)); start += length + 1
    }
    var output: [String] = [], index = 0
    while index < lines.count {
      let (block, content) = lines[index]
      if block.kind == "code" {
        var code: [String] = [], language = block.language
        while index < lines.count, lines[index].0.kind == "code", lines[index].0.language == language {
          code.append(lines[index].1); index += 1
        }
        language = language.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\n", with: "")
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(code.joined(separator: "\n")) + 1))
        output.append(fence + language); output.append(contentsOf: code); output.append(fence); continue
      }
      let indent = String(repeating: "  ", count: max(0, block.depth))
      switch block.kind {
      case "heading": output.append(String(repeating: "#", count: min(6, max(1, block.level))) + " " + content)
      case "bullet": output.append(indent + "- " + content)
      case "ordered": output.append(indent + "\(block.ordinal). " + content)
      case "task": output.append(indent + (block.checked ? "- [x] " : "- [ ] ") + content)
      case "quote": output.append("> " + content)
      case "rule": output.append("---")
      default: output.append(content)
      }
      index += 1
    }
    return output.joined(separator: "\n")
  }
  static func encodeInline(_ text: NSAttributedString) -> String {
    // TextKit can split a semantic span for fallback fonts (e.g. emoji). Merge
    // semantic attributes first, then balance nested delimiters across spans.
    let normalized = NSMutableAttributedString(string: "")
    text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
      var semantic: [NSAttributedString.Key: Any] = [:]
      for key in [NSAttributedString.Key.noteBold, .noteItalic, .noteStrike, .noteInlineCode] where attrs[key] as? Bool == true { semantic[key] = true }
      for key in [NSAttributedString.Key.noteImage, .noteLinkDestination, .link] { semantic[key] = attrs[key] }
      normalized.append(NSAttributedString(string: (text.string as NSString).substring(with: range), attributes: semantic))
    }
    struct Marker: Equatable { let open: String; let close: String }
    var output = "", active: [Marker] = []
    func emit(_ value: String, markers: [Marker]) {
      var common = 0
      while common < min(active.count, markers.count), active[common] == markers[common] { common += 1 }
      for marker in active.dropFirst(common).reversed() { output += marker.close }
      for marker in markers.dropFirst(common) { output += marker.open }
      output += value; active = markers
    }
    normalized.enumerateAttributes(in: NSRange(location: 0, length: normalized.length)) { attrs, range, _ in
      let raw = (normalized.string as NSString).substring(with: range)
      let leading = String(raw.prefix(while: \.isWhitespace)), trailing = String(raw.reversed().prefix(while: \.isWhitespace).reversed())
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { emit(raw, markers: []); return }
      if !leading.isEmpty { emit(leading, markers: []) }
      var markers: [Marker] = []
      if let image = attrs[.noteImage] as? String { markers.append(Marker(open: "![", close: "](\(destination(image)))")) }
      else if let link = (attrs[.link] as? URL)?.absoluteString ?? attrs[.noteLinkDestination] as? String {
        markers.append(Marker(open: "[", close: "](\(destination(link)))"))
      }
      if attrs[.noteStrike] as? Bool == true { markers.append(Marker(open: "~~", close: "~~")) }
      if attrs[.noteBold] as? Bool == true { markers.append(Marker(open: "**", close: "**")) }
      if attrs[.noteItalic] as? Bool == true { markers.append(Marker(open: "*", close: "*")) }
      var content = escape(trimmed)
      if attrs[.noteInlineCode] as? Bool == true {
        let fence = String(repeating: "`", count: max(1, longestBacktickRun(trimmed) + 1))
        let padding = trimmed.hasPrefix("`") || trimmed.hasSuffix("`") ? " " : ""
        markers.append(Marker(open: fence + padding, close: padding + fence)); content = trimmed
      }
      emit(content, markers: markers)
      if !trailing.isEmpty { emit(trailing, markers: []) }
    }
    emit("", markers: [])
    return output
  }
  static func escape(_ text: String) -> String {
    text.reduce(into: "") { result, character in
      if #"\`*_{}[]<>#+-.!~|"#.contains(character) { result.append("\\") }
      result.append(character)
    }
  }
  private static func destination(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "%5C").replacingOccurrences(of: "(", with: "%28")
      .replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")
  }
  static func longestBacktickRun(_ source: String) -> Int {
    var longest = 0, current = 0
    for character in source { current = character == "`" ? current + 1 : 0; longest = max(longest, current) }
    return longest
  }
  static func captures(_ pattern: String, _ source: String) -> [String]? {
    let text = source as NSString
    guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: text.length)) else { return nil }
    return (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : text.substring(with: match.range(at: $0)) }
  }
}
