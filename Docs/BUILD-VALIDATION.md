# 目录整理后的编译与运行验证

验证日期：2026-11-15（Asia/Shanghai）。目录整理后的当前源码已通过编译、回归测试及本机运行验证。

## 环境与结果

| 项目 | 结果 |
| --- | --- |
| 系统 | macOS 27.2.1，Apple Silicon |
| 工具链 | Xcode 27.2（27B52），Swift 6.4.2 |
| 应用源码 | 96 个 Swift 文件，内容与目录整理前一致 |
| 测试源码 | 40 个文件，全部被 SwiftPM 发现 |
| XCTest | 共 486 项：476 项通过、10 项跳过、0 项失败 |
| Release 构建 | arm64、x86_64 双架构成功，版本 0.1.0（1） |
| 产物预检 | 图标、隐私清单、版本、最低系统声明及双架构检查通过 |
| 本机运行 | 空书库启动、添加书籍、创建子笔记、自动保存及重启读取通过 |
| 架构与引用 | 架构检查、Xcode 源文件覆盖、测试资源及文档链接检查通过 |

## 执行方式

```sh
bash scripts/verify-project.sh --disable-sandbox
bash scripts/build-release.sh
```

验证脚本为本次进程选择 `/Applications/Xcode.app/Contents/Developer`，不修改系统全局 `xcode-select`。构建中间文件放在本机临时目录。

SwiftPM 验证在受限运行器内完成。Xcode Release 构建在受限运行器内遭遇 `sandbox-exec: sandbox_apply: Operation not permitted`，宏插件因此报告 `malformed response`；经正常权限审批在执行沙盒外运行同一构建脚本后成功。应用自身的 App Sandbox 权限保持原样。

## 本机运行步骤

从本次 Release 产物创建独立测试副本，只修改 Bundle Identifier、显示名称并附加本地临时签名。测试副本使用 `com.example.Bookshelf.DirectoryValidation`，保留原应用的三项沙盒权限，测试数据位于独立容器。原始 Release 与测试副本的两个架构 Mach-O UUID 一致。

实际完成以下操作并在界面核对结果：

1. 启动新构建的测试应用，空书库与三栏主窗口正常显示。
2. 添加“目录整理验证 2026-11-15”，填写作者“验证作者”和出版社“本地验证出版社”，保存后在列表与详情中核对。
3. 在该书下新建子笔记，输入两行正文，切换条目后笔记标题与数量正确更新。
4. 正常退出应用并重新启动，书籍、作者、出版社、子笔记归属及完整正文均恢复；书籍展开状态也恢复。

## 跳过项与验证范围

10 项可选测试按现有测试逻辑跳过：2 项需要额外旧版数据库，5 项需要显式开启实时网站请求，3 项需要手工保存的 HTML 或搜索样本。现有 Fixtures 内的迁移测试已随默认测试套件运行。

此次应用运行验证在本机 arm64 上完成；x86_64 已编译但未在 Intel Mac 上运行，macOS 14 最低版本也未实机复测。

## 本地证据与产物

以下均位于项目的 `work/ToolchainInvestigation/XcodeValidation/`，由 Git 忽略：

| 文件 | 内容 |
| --- | --- |
| `swift-tests.log` | 完整 XCTest 执行输出与跳过原因 |
| `release-build.log` | 受限沙盒内的 Release 失败诊断 |
| `release-build-unrestricted.log` | 成功的双架构构建与产物预检输出 |
| `results.json` | 本次验证的结构化结果 |
| `runtime-bundle.json` | 原产物、测试副本及 Bundle Identifier 记录 |
| `Bookshelf.app` | 保留的原始本地 Release 产物 |
| `BookshelfDirectoryValidation.app` | 已实际运行验证的独立沙盒测试副本 |

后续复现方法见[构建与测试](BUILDING.md)，目录职责见[目录结构与维护约定](PROJECT-STRUCTURE.md)。
