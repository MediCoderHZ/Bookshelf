import Foundation
import Observation

@MainActor
@Observable
final class TranslatorStore {
  static let shared = TranslatorStore()
  private(set) var rules: [TranslatorRule] = []
  private(set) var diagnostics: [String] = []
  private(set) var revision = 0
  private let directory: URL
  private let defaults: UserDefaults
  private var enabled: [String: Bool] = [:]
  private var customTranslators: [RuleBasedWebTranslator] = []

  init(directory: URL? = nil, defaults: UserDefaults = .standard) {
    self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Bookshelf/Translators", isDirectory: true)
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
    TranslatorRegistry(translators: BuiltinTranslators.catalog + customTranslators,
      disabledIDs: Set(enabled.filter { !$0.value }.map(\.key)))
  }
  var registry: WebTranslatorRegistry { catalog.webRegistry }

  func isEnabled(_ id: String) -> Bool { enabled[id] ?? true }
  func isBuiltin(_ id: String) -> Bool { BuiltinTranslators.catalog.contains { $0.descriptor.id == id } }

  func setEnabled(_ value: Bool, for id: String) {
    enabled[id] = value
    defaults.set(value, forKey: "translator.enabled.\(id)")
    revision += 1
  }

  func install(_ rule: TranslatorRule) throws {
    try rule.validate()
    guard !isBuiltin(rule.id) else { throw WebMetadataError.invalidConfiguration(L10n.tr("内置解析器 ID 不可覆盖，请使用新的 ID")) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try rule.encoded().write(to: directory.appendingPathComponent(rule.id + ".json"), options: .atomic)
    reload()
  }

  func remove(_ id: String) throws {
    guard rules.contains(where: { $0.id == id }), !isBuiltin(id) else { return }
    try FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".json"))
    defaults.removeObject(forKey: "translator.enabled.\(id)")
    reload()
  }

  func reload() {
    var loaded: [TranslatorRule] = []
    var problems: [String] = []
    if FileManager.default.fileExists(atPath: directory.path) {
      do {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
          includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]).filter { $0.pathExtension == "json" }
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
          do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256 * 1_024 else {
              throw WebMetadataError.invalidConfiguration(L10n.tr("文件超过 256 KB"))
            }
            let rule = try TranslatorRule.decode(Data(contentsOf: url))
            guard url.lastPathComponent == rule.id + ".json", !isBuiltin(rule.id),
              !loaded.contains(where: { $0.id == rule.id }) else {
              throw WebMetadataError.invalidConfiguration(L10n.tr("文件名与 ID 不一致或 ID 已占用"))
            }
            loaded.append(rule)
          } catch { problems.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
      } catch { problems.append(L10n.tr("无法读取解析器目录：\(error.localizedDescription)")) }
    }
    rules = loaded
    customTranslators = loaded.compactMap { try? RuleBasedWebTranslator(rule: $0) }
    diagnostics = problems
    enabled = Dictionary(uniqueKeysWithValues: (BuiltinTranslators.catalog.map(\.descriptor.id) + loaded.map(\.id)).map {
      ($0, defaults.object(forKey: "translator.enabled.\($0)") as? Bool ?? true)
    })
    revision += 1
  }
}
