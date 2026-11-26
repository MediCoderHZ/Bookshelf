# Bookshelf

Bookshelf 是一款为 macOS 开发的开源个人藏书管理软件，参考 Zotero 用文件夹、条目列表和详情面板整理资料的方式。你可以按书名或 ISBN 查找一本书，把不同译本分别归档，再把摘录和想法记在对应的书下。书目和笔记保存在自己的 Mac 上，界面支持简体中文和英文。

## 下载与运行

**[下载 Bookshelf for Mac（DMG）](https://github.com/MediCoderHZ/Bookshelf/releases/download/v0.1.0/Bookshelf-0.1.0-macOS.dmg)**

Bookshelf 0.1.0（构建 9）支持 macOS 14 及以上的 Apple 芯片和 Intel Mac。双击打开 DMG，将左侧的 Bookshelf 拖到右侧的「应用程序」。复制完成后，推出磁盘映像，从「应用程序」打开 Bookshelf。应用和磁盘映像均已通过 Apple 公证。[发行说明与 SHA-256 校验值](https://github.com/MediCoderHZ/Bookshelf/releases/tag/v0.1.0)

这个版本通过 GitHub Releases 手动更新。以后安装新版时，先退出 Bookshelf，再用新版替换原位置的应用。

### 从源码构建

源码构建请使用完整版 Xcode 27。首次打开 Xcode 并完成组件安装，然后在解压后的项目目录运行以下命令。首次构建会联网下载 Sparkle 依赖。如果已经打开 Bookshelf，请先正常退出。

```sh
bash scripts/install-local.sh
open ~/Applications/Bookshelf.app
```

安装脚本会构建应用、在本机签名并安装到 `~/Applications/Bookshelf.app`。以后从这个位置打开即可。[构建与测试说明](Docs/BUILDING.md)

## 用 Bookshelf 管理一本书

1. **添加书目。** 输入书名、ISBN 或支持的图书详情页地址，从豆瓣读书、Goodreads 或 Open Library 获取候选记录。核对作者、译者和出版信息后保存，也可以手动录入。
2. **整理藏书。** 把书放进文件夹，添加主题标签。经常使用的筛选条件可以保存成智能文件夹，新加入且符合条件的书会出现在其中。
3. **写阅读笔记。** 右键一本书，选择「新建笔记 → 从模板新建笔记 → 阅读笔记」，即可在书下记录摘录、思考和待查问题。在「插件 → 管理插件…」可以安装或停用笔记模板。[阅读笔记示例](Bookshelf/Resources/reading-notes.bookshelfplugin)
4. **备份书库。** 应用默认每小时自动备份，并单独保留升级前的快照。可在「设置 → 备份与恢复」查看历史版本，在「文件与数据库」选择数据目录或检查数据库完整性。[使用手册](Docs/USER-GUIDE.md)

## 致谢 Zotero

感谢 Zotero 项目及其维护者、插件作者和文档贡献者。Bookshelf 的三栏布局、保存搜索、元信息解析器和插件管理面板，都参考了 Zotero 的设计和公开文档。Bookshelf 由本项目独立开发，专注于个人藏书与阅读笔记。[Zotero 官网](https://www.zotero.org/) · [Zotero 开发者文档](https://www.zotero.org/support/dev/start) · [Zotero 源码](https://github.com/zotero/zotero)

## 项目目录

```text
Bookshelf/
├── App/                 应用入口与窗口状态
├── Domain/              领域值、搜索规则与合并逻辑
├── Models/              SwiftData 数据模型
├── Application/         命令、查询、事务通知与撤销
├── Persistence/         数据库、仓储、备份与草稿恢复
├── Translation/         元信息检索与网页解析
├── Views/               按功能划分的原生界面
├── Resources/           图标与隐私清单
└── Support/             Info.plist 与沙盒权限
BookshelfTests/          按功能划分的测试与 Fixtures
Bookshelf.xcodeproj/     Xcode 工程与共享 Scheme
Config/                 Release 配置与本地配置示例
Docs/                   使用手册、架构与专题文档
Distribution/           GitHub Pages 更新清单
.github/                CI、手动更新清单发布、Issue 与 PR 模板
Examples/               网页解析器示例
scripts/                架构检查、构建与发布前检查
Archive/                历史编号副本及校验清单
work/                   本地构建、缓存与备份（Git 忽略）
Package.swift           Swift Package Manager 构建与测试入口
```

各子目录职责、归档说明及新增文件规则见[目录结构与维护约定](Docs/PROJECT-STRUCTURE.md)。

## 开发与验证

使用完整版 Xcode 打开 `Bookshelf.xcodeproj` 查看与编辑源码，在项目根目录执行回归测试：

```sh
bash scripts/verify-project.sh
```

需要完整版 Xcode 提供 SwiftData/SwiftUI 宏、XCTest 和资源编译工具。脚本会检查工具链，并将中间文件与缓存放到系统临时目录，避免当前外置卷上的构建权限问题。其他 Xcode 安装位置可通过 `DEVELOPER_DIR` 指定；详见[构建与测试](Docs/BUILDING.md)。

本地双架构 Release 验证：

```sh
bash scripts/build-release.sh
```

此脚本生成未签名的本地验证产物。GitHub 下载版采用 Developer ID 签名及 Apple 公证。启用应用内更新时还需要为 Sparkle 更新包签名。[分发流程](Docs/DISTRIBUTION.md)

本机日常使用统一安装到 `~/Applications/Bookshelf.app`。退出当前“Bookshelf”后运行 `bash scripts/install-local.sh`，再打开这个固定入口；后续更新沿用同一应用身份与书库，不再启动多个验证副本。安装已编译产物的方式见[本机固定应用入口](Docs/BUILDING.md#本机固定应用入口)。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [目录结构与维护约定](Docs/PROJECT-STRUCTURE.md) | 文件归属、构建引用与归档说明 |
| [构建与测试](Docs/BUILDING.md) | Xcode 要求、验证脚本、缓存路径与环境排查 |
| [编译与运行验证](Docs/BUILD-VALIDATION.md) | 目录整理后的实测结果、跳过项与证据位置 |
| [使用手册](Docs/USER-GUIDE.md) | 原 README 中的完整功能与交互说明 |
| [架构说明](Docs/ARCHITECTURE.md) | 分层、数据流、扩展边界与开发约束 |
| [文件夹与笔记](Docs/ORGANIZATION.md) | 书库内容组织、笔记与备份规则 |
| [解析器扩展](Docs/TRANSLATORS.md) | 元信息检索、网页解析与自定义规则 |
| [隐私政策草案](Docs/PRIVACY.md) | 本地数据、网络请求与文件访问 |
| [更新接入验收](Docs/UPDATE-VALIDATION.md) | Sparkle、开源准备与签名测试结果及待验证范围 |
| [GitHub 分发与更新](Docs/DISTRIBUTION.md) | 开源发布、Developer ID、公证、Sparkle 与更新清单 |
| [参与贡献](CONTRIBUTING.md) | 开发、反馈与 Pull Request 约定 |

## 许可

Bookshelf 使用 [MIT 许可证](LICENSE)，Copyright © 2026 MediCoderHZ。Sparkle 及其组成部分保留各自的许可和版权声明，详见[许可与第三方声明](Bookshelf/Resources/ThirdPartyNotices.txt)，应用设置中也提供入口。
