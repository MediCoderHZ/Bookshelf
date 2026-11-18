# Bookshelf

本地优先的 macOS 原生书籍元信息管理器，使用 SwiftUI、SwiftData 和 Swift 6，支持 macOS 14 及以上版本。

支持书籍与笔记管理、多层文件夹、标签、搜索与智能文件夹、元信息检索、批量编辑、回收站、撤销重做，以及 JSON 备份、RIS 导入导出和 CSV 导出。完整功能说明见[使用手册](Docs/USER-GUIDE.md)。

## 下载与更新

正式安装包将通过 [GitHub Releases](https://github.com/MediCoderHZ/Bookshelf/releases) 发布，支持 Apple Silicon 与 Intel Mac。当前仍处于首次公开发行准备阶段；没有正式安装包时，请按下文从源码构建。Releases 中自动生成的 Source code ZIP 仅包含源码。

应用已接入 Sparkle 2，提供“检查更新…”和自动更新设置。线上更新清单发布前，开发版的在线更新保持关闭。发布步骤与当前待办见 [GitHub 分发与更新](Docs/DISTRIBUTION.md)。

书库默认每小时自动备份，保留最近 30 份定时与手动版本，升级前额外备份并单独保留 10 份。设置中可以调整频率与保留数量、查看历史并预览恢复；详见[自动备份与历史恢复](Docs/USER-GUIDE.md#自动备份与历史恢复)。

界面支持简体中文和 English，可在「设置 → 通用 → 界面语言」中选择。完成编辑后点击「重启应用」，自动备份并重新打开同一个应用，窗口、菜单、文件对话框与界面文字统一切换；重启前可取消语言更改。书籍、笔记和自定义名称保持原文。

「设置 → 文件与数据库」支持自定义数据目录、在 Finder 中显示数据库，以及只读完整性检查。迁移前备份、校验后启用新位置，保留原数据库；详见[数据目录与完整性检查](Docs/USER-GUIDE.md#数据目录与完整性检查)。

## 项目目录

```text
Bookshelf/
├── App/                 应用入口与窗口状态
├── Domain/              领域值、搜索规则与合并逻辑
├── Models/              SwiftData 数据模型
├── Application/         命令、查询、事务通知与撤销
├── Persistence/         数据库、仓储、备份与草稿恢复
├── Translation/         元信息检索、网页解析与书目交换
├── Views/               按功能划分的原生界面
├── Resources/           图标与隐私清单
└── Support/             Info.plist 与沙盒权限
BookshelfTests/          按功能划分的测试与 Fixtures
Bookshelf.xcodeproj/     Xcode 工程与共享 Scheme
Config/                 Release 配置与本地配置示例
Docs/                   使用手册、架构与专题文档
Distribution/           GitHub Pages 更新清单
.github/                CI、手动更新清单发布、Issue 与 PR 模板
AppStore/               历史商店材料（不参与当前 GitHub 发布）
Examples/               书目交换和解析器示例
scripts/                架构检查、构建与发布前检查
Archive/                带编号副本的原样归档及校验清单
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

此脚本生成未签名的本地验证产物。正式发行采用 Developer ID 签名、公证和 Sparkle 更新包签名，见[分发流程](Docs/DISTRIBUTION.md)。首次构建需要联网下载固定版本的 Sparkle；运行本地测试无需真实更新服务器。

本机日常使用统一安装到 `~/Applications/Bookshelf.app`。退出当前“书架”后运行 `bash scripts/install-local.sh`，再打开这个固定入口；后续更新沿用同一应用身份与书库，不再启动多个验证副本。安装已编译产物的方式见[本机固定应用入口](Docs/BUILDING.md#本机固定应用入口)。

2026-11-15 已完成目录整理后的验证：XCTest 476 项通过、10 项可选测试跳过、0 项失败；双架构 Release 构建及本机启动、书籍与笔记保存、重启读取通过。详见[验证记录](Docs/BUILD-VALIDATION.md)。

Sparkle 接入后的最新验证：XCTest 481 项通过、10 项跳过、0 失败，8 项发布工具测试通过；双架构构建、更新界面及签名包完整性检查通过。完整范围见[更新接入验收](Docs/UPDATE-VALIDATION.md)。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [目录结构与维护约定](Docs/PROJECT-STRUCTURE.md) | 文件归属、构建引用与归档说明 |
| [构建与测试](Docs/BUILDING.md) | Xcode 要求、验证脚本、缓存路径与环境排查 |
| [编译与运行验证](Docs/BUILD-VALIDATION.md) | 目录整理后的实测结果、跳过项与证据位置 |
| [使用手册](Docs/USER-GUIDE.md) | 原 README 中的完整功能与交互说明 |
| [架构说明](Docs/ARCHITECTURE.md) | 分层、数据流、扩展边界与开发约束 |
| [文件夹与笔记](Docs/ORGANIZATION.md) | 书库内容组织、笔记与备份规则 |
| [书目交换](Docs/INTERCHANGE.md) | RIS、CSV 和 JSON 的适用范围 |
| [解析器扩展](Docs/TRANSLATORS.md) | 元信息检索、网页解析与自定义规则 |
| [隐私政策草案](Docs/PRIVACY.md) | 本地数据、网络请求与文件访问 |
| [更新接入验收](Docs/UPDATE-VALIDATION.md) | Sparkle、开源准备与签名测试结果及待验证范围 |
| [GitHub 分发与更新](Docs/DISTRIBUTION.md) | 开源发布、Developer ID、公证、Sparkle 与更新清单 |
| [参与贡献](CONTRIBUTING.md) | 开发、反馈与 Pull Request 约定 |

## 许可

Bookshelf 使用 [MIT 许可证](LICENSE)，Copyright © 2026 MediCoderHZ。Sparkle 及其组成部分保留各自的许可和版权声明，详见[许可与第三方声明](Bookshelf/Resources/ThirdPartyNotices.txt)，应用设置中也提供入口。
