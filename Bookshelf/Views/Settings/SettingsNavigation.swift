import AppKit
import SwiftUI

/// SwiftUI's Settings scene otherwise combines a cached system suffix with
/// CFBundleDisplayName. Own the complete title instead of mixing these sources.
struct SettingsWindowTitle: NSViewRepresentable {
  func makeNSView(context: Context) -> Observer { Observer() }
  func updateNSView(_ view: Observer, context: Context) {
    view.localizedTitle = L10n.tr("Bookshelf 设置")
    view.applyTitle()
  }
  final class Observer: NSView {
    var localizedTitle = ""
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      applyTitle()
    }
    func applyTitle() {
      window?.title = localizedTitle
      // Settings assigns its initial title after attaching the content view.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.window?.title = self.localizedTitle
      }
    }
  }
}

enum SettingsPane: String, CaseIterable, Identifiable {
  case general, backups, storage, ai, about
  var id: Self { self }
  var titleKey: InterfaceText {
    switch self {
    case .ai: "AI 与 MCP"
    case .general: "通用"
    case .backups: "备份与恢复"
    case .storage: "文件与数据库"
    case .about: "关于"
    }
  }
  var title: String { L10n.tr(titleKey) }
  var symbol: String {
    switch self {
    case .ai: "sparkles"
    case .general: "gearshape"
    case .backups: "clock.arrow.circlepath"
    case .storage: "externaldrive"
    case .about: "info.circle"
    }
  }
  var groups: [SettingsGroup] { SettingsGroup.allCases.filter { $0.pane == self } }
}

/// Search the settings themselves in either language, independently of library data.
enum SettingsGroup: String, CaseIterable, Identifiable {
  case appearance, automaticBackup, restore, storage, attachmentFolder, attachments, translators, model, mcp, about
  var id: Self { self }
  var pane: SettingsPane {
    switch self {
    case .model, .mcp: .ai
    case .appearance: .general
    case .automaticBackup, .restore: .backups
    case .storage, .attachmentFolder, .attachments, .translators: .storage
    case .about: .about
    }
  }
  var titleKey: InterfaceText {
    switch self {
    case .model: "模型服务"
    case .mcp: "外部 AI 客户端"
    case .appearance: "界面语言"
    case .automaticBackup: "自动备份"
    case .restore: "备份文件"
    case .storage: "数据目录与维护"
    case .attachmentFolder: "附件保存位置"
    case .attachments: "附件重命名"
    case .translators: "元信息解析器"
    case .about: "关于 Bookshelf"
    }
  }
  var title: String { L10n.tr(titleKey) }
  private var keywords: [InterfaceText] {
    switch self {
    case .model: ["模型名称", "服务地址", "API Key"]
    case .mcp: ["MCP", "stdio"]
    case .appearance: ["界面语言", "简体中文", "English", "Language", "中文", "英文"]
    case .automaticBackup: ["定期备份书籍和笔记", "备份频率", "保留定时与手动备份", "最近成功备份", "立即备份", "查看历史备份…", "每小时", "每天", "升级", "历史", "频率", "History", "Retention", "Interval", "Update"]
    case .restore: ["保存 JSON 备份…", "从备份恢复…", "JSON", "Restore"]
    case .attachmentFolder: ["选择附件文件夹…", "使用书库文件夹", "外部文件夹", "软链接", "Symbolic links", "Symlinks"]
    case .attachments: ["配置附件重命名", "附件命名格式", "文件名模板", "自动重命名新添加的文件", "重命名已有附件", "Rename", "Attachments"]
    case .translators: ["管理元信息解析器…", "打开解析器目录", "重新加载", "Translators", "Metadata"]
    case .storage: ["数据目录", "数据库维护", "检查数据库完整性", "使用自定义位置…", "Database", "Directory", "Location", "Integrity", "Storage"]
    case .about: ["应用名称", "版本", "帮助与支持", "许可与致谢…", "查看隐私政策…", "隐私", "Privacy", "MIT", "License", "Bookshelf", "书架"]
    }
  }
  static func search(_ query: String) -> [Self] {
    let terms = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return allCases }
    return allCases.filter { group in
      let keys = [group.titleKey, group.pane.titleKey] + group.keywords
      let text = normalized(InterfaceLanguage.allCases.flatMap { language in
        keys.map { L10n.render($0, language: language) }
      }.joined(separator: " "))
      return terms.allSatisfy { text.contains($0) }
    }
  }
  private static func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
}

struct SettingsControlRow<Control: View>: View {
  let title: String
  @ViewBuilder var control: Control
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(title).frame(width: 168, alignment: .leading).fixedSize(horizontal: false, vertical: true)
      control
      Spacer(minLength: 0)
    }
  }
}
