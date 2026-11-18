import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let bookshelfPluginType = UTType(exportedAs: "io.github.medicoderhz.bookshelf.plugin", conformingTo: .package)

struct PluginManagerView: View {
  @State private var store = PluginStore.shared
  @State private var isInstalling = false
  @State private var sheet: PluginSheet?
  @State private var removing: NoteTemplatePlugin?
  @State private var errorMessage: String?

  private enum PluginSheet: Identifiable {
    case install(NoteTemplatePlugin)
    case details(NoteTemplatePlugin)

    var id: String {
      switch self {
      case .install(let plugin): "install." + plugin.id
      case .details(let plugin): "details." + plugin.id
      }
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading) {
        Label(L10n.tr("插件"), systemImage: "puzzlepiece.extension")
          .font(.headline).foregroundStyle(Color.accentColor)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
        Spacer()
      }
      .padding(12).frame(width: 150)
      .background(.bar)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          HStack {
            Text(L10n.tr("管理插件")).font(.title.bold())
              .accessibilityAddTraits(.isHeader)
            Spacer()
            actionsMenu
          }
          pluginGroup(L10n.tr("已启用"), plugins: store.enabledTemplates)
          pluginGroup(L10n.tr("已停用"), plugins: store.noteTemplates.filter { !store.isEnabled($0.id) })
          if store.noteTemplates.isEmpty {
            ContentUnavailableView {
              Label(L10n.tr("尚未安装插件"), systemImage: "puzzlepiece.extension")
            } actions: {
              Button(L10n.tr("从文件安装插件…")) { isInstalling = true }
            }
          }
          if !store.diagnostics.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text(L10n.tr("未加载的插件")).font(.headline)
              ForEach(store.diagnostics, id: \.self) { Text($0).textSelection(.enabled) }
            }.foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(26)
      }.background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 620, minHeight: 360)
    .fileImporter(isPresented: $isInstalling, allowedContentTypes: [bookshelfPluginType, .json]) { result in
      do { preview(try result.get()) }
      catch CocoaError.userCancelled { return }
      catch { errorMessage = error.localizedDescription }
    }
    .sheet(item: $sheet) { item in
      switch item {
      case .install(let plugin): pluginSheet(plugin, installing: true)
      case .details(let plugin): pluginSheet(plugin, installing: false)
      }
    }
    .confirmationDialog(L10n.tr("移除插件？"), isPresented: Binding(
      get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { plugin in
        Button(L10n.tr("移除"), role: .destructive) {
          do { try store.remove(plugin.id) } catch { errorMessage = error.localizedDescription }
        }
      } message: { plugin in Text(L10n.tr("移除“\(plugin.displayName)”后，已保存的书籍和笔记会保留。")) }
    .alert(L10n.tr("插件"), isPresented: Binding(
      get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
        Button(L10n.tr("好"), role: .cancel) {}
      } message: { Text(errorMessage ?? "") }
  }

  private var actionsMenu: some View {
    Menu {
      Button(L10n.tr("从文件安装插件…")) { isInstalling = true }
      if let url = store.exampleURL {
        Button(L10n.tr("安装阅读笔记示例…")) { preview(url) }
      }
      Divider()
      Button(L10n.tr("重新加载")) { store.reload() }
    } label: {
      Label(L10n.tr("插件操作"), systemImage: "gearshape")
    }
    .labelStyle(.iconOnly).menuIndicator(.hidden).fixedSize()
    .help(L10n.tr("插件操作"))
  }

  @ViewBuilder
  private func pluginGroup(_ title: String, plugins: [NoteTemplatePlugin]) -> some View {
    if !plugins.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        ForEach(plugins) { plugin in
          let enabled = store.isEnabled(plugin.id)
          HStack(spacing: 12) {
            pluginIcon(plugin, enabled: enabled)
            VStack(alignment: .leading, spacing: 4) {
              Text(plugin.displayName).font(.headline).foregroundStyle(enabled ? .primary : .secondary)
              Text(summary(plugin)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle(plugin.displayName, isOn: Binding(get: { store.isEnabled(plugin.id) },
              set: { store.setEnabled($0, for: plugin.id) }))
              .labelsHidden().toggleStyle(.switch).controlSize(.small)
              .accessibilityIdentifier("plugin.enabled." + plugin.id)
            Menu {
              Button(L10n.tr("查看详情…")) { sheet = .details(plugin) }
              Divider()
              Button(L10n.tr("移除…"), role: .destructive) { removing = plugin }
            } label: {
              Label(L10n.tr("管理“\(plugin.displayName)”"), systemImage: "ellipsis")
            }.labelStyle(.iconOnly).menuIndicator(.hidden).fixedSize()
              .help(L10n.tr("管理“\(plugin.displayName)”"))
          }
          .padding(14)
          .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
        }
      }
    }
  }

  private func summary(_ plugin: NoteTemplatePlugin) -> String {
    plugin.localized(for: InterfaceLanguagePreferences.shared.language).description ?? L10n.tr("从所选书籍创建模板笔记。")
  }

  private func pluginIcon(_ plugin: NoteTemplatePlugin, enabled: Bool) -> some View {
    let symbol = plugin.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 }
    let tint = enabled ? Color.accentColor : Color.secondary
    return Image(systemName: symbol ?? "note.text").font(.system(size: 20, weight: .medium))
      .foregroundStyle(tint).frame(width: 40, height: 40)
      .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
      .accessibilityHidden(true)
  }

  private func preview(_ url: URL) {
    do {
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      sheet = .install(try NoteTemplatePlugin.read(from: url))
    } catch { errorMessage = error.localizedDescription }
  }

  private func pluginSheet(_ plugin: NoteTemplatePlugin, installing: Bool) -> some View {
    let previous = store.noteTemplates.first { $0.id == plugin.id }
    return VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        pluginIcon(plugin, enabled: true)
        VStack(alignment: .leading, spacing: 3) {
          Text(plugin.displayName).font(.title2.bold())
          Text(summary(plugin)).foregroundStyle(.secondary)
        }
      }
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
        GridRow { Text(L10n.tr("版本")); Text(plugin.version) }
        GridRow { Text(L10n.tr("作者")); Text(plugin.author) }
        GridRow { Text(L10n.tr("插件标识")); Text(plugin.id) }
      }.textSelection(.enabled)
      Text(L10n.tr("笔记模板")).font(.headline)
      ScrollView {
        Text(plugin.localized(for: InterfaceLanguagePreferences.shared.language).body)
          .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
      }.frame(maxHeight: 160)
      if installing, let previous {
        Text(L10n.tr("将替换同 ID 的版本 \(previous.version)，保留其启用状态。")).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        if installing {
          Button(L10n.tr("取消")) { sheet = nil }.keyboardShortcut(.cancelAction)
          Button(previous == nil ? L10n.tr("安装") : L10n.tr("替换")) {
            sheet = nil
            do { try store.install(plugin) } catch { errorMessage = error.localizedDescription }
          }.keyboardShortcut(.defaultAction)
        } else {
          Button(L10n.tr("完成")) { sheet = nil }.keyboardShortcut(.defaultAction)
        }
      }
    }.padding(24).frame(width: 470)
  }
}
