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
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
  @Published private(set) var canCheckForUpdates = true
  @Published private(set) var isAvailable = false
  @Published private(set) var automaticallyChecksForUpdates = false
  @Published private(set) var automaticallyDownloadsUpdates = false
  @Published private(set) var installationPaused = false
  private let backups: AutomaticBackupController?
  private var pendingInstall: (() -> Void)?
  private var controller: SPUStandardUpdaterController?
  private var startupError: String?
  private var unavailableMessage: String {
    if let startupError {
      return L10n.tr("暂时无法启用在线更新，请前往项目发布页面获取新版。\n\(startupError)")
    }
    return L10n.tr("此版本尚未启用在线更新。你可以前往项目发布页面获取新版。")
  }

  init(bundle: Bundle = .main, backups: AutomaticBackupController? = nil) {
    self.backups = backups
    super.init()
    // SwiftPM test executables are not application bundles and must not start an updater.
    guard bundle.bundleURL.pathExtension == "app",
      (try? AppUpdateConfiguration(info: bundle.infoDictionary ?? [:])) != nil
    else { return }

    let candidate = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
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
      startupError = error.localizedDescription
    }
  }

  func checkForUpdates() {
    if installationPaused { retryInstallation(); return }
    if let controller {
      guard canCheckForUpdates else { return }
      controller.checkForUpdates(nil)
    } else {
      let alert = NSAlert()
      alert.messageText = L10n.tr("软件更新")
      alert.informativeText = unavailableMessage
      alert.addButton(withTitle: L10n.tr("好"))
      alert.runModal()
    }
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    controller?.updater.automaticallyChecksForUpdates = enabled
  }

  func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
    controller?.updater.automaticallyDownloadsUpdates = enabled
  }

  func prepareUpdateBackup() throws {
    guard let backups else { throw AutomaticBackupError.unavailable }
    try backups.prepareForUpdate()
  }

  func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
    updateCheck: SPUUpdateCheck) throws {
    try prepareUpdateBackup()
  }

  func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
    do { try prepareUpdateBackup(); return false }
    catch { pendingInstall = installHandler; installationPaused = true; return true }
  }

  func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
    backups?.upgradePending = true
    return false // The application termination delegate performs the final backup.
  }

  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    backups?.upgradePending = true
  }

  func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
    forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
    if choice == .skip || (choice == .dismiss && state.stage != .installing) { cancelPendingUpdate() }
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { cancelPendingUpdate() }

  func cancelPendingUpdate() {
    pendingInstall = nil; installationPaused = false; backups?.upgradePending = false
  }

  func retryInstallation() {
    guard let install = pendingInstall else { return }
    do {
      try prepareUpdateBackup()
      pendingInstall = nil; installationPaused = false
      install()
    } catch { /* Keep the install deferred and expose the backup error in Settings. */ }
  }
}

struct AppUpdateCommands: Commands {
  @ObservedObject var updater: AppUpdater

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button(L10n.tr("检查更新…"), action: updater.checkForUpdates)
        .disabled(!updater.canCheckForUpdates)
    }
  }
}
