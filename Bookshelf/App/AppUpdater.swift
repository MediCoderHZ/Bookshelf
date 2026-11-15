import AppKit
import Combine
import Sparkle
import SwiftUI

/// Reject incomplete release settings before Sparkle can make any network requests.
struct AppUpdateConfiguration {
  enum ConfigurationError: Error, Equatable {
    case disabled, invalidFeed, invalidPublicKey
  }

  let feedURL: URL
  let publicKey: String

  init(info: [String: Any]) throws {
    guard (info["BookshelfUpdatesEnabled"] as? String)?.uppercased() == "YES" else {
      throw ConfigurationError.disabled
    }
    guard let feed = info["SUFeedURL"] as? String,
      !feed.contains("$("), !feed.contains("REPLACE"),
      let url = URL(string: feed), url.scheme == "https",
      let host = url.host, !host.isEmpty, host != "example.com",
      url.user == nil, url.password == nil, url.fragment == nil
    else { throw ConfigurationError.invalidFeed }
    guard let key = info["SUPublicEDKey"] as? String,
      let bytes = Data(base64Encoded: key), bytes.count == 32,
      bytes.base64EncodedString() == key
    else { throw ConfigurationError.invalidPublicKey }
    feedURL = url
    publicKey = key
  }
}

@MainActor
final class AppUpdater: ObservableObject {
  @Published private(set) var canCheckForUpdates = true
  @Published private(set) var isAvailable = false
  @Published private(set) var automaticallyChecksForUpdates = false
  @Published private(set) var automaticallyDownloadsUpdates = false
  private var controller: SPUStandardUpdaterController?
  private var unavailableMessage = "此版本尚未启用在线更新。你可以前往项目发布页面获取新版。"

  init(bundle: Bundle = .main) {
    // SwiftPM test executables are not application bundles and must not start an updater.
    guard bundle.bundleURL.pathExtension == "app",
      (try? AppUpdateConfiguration(info: bundle.infoDictionary ?? [:])) != nil
    else { return }

    let candidate = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    do {
      try candidate.updater.start()
      controller = candidate
      isAvailable = true
      candidate.updater.publisher(for: \.canCheckForUpdates)
        .assign(to: &$canCheckForUpdates)
      candidate.updater.publisher(for: \.automaticallyChecksForUpdates)
        .assign(to: &$automaticallyChecksForUpdates)
      candidate.updater.publisher(for: \.automaticallyDownloadsUpdates)
        .assign(to: &$automaticallyDownloadsUpdates)
    } catch {
      unavailableMessage = "暂时无法启用在线更新，请前往项目发布页面获取新版。\n\(error.localizedDescription)"
    }
  }

  func checkForUpdates() {
    if let controller {
      guard canCheckForUpdates else { return }
      controller.checkForUpdates(nil)
    } else {
      let alert = NSAlert()
      alert.messageText = "软件更新"
      alert.informativeText = unavailableMessage
      alert.addButton(withTitle: "好")
      alert.runModal()
    }
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    controller?.updater.automaticallyChecksForUpdates = enabled
  }

  func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
    controller?.updater.automaticallyDownloadsUpdates = enabled
  }
}

struct AppUpdateCommands: Commands {
  @ObservedObject var updater: AppUpdater

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("检查更新…", action: updater.checkForUpdates)
        .disabled(!updater.canCheckForUpdates)
    }
  }
}

struct AppUpdateSettings: View {
  @ObservedObject var updater: AppUpdater

  var body: some View {
    Section("软件更新") {
      Toggle("自动检查更新", isOn: Binding(
        get: { updater.automaticallyChecksForUpdates },
        set: updater.setAutomaticallyChecksForUpdates))
        .disabled(!updater.isAvailable)
      Toggle("自动下载并安装更新", isOn: Binding(
        get: { updater.automaticallyDownloadsUpdates },
        set: updater.setAutomaticallyDownloadsUpdates))
        .disabled(!updater.isAvailable || !updater.automaticallyChecksForUpdates)
      HStack {
        Button("检查更新…", action: updater.checkForUpdates)
          .disabled(!updater.canCheckForUpdates)
        Link("版本与下载", destination: URL(string: "https://github.com/MediCoderHZ/Bookshelf/releases")!)
      }
      if !updater.isAvailable {
        Text("此版本尚未启用在线更新。").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
