import AppKit
import SwiftData
import SwiftUI

@main
struct BookshelfApp: App {
  @NSApplicationDelegateAdaptor(BookshelfLifecycleDelegate.self) private var lifecycle
  @StateObject private var updater: AppUpdater
  @StateObject private var backups: AutomaticBackupController
  @StateObject private var relauncher: AppRelaunchController
  @StateObject private var locations: LibraryLocationController
  private let storage: Result<(container: ModelContainer, translators: TranslatorStore, ai: AIMetadataWorkspace), Error>

  init() {
    _ = PluginStore.shared // Separate legacy note templates before the translator catalog opens.
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let backups = AutomaticBackupController(appVersion: "\(AppReleaseInfo.version) (\(AppReleaseInfo.build))",
      recoveryRoot: support.appendingPathComponent("Bookshelf"))
    _backups = StateObject(wrappedValue: backups)
    let locations = LibraryLocationController(defaultStoreURL: LibraryDatabase.defaultStoreURL,
      configurationURL: support.appendingPathComponent("Bookshelf/LibraryLocation.json"), recoveryRoot: support.appendingPathComponent("Bookshelf"))
    _locations = StateObject(wrappedValue: locations)
    storage = Result {
      RetiredReadingData.cleanPreferences(.standard)
      LibrarySearchScope.migratePreference(in: .standard)
      let container = try locations.openLibrary(backups: backups)
      try SmartCollectionService.retireBookTypeDefaults(in: container.mainContext)
      let translators = TranslatorStore(directory: locations.translatorDirectory, prepareDirectory: locations.migrateLegacyTranslatorsIfNeeded)
      return (container, translators, AIMetadataWorkspace(context: container.mainContext))
    }
    _updater = StateObject(wrappedValue: AppUpdater(backups: backups))
    _relauncher = StateObject(wrappedValue: AppRelaunchController(prepare: {
      guard NSApp.keyWindow?.makeFirstResponder(nil) != false else { throw AutomaticBackupError.pendingChanges }
      if locations.isOpen { _ = try backups.create() }
    }))
    lifecycle.backups = backups
  }

  var body: some Scene {
    WindowGroup(AppReleaseInfo.displayName) {
      Group {
        switch storage {
        case .success(let library):
          LibraryWindowRoot(container: library.container)
            .environment(library.ai)
            .environment(library.translators)
            .safeAreaInset(edge: .bottom) {
              VStack(spacing: 0) {
                if let message = locations.locationError {
                  Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                AutomaticBackupWarning(backups: backups)
              }
            }
            .task { backups.start() }
        case .failure(let error):
          storageFailure(error)
        }
      }.frame(minWidth: 900, minHeight: 620)
        .environment(\.locale, L10n.locale)
    }
    .defaultSize(width: 1380, height: 820)
    .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    .commands {
      AppUpdateCommands(updater: updater)
      PluginCommands()
      LibraryUndoCommands()
      LibraryNewBookCommands()
      LibrarySearchCommands()
      LibraryToolbarCommands()
    }

    Window(Text(L10n.tr("插件")), id: PluginCommands.windowID) {
      PluginManagerView().environment(\.locale, L10n.locale)
    }
    .defaultSize(width: 840, height: 560)

    Window(Text(L10n.tr("元信息解析器")), id: TranslatorSettingsView.windowID) {
      switch storage {
      case .success(let library):
        TranslatorSettingsView().environment(library.translators).environment(\.locale, L10n.locale)
      case .failure(let error):
        storageFailure(error)
      }
    }
    .defaultSize(width: 490, height: 200)

    Settings {
      switch storage {
      case .success(let library):
        LibraryUndoScope {
          SettingsView().environment(library.ai).environmentObject(backups).environmentObject(relauncher)
            .environmentObject(locations)
            .environment(\.locale, L10n.locale)
            .environment(library.translators)
            .modelContainer(library.container)
            .frame(width: 960, height: 700)
        }
      case .failure(let error):
        storageFailure(error).frame(width: 500, height: 340)
      }
    }
  }

  private func storageFailure(_ error: Error) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
      Text(L10n.tr("暂时无法打开本地书库")).font(.title2)
      Text(L10n.tr("应用没有删除或重建你的书库。请先退出并重新打开应用；如果问题持续，请联系支持并提供以下错误信息。"))
        .multilineTextAlignment(.center)
      Text(error.localizedDescription).font(.caption).textSelection(.enabled)
      Text(locations.configuredDirectory.path).font(.caption).textSelection(.enabled)
      Button(L10n.tr("重启应用")) { Task { await relauncher.restart() } }.disabled(relauncher.isRestarting)
      if locations.canReauthorize {
        Button(L10n.tr("重新授权数据目录…")) {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
          panel.directoryURL = locations.configuredDirectory
          panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
              try locations.reauthorize(url)
              Task { await relauncher.restart() }
            } catch {
              let alert = NSAlert(); alert.messageText = error.localizedDescription; alert.runModal()
            }
          }
        }
      }
      if let message = relauncher.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
      if let url = AppReleaseInfo.supportURL { Link(L10n.tr("联系支持"), destination: url) }
    }.padding(32).frame(maxWidth: 560)
  }
}

