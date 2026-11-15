# 构建与测试

本项目需要完整版 Xcode，既用于 SwiftData/SwiftUI 宏展开，也用于 XCTest 测试、Asset Catalog 编译和原生应用打包。单独安装 Command Line Tools 不足以验证本项目。

## 常用命令

在项目根目录运行：

```sh
# 架构检查、本地技术预检及 SwiftPM 回归测试
bash scripts/verify-project.sh

# 未签名的 arm64 / x86_64 Release 应用及产物预检
bash scripts/build-release.sh
```

脚本使用 `DEVELOPER_DIR` 或当前选中的 Xcode。如果当前选中 Command Line Tools，但 `/Applications/Xcode.app` 存在，会为本次命令使用该 Xcode；不会修改系统的 `xcode-select` 设置。其他安装位置可显式传入：

```sh
DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer" bash scripts/verify-project.sh
DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer" bash scripts/build-release.sh
```

安装 Xcode 后，先打开一次，阅读并接受许可协议，完成它提示的组件设置。工具链检查会在缺少 Xcode、首次启动未完成、缺少 `xctest` 或 `actool` 时明确退出，避免继续输出大量连带编译错误。

## 本机固定应用入口

日常使用与界面检查统一使用 `~/Applications/Bookshelf.app`，显示名称为“书架”，Bundle Identifier 固定为 `io.github.medicoderhz.bookshelf`。后续更新替换这个应用，继续使用同一个书库，不再创建或启动多个验证版本。

先正常退出“书架”，再运行：

```sh
# 编译、临时签名并安装到固定位置
bash scripts/install-local.sh

# 或安装已经编译验证的标准 Release 产物
bash scripts/install-local.sh --app /path/to/Bookshelf.app
```

安装脚本保留旧应用到 `work/LocalAppBackups/`，拒绝覆盖仍在运行的应用，不启动应用，也不修改书库。安装完成后只打开 `~/Applications/Bookshelf.app`。本机数据位于 `~/Library/Containers/io.github.medicoderhz.bookshelf/Data/Library/Application Support/`；迁移前备份保存在被 Git 忽略的 `work/LibraryMigration/`，不要上传个人书库。

此脚本为本机运行临时签名，原始 Release 产物保持不变；安装后的本机应用不作为公开分发包。

## 构建文件的位置

源码可以继续保存在当前外置卷。脚本默认将中间文件放到 `/private/tmp/Bookshelf-<用户 ID>-<项目路径摘要>/`，具体位置会在执行时打印：

| 子目录 | 用途 |
| --- | --- |
| `SwiftPMBuild/` | 应用与 XCTest 编译产物、测试资源 |
| `ModuleCache/` | Swift / Clang 模块缓存 |
| `SwiftPMCache/` | SwiftPM 缓存 |
| `SwiftPMConfig/`、`SwiftPMSecurity/` | 本次项目的 SwiftPM 配置目录 |
| `ReleaseCheck/` | Xcode DerivedData；应用位于 `Build/Products/Release/Bookshelf.app` |

这些目录可由系统清理。需要长期保留产物时，将构建目录指定到已有写权限的本机目录，例如：

```sh
BOOKSHELF_BUILD_ROOT="/path/to/local/builds/Bookshelf" bash scripts/verify-project.sh
BOOKSHELF_BUILD_ROOT="/path/to/local/builds/Bookshelf" bash scripts/build-release.sh
```

也可以仅通过 `BOOKSHELF_DERIVED_DATA` 覆盖 Release 的 DerivedData 路径。项目原有 `work/` 中的历史构建、快照与原始资料保留原位。

## 受限执行环境

如果运行器本身已处于沙盒中，SwiftPM 的包清单子进程可能无法再次创建沙盒。可在确认当前项目内容后执行：

```sh
bash scripts/verify-project.sh --disable-sandbox
```

这只影响 SwiftPM 子进程沙盒，不修改应用的 App Sandbox 权限。不要因为路径权限错误对整个源码目录、用户目录或磁盘执行递归权限修改。

