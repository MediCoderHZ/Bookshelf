import SwiftUI
import UniformTypeIdentifiers

struct PluginManagerView: View {
  @State private var store = PluginStore.shared
  @State private var isInstalling = false
  @State private var pending: NoteTemplatePlugin?
  @State private var removing: NoteTemplatePlugin?
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section(L10n.tr("笔记模板")) {
        ForEach(store.noteTemplates) { template in
          HStack(alignment: .firstTextBaseline) {
            DisclosureGroup(template.displayName) {
              VStack(alignment: .leading, spacing: 4) {
                Text("\(template.version) · \(template.author)")
                Text(template.localized(for: InterfaceLanguagePreferences.shared.language).body)
                  .textSelection(.enabled)
              }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            Button(L10n.tr("移除…"), role: .destructive) { removing = template }
            enabledToggle(template.displayName, id: template.id)
          }
        }
        if let url = store.exampleURL, !store.noteTemplates.contains(where: { $0.id == NoteTemplatePlugin.readingNotesID }) {
          Button(L10n.tr("安装阅读笔记示例…")) { preview(url) }
        }
      }
      if !store.diagnostics.isEmpty {
        Section(L10n.tr("未加载的插件")) {
          ForEach(store.diagnostics, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
          Button(L10n.tr("重新加载")) { store.reload() }
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 570, minHeight: 400)
    .toolbar {
      Button { isInstalling = true } label: { Label(L10n.tr("安装插件…"), systemImage: "plus") }
        .labelStyle(.titleAndIcon)
    }
    .fileImporter(isPresented: $isInstalling, allowedContentTypes: [.json]) { result in
      switch result {
      case .success(let url): preview(url)
      case .failure(let error): if (error as NSError).code != NSUserCancelledError { errorMessage = error.localizedDescription }
      }
    }
    .sheet(item: $pending) { package in installationPreview(package) }
    .confirmationDialog(L10n.tr("移除插件？"), isPresented: Binding(
      get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { package in
        Button(L10n.tr("移除"), role: .destructive) {
          do { try store.remove(package.id) } catch { errorMessage = error.localizedDescription }
        }
      } message: { package in Text(L10n.tr("移除“\(package.displayName)”后，已保存的书籍和笔记会保留。")) }
    .alert(L10n.tr("插件"), isPresented: Binding(
      get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
        Button(L10n.tr("好"), role: .cancel) {}
      } message: { Text(errorMessage ?? "") }
  }

  private func enabledToggle(_ name: String, id: String) -> some View {
    Toggle(name, isOn: Binding(get: { store.isEnabled(id) }, set: { store.setEnabled($0, for: id) }))
      .labelsHidden()
  }

  private func preview(_ url: URL) {
    do {
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      pending = try NoteTemplatePlugin.read(from: url)
    } catch { errorMessage = error.localizedDescription }
  }

  private func installationPreview(_ package: NoteTemplatePlugin) -> some View {
    let previousVersion = store.noteTemplates.first { $0.id == package.id }?.version
    return VStack(alignment: .leading, spacing: 14) {
      Text(package.displayName).font(.title2.bold())
      Text("\(package.version) · \(package.author)")
      Text(package.id).font(.caption).foregroundStyle(.secondary)
      ScrollView {
        Text(package.localized(for: InterfaceLanguagePreferences.shared.language).body)
          .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
      }.frame(maxHeight: 180)
      if let previousVersion {
        Text(L10n.tr("将替换同 ID 的版本 \(previousVersion)，保留其启用状态。"))
      }
      HStack {
        Spacer()
        Button(L10n.tr("取消")) { pending = nil }
        Button(previousVersion == nil ? L10n.tr("安装") : L10n.tr("替换")) {
          pending = nil
          do { try store.install(package) } catch { errorMessage = error.localizedDescription }
        }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 480)
  }
}
