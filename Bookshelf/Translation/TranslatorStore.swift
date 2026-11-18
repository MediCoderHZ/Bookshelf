import Foundation
import Observation

@MainActor
@Observable
final class TranslatorStore {
  private(set) var rules: [TranslatorRule] = []
  private(set) var diagnostics: [String] = []
  private(set) var revision = 0
  private let prepareDirectory: () throws -> Void
  let directory: URL
  private var scripts: [TranslatorScript] = []
  private var files: [String: URL] = [:]
  private var duplicatedIDs: Set<String> = []
  private let defaults: UserDefaults
  private var enabled: [String: Bool] = [:]
  private var customTranslators: [RuleBasedWebTranslator] = []

  init(directory: URL, defaults: UserDefaults = .standard, prepareDirectory: @escaping () throws -> Void = {}) {
    self.directory = directory
    self.prepareDirectory = prepareDirectory
    self.defaults = defaults
    // Preserve the user's preference from the previous, single-site implementation.
    if defaults.object(forKey: "translator.enabled.douban-books") == nil,
      let previous = defaults.object(forKey: "translator.douban.enabled") as? Bool {
      defaults.set(previous, forKey: "translator.enabled.douban-books")
    }
    reload()
  }

  var descriptors: [TranslatorDescriptor] { catalog.translators.map(\.descriptor).sorted { $0.name < $1.name } }

  var catalog: TranslatorRegistry {
    TranslatorRegistry(translators: scripts.map(BuiltinTranslators.translator(for:)) + customTranslators,
      disabledIDs: Set(enabled.filter { !$0.value }.map(\.key)))
  }
  var registry: WebTranslatorRegistry { catalog.webRegistry }

  func isEnabled(_ id: String) -> Bool { enabled[id] ?? true }
  func isBuiltin(_ id: String) -> Bool { TranslatorScript.bundled.contains { $0.id == id } }

  func scriptFile(for id: String) -> URL? { scripts.first { $0.id == id }?.file }

  func setEnabled(_ value: Bool, for id: String) {
    enabled[id] = value
    defaults.set(value, forKey: "translator.enabled.\(id)")
    revision += 1
  }

  func install(_ rule: TranslatorRule) throws {
    try rule.validate()
    guard !isBuiltin(rule.id) else { throw WebMetadataError.invalidConfiguration(L10n.tr("内置解析器 ID 不可覆盖，请使用新的 ID")) }
    reload()
    let url = files[rule.id] ?? directory.appendingPathComponent(rule.id + ".json")
    guard !duplicatedIDs.contains(rule.id), files[rule.id] != nil || !FileManager.default.fileExists(atPath: url.path)
    else { throw WebMetadataError.invalidConfiguration(L10n.tr("规则 ID 或文件名冲突，请在解析器目录中核对文件。")) }
    let data = try rule.encoded()
    guard data.count <= 256 * 1024 else { throw WebMetadataError.invalidConfiguration(L10n.tr("规则文件不能超过 256 KB")) }
    try ensureDirectory()
    try data.write(to: url, options: .atomic)
    reload()
  }

  func ensureDirectory() throws {
    try prepareDirectory()
    try LibraryTranslatorDirectory.ensure(directory)
  }

  func remove(_ id: String) throws {
    reload()
    guard let url = files[id] else { throw WebMetadataError.invalidConfiguration(L10n.tr("解析规则已更改，请重新加载。")) }
    try FileManager.default.removeItem(at: url)
    defaults.removeObject(forKey: "translator.enabled.\(id)")
    reload()
  }

  func reload() {
    var loaded: [String: TranslatorRule] = [:]
    var sources: [String: URL] = [:]
    var duplicates: Set<String> = []
    var problems: [String] = []
    var nextScripts: [TranslatorScript] = []
    do {
      try ensureDirectory()
      for seed in TranslatorScript.bundled {
        do { nextScripts.append(try seed.installed(in: directory, defaults: defaults)) }
        catch { problems.append("\(seed.id).js：\(error.localizedDescription)") }
      }
      let urls = try FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
      for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension.lowercased() == "json" {
        do {
          guard case .translator(let rule) = try ExtensionFile.read(from: url) else {
            throw WebMetadataError.invalidConfiguration(L10n.tr("笔记模板由插件窗口管理。"))
          }
          guard !isBuiltin(rule.id) else { throw WebMetadataError.invalidConfiguration(L10n.tr("此 ID 属于内置解析器，请修改 ID")) }
          if let first = sources[rule.id] {
            duplicates.insert(rule.id)
            throw WebMetadataError.invalidConfiguration(L10n.tr("与文件“\(first.lastPathComponent)”的解析器 ID 重复。"))
          }
          sources[rule.id] = url
          loaded[rule.id] = rule
        } catch { problems.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
      }
    } catch { problems.append(L10n.tr("无法读取解析器目录：\(error.localizedDescription)")) }
    for id in duplicates { loaded.removeValue(forKey: id); sources.removeValue(forKey: id) }
    files = sources
    duplicatedIDs = duplicates
    let nextRules = loaded.values.sorted { $0.id < $1.id }
    let nextEnabled = Dictionary(uniqueKeysWithValues: (nextScripts.map(\.id) + nextRules.map(\.id)).map {
      ($0, defaults.object(forKey: "translator.enabled.\($0)") as? Bool ?? true)
    })
    diagnostics = problems
    guard nextRules != rules || nextEnabled != enabled || nextScripts.map(\.fingerprint) != scripts.map(\.fingerprint) else { return }
    scripts = nextScripts
    rules = nextRules
    customTranslators = nextRules.compactMap { try? RuleBasedWebTranslator(rule: $0) }
    enabled = nextEnabled
    revision += 1
  }
}
