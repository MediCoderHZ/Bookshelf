# 目录结构与维护约定

本项目包含一个原生 macOS 应用目标和一个 SwiftPM 测试目标。目录按代码职责划分，应用源码仍编译为同一个模块。所有命令均从项目根目录执行。

## 顶层职责

| 路径 | 职责与放置规则 |
| --- | --- |
| `Bookshelf/` | 当前应用源码、运行资源和应用配置 |
| `BookshelfTests/` | 当前回归测试，按业务主题分组；`Fixtures/` 保存版本迁移样本 |
| `Bookshelf.xcodeproj/` | 原生应用构建、签名配置和共享 Scheme |
| `Package.swift` | SwiftPM 应用目标、测试目标和测试资源定义 |
| `Config/` | 发布构建配置；本机签名配置放入被忽略的 `Release.local.xcconfig` |
| `Docs/` | 当前维护的使用、架构、专题与隐私文档 |
| `Distribution/Updates/` | Sparkle 从 GitHub 仓库的 `main` 分支读取的更新清单 |
| `.github/` | 构建验证、手动 Pages 发布及协作模板 |
| `Examples/` | 可供手动体验和测试复用的 JSON 与 HTML 示例 |
| `scripts/` | 架构检查、项目验证、Release 构建和发布前检查；`lib/` 共用工具链与构建目录设置 |
| `Archive/` | 历史编号副本、原相对路径和校验清单 |
| `work/` | 本地构建、缓存、原始设计图片和操作前快照，由 Git 忽略 |

根目录的 [README](../README.md) 是统一入口。应用文件夹与笔记功能仍在 [ORGANIZATION.md](ORGANIZATION.md) 中说明，项目文件组织以本文为准。

## 应用源码

| 目录 | 主要职责 |
| --- | --- |
| `App/` | `BookshelfApp` 应用入口、`AppState` 窗口状态与 `AppUpdater` 更新协调 |
| `Domain/` | 书籍快照、标签、文件夹顺序、搜索、Markdown 与重复项判断 |
| `Models/` | SwiftData 实体及关系定义 |
| `Application/` | 书籍、文件夹、笔记与标签命令，查询、建议、历史和通知 |
| `Persistence/` | 数据库打开、事务仓储、组织数据、JSON 备份与草稿恢复 |
| `Translation/` | 插件格式与本机存储、解析器注册、网络客户端和站点适配 |
| `Resources/` | Asset Catalog、应用图标、隐私清单与许可声明 |
| `Support/` | Info.plist 和 Bookshelf.entitlements |

`Views/` 进一步按界面用途划分：

```text
Views/
├── Books/          书籍编辑、详情、贡献者字段与阅读位置
├── Library/        主窗口、书库列表、复核与书籍拖放
├── Metadata/       高级搜索、在线检索、导入导出与备份文档
├── Notes/          笔记编辑器、富文本转换、拖放与编辑位置
├── Organization/   左侧导航、文件夹、标签与相关拖放
├── Settings/       设置、解析器管理与应用内隐私说明
└── Shared/         显示偏好、工作区状态、建议输入与面板宽度
```

界面写入继续通过应用命令完成。Domain、Application、Persistence、Translation 不导入 SwiftUI；Translation 不访问 SwiftData。具体边界见[架构说明](ARCHITECTURE.md)。

## 测试与样本

```text
BookshelfTests/
├── Books/          书籍类型、编辑、贡献者、规范化与批量操作
├── Collections/    文件夹层级、顺序、拖放与智能文件夹
├── Notes/          笔记层级、编辑、Markdown 与回收站
├── Persistence/    事务架构、书库安全与旧版本兼容
├── Search/         搜索范围与已保存查询
├── Tags/           标签管理、建议与侧栏范围
├── Translation/    站点解析、元信息检索与自定义规则
├── Workspace/      列表投影、列宽、滚动、选区与工作区状态
└── Fixtures/       ReadingStatusV5、RatingV6、FavoriteV7、CoverV8
```

SwiftPM 递归发现测试文件，`Fixtures/` 仍通过 `.copy("Fixtures")` 打包。`TranslatorSystemTests` 读取 `Examples/Translators/`，`NoteReparentingTests` 读取应用 Info.plist；移动这些测试时必须同步检查从 `#filePath` 推导的根目录。

## 文档和示例

