import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
  @AppStorage("libraryDisplayDensity") private var density = LibraryDisplayDensity.compact
  @AppStorage("libraryInterfaceFontSize") private var fontSize = 13.0
  @State private var translators = TranslatorStore.shared
  @State private var isShowingTranslators = false

  @State private var exportDocument = LibraryBackupDocument()
  @State private var isExporting = false
  @State private var isImporting = false
  @State private var isShowingPrivacyPolicy = false
  @State private var resultMessage: String?
  @State private var errorMessage: String?
  @State private var importPlan: LibraryImportPlan?
  @State private var pendingImportMessage: String?
  private var history: LibraryHistory { LibraryServices.forContext(modelContext).history }

  var body: some View {
    Form {
      Section("关于") {
        LabeledContent("应用", value: AppReleaseInfo.displayName)
        LabeledContent("版本", value: "\(AppReleaseInfo.version) (\(AppReleaseInfo.build))")
        if let url = AppReleaseInfo.supportURL { Link("帮助与支持", destination: url) }
      }
      Section("显示") {

        Picker("界面密度", selection: $density) {
          ForEach(LibraryDisplayDensity.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented)
        Picker("界面字号", selection: $fontSize) {
          ForEach([12, 13, 14, 16, 18], id: \.self) { size in
            Text("\(size) 磅" + (size == 13 ? "（默认）" : "")).tag(Double(size))
          }
        }
        Text("立即应用于文件夹、书籍列表、标签和信息面板，并记住你的设置。")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("元信息解析器") {
        Button("管理元信息解析器…") { isShowingTranslators = true }
        Text("已安装 \(translators.descriptors.count) 个解析器，统一管理网页、搜索、导入和导出；自定义网页规则支持独立测试。")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("书目交换") {
        BibliographicExchangeMenu(books: books, scopeName: "全部书籍")
        Text("导入 RIS 图书并预览冲突；导出 RIS 书目或 CSV 清单。书籍备注默认不导出；新笔记与文件夹层级请用 JSON 备份完整迁移。")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("备份与恢复") {
        LibraryUndoButtons()
        HStack {
          Button("导出 JSON 备份…") {
            prepareExport()
          }
          Button("从备份恢复…") {
            isImporting = true
          }
        }

        Text("先预览新增、重复与版本冲突，再选择添加、补全或更新。JSON 备份包含文件夹层级、独立笔记、书籍子笔记、回收站和智能规则，并兼容旧版。预览中可选择导入范围，冲突默认保留本地；整次导入可撤销。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("隐私") {
        LabeledContent("数据位置", value: "仅保存在这台 Mac 上")
        Text("本地书库不会上传；主动搜索或提取网页时，会向对应网站发送查询或页面请求。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("查看隐私政策…") {
          isShowingPrivacyPolicy = true
        }
        if let url = AppReleaseInfo.privacyURL { Link("在线隐私政策", destination: url) }
      }
    }
    .formStyle(.grouped)
    .padding()
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
    .sheet(isPresented: $isShowingTranslators) { TranslatorSettingsView() }
    .sheet(item: $importPlan, onDismiss: {
      if let message = pendingImportMessage { resultMessage = message; pendingImportMessage = nil }
    }) { plan in
      ImportPreviewView(plan: plan) { pendingImportMessage = $0.message }
    }
    .alert(
      "备份与恢复",
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
      Button("好", role: .cancel) {}
    } message: {
      Text(errorMessage ?? history.errorMessage ?? resultMessage ?? "")
    }
  }

  private var defaultBackupFileName: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return "书架备份-\(formatter.string(from: Date()))"
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
