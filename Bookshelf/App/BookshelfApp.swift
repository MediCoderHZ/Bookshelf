import AppKit
import SwiftData
import SwiftUI

@main
struct BookshelfApp: App {
  private let storage: Result<ModelContainer, Error> = Result {
    RetiredReadingData.cleanPreferences(.standard)
    LibrarySearchScope.migratePreference(in: .standard)
    let container = try LibraryDatabase.open()
    try SmartCollectionService.retireBookTypeDefaults(in: container.mainContext)
    return container
  }

  var body: some Scene {
    WindowGroup(AppReleaseInfo.displayName) {
      Group {
        switch storage {
        case .success(let container):
          LibraryWindowRoot(container: container)
        case .failure(let error):
          storageFailure(error)
        }
      }.frame(minWidth: 900, minHeight: 620)
    }
    .defaultSize(width: 1380, height: 820)
    .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    .commands {
      LibraryUndoCommands()
      LibraryNewBookCommands()
      LibrarySearchCommands()
      LibraryToolbarCommands()
    }

    Settings {
      switch storage {
      case .success(let container):
        LibraryUndoScope { SettingsView().modelContainer(container).frame(width: 500, height: 560) }
      case .failure(let error):
        storageFailure(error).frame(width: 500, height: 340)
      }
    }
  }

  private func storageFailure(_ error: Error) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
      Text("暂时无法打开本地书库").font(.title2)
      Text("应用没有删除或重建你的书库。请先退出并重新打开应用；如果问题持续，请联系支持并提供以下错误信息。")
        .multilineTextAlignment(.center)
      Text(error.localizedDescription).font(.caption).textSelection(.enabled)
      if let url = AppReleaseInfo.supportURL { Link("联系支持", destination: url) }
    }.padding(32).frame(maxWidth: 560)
  }
}

private struct LibraryWindowRoot: View {
  let container: ModelContainer
  @State private var appState = AppState()
  var body: some View {
    LibraryUndoScope {
      ContentView().environment(appState).modelContainer(container)
        .focusedSceneValue(\.newBookAction, { appState.presentNewBook() })
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
      Button("添加书籍") { newBook?() }.keyboardShortcut("n", modifiers: .command).disabled(newBook == nil)
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
      Button("撤销") { perform(redo: false) }
        .keyboardShortcut("z", modifiers: .command).disabled(manager == nil)
      Button("重做") { perform(redo: true) }
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
      Button("搜索书库") { search?() }
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
      Button("按书名或 ISBN 添加…") { actions?.lookupBook() }
        .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(actions == nil)
    }
    CommandGroup(after: .textEditing) {
      Button("高级筛选") { actions?.advancedSearch?() }
        .keyboardShortcut("f", modifiers: [.command, .option]).disabled(actions?.advancedSearch == nil)
    }
  }
}
