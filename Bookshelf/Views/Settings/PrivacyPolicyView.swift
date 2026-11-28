import SwiftUI

struct PrivacyPolicyView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          policySection(
            L10n.tr("数据存储"),
            L10n.tr("书籍、笔记和智能文件夹默认保存在本机应用目录，也可由你选择自定义数据目录。切换目录前先备份，原数据库保留。自动备份和恢复草稿仍保存在本机应用目录。高级筛选和完整性检查只在本机运行，不上传书库内容。数据库与 JSON 备份未单独加密，请妥善保管。")
          )
          policySection(
            L10n.tr("自动备份"),
            L10n.tr("应用默认每小时在本机保存书籍、笔记和书库关联数据的备份，保留最近 30 份定时与手动备份。升级前备份单独保留最近 10 份。备份包含回收站和可用的恢复草稿，不会上传，也未单独加密。你可以在设置中调整频率、保留份数或关闭定期备份；升级保护始终保留。删除书库条目不会立即从已有历史备份中移除它。")
          )
          policySection(
            L10n.tr("数据收集"),
            L10n.tr("开发者不运营接收书库数据的服务器，应用不内置广告或行为分析 SDK。本地书库、个人备注、标签和阅读记录不会自动上传。在线检索涉及的第三方数据处理见下文。")
          )
          policySection(L10n.tr("AI 与 MCP"), L10n.tr("通过右键补全时，所选书籍的书目字段会发送到你配置的模型服务。启用 MCP 后，本机客户端可查询书目并提交建议。两个入口均需在 Bookshelf 中核对后保存，笔记与附件不会发送。"))
          policySection(
            L10n.tr("在线书籍检索"),
            L10n.tr("仅在点击搜索后，应用将书名或 ISBN 发送至所选来源：豆瓣 www.douban.com、Goodreads www.goodreads.com 或 Open Library openlibrary.org。选择全部来源会分别请求全部已启用来源，停用的解析器不参与。选择候选后读取详情（豆瓣详情来自 book.douban.com）；ISBN 搜索有时直接返回详情。服务方会收到请求内容、IP 地址及应用版本等网络信息，可能按其政策保留日志。本地书库和个人备注不会随请求发送。可以取消任务；已经发出的请求无法撤回。")
          )
          Link(
            L10n.tr("Open Library / Internet Archive 服务与隐私说明"),
            destination: URL(string: "https://archive.org/about/terms.php")!)
          policySection(
            L10n.tr("网页解析器与自定义规则"),
            L10n.tr("仅在点击提取或选择列表中的图书后，应用才向已启用解析器匹配的网址请求页面。网站会收到请求网址、IP 地址和应用版本等网络信息，可能依其政策记录日志。内置豆瓣解析器使用 book.douban.com；自定义 JSON 规则导入前会显示目标网站。导入规则不发出网络请求，规则保存在本机，不运行代码。应用不读取浏览器 Cookie、不登录网站、不上传书库或笔记、不执行网页脚本。来源和时间随书籍保存并包含在书库备份中；自定义规则需单独导出。可在元信息解析器窗口中停用或移除自定义规则。打开浏览器后，适用浏览器和网站自身的设置。")
          )
          Link(L10n.tr("豆瓣个人信息保护政策"), destination: URL(string: "https://www.douban.com/about/privacy")!)
          policySection(
            "Goodreads",
            L10n.tr("内置 Goodreads 解析器请求 www.goodreads.com 的公开页面。网站会收到网址、IP 地址及应用标识等网络信息，其处理受服务方政策约束。应用不登录账号，不使用页面认证信息请求 API，不保存页面中的用户资料、广告或认证字段。只提取书籍元信息，可在元信息解析器窗口中停用。")
          )
          Link(L10n.tr("Goodreads 隐私政策"), destination: URL(string: "https://www.goodreads.com/about/privacy")!)
          policySection(
            L10n.tr("软件更新"),
            L10n.tr("选择“Bookshelf → 检查更新…”或同意自动检查后，Sparkle 会从 raw.githubusercontent.com 读取更新清单。下载更新时会访问 GitHub Releases。GitHub 可能收到 IP 地址和应用版本，更新请求不包含书籍、笔记或书库备份。系统分析默认关闭。")
          )
          policySection(
            L10n.tr("文件访问"),
            L10n.tr("导入、导出或添加附件时，应用访问你明确选择的文件或位置。自定义数据目录和附件文件夹的授权保存在本机。选择外部附件文件夹后，新添加的文件存入该文件夹，书库通过软链接访问它们。应用从当前数据库旁的 translators 文件夹加载解析规则。HTML 在本机解析，不执行脚本、不加载引用资源；应用不会扫描其他文件夹。")
          )
          policySection(
            L10n.tr("数据共享"),
            L10n.tr("应用不会向开发者或任何第三方出售用户数据。在线检索、网页提取与软件更新会产生前述网络请求；本地书库和笔记不会随请求发送。用户自行导出的 JSON 备份由用户负责保管。")
          )
          policySection(
            L10n.tr("删除数据"),
            L10n.tr("移入回收站后，书籍元信息、笔记、分类仍保留，可恢复。合并的其他原记录也保留在回收站。永久删除或清空回收站才删除记录，且无法撤销。撤销历史仅保留在当前窗口会话的内存中，退出后清空；JSON 备份包含回收站状态和字段来源。移除应用后，macOS 仍可能保留应用容器。此前导出的备份文件不会被自动删除。")
          )
          policySection(
            L10n.tr("联系我们"),
            L10n.tr("如对隐私政策有疑问，请通过项目 GitHub 仓库的 Issues 联系维护者。请勿在公开反馈中附上私密书库或个人信息。")
          )

          if let url = AppReleaseInfo.supportURL { Link(L10n.tr("帮助与支持"), destination: url) }
          Text(L10n.tr("最后更新：2026 年 11 月 16 日"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(28)
      }
      .navigationTitle(L10n.tr("隐私政策"))
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.tr("完成")) { dismiss() }
        }
      }
    }
  }

  private func policySection(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)
      Text(text)
        .textSelection(.enabled)
    }
  }
}
