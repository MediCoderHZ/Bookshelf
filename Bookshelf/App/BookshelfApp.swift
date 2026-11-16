import AppKit
import SwiftData
import SwiftUI

@main
struct BookshelfApp: App {
  @NSApplicationDelegateAdaptor(BookshelfLifecycleDelegate.self) private var lifecycle
  @StateObject private var updater: AppUpdater
  @StateObject private var backups: AutomaticBackupController
  @StateObject private var relauncher: AppRelaunchController
  private let storage: Result<ModelContainer, Error>

  init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let backups = AutomaticBackupController(appVersion: "\(AppReleaseInfo.version) (\(AppReleaseInfo.build))",
      recoveryRoot: support.appendingPathComponent("Bookshelf"))
    _backups = StateObject(wrappedValue: backups)
    storage = Result {
      let url = LibraryDatabase.defaultStoreURL
      try backups.prepareToOpenStore(at: url)
      RetiredReadingData.cleanPreferences(.standard)
      LibrarySearchScope.migratePreference(in: .standard)
      let container = try LibraryDatabase.open(at: url)
      try SmartCollectionService.retireBookTypeDefaults(in: container.mainContext)
      backups.attach(context: container.mainContext, storeURL: url)
      return container
    }
    _updater = StateObject(wrappedValue: AppUpdater(backups: backups))
    _relauncher = StateObject(wrappedValue: AppRelaunchController(prepare: {
      guard NSApp.keyWindow?.makeFirstResponder(nil) != false else { throw AutomaticBackupError.pendingChanges }
      _ = try backups.create()
    }))
    lifecycle.backups = backups
  }

  var body: some Scene {
    WindowGroup(AppReleaseInfo.displayName) {
      Group {
        switch storage {
        case .success(let container):
          LibraryWindowRoot(container: container)
            .safeAreaInset(edge: .bottom) { AutomaticBackupWarning(backups: backups) }
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
      LibraryUndoCommands()
      LibraryNewBookCommands()
      LibrarySearchCommands()
      LibraryToolbarCommands()
    }

    Settings {
      switch storage {
      case .success(let container):
        LibraryUndoScope {
          SettingsView().environmentObject(updater).environmentObject(backups).environmentObject(relauncher)
            .environment(\.locale, L10n.locale)
            .modelContainer(container)
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
        alert.addButton(withTitle: L10n.tr("返回书架"))
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
