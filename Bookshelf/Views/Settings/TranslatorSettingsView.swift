import SwiftUI
import UniformTypeIdentifiers

struct TranslatorSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var store = TranslatorStore.shared
  @State private var isImporting = false
  @State private var isExporting = false
  @State private var exportDocument = TranslatorRuleDocument()
  @State private var exportName = "translator-template"
  @State private var pendingRule: TranslatorRule?
  @State private var removingRule: TranslatorRule?
  @State private var testDestination: TranslatorTestDestination?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack {
            Button(L10n.tr("导入解析规则…")) { isImporting = true }
            Button(L10n.tr("导出规则模板…")) { export(TranslatorRule.example, name: "translator-template") }
          }
          Text(L10n.tr("导入 JSON 规则即可扩展网站，无需重新编译。测试只预览提取结果，不写入书库。"))
            .font(.caption).foregroundStyle(.secondary)
        }
        Section(L10n.tr("已安装的解析器")) {
          ForEach(store.descriptors) { descriptor in
            VStack(alignment: .leading, spacing: 8) {
              Toggle(descriptor.name, isOn: Binding(
                get: { store.isEnabled(descriptor.id) },
                set: { store.setEnabled($0, for: descriptor.id) }))
                .font(.headline)
              Text(L10n.tr("\(descriptor.version) · \(descriptor.author) · 优先级 \(descriptor.priority)"))
                .font(.caption).foregroundStyle(.secondary)
              Text(store.catalog.capabilities(for: descriptor.id).title).font(.caption).foregroundStyle(.secondary)
              Text(descriptor.targetDescription).font(.caption).textSelection(.enabled)
              HStack {
                Text(store.isBuiltin(descriptor.id) ? L10n.tr("内置") : L10n.tr("自定义 JSON")).font(.caption2).foregroundStyle(.secondary)
                Text(descriptor.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                if store.catalog.capabilities(for: descriptor.id).contains(.web) {
                Button(L10n.tr("测试…")) { testDestination = TranslatorTestDestination(id: descriptor.id) }
                  .disabled(!store.isEnabled(descriptor.id))
                  .accessibilityLabel(L10n.tr("测试\(descriptor.name)"))
                  .accessibilityIdentifier("translator.test.\(descriptor.id)")
                }
                if let rule = store.rules.first(where: { $0.id == descriptor.id }) {
                  Button(L10n.tr("导出…")) { export(rule, name: rule.id) }
                  Button(L10n.tr("移除…"), role: .destructive) { removingRule = rule }
                }
              }
            }.padding(.vertical, 6)
          }
        }
        if !store.diagnostics.isEmpty {
          Section(L10n.tr("未加载的规则")) {
            ForEach(store.diagnostics, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            Button(L10n.tr("重新加载")) { store.reload() }
          }
        }
        Section {
          Text(L10n.tr("内置解析器随应用更新。自定义规则仅在本机解析 HTML，不运行 JavaScript；访问域名由规则声明，网页提取由你主动发起。书库备份不包含规则，请单独导出保管。"))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(L10n.tr("元信息解析器"))
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("完成")) { dismiss() } } }
    }
    .frame(width: 680, height: 640)
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
      do {
        let url = try result.get()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256 * 1_024 else {
          throw WebMetadataError.invalidConfiguration(L10n.tr("规则文件不能超过 256 KB"))
        }
        let rule = try TranslatorRule.decode(Data(contentsOf: url))
        guard !store.isBuiltin(rule.id) else { throw WebMetadataError.invalidConfiguration(L10n.tr("此 ID 属于内置解析器，请修改 ID")) }
        pendingRule = rule
      } catch { errorMessage = error.localizedDescription }
    }
    .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json, defaultFilename: exportName) {
      if case .failure(let error) = $0 { errorMessage = error.localizedDescription }
    }
    .sheet(item: $pendingRule) { rule in
      VStack(alignment: .leading, spacing: 16) {
        Text(L10n.tr("导入 \(rule.name)")).font(.title2.bold())
        Text(L10n.tr("版本 \(rule.version) · 作者 \(rule.author) · 优先级 \(rule.priority)"))
        Text(L10n.tr("网页范围：\(rule.descriptor.targetDescription)")).textSelection(.enabled)
        if let previous = store.rules.first(where: { $0.id == rule.id }) {
          Text(L10n.tr("将替换同 ID 的版本 \(previous.version)，保留其启用状态。"))
        }
        Text(L10n.tr("导入不会访问网站。完成后可点击“测试”，使用已保存的 HTML 验证规则。"))
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Spacer()
          Button(L10n.tr("取消")) { pendingRule = nil }
          Button(store.rules.contains(where: { $0.id == rule.id }) ? L10n.tr("替换规则") : L10n.tr("导入规则")) {
            do { try store.install(rule); pendingRule = nil }
            catch { pendingRule = nil; errorMessage = error.localizedDescription }
          }.keyboardShortcut(.defaultAction)
        }
      }.padding(24).frame(width: 540)
    }
    .sheet(item: $testDestination) { destination in
      WebMetadataImportView(testTranslatorID: destination.id) { _ in }
    }
    .confirmationDialog(L10n.tr("移除此解析器？"), isPresented: Binding(
      get: { removingRule != nil }, set: { if !$0 { removingRule = nil } }), titleVisibility: .visible) {
        Button(L10n.tr("移除规则"), role: .destructive) {
          guard let rule = removingRule else { return }
          do { try store.remove(rule.id) } catch { errorMessage = error.localizedDescription }
          removingRule = nil
        }
      } message: { Text(L10n.tr("已保存的书籍不受影响。如需保留配置，请先导出规则。")) }
    .alert(L10n.tr("元信息解析器"), isPresented: Binding(
      get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
        Button(L10n.tr("好"), role: .cancel) {}
      } message: { Text(errorMessage ?? "") }
  }

  private func export(_ rule: TranslatorRule, name: String) {
    do { exportDocument = TranslatorRuleDocument(data: try rule.encoded()); exportName = name; isExporting = true }
    catch { errorMessage = error.localizedDescription }
  }
}

private struct TranslatorTestDestination: Identifiable { let id: String }

struct TranslatorRuleDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data = Data()
  init(data: Data = Data()) { self.data = data }
  init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
