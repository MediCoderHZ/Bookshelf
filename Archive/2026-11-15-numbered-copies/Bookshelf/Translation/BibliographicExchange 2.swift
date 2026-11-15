import Foundation

enum BibliographicExchangeError: LocalizedError {
  case invalid(String)
  var errorDescription: String? { switch self { case .invalid(let message): message } }
}

struct BibliographicImportResult {
  let records: [BookArchive]
  let totalCount: Int
  let notices: [String]
  var formatName = "RIS"
  var summary: String { "\(formatName) 共 \(totalCount) 条，可导入 \(records.count) 本，跳过 \(totalCount - records.count) 条。" }
}

typealias RISImportResult = BibliographicImportResult

enum BibliographicFormat: String, CaseIterable, Identifiable {
  case ris, csv
  var id: String { rawValue }
  var title: String { self == .ris ? "RIS 书目" : "CSV 清单" }
}

/// Independently implemented interchange subset. No translator scripts or network requests.
@MainActor
enum BibliographicExchange {
  static let maximumImportBytes = 10 * 1024 * 1024
  static let maximumImportRecords = 5_000
  private struct RISField { var tag: String; var value: String }
  private struct RISEntry { let line: Int; var fields: [RISField] }
  private static let supportedTypes: Set<String> = ["BOOK", "EBOOK", "EDBOOK", "CLSWK", "SER"]
  private static let supportedTags: Set<String> = ["TY", "TI", "T1", "AU", "A1", "A2", "A3", "A4", "PB", "DA", "Y1", "PY", "SN", "ET", "SP", "LA", "AB", "N2", "N1", "RN", "KW", "UR", "T2", "T3", "VL", "C1", "C2"]

