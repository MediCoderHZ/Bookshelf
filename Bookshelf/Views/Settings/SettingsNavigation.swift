import AppKit
import SwiftUI

/// SwiftUI's Settings scene otherwise combines a cached system suffix with
/// CFBundleDisplayName. Own the complete title instead of mixing these sources.
struct SettingsWindowTitle: NSViewRepresentable {
  func makeNSView(context: Context) -> Observer { Observer() }
  func updateNSView(_ view: Observer, context: Context) {
    view.localizedTitle = L10n.tr("书架设置")
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
  case general, exchange, backups, storage, about
  var id: Self { self }
  var titleKey: InterfaceText {
    switch self {
    case .general: "通用"
    case .exchange: "导入与导出"
    case .backups: "备份与恢复"
    case .storage: "文件与数据库"
    case .about: "关于"
    }
  }
  var title: String { L10n.tr(titleKey) }
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .exchange: "square.and.arrow.up"
    case .backups: "clock.arrow.circlepath"
    case .storage: "externaldrive"
    case .about: "info.circle"
    }
  }
  var groups: [SettingsGroup] { SettingsGroup.allCases.filter { $0.pane == self } }
}

/// Search the settings themselves in either language, independently of library data.
enum SettingsGroup: String, CaseIterable, Identifiable {
  case appearance, exchange, translators, automaticBackup, restore, storage, about
  var id: Self { self }
  var pane: SettingsPane {
    switch self {
    case .appearance: .general
    case .exchange, .translators: .exchange
    case .automaticBackup, .restore: .backups
    case .storage: .storage
    case .about: .about
    }
  }
  var titleKey: InterfaceText {
    switch self {
    case .appearance: "界面语言"
    case .exchange: "书目交换"
    case .translators: "元信息解析器"
    case .automaticBackup: "自动备份"
    case .restore: "导出与恢复"
    case .storage: "数据目录与维护"
    case .about: "关于书架"
    }
  }
  var title: String { L10n.tr(titleKey) }
  private var keywords: [InterfaceText] {
    switch self {
    case .appearance: ["界面语言", "简体中文", "English", "Language", "中文", "英文"]
    case .exchange: ["导入 RIS 书目…", "导出", "RIS", "CSV", "书目", "Bibliography"]
    case .translators: ["管理元信息解析器…", "网页", "搜索", "自定义规则", "Metadata", "Translators", "Web", "Rules", "RIS", "CSV"]
    case .automaticBackup: ["定期备份书籍和笔记", "备份频率", "保留定时与手动备份", "最近成功备份", "立即备份", "查看历史备份…", "每小时", "每天", "升级", "历史", "频率", "History", "Retention", "Interval", "Update"]
    case .restore: ["导出 JSON 备份…", "从备份恢复…", "JSON", "Restore", "Import", "Export"]
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
