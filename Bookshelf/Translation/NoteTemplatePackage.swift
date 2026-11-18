import Foundation

/// A macOS file package. Read only the declared template and install the validated
/// snapshot, so preview, replacement and legacy JSON share the same atomic write.
enum NoteTemplatePackage {
  private struct Manifest: Decodable {
    struct Metadata: Decodable { let name, description: String }
    struct Contributions: Decodable { let noteTemplate: String }
    let manifestVersion: Int
    let id, version, author: String
    let icon: String?
    let locales: [String: Metadata]
    let contributes: Contributions
  }

  private struct TemplateText: Decodable { let title, body: String }

  static func read(from directory: URL) throws -> NoteTemplatePlugin {
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("请选择有效的书架插件包。"))
    }
    let manifestData = try ExtensionFile.readData(from: directory.appendingPathComponent("manifest.json"))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let manifest = try decoder.decode(Manifest.self, from: manifestData)
    guard manifest.manifestVersion == 1 else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("不支持的插件清单版本。"))
    }
    let filename = manifest.contributes.noteTemplate
    guard filename.count <= 128, filename != "manifest.json",
      filename.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9._-]*\.json/) != nil else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("模板文件必须位于插件包的顶层。"))
    }
    let data = try ExtensionFile.readData(from: directory.appendingPathComponent(filename),
      limit: ExtensionFile.sizeLimit - manifestData.count)
    let translations = try decoder.decode([String: TemplateText].self, from: data)
    guard Set(translations.keys) == Set(manifest.locales.keys) else {
      throw WebMetadataError.invalidConfiguration(L10n.tr("插件清单与模板的语言必须一致。"))
    }
    var content: [String: NoteTemplatePlugin.Content] = [:]
    for (language, text) in translations {
      guard let metadata = manifest.locales[language],
        !metadata.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw WebMetadataError.invalidConfiguration(L10n.tr("请填写插件简介。"))
      }
      content[language] = .init(name: metadata.name, title: text.title, body: text.body, description: metadata.description)
    }
    let plugin = NoteTemplatePlugin(type: "note-template", schemaVersion: 1, id: manifest.id,
      version: manifest.version, author: manifest.author, content: content, icon: manifest.icon)
    try plugin.validate()
    return plugin
  }
}
