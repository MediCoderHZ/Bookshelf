import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject private var updater: AppUpdater
  @EnvironmentObject private var backups: AutomaticBackupController
  @EnvironmentObject private var relauncher: AppRelaunchController
  @Bindable private var languagePreferences = InterfaceLanguagePreferences.shared
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
  @AppStorage("libraryDisplayDensity") private var density = LibraryDisplayDensity.compact
  @AppStorage("libraryInterfaceFontSize") private var fontSize = 13.0
  @State private var selectedPane = SettingsPane.general
  @State private var searchText = ""
  @FocusState private var searchFocused: Bool
  @State private var exchangePresentation = BibliographicExchangePresentation()
  @State private var translators = TranslatorStore.shared
  @State private var isShowingTranslators = false

  @State private var exportDocument = LibraryBackupDocument()
  @State private var isExporting = false
  @State private var isImporting = false
  @State private var isShowingPrivacyPolicy = false
  @State private var isShowingLicenses = false
  @State private var isShowingBackupHistory = false
  @State private var pendingBackupRestore: Data?
  @State private var resultMessage: String?
  @State private var errorMessage: String?
  @State private var importPlan: LibraryImportPlan?
  @State private var pendingImportMessage: String?
  private var history: LibraryHistory { LibraryServices.forContext(modelContext).history }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .center, spacing: 20) {
          Text(isSearching ? L10n.tr("搜索结果") : selectedPane.title)
            .font(.system(size: 25, weight: .semibold)).accessibilityAddTraits(.isHeader)
          Spacer(minLength: 8)
          searchField
        }.padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 24)
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 30) {
              Color.clear.frame(height: 0).id("settingsTop")
              if isSearching && visibleGroups.isEmpty {
                VStack(spacing: 12) {
                  Image(systemName: "magnifyingglass").font(.system(size: 32)).foregroundStyle(.tertiary)
                  Text(L10n.tr("未找到相关设置")).font(.title3.weight(.semibold))
                  Text(L10n.tr("试试其他关键词，或从左侧选择分类。"))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                  Button(L10n.tr("清除搜索")) { searchText = "" }
                }.frame(maxWidth: .infinity, minHeight: 260)
              } else {
                ForEach(visibleGroups) { group in
                  VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                      if isSearching {
                        Text(group.pane.title).font(.caption).foregroundStyle(.secondary)
                      }
                      Text(group.title).font(.system(size: 16, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    }
                    settingsContent(group)
                  }.frame(maxWidth: .infinity, alignment: .leading)
                  if group != visibleGroups.last { Divider() }
                }
              }
            }.padding(.horizontal, 30).padding(.bottom, 32)
          }
          .onChange(of: selectedPane) { _, _ in proxy.scrollTo("settingsTop", anchor: .top) }
          .onChange(of: searchText) { _, _ in proxy.scrollTo("settingsTop", anchor: .top) }
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .font(.system(size: 13))
    .background(Color(nsColor: .windowBackgroundColor))
    .background(SettingsWindowTitle())
    .modifier(BibliographicExchangePresenter(presentation: exchangePresentation))
    .fileExporter(
      isPresented: $isExporting,
      document: exportDocument,
      contentType: .json,
      defaultFilename: defaultBackupFileName
    ) { result in
      if case .failure(let error) = result {
        errorMessage = error.localizedDescription
      }
    }
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { result in
      importBackup(result)
    }
    .sheet(isPresented: $isShowingPrivacyPolicy) {
      PrivacyPolicyView()
        .frame(minWidth: 620, minHeight: 560)
    }
    .sheet(isPresented: $isShowingLicenses) {
      VStack(alignment: .leading, spacing: 16) {
        Text(L10n.tr("许可与致谢")).font(.title2)
        ScrollView {
          Text(licenseText).font(.system(.caption, design: .monospaced))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        Button(L10n.tr("完成")) { isShowingLicenses = false }.frame(maxWidth: .infinity, alignment: .trailing)
      }.padding(24).frame(width: 640, height: 520)
    }
    .sheet(isPresented: $isShowingTranslators) { TranslatorSettingsView() }
    .sheet(isPresented: $isShowingBackupHistory, onDismiss: {
      guard let data = pendingBackupRestore else { return }
      pendingBackupRestore = nil
      do { importPlan = try LibraryImportPlanner.prepare(data, context: modelContext) }
      catch { errorMessage = error.localizedDescription }
    }) {
      AutomaticBackupHistoryView(backups: backups) { pendingBackupRestore = $0 }
    }
    .sheet(item: $importPlan, onDismiss: {
      if let message = pendingImportMessage { resultMessage = message; pendingImportMessage = nil }
    }) { plan in
      ImportPreviewView(plan: plan) { pendingImportMessage = $0.message }
    }
    .alert(
      L10n.tr("备份与恢复"),
      isPresented: Binding(
        get: { resultMessage != nil || errorMessage != nil || history.errorMessage != nil },
        set: {
          if !$0 {
            resultMessage = nil
            errorMessage = nil
            history.errorMessage = nil
          }
        }
      )
    ) {
      Button(L10n.tr("好"), role: .cancel) {}
    } message: {
      Text(errorMessage ?? history.errorMessage ?? resultMessage ?? "")
    }
  }

  private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  private var visibleGroups: [SettingsGroup] {
    isSearching ? SettingsGroup.search(searchText) : selectedPane.groups
  }

  private var sidebar: some View {
    VStack(spacing: 4) {
      ForEach(SettingsPane.allCases) { pane in
        if pane == .updates { Divider().padding(.horizontal, 12).padding(.vertical, 12) }
        Button {
          selectedPane = pane
          searchText = ""
          searchFocused = false
        } label: {
          HStack(spacing: 12) {
            Image(systemName: pane.symbol).font(.system(size: 20, weight: .regular)).frame(width: 24)
            Text(pane.title).font(.system(size: 14, weight: selectedPane == pane ? .medium : .regular))
              .multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, 12).frame(minHeight: 50)
          .foregroundStyle(selectedPane == pane && !isSearching ? Color.white : Color.primary)
          .background(selectedPane == pane && !isSearching ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settingsPane." + pane.rawValue)
        .accessibilityAddTraits(selectedPane == pane && !isSearching ? [.isSelected] : [])
      }
      Spacer(minLength: 0)
    }
    .padding(12).frame(width: 222).frame(maxHeight: .infinity)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("设置分类"))
    .onMoveCommand { direction in
      guard !searchFocused, let index = SettingsPane.allCases.firstIndex(of: selectedPane) else { return }
      let next = direction == .down ? index + 1 : direction == .up ? index - 1 : index
      guard SettingsPane.allCases.indices.contains(next) else { return }
      selectedPane = SettingsPane.allCases[next]; searchText = ""
    }
  }

  private var searchField: some View {
    HStack(spacing: 7) {
      Button { searchFocused = true } label: {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      }.buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
        .accessibilityLabel(L10n.tr("搜索设置"))
      TextField(L10n.tr("搜索设置"), text: $searchText)
        .textFieldStyle(.plain).focused($searchFocused)
        .accessibilityIdentifier("settingsSearch")
        .onExitCommand { searchText = ""; searchFocused = false }
      if !searchText.isEmpty {
        Button { searchText = ""; searchFocused = true } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }.buttonStyle(.plain).accessibilityLabel(L10n.tr("清除搜索"))
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 8).frame(width: 230)
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7)
      .strokeBorder(searchFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: searchFocused ? 2 : 1))
    .help(L10n.tr("搜索所有设置，支持中英文关键词（⌘F）。"))
  }

  @ViewBuilder private func settingsContent(_ group: SettingsGroup) -> some View {
    switch group {
    case .appearance:
      SettingsControlRow(title: L10n.tr("界面语言")) {
        Picker(L10n.tr("界面语言"), selection: $languagePreferences.requestedLanguage) {
          ForEach(InterfaceLanguage.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().frame(width: 210, alignment: .leading).disabled(relauncher.isRestarting)
      }
      SettingsHelp(L10n.tr("语言更改将在重新打开应用后统一生效，包括窗口、菜单、文件对话框和更新窗口。当前界面保持原语言，避免中英文混用。"))
      if languagePreferences.requiresRelaunch {
        VStack(alignment: .leading, spacing: 12) {
          Text(L10n.tr("语言更改已保存。重启后将自动重新打开当前应用并应用所选语言。"))
          HStack(spacing: 12) {
            Button(relauncher.isRestarting ? L10n.tr("正在重启…") : L10n.tr("重启应用")) {
              Task { await relauncher.restart() }
            }
            .disabled(relauncher.isRestarting)
            Button(L10n.tr("取消语言更改")) { languagePreferences.requestedLanguage = languagePreferences.language }
              .disabled(relauncher.isRestarting)
          }
          if let message = relauncher.errorMessage { Text(message).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
      }
    case .display:
      SettingsControlRow(title: L10n.tr("界面密度")) {
        Picker(L10n.tr("界面密度"), selection: $density) {
          ForEach(LibraryDisplayDensity.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().pickerStyle(.segmented).frame(width: 210, alignment: .leading)
      }
      SettingsControlRow(title: L10n.tr("界面字号")) {
        Picker(L10n.tr("界面字号"), selection: $fontSize) {
          ForEach([12, 13, 14, 16, 18], id: \.self) { size in
            Text(L10n.tr("\(size) 磅") + (size == 13 ? L10n.tr("（默认）") : "")).tag(Double(size))
          }
        }.labelsHidden().frame(width: 210, alignment: .leading)
      }
      SettingsHelp(L10n.tr("立即应用于文件夹、书籍列表、标签和信息面板，并记住你的设置。"))
    case .exchange:
      SettingsHelp(L10n.tr("导入 RIS 图书并预览冲突；导出 RIS 书目或 CSV 清单。书籍备注默认不导出；新笔记与文件夹层级请用 JSON 备份完整迁移。"))
      BibliographicExchangeMenu(books: books, scopeName: L10n.tr("全部书籍"), presentation: exchangePresentation)
      Button(L10n.tr("前往备份与恢复")) { selectedPane = .backups; searchText = "" }
    case .translators:
      SettingsHelp(L10n.tr("已安装 \(translators.descriptors.count) 个解析器，统一管理网页、搜索、导入和导出；自定义网页规则支持独立测试。"))
      Button(L10n.tr("管理元信息解析器…")) { isShowingTranslators = true }
    case .automaticBackup:
      AutomaticBackupSettings(backups: backups, onHistory: { isShowingBackupHistory = true })
    case .restore:
      SettingsHelp(L10n.tr("先预览新增、重复与版本冲突，再选择添加、补全或更新。JSON 备份包含文件夹层级、独立笔记、书籍子笔记、回收站和智能规则，并兼容旧版。预览中可选择导入范围，冲突默认保留本地；整次导入可撤销。"))
      HStack(spacing: 12) {
        Button(L10n.tr("导出 JSON 备份…"), action: prepareExport)
        Button(L10n.tr("从备份恢复…")) { isImporting = true }
      }
      LibraryUndoButtons()
    case .updates:
      AppUpdateSettings(updater: updater)
    case .privacy:
      SettingsControlRow(title: L10n.tr("数据位置")) { Text(L10n.tr("仅保存在这台 Mac 上")) }
      SettingsHelp(L10n.tr("本地书库不会上传。在线检索和软件更新会访问相应服务，详见隐私政策。"))
      HStack(spacing: 12) {
        Button(L10n.tr("查看隐私政策…")) { isShowingPrivacyPolicy = true }
        if let url = AppReleaseInfo.privacyURL { Link(L10n.tr("在线隐私政策"), destination: url) }
      }
    case .about:
      HStack(spacing: 16) {
        Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text(AppReleaseInfo.displayName).font(.title2.weight(.semibold))
          Text(L10n.tr("版本") + " \(AppReleaseInfo.version) (\(AppReleaseInfo.build))").foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 12) {
        Button(L10n.tr("许可与致谢…")) { isShowingLicenses = true }
        if let url = AppReleaseInfo.supportURL { Link(L10n.tr("帮助与支持"), destination: url) }
      }
    }
  }

  private var defaultBackupFileName: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return L10n.tr("书架备份-\(formatter.string(from: Date()))")
  }

  private var licenseText: String {
    guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return L10n.tr("请查看源码仓库中的 LICENSE 与 Bookshelf/Resources/ThirdPartyNotices.txt。") }
    return text
  }

  private func prepareExport() {
    do {
      exportDocument = LibraryBackupDocument(
        data: try LibraryBackupService.exportData(from: modelContext)
      )
      isExporting = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func importBackup(_ result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first else { return }
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }

      let data = try Data(contentsOf: url)
      importPlan = try LibraryImportPlanner.prepare(data, context: modelContext)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