@MainActor
final class BookshelfLifecycleDelegate: NSObject, NSApplicationDelegate {
  var backups: AutomaticBackupController?
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if let backups, backups.upgradePending {
      do { try backups.prepareForTermination() }
      catch {
        let alert = NSAlert()
        alert.messageText = L10n.tr("升级前备份未完成")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.tr("返回 Bookshelf"))
        alert.runModal()
        return .terminateCancel
      }
    }
    InterfaceLanguagePreferences.shared.prepareForRelaunch()
    return .terminateNow
  }
  func applicationWillTerminate(_ notification: Notification) { backups?.stop() }
}

private struct LibraryWindowRoot: View {
  let container: ModelContainer
  @State private var appState = AppState()
  @Environment(\.openSettings) private var openSettings
  var body: some View {
    LibraryUndoScope {
      ContentView().environment(appState).modelContainer(container)
        .focusedSceneValue(\.newBookAction, { appState.presentNewBook() })
        .task { reopenSettingsIfRequested() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
          reopenSettingsIfRequested()
        }
    }
  }
  private func reopenSettingsIfRequested() {
    guard NSApp.isActive, UserDefaults.standard.bool(forKey: AppRelaunchController.settingsRequestKey) else { return }
    UserDefaults.standard.removeObject(forKey: AppRelaunchController.settingsRequestKey)
    // Launch Services can omit launch arguments for a sandboxed app. Consume
    // this one-shot preference after activation, when Settings is registered.
    DispatchQueue.main.async { openSettings() }
  }
}

private struct PluginCommands: Commands {
  static let windowID = "plugin-manager"
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    CommandMenu(Text(L10n.tr("插件"))) {
      Button(L10n.tr("管理插件…")) { openWindow(id: Self.windowID) }
    }
  }
}

private struct NewBookActionKey: FocusedValueKey { typealias Value = () -> Void }
private extension FocusedValues {
  var newBookAction: (() -> Void)? {
    get { self[NewBookActionKey.self] }
    set { self[NewBookActionKey.self] = newValue }
  }
}
private struct LibraryNewBookCommands: Commands {
  @FocusedValue(\.newBookAction) private var newBook
  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button(L10n.tr("添加书籍")) { newBook?() }.keyboardShortcut("n", modifiers: .command).disabled(newBook == nil)
    }
  }
}

/// Sheets must share their parent window's history instead of a temporary sheet undo manager.
private struct LibraryUndoScope<Content: View>: View {
  @State private var manager = UndoManager()
  @ViewBuilder let content: () -> Content
  var body: some View {
    content().environment(\.libraryUndoManager, manager)
      .focusedSceneValue(\.libraryUndoManager, manager)
  }
}

private struct LibraryUndoManagerKey: FocusedValueKey { typealias Value = UndoManager }
private struct LibraryUndoEnvironmentKey: EnvironmentKey {
  static let defaultValue: UndoManager? = nil
}
extension EnvironmentValues {
  var libraryUndoManager: UndoManager? {
    get { self[LibraryUndoEnvironmentKey.self] }
    set { self[LibraryUndoEnvironmentKey.self] = newValue }
  }
}
private extension FocusedValues {
  var libraryUndoManager: UndoManager? {
    get { self[LibraryUndoManagerKey.self] }
    set { self[LibraryUndoManagerKey.self] = newValue }
  }
}

private struct LibraryUndoCommands: Commands {
  @FocusedValue(\.libraryUndoManager) private var manager
  var body: some Commands {
    CommandGroup(replacing: .undoRedo) {
      Button(L10n.tr("撤销")) { perform(redo: false) }
        .keyboardShortcut("z", modifiers: .command).disabled(manager == nil)
      Button(L10n.tr("重做")) { perform(redo: true) }
        .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(manager == nil)
    }
  }
  private func perform(redo: Bool) {
    // Keep native text editing undo separate when a text field/editor owns keyboard focus.
    let target: UndoManager?
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
      target = editor.undoManager
    } else { target = manager }
    if redo { target?.redo() } else { target?.undo() }
  }
}

struct LibrarySearchActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
  var librarySearchAction: (() -> Void)? {
    get { self[LibrarySearchActionKey.self] }
    set { self[LibrarySearchActionKey.self] = newValue }
  }
}
private struct LibrarySearchCommands: Commands {
  @FocusedValue(\.librarySearchAction) private var search
  var body: some Commands {
    CommandGroup(after: .textEditing) {
      Button(L10n.tr("搜索书库")) { search?() }
        .keyboardShortcut("f", modifiers: .command).disabled(search == nil)
    }
  }
}

/// Scene commands keep lookup and advanced search available from the macOS menus.
struct LibraryToolbarActions {
  var lookupBook: () -> Void
  var advancedSearch: (() -> Void)?
}
private struct LibraryToolbarActionsKey: FocusedValueKey { typealias Value = LibraryToolbarActions }
extension FocusedValues {
  var libraryToolbarActions: LibraryToolbarActions? {
    get { self[LibraryToolbarActionsKey.self] }
    set { self[LibraryToolbarActionsKey.self] = newValue }
  }
}
private struct LibraryToolbarCommands: Commands {
  @FocusedValue(\.libraryToolbarActions) private var actions
  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button(L10n.tr("按书名或 ISBN 添加…")) { actions?.lookupBook() }
        .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(actions == nil)
    }
    CommandGroup(after: .textEditing) {
      Button(L10n.tr("高级筛选")) { actions?.advancedSearch?() }
        .keyboardShortcut("f", modifiers: [.command, .option]).disabled(actions?.advancedSearch == nil)
    }
  }
}