  static func decodeRIS(_ data: Data) throws -> RISImportResult {
    guard data.count <= maximumImportBytes else { throw BibliographicExchangeError.invalid("RIS 文件不能超过 10 MB，请分批导出。") }
    let text: String?
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16) }
    else { text = String(data: data, encoding: .utf8) }
    guard var text, !text.contains("\0") else { throw BibliographicExchangeError.invalid("无法读取文件编码。请使用 UTF-8，或带 BOM 的 UTF-16 RIS 文件。") }
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let pattern = try NSRegularExpression(pattern: "^([A-Za-z][A-Za-z0-9])[ \\t]{1,2}-(?:[ \\t](.*))?$")
    var entries: [RISEntry] = []
    var current: RISEntry?
    for (offset, line) in text.components(separatedBy: "\n").enumerated() {
      let number = offset + 1
      let range = NSRange(line.startIndex..., in: line)
      if let match = pattern.firstMatch(in: line, range: range) {
        let tag = String(line[Range(match.range(at: 1), in: line)!]).uppercased()
        let value = Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? ""
        if tag == "TY" {
          guard current == nil else { throw malformed(number, "上一条记录缺少 ER 结束标记") }
          current = RISEntry(line: number, fields: [RISField(tag: tag, value: value)])
        } else if tag == "ER" {
          guard let entry = current else { throw malformed(number, "ER 前没有 TY 开始标记") }
          entries.append(entry); current = nil
          guard entries.count <= maximumImportRecords else { throw BibliographicExchangeError.invalid("单次最多导入 5000 条 RIS 记录，请分批导出。") }
        } else {
          guard current != nil else { throw malformed(number, "字段位于 TY / ER 记录之外") }
          current?.fields.append(RISField(tag: tag, value: value))
        }
      } else if current != nil {
        // Indented lines are continuations even when their text resembles RIS tags.
        let continuation = line.hasPrefix("      ") ? String(line.dropFirst(6)) : line
        let index = current!.fields.count - 1
        current!.fields[index].value += "\n" + continuation
      } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw malformed(number, "不是有效的 RIS 记录")
      }
    }
    guard current == nil else { throw malformed(current!.line, "记录缺少 ER 结束标记") }
    var records: [BookArchive] = [], notices: [String] = []
    var noticeCount = 0
    func notice(_ message: String) { noticeCount += 1; if notices.count < 100 { notices.append(message) } }
    for (index, entry) in entries.enumerated() {
      let prefix = "第 \(index + 1) 条（行 \(entry.line)）"
      func values(_ tags: [String]) -> [String] {
        entry.fields.filter { tags.contains($0.tag) }.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      }
      func first(_ tags: [String]) -> String? {
        for tag in tags { if let value = values([tag]).first { return value } }
        return nil
      }
      let type = first(["TY"])?.uppercased() ?? ""
      guard supportedTypes.contains(type) else { notice("\(prefix)：跳过类型 \(type)，目前仅导入整本图书。"); continue }
      guard let title = first(["TI", "T1"]) else { notice("\(prefix)：缺少书名，已跳过。"); continue }
      for tag in ["TI", "T1", "PB", "ET", "LA", "DA", "Y1", "PY", "AB", "N2", "T2", "T3", "VL", "UR", "SP", "C1", "C2"] {
        if Set(values([tag])).count > 1 { notice("\(prefix)：字段 \(tag) 有多个值，仅采用首个值。") }
      }
      var book = BookArchive(book: Book(title: title))
      book.publisher = first(["PB"]); book.edition = first(["ET"]); book.languageCode = first(["LA"])
      // Namespaced custom fields round-trip our categories without changing RIS TY=BOOK.
      if let raw = first(["C1"]) {
        let marker = "Bookshelf.BookType="
        if raw.hasPrefix(marker), let type = BookType(rawValue: String(raw.dropFirst(marker.count))) {
          book.bookTypeRaw = type.rawValue
        } else { notice("\(prefix)：未识别 C1 条目类型扩展，请导入后手动选择。") }
      }
      if let raw = first(["C2"]) {
        let marker = "Bookshelf.OriginalLanguage="
        if raw.hasPrefix(marker) {
          let language = String(raw.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
          book.originalLanguageCode = language.isEmpty ? nil : language
        } else { notice("\(prefix)：未导入其他应用的 C2 扩展字段。") }
      }
      book.publicationDate = first(["DA", "Y1", "PY"]).map(normalizeRISDate)
      book.bookDescription = first(["AB", "N2"])
      let notes = values(["N1", "RN"])
      book.notes = notes.isEmpty ? nil : notes.joined(separator: "\n\n")
      book.tags = uniqueNames(values(["KW"]))
      for (tags, role) in [(["AU", "A1"], ContributorRole.author), (["A2", "A3"], .editor), (["A4"], .translator)] {
        book.contributors += uniqueNames(values(tags)).enumerated().map {
          ContributorArchive(name: $0.element, role: role, order: $0.offset)
        }
      }
      if let series = first(["T2", "T3"]) {
        book.seriesMemberships = [SeriesMembershipArchive(name: series, volume: first(["VL"]))]
      }
      let numbers = values(["SN"])
      let candidates = numbers.flatMap(isbnCandidates)
      var editionKey: String?
      for number in candidates {
        guard let key = ISBN.identity(number) else { continue }
        if let editionKey, editionKey != key { notice("\(prefix)：有多个不同版本的 ISBN，仅采用首个版本。"); continue }
        editionKey = key
        if number.count == 10 { book.isbn10 = number } else { book.isbn13 = number }
      }
      if !numbers.isEmpty && editionKey == nil { notice("\(prefix)：ISBN 无效或无法识别，已留空，请核对原文件。") }
      if let pages = first(["SP"]) {
        if first(["EP"]) == nil, let count = Int(pages), (0...1_000_000).contains(count) { book.pageCount = count }
        else { notice("\(prefix)：页数不是单一整数，已留空。") }
      }
      if let address = first(["UR"]) {
        if let url = publicWebURL(address) { book.metadataSourceURL = url.absoluteString }
        else { notice("\(prefix)：网址不是普通 HTTP(S) 网址，未保存。") }
      }
      book.metadataSourceName = "RIS 文件导入"
      book.metadataRetrievedAt = Date()
      book.metadataFieldSourcesJSON = BookRecordMerge.encodeOrigins(Dictionary(uniqueKeysWithValues:
        BookField.allCases.filter { !$0.value(in: book).isEmpty }.map {
          ($0.rawValue, MetadataFieldOrigin(name: "RIS 文件导入", url: book.metadataSourceURL, retrievedAt: book.metadataRetrievedAt))
        }))
      let ignored = Set(entry.fields.map(\.tag)).subtracting(supportedTags)
      if !ignored.isEmpty { notice("\(prefix)：未导入字段 \(ignored.sorted().joined(separator: "、"))。附件不会读取或下载。") }
      records.append(book)
    }
    if noticeCount > notices.count { notices.append("另有 \(noticeCount - notices.count) 条字段或条目提示；请分批导入以逐一核对。") }
    guard !records.isEmpty else {
      throw BibliographicExchangeError.invalid("未找到可导入的图书。仅支持 BOOK、EBOOK、EDBOOK、CLSWK、SER，且必须有书名。" + (notices.first.map { "\n" + $0 } ?? ""))
    }
    return RISImportResult(records: records, totalCount: entries.count, notices: notices)
  }

  static func export(_ books: [BookArchive], format: BibliographicFormat, includeNotes: Bool = false) -> Data {
    let active = books.filter { $0.deletedAt == nil }
    return format == .ris ? exportRIS(active, includeNotes: includeNotes) : exportCSV(active, includeNotes: includeNotes)
  }

  private static func exportRIS(_ books: [BookArchive], includeNotes: Bool) -> Data {
    var lines: [String] = []
    func emit(_ tag: String, _ value: String?) {
      guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      let parts = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        .replacingOccurrences(of: "\0", with: "").components(separatedBy: "\n")
      lines.append(tag + "  - " + parts[0])
      lines += parts.dropFirst().map { "      " + $0 }
    }
    for book in books {
      emit("TY", "BOOK")
      if let type = book.bookType { emit("C1", "Bookshelf.BookType=" + type.rawValue) }
      if let language = book.originalLanguageCode { emit("C2", "Bookshelf.OriginalLanguage=" + language) }
      emit("TI", book.title + (book.subtitle.map { $0.isEmpty ? "" : ": " + $0 } ?? ""))
      for contributor in book.contributors.sorted(by: { $0.displayOrder < $1.displayOrder }) {
        let tag: String?
        switch ContributorRole(rawValue: contributor.roleRaw) {
        case .author: tag = "AU"; case .translator: tag = "A4"; case .editor: tag = "A2"; default: tag = nil
        }
        if let tag { emit(tag, contributor.name) }
      }
      emit("PB", book.publisher); emit("DA", book.publicationDate); emit("ET", book.edition)
      emit("LA", book.languageCode); emit("SP", book.pageCount.map(String.init))
      emit("SN", book.isbn13); emit("SN", book.isbn10)
      emit("AB", book.bookDescription)
      if let series = book.seriesMemberships.first { emit("T2", series.seriesName); emit("VL", series.volumeLabel) }
      for tag in book.tags { emit("KW", tag) }
      if let raw = book.metadataSourceURL, let url = publicWebURL(raw) { emit("UR", url.absoluteString) }
      if includeNotes { emit("N1", book.notes) }
      lines += ["ER  - ", ""]
    }
    return Data(lines.joined(separator: "\r\n").utf8)
  }

  private static func exportCSV(_ books: [BookArchive], includeNotes: Bool) -> Data {
    var headers = ["书名", "副标题", "原书名", "作者", "译者", "出版社", "出版日期", "版次", "ISBN-13", "ISBN-10", "页数", "语言", "简介", "标签", "书单", "收藏", "来源网址", "条目类型", "原作语言"]
    if includeNotes { headers.append("个人笔记") }
    var rows = [headers.map { csvCell($0) }.joined(separator: ",")]
    for book in books {
      var fields = [book.title, book.subtitle ?? "", book.originalTitle ?? "", BookField.authors.value(in: book), BookField.translators.value(in: book),
        book.publisher ?? "", book.publicationDate ?? "", book.edition ?? "", book.isbn13 ?? "", book.isbn10 ?? "",
        book.pageCount.map(String.init) ?? "", book.languageCode ?? "", book.bookDescription ?? "", book.tags.joined(separator: "、"),
        book.collections.joined(separator: "、"),
        book.isFavorite ? "是" : "否", book.metadataSourceURL ?? "", BookField.bookType.value(in: book), book.originalLanguageCode ?? ""]
      if includeNotes { fields.append(book.notes ?? "") }
      rows.append(fields.enumerated().map { csvCell($0.element, forceText: $0.offset == 8 || $0.offset == 9) }.joined(separator: ","))
    }
    return Data(("\u{FEFF}" + rows.joined(separator: "\r\n") + "\r\n").utf8)
  }

  static func csvCell(_ value: String, forceText: Bool = false) -> String {
    let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
    let dangerous = first.map { "=+-@＝＋－＠".contains($0) } ?? false
    let prefix = !value.isEmpty && (forceText || dangerous || value.hasPrefix("\t") || value.hasPrefix("\r") || value.hasPrefix("\n")) ? "'" : ""
    return "\"" + prefix + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private static func malformed(_ line: Int, _ message: String) -> BibliographicExchangeError {
    .invalid("RIS 第 \(line) 行：\(message)。请修正文件后重新导入；本次未写入书库。")
  }
  private static func uniqueNames(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert(MetadataNormalizer.normalizedName($0)).inserted }
  }
  private static func normalizeRISDate(_ value: String) -> String {
    guard value.range(of: "^[0-9]{4}/[0-9]{0,2}/[0-9]{0,2}/?$", options: .regularExpression) != nil else { return value }
    return value.split(separator: "/").map(String.init).joined(separator: "-")
  }
  private static func publicWebURL(_ text: String) -> URL? {
    guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil, url.user == nil, url.password == nil else { return nil }
    return url
  }
  private static func isbnCandidates(_ text: String) -> [String] {
    let pattern = "(?<![0-9])(?:97[89](?:[ -]?[0-9]){10}|[0-9](?:[ -]?[0-9]){8}[ -]?[0-9Xx])(?![0-9])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      Range($0.range, in: text).flatMap { ISBN.normalized(String(text[$0])) }
    }
  }
}

extension ContributorArchive {
  init(name: String, role: ContributorRole, order: Int) {
    self.name = name; roleRaw = role.rawValue; displayOrder = order
  }
}
extension SeriesMembershipArchive {
  init(name: String, volume: String?) {
    seriesName = name; volumeLabel = volume; displayOrder = 0
  }
}
