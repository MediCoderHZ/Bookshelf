import Foundation

enum ExtensionFile {
  case translator(TranslatorRule)
  case noteTemplate(NoteTemplatePlugin)

  static let sizeLimit = 256 * 1024

  static func readData(from url: URL, limit: Int = sizeLimit) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("请选择 JSON 插件文件。"))
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw WebMetadataError.invalidConfiguration(L10n.tr("文件超过 256 KB")) }
    return data
  }

  static func read(from url: URL) throws -> Self {
    let data = try readData(from: url)
    struct Header: Decodable { var type: String? }
    switch try JSONDecoder().decode(Header.self, from: data).type {
    case nil, "web-translator": return .translator(try TranslatorRule.decode(data))
    case "note-template":
      let template = try JSONDecoder().decode(NoteTemplatePlugin.self, from: data)
      try template.validate()
      return .noteTemplate(template)
    default: throw WebMetadataError.invalidConfiguration(L10n.tr("不支持此插件类型。"))
    }
  }
}

/// Text-only templates. Substitutions are made in a single pass over the original
/// strings, so a book title containing "{{authors}}" is preserved verbatim.
struct NoteTemplatePlugin: Codable, Identifiable {
  static func read(from url: URL) throws -> Self {
    if url.pathExtension.lowercased() == "bookshelfplugin" { return try NoteTemplatePackage.read(from: url) }
    guard case .noteTemplate(let template) = try ExtensionFile.read(from: url) else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("这是解析规则，请在「设置 → 文件与数据库 → 元信息解析器」中安装。"))
    }
    return template
  }

  struct Content: Codable {
    let name: String
    let title: String
    let body: String
    var description: String?
  }
  let type: String
  let schemaVersion: Int
  let id: String
  let version: String
  let author: String
  let content: [String: Content]
  var icon: String?
  static let readingNotesID = "bookshelf.reading-notes"
  var displayName: String { localized(for: InterfaceLanguagePreferences.shared.language).name }

  func localized(for language: InterfaceLanguage) -> Content {
    // Validation guarantees at least one of the two supported localizations.
    content[language.rawValue] ?? content[InterfaceLanguage.english.rawValue] ?? content[InterfaceLanguage.chinese.rawValue]!
  }

  func validate() throws {
    guard type == "note-template", schemaVersion == 1 else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("不支持的笔记模板格式或版本。"))
    }
    guard id.wholeMatch(of: /[a-z][a-z0-9.-]{2,63}/) != nil else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("ID 须为 3–64 位小写字母、数字、点或连字符，并以字母开头"))
    }
    guard version.count <= 30, version.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("版本须采用 1.0.0 格式"))
    }
    guard icon.map({ $0.count <= 80 && $0.wholeMatch(of: /[a-z0-9.]+/) != nil }) ?? true else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("插件图标须使用系统符号名称。"))
    }
    guard !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, author.count <= 100,
      !content.isEmpty, Set(content.keys).isSubset(of: InterfaceLanguage.allCases.map(\.rawValue)) else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("请填写插件作者，并提供简体中文或英文模板。"))
    }
    for value in content.values {
      guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.name.count <= 100,
        !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.title.count <= 240,
        !value.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.body.utf8.count <= 32_768,
        (value.description?.count ?? 0) <= 240 else {
        throw WebMetadataError.invalidConfiguration(L10n.tr("请检查模板名称、标题和正文的长度。"))
      }
      for text in [value.title, value.body] {
        let stripped = text.replacing(/\{\{(title|authors|publisher|isbn)\}\}/, with: "")
        guard !stripped.contains("{{"), !stripped.contains("}}") else {
          throw WebMetadataError.invalidConfiguration(L10n.tr("模板含有未知或不完整的字段占位符。"))
        }
      }
    }
  }

  func render(_ text: String, fields: [String: String]) -> String {
    text.replacing(/\{\{([a-z]+)\}\}/) { fields[String($0.1)] ?? "" }
  }
}