- [USER-GUIDE.md](USER-GUIDE.md)：从原 README 迁入的完整功能说明。
- [ARCHITECTURE.md](ARCHITECTURE.md)：源码分层与扩展约束。
- [ORGANIZATION.md](ORGANIZATION.md)：应用中的文件夹与笔记功能。
- [TRANSLATORS.md](TRANSLATORS.md)：解析器扩展；样例位于 `Examples/Translators/`。
- [PRIVACY.md](PRIVACY.md)：可用于发布准备的隐私政策草案。
- [BUILDING.md](BUILDING.md)：工具链、验证命令、中间文件位置与环境排查。
- [BUILD-VALIDATION.md](BUILD-VALIDATION.md)：目录整理后的完整编译、测试与本机运行结果。
- [UPDATE-VALIDATION.md](UPDATE-VALIDATION.md)：开源准备与 Sparkle 集成的实测结果。
- [DISTRIBUTION.md](DISTRIBUTION.md)：当前 GitHub 开源分发、签名、公证与自动更新流程。

## 编号副本与本地工作区

[2026-11-15 编号副本归档](../Archive/2026-11-15-numbered-copies/) 现存 35 个文件，包括 17 个应用源码、12 个测试和 6 个文档。归档保留原目录层级，位于两个 SwiftPM target 路径之外，当前构建使用无编号的主文件。[校验清单](../Archive/2026-11-15-numbered-copies/manifest.json) 记录每个现存文件的原位置、归档位置、大小和 SHA-256。

`work/` 中已有的 `DerivedData/`、`SwiftPMBuild/`、`build/`、缓存、`PreBookTypes/` 和 `RecoveredDuplicateSources/` 保留原位置，避免破坏构建路径或历史快照。该目录同时包含可重建产物和不可直接丢弃的原始资料，清理前应逐项区分。

本次整理前的文件校验、文本快照及移动映射位于本机 `work/DirectoryOrganization/2026-11-15/`，便于核对和恢复。

## 后续维护

1. 新源码放入对应职责目录；新增或移动应用源码时同步 Xcode 中的文件引用与分组，确保物理路径一致。
2. 新测试放入相应主题目录；版本迁移样本放入 `Fixtures/`，不要改写已有历史样本。
3. 当前维护文件使用唯一的正式名称。历史差异保存在版本历史或明确的归档目录，避免在源码、测试与当前文档旁新增编号副本。
4. 详细说明放入 `Docs/`，在 README 中增加入口；移动文档时同步相对链接。
5. 操作前快照与验证日志放入 `work/`。构建脚本默认将新的中间文件和缓存放在系统临时目录，避免本次发现的外置卷输出权限问题；旧 `work/` 产物保留。本机配置和用户数据不纳入应用资源。
6. 整理后运行 `bash scripts/verify-project.sh`；涉及 Xcode 引用时还应运行 `bash scripts/build-release.sh`。这两项均要求完整版 Xcode，具体见[构建与测试](BUILDING.md)。

## 本次整理验证（2026-11-15）

- 整理当日核对了 227 个文件的位置，并验证了当时 42 个编号副本的 SHA-256。应用 Swift 源码及版本迁移样本内容未改动。
- 架构检查通过，检查脚本已递归覆盖新子目录；本地发布技术预检通过，原有正式发布待办仍保留。
- Xcode 工程语法检查通过，所有文件引用可解析，96 个应用 Swift 文件均有且只有一个 Sources 编译条目。
- SwiftPM 成功解析 Package.swift，并识别全部 96 个应用源码、40 个测试文件及 Fixtures 资源。
- 当前维护文档的本地文件与目录链接检查通过。
- 完整 XCTest 共 486 项：476 项通过、10 项可选测试跳过、0 项失败。
- Xcode 27.2 双架构 Release 构建与产物预检通过；独立沙盒测试副本的启动、书籍与笔记保存、退出重启后的读取通过。

初始权限错误来自执行沙盒对外置卷构建输出的限制，已通过本机临时目录设置解决。用户安装完整 Xcode 并完成首次启动后，SwiftPM 编译和测试通过；Xcode Release 构建的宏插件沙盒限制通过正常权限审批在沙盒外执行解决。96 个应用 Swift 文件内容保持不变。详见[编译与运行验证](BUILD-VALIDATION.md)和[排查记录](BUILDING.md)。