若 Xcode Release 构建同时报告 `sandbox-exec: sandbox_apply: Operation not permitted` 和宏插件 `malformed response`，需要通过运行器正常的权限审批，在执行沙盒外运行 `bash scripts/build-release.sh`。本次按此方式已成功构建；无需改写 SwiftData/SwiftUI 业务代码或削弱应用沙盒权限。

默认测试不访问真实站点。依赖在线网站、手工 HTML 样本或额外旧数据库的可选测试可能跳过，具体以测试输出为准。界面检查在上述固定入口中进行；用户书库只做读取与重启检查，不自动添加验证样本。空书库、增删和迁移等自动测试使用临时数据。

## 当前验证状态

2026-11-15 当前完整版本已使用 Xcode 27.2 完成验证：491 项 XCTest 中 481 项通过、10 项按设计跳过、0 项失败，8 项发布工具测试通过；arm64 / x86_64 Release 构建通过。固定应用入口中的书库重启读取、高级筛选缩放和视图条目数量显示均已检查。当前范围见[完整版本验收记录](UPDATE-VALIDATION.md)，早期目录整理的验证保留在[初始验证记录](BUILD-VALIDATION.md)。

## 2026-11-15 初始排查记录

- 初始环境为 Command Line Tools，Swift 6.4.2；当时未找到完整版 Xcode、`xctest` 或 `actool`。
- 在系统临时目录，Foundation 编译与可执行文件启动成功。
- 最小 SwiftPM 包在系统临时目录使用默认 swiftbuild 后端构建成功，生成的可执行文件启动成功。
- 对同一个最小包做对照：当前执行沙盒内向外置卷的工作目录输出时出现 manifest.json 权限错误；经授权在沙盒外向同一项目工作区输出则构建、启动成功。由此确认本轮路径权限错误来自执行沙盒限制，而非源码目录损坏或需要修改磁盘权限。默认使用本机临时目录已绕开该限制。
- 将项目的 SwiftPM native 构建中间文件移到系统临时目录后，越过了原先 output-file-map.json 的 I/O 错误，进入应用源码编译。
- 应用编译随后失败于缺少 `SwiftDataMacros` / `SwiftUIMacros`。`@Model`、`@Query`、`@State` 无法展开，产生的 PersistentModel、绑定与不可变 self 等错误不能据此认定为业务源码问题。
- 原有源码未因这些环境错误而修改。随后用户安装 Xcode 并确认许可协议，完整编译、XCTest 回归和新产物启动验证已完成。

应用编译日志在本机 `work/DirectoryOrganization/2026-11-15/`：`swift-build-local.log`、`swiftpm-probe.log` 和此前的测试日志。沙盒对照及验证脚本日志在 `work/ToolchainInvestigation/`：`probe-external.log`、`probe-external-unrestricted.log`、`verify-project.log`、`build-release.log`。

## Sparkle 依赖与发行构建

SwiftPM 和 Xcode 都固定 Sparkle 2.10.1；根目录与 Xcode workspace 下的 `Package.resolved` 一并纳入 Git。首次构建需要访问官方 GitHub 仓库及二进制附件。应用框架由 Xcode 的 Swift Package 集成自动嵌入；不要手工添加引用包产品的 Copy Files 阶段。

Debug 构建配置使用 `io.github.medicoderhz.bookshelf.debug` 容器并关闭 Hardened Runtime，以便临时签名加载 Sparkle；App Sandbox 保持开启。日常体验不启动该配置，统一通过 `install-local.sh` 更新固定的 Release 应用入口。Release 发行配置保持 Hardened Runtime，正式发行必须使用 Developer ID 签名、公证；本机安装脚本只对暂存副本进行临时签名，不修改发行配置。

更新配置及发布脚本测试：

```sh
python3 -m unittest discover -s scripts/tests
python3 scripts/check-update-config.py --app /path/to/Bookshelf.app
```

正式分发还需 `--distribution` 检查，详见 [分发与更新](DISTRIBUTION.md)。线上清单未发布前，`BOOKSHELF_UPDATES_ENABLED = NO` 是有意配置，不影响书籍与笔记功能。
