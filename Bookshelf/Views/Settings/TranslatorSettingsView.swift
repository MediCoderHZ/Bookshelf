import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranslatorSettingsView: View {
  static let windowID = "metadata-translators"
  @Environment(TranslatorStore.self) private var store
  @State private var isImporting = false
  @State private var isExporting = false
  @State private var exportDocument = TranslatorRuleDocument()
  @State private var exportName = ""
  @State private var pendingRule: TranslatorRule?
  @State private var removingRule: TranslatorRule?
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section {
        ForEach(store.descriptors) { descriptor in
          Toggle(descriptor.name, isOn: Binding(
            get: { store.isEnabled(descriptor.id) },
            set: { store.setEnabled($0, for: descriptor.id) }))
            .toggleStyle(.switch)
            .accessibilityIdentifier("translator.enabled.\(descriptor.id)")
            .contextMenu {
              if let file = store.scriptFile(for: descriptor.id) {
                Button(L10n.tr("在 Finder 中显示解析器文件")) {
                  NSWorkspace.shared.activateFileViewerSelecting([file])
                }
              }
              if let rule = store.rules.first(where: { $0.id == descriptor.id }) {
                Button(L10n.tr("导出…")) { export(rule) }
                Button(L10n.tr("移除…"), role: .destructive) { removingRule = rule }
              }
            }
        }
      }
      if !store.diagnostics.isEmpty {
        Section(L10n.tr("未加载的规则")) {
          ForEach(store.diagnostics, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 430, minHeight: 175)
    .onAppear { store.reload() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.reload() }
    .toolbar {
      Button {
        do {
          try store.ensureDirectory()
          guard NSWorkspace.shared.open(store.directory) else { throw CocoaError(.fileReadUnknown) }
        } catch { errorMessage = error.localizedDescription }
      } label: { Label(L10n.tr("打开解析器目录"), systemImage: "folder") }
        .labelStyle(.titleAndIcon)
      Menu {
        Button(L10n.tr("重新加载")) { store.reload() }
        Button(L10n.tr("导入解析规则…")) { isImporting = true }
      } label: {
        Label(L10n.tr("更多操作"), systemImage: "ellipsis.circle")
      }
      .labelStyle(.iconOnly)
      .help(L10n.tr("更多操作"))
    }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
      do {
        let url = try result.get()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard case .translator(let rule) = try ExtensionFile.read(from: url) else {
          throw WebMetadataError.invalidConfiguration(L10n.tr("笔记模板由插件窗口管理。"))
        }
        guard !store.isBuiltin(rule.id) else { throw WebMetadataError.invalidConfiguration(L10n.tr("此 ID 属于内置解析器，请修改 ID")) }
        pendingRule = rule
      } catch CocoaError.userCancelled { return }
      catch { errorMessage = error.localizedDescription }
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
    .confirmationDialog(L10n.tr("移除此解析器？"), isPresented: Binding(
      get: { removingRule != nil }, set: { if !$0 { removingRule = nil } }), titleVisibility: .visible, presenting: removingRule) { rule in
        Button(L10n.tr("移除规则"), role: .destructive) {
          do { try store.remove(rule.id) } catch { errorMessage = error.localizedDescription }
        }
      } message: { _ in Text(L10n.tr("已保存的书籍不受影响。如需保留配置，请先导出规则。")) }
    .alert(L10n.tr("元信息解析器"), isPresented: Binding(
      get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
        Button(L10n.tr("好"), role: .cancel) {}
      } message: { Text(errorMessage ?? "") }
  }

  private func export(_ rule: TranslatorRule) {
    do {
      exportDocument = TranslatorRuleDocument(data: try rule.encoded())
      exportName = rule.id
      isExporting = true
    }
    catch { errorMessage = error.localizedDescription }
  }
}

private struct TranslatorRuleDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data = Data()
  init(data: Data = Data()) { self.data = data }
  init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
