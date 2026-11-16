import Combine
import Foundation
import SwiftData

@MainActor
final class AutomaticBackupController: ObservableObject {
  @Published var isEnabled: Bool { didSet { preferences.set(isEnabled, forKey: "automaticBackup.enabled"); if isEnabled { checkIfDue() } } }
  @Published var intervalHours: Int { didSet { preferences.set(intervalHours, forKey: "automaticBackup.hours"); checkIfDue() } }
  @Published var retentionCount: Int { didSet { preferences.set(retentionCount, forKey: "automaticBackup.retention") } }
  @Published private(set) var entries: [AutomaticBackupManifest] = []
  @Published private(set) var lastError: String?
  @Published private(set) var cleanupWarning: String?
  var upgradePending = false
  let store: AutomaticBackupStore
  private let preferences: UserDefaults
  private let appVersion: String
  private let recoveryRoot: URL?
  private var context: ModelContext?
  private var storeURL: URL?
  private var timer: Task<Void, Never>?
  private var lastRegularBackup: Date? { entries.first { !$0.kind.isUpgrade }?.date }
  var lastBackup: Date? { entries.first?.date }
  var nextBackup: Date? { isEnabled ? (lastRegularBackup?.addingTimeInterval(Double(intervalHours) * 3600) ?? Date()) : nil }

  init(directory: URL = AutomaticBackupStore.defaultDirectory, preferences: UserDefaults = .standard,
    appVersion: String, recoveryRoot: URL? = nil) {
    store = AutomaticBackupStore(directory: directory)
    self.preferences = preferences; self.appVersion = appVersion; self.recoveryRoot = recoveryRoot
    isEnabled = preferences.object(forKey: "automaticBackup.enabled") as? Bool ?? true
    let hours = preferences.integer(forKey: "automaticBackup.hours")
    intervalHours = [1, 6, 24].contains(hours) ? hours : 1
    let count = preferences.integer(forKey: "automaticBackup.retention")
    retentionCount = [7, 30, 90].contains(count) ? count : 30
    refresh()
  }

  /// This runs BEFORE ModelContainer can migrate an existing store. Failure
  /// propagates to the non-destructive storage error screen, never an empty store.
  func prepareToOpenStore(at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path),
      preferences.string(forKey: "automaticBackup.lastOpenedVersion") != appVersion else { return }
    do {
      _ = try store.create(kind: .beforeMigration, data: nil, storeURL: url, recoveryRoot: recoveryRoot, appVersion: appVersion)
      refresh()
    } catch {
      lastError = L10n.tr("数据库升级前备份失败，已停止打开书库：") + error.localizedDescription
      throw error
    }
  }

  func attach(context: ModelContext, storeURL: URL?) {
    self.context = context; self.storeURL = storeURL
    preferences.set(appVersion, forKey: "automaticBackup.lastOpenedVersion")
  }
  func start() {
    guard timer == nil else { return }
    checkIfDue()
    timer = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
        self?.checkIfDue()
      }
    }
  }
  func stop() { timer?.cancel(); timer = nil }

  func checkIfDue(now: Date = Date()) {
    guard isEnabled, context != nil else { return }
    // Persisted UNIX timestamps may round by a fraction of a microsecond. Use
    // whole seconds so an exactly due backup is not skipped after relaunch.
    if let last = lastRegularBackup, now >= last,
      floor(now.timeIntervalSince1970) < floor(last.timeIntervalSince1970) + Double(intervalHours) * 3600 { return }
    do { _ = try create(kind: .scheduled, now: now) } catch { /* Persistent UI explains the failure; retry next minute. */ }
  }

  @discardableResult
  func create(kind: AutomaticBackupKind = .manual, now: Date = Date()) throws -> AutomaticBackupManifest {
    do {
      guard let context else { throw AutomaticBackupError.unavailable }
      guard !context.hasChanges else { throw AutomaticBackupError.pendingChanges }
      let data = try LibraryBackupService.exportData(from: context)
      let result = try store.create(kind: kind, data: data, storeURL: storeURL, recoveryRoot: recoveryRoot,
        appVersion: appVersion, now: now)
      lastError = nil; cleanupWarning = nil
      do { try store.prune(regularLimit: retentionCount) }
      catch { cleanupWarning = L10n.tr("新备份已保存，但旧版本清理未完成：") + error.localizedDescription }
      refresh()
      return result
    } catch {
      lastError = error.localizedDescription
      throw error
    }
  }

  func prepareForUpdate() throws {
    upgradePending = true
    do { _ = try create(kind: .beforeUpdate) }
    catch {
      throw NSError(domain: "Bookshelf.Backup", code: 1,
        userInfo: [NSLocalizedDescriptionKey: L10n.tr("升级前备份失败，已暂停升级。请检查可用空间和备份目录后重试。\n") + error.localizedDescription])
    }
  }

  func prepareForTermination() throws {
    if upgradePending { try prepareForUpdate() }
  }

  func refresh() {
    do { entries = try store.entries() }
    catch { lastError = L10n.tr("无法读取备份目录：") + error.localizedDescription }
  }
}
