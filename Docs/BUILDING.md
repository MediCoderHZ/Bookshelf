# 构建与测试

本项目需要完整版 Xcode，既用于 SwiftData/SwiftUI 宏展开，也用于 XCTest 测试、Asset Catalog 编译和原生应用打包。单独安装 Command Line Tools 不足以验证本项目。

首次源码版已在 Xcode 27.2 从公开 ZIP 构建。GitHub CI 选择 Xcode 26.6；Xcode 16.4 的 SDK 会在撤销管理相关代码中报告并发隔离错误。应用的最低运行系统为 macOS 14。

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

安装脚本保留旧应用到 `work/LocalAppBackups/`，拒绝覆盖仍在运行的应用。在替换应用前，通过 `scripts/lib/backup_local_library.py` 将现有书库及恢复草稿备份到正式容器的 `Bookshelf/Backups/`，包含 WAL 数据并校验完整性；备份失败时停止安装。脚本读取 `Bookshelf/LibraryLocation.json` 中已经生效的目录，尚未执行的迁移仍备份原书库；自定义目录不可用、配置损坏或已初始化的数据库缺失时停止安装。脚本不启动应用，也不修改书库。安装完成后只打开 `~/Applications/Bookshelf.app`。默认本机数据位于 `~/Library/Containers/io.github.medicoderhz.bookshelf/Data/Library/Application Support/`；此前迁移备份仍保存在被 Git 忽略的 `work/LibraryMigration/`，不要上传个人书库。

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

## 界面语言资源

`Bookshelf/Resources/zh-Hans.lproj/Localizable.strings` 与 `en.lproj/Localizable.strings` 分别保存中文和英文界面文字；Xcode 和 SwiftPM 均打包这两份资源，各语言目录下的 `InfoPlist.strings` 同时本地化应用名称。应用文字通过 `L10n.tr` 读取，插值转换为 `{0}`、`{1}` 等编号，译文可调整参数顺序，参数内容本身不会再次参与翻译或格式解析。

应用进程使用 `Bundle.main.preferredLocalizations` 对应的启动语言。设置只保存 `requestedLanguage`，正常退出获准后才同步 `AppleLanguages`，避免当前进程新打开的系统面板提前改变语言；下次启动统一应用。设置标题由应用完整指定，不使用系统缓存后缀拼接。非应用测试进程固定中文基线，双语用例单独指定语言。

「重启应用」先调用现有备份控制器，再启动打包的 `relaunch.sh` 并确认准备就绪，通过正常终止流程退出。临时子进程继承应用沙盒，等待父进程的管道关闭及退出后，使用 `open -n -a` 在原路径启动新进程，避免 Launch Services 仍将普通打开请求交给已退出的旧实例。取消退出时会撤销重启；一次性偏好让新进程激活后回到设置页。Xcode 和 SwiftPM 都需包含该资源，产物预检会检查它。

新增界面文字时同步补全两种资源，并保留对应参数编号。书库字段、枚举原始值、解析器匹配词、历史迁移名称和用户内容应保持稳定，不能替换成翻译后的标签。`InterfaceLanguageTests` 检查资源、参数、偏好持久化、历史兼容和数据不变；原生表头在保留列对象与列宽的情况下刷新。

## 自定义数据目录与完整性检查

`LibraryLocationController` 在打开 SwiftData 前读取容器内 `Bookshelf/LibraryLocation.json`，通过用户在目录选择器中授予的安全作用域书签访问自定义目录。App Sandbox 保持开启，新增的 `com.apple.security.files.bookmarks.app-scope` 只用于持久保存用户所选目录的授权。

选择目录只保存待生效请求。下一次启动时，先备份原库，再通过 SQLite backup API 复制包含已提交 WAL 内容的快照，检查复制后的数据库及应用记录关联，成功后原子保存已生效的目录配置。目标必须为空，原数据库保留；失败时继续使用原目录并显示错误。已经生效的自定义目录不可访问或数据库缺失时停止打开，不回退到旧书库，也不创建空库。已初始化的默认数据库缺失时同样停止打开。解析器位于数据库同级的 `translators/` 文件夹，切换数据目录时一并复制并校验。备份、恢复草稿和偏好仍位于原应用容器中。

`LibraryIntegrity` 使用只读事务执行 `integrity_check` 和 `foreign_key_check`，并检查各模型的唯一标识、书籍关联和备份格式中的笔记／文件夹关系。该操作不修复、不删除，也不强制保存未提交修改。迁移与损坏数据用例统一使用临时测试书库。

## 当前验证状态

2026-11-18 设置精简为五类，解析器与隐私政策归入对应分类，删除重复入口并缩短说明。最终源码的完整 XCTest 仍为 539 项（529 通过、10 跳过、0 失败），双架构 Release 构建通过；固定应用中完成中英文全部分类、合并入口、搜索及双向重启验证，用户书库全部记录和目录配置保持一致。证据位于 `work/SettingsSimplification/`。

2026-11-16 自定义数据目录与完整性检查已使用 Xcode 27.2 完成验证：539 项 XCTest 中 529 项通过、10 项按设计跳过、0 项失败；Python 工具测试 16 项通过；arm64 / x86_64 Release 构建、双语应用名称和重启资源检查通过。最终英文文案调整后，15 项语言资源测试再次通过。固定入口中验证了中英文数据库设置、完整性检查、目录选择与取消、显示数据目录及双向语言重启；取消的目录更改不会在重启后生效。实际用户书库没有迁移，验证前后 10 类模型的全部记录一致。此前设置、重启、发布、备份、筛选和条目数量验证仍保留。当前范围见[完整版本验收记录](UPDATE-VALIDATION.md)，早期目录整理的验证保留在[初始验证记录](BUILD-VALIDATION.md)。

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
