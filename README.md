# Bookshelf

本地优先的 macOS 原生书籍元信息管理器，使用 SwiftUI、SwiftData 和 Swift 6，支持 macOS 14 及以上版本。

支持书籍与笔记管理、多层文件夹、标签、搜索与智能文件夹、元信息检索、批量编辑、回收站、撤销重做，以及 JSON 备份、RIS 导入导出和 CSV 导出。完整功能说明见[使用手册](Docs/USER-GUIDE.md)。

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
AppStore/               商店文案、发布清单与验收记录
Examples/               书目交换和解析器示例
scripts/                架构检查、构建与发布前检查
Archive/                带编号副本的原样归档及校验清单
work/                   本地构建、缓存与备份（Git 忽略）
Package.swift           Swift Package Manager 构建与测试入口
```

各子目录职责、归档说明及新增文件规则见[目录结构与维护约定](Docs/PROJECT-STRUCTURE.md)。

## 开发与验证

使用完整版 Xcode 打开 `Bookshelf.xcodeproj`，选择 `Bookshelf` Scheme 运行。也可在项目根目录执行：

```sh
bash scripts/verify-project.sh
```

需要完整版 Xcode 提供 SwiftData/SwiftUI 宏、XCTest 和资源编译工具。脚本会检查工具链，并将中间文件与缓存放到系统临时目录，避免当前外置卷上的构建权限问题。其他 Xcode 安装位置可通过 `DEVELOPER_DIR` 指定；详见[构建与测试](Docs/BUILDING.md)。

本地双架构 Release 验证：

```sh
bash scripts/build-release.sh
```

此脚本生成未签名的本地产物；正式发布前还需配置 Bundle Identifier、开发团队、版权与公开隐私政策网址，并完成[发布准备与待办](AppStore/RELEASE-READINESS.md)。

2026-11-15 已完成目录整理后的验证：XCTest 476 项通过、10 项可选测试跳过、0 项失败；双架构 Release 构建及本机启动、书籍与笔记保存、重启读取通过。详见[验证记录](Docs/BUILD-VALIDATION.md)。

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
| [发布准备](AppStore/RELEASE-READINESS.md) | 商店材料、签名与发布前待办 |
