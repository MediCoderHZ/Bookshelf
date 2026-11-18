import Foundation
import Observation

@MainActor
@Observable
final class PluginStore {
  static let shared = PluginStore(legacyDirectory: LibraryTranslatorDirectory.legacy,
    exampleURL: L10n.resourceBundle.url(forResource: "reading-notes", withExtension: "bookshelfplugin"))
  private(set) var noteTemplates: [NoteTemplatePlugin] = []
  private(set) var diagnostics: [String] = []
  private let directory: URL
  private var pendingLegacyDirectory: URL?
  private let defaults: UserDefaults
  let exampleURL: URL?
  private var enabled: [String: Bool] = [:]

  init(directory: URL? = nil, defaults: UserDefaults = .standard, legacyDirectory: URL? = nil, exampleURL: URL? = nil) {
    self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Bookshelf/Plugins", isDirectory: true)
    self.pendingLegacyDirectory = defaults.bool(forKey: "plugins.separatedTemplates.v1") ? nil : legacyDirectory
    self.defaults = defaults
    self.exampleURL = exampleURL
    reload()
    if pendingLegacyDirectory == nil, let exampleURL, !defaults.bool(forKey: "plugins.didOfferReadingNotes.v1") {
      do {
        let example = try NoteTemplatePlugin.read(from: exampleURL)
        if !FileManager.default.fileExists(atPath: file(for: example.id).path) { try install(example) }
        defaults.set(true, forKey: "plugins.didOfferReadingNotes.v1")
      } catch { diagnostics.append(error.localizedDescription) }
    }
  }

  var enabledTemplates: [NoteTemplatePlugin] { noteTemplates.filter { isEnabled($0.id) } }
  func isEnabled(_ id: String) -> Bool { enabled[id] ?? true }

  func setEnabled(_ value: Bool, for id: String) {
    enabled[id] = value
    defaults.set(value, forKey: "plugin.enabled.\(id)")
  }

  private func file(for id: String) -> URL { directory.appendingPathComponent(id + ".json") }

  func install(_ template: NoteTemplatePlugin) throws {
    try template.validate()
    let data = try JSONEncoder().encode(template)
    guard data.count <= 256 * 1024 else { throw WebMetadataError.invalidConfiguration(L10n.tr("文件超过 256 KB")) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: file(for: template.id), options: .atomic)
    reload()
  }

  func remove(_ id: String) throws {
    guard noteTemplates.contains(where: { $0.id == id }) else { return }
    try FileManager.default.removeItem(at: file(for: id))
    defaults.removeObject(forKey: "plugin.enabled.\(id)")
    reload()
  }

  func reload() {
    var loaded: [NoteTemplatePlugin] = []
    var problems: [String] = []
    let manager = FileManager.default
    if let legacy = pendingLegacyDirectory {
      do {
        if manager.fileExists(atPath: legacy.path) { try migrateTemplates(from: legacy, problems: &problems) }
        if problems.isEmpty {
          defaults.set(true, forKey: "plugins.separatedTemplates.v1")
          pendingLegacyDirectory = nil
        }
      } catch { problems.append(error.localizedDescription) }
    }
    do {
      if manager.fileExists(atPath: directory.path) {
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
          where url.pathExtension == "json" {
          do {
            let template = try NoteTemplatePlugin.read(from: url)
            guard url.lastPathComponent == template.id + ".json" else {
              throw WebMetadataError.invalidConfiguration(L10n.tr("文件名与 ID 不一致或 ID 已占用"))
            }
            loaded.append(template)
          } catch { problems.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
      }
    } catch { problems.append(error.localizedDescription) }
    noteTemplates = loaded.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    diagnostics = problems
    enabled = Dictionary(uniqueKeysWithValues: loaded.map {
      ($0.id, defaults.object(forKey: "plugin.enabled.\($0.id)") as? Bool ?? true)
    })
  }

  private func migrateTemplates(from legacy: URL, problems: inout [String]) throws {
    let manager = FileManager.default
    let urls = try manager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    for url in urls where url.pathExtension == "json" {
      guard let template = try? NoteTemplatePlugin.read(from: url), url.lastPathComponent == template.id + ".json" else { continue }
      do {
        var destination = file(for: template.id)
        if manager.fileExists(atPath: destination.path) {
          // Preserve both copies if someone already installed a template in the new directory.
          destination = directory.appendingPathComponent("Previous").appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(url.lastPathComponent)
        } else if let previous = defaults.object(forKey: "translator.enabled.\(template.id)") as? Bool,
          defaults.object(forKey: "plugin.enabled.\(template.id)") == nil {
          defaults.set(previous, forKey: "plugin.enabled.\(template.id)")
        }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: url, to: destination)
        defaults.removeObject(forKey: "translator.enabled.\(template.id)")
      } catch { problems.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
    }
  }
}
