# GitHub 分发与 Sparkle 更新

Bookshelf 采用 MIT 许可证，通过 GitHub 提供源码与 macOS 应用。0.1.1（构建 10）分别提供 Apple 芯片和 Intel 的 DMG。手动安装和 Sparkle 应用内更新共用这两份文件。[下载与校验文件](https://github.com/MediCoderHZ/Bookshelf/releases/tag/v0.1.1) · [从源码构建](BUILDING.md)

## 已配置的身份与渠道

| 项目 | 配置 |
| --- | --- |
| 正式 Bundle Identifier | `io.github.medicoderhz.bookshelf` |
| Debug Bundle Identifier | `io.github.medicoderhz.bookshelf.debug` |
| 安装包 | `https://github.com/MediCoderHZ/Bookshelf/releases` |
| 更新清单 | [main 分支的 appcast.xml](https://raw.githubusercontent.com/MediCoderHZ/Bookshelf/main/Distribution/Updates/appcast.xml) |
| Sparkle | 2.10.1，SwiftPM 与 Xcode 均固定版本并提交锁文件 |
| 更新签名密钥账户 | macOS 钥匙串中的 `io.github.medicoderhz.bookshelf` |

`Config/Release.xcconfig` 保存公开配置，包括 Ed25519 公钥。私钥由 Sparkle 官方工具生成，保存在本机登录钥匙串中，没有导出到仓库或日志。Apple Developer ID 签名与 Sparkle 更新签名用途不同，两者都应保留。

从 0.1.1 起，选择「Bookshelf → 检查更新…」会从 GitHub 读取清单。清单按芯片提供 DMG，并记录构建号、文件长度和 Ed25519 签名。自动检查需取得用户许可，系统分析默认关闭。

已发布的 0.1.0 DMG 内置的更新开关为关闭状态。0.1.0 用户需手动下载一次 0.1.1，退出 Bookshelf 后替换原位置的应用。此后即可在应用内检查更新。[Apple 芯片 DMG](https://github.com/MediCoderHZ/Bookshelf/releases/download/v0.1.1/Bookshelf-0.1.1-macos-arm64.dmg) · [Intel DMG](https://github.com/MediCoderHZ/Bookshelf/releases/download/v0.1.1/Bookshelf-0.1.1-macos-x64.dmg)

## 发布 DMG 与更新清单

1. 更新版本与构建号，将审核后的源码推送至仓库的默认分支 `main`。Release 的版本标签指向打包所用的提交。
2. 确认公开仓库默认分支 `main` 包含 `Distribution/Updates/appcast.xml`。更新器直接读取该文件的原始内容。
3. 检查清单原始地址可以通过 HTTPS 读取并返回有效 RSS XML。确认待发布应用内的 `BookshelfUpdatesEnabled` 为 `YES`，`SUFeedURL` 与上表一致，`SUPublicEDKey` 对应发布用的签名密钥。
4. 配置自己的 Apple Developer Program 团队、Developer ID Application 证书和必要联系信息。本机签名设置使用被忽略的 `Config/Release.local.xcconfig`。不要直接复制仍含 `REPLACE_*` 的示例进行发布，也不要覆盖已确定的应用身份和公钥。
5. 运行完整测试，从同一提交生成 arm64、x86_64 两个 Release 应用，保留 Hardened Runtime 和 App Sandbox。为各架构的应用及嵌套组件签名，完成 Apple 公证并装订。分别制作带有「应用程序」链接的 DMG，为磁盘映像签名、公证并装订。
6. 对原始双架构应用运行 `preflight.py`（`build-release.sh` 会自动执行）。随后分别对已装订的 arm64 和 x86_64 应用运行分发检查，再用最终的两份 DMG 生成 Sparkle 更新清单。以 0.1.1 为例：

   ```sh
   python3 scripts/preflight.py --app /path/to/universal/Bookshelf.app
   python3 scripts/check-update-config.py --app /path/to/arm64/Bookshelf.app --distribution
   python3 scripts/check-update-config.py --app /path/to/x86_64/Bookshelf.app --distribution
   bash scripts/prepare-update.sh --dmgs \
     dist/Bookshelf-0.1.1-macos-arm64.dmg \
     dist/Bookshelf-0.1.1-macos-x64.dmg \
     dist/sparkle-0.1.1
   ```

   输出目录应为新目录。脚本从已完成的 DMG 生成 `appcast.xml` 和 `SHA256SUMS.txt`。清单里的两条下载地址分别对应上传到 Release 的原始 DMG。签名后修改或重新压制 DMG 都需要重新生成签名与校验值。
7. 在相应的 GitHub Release 上传两个 DMG 和 `SHA256SUMS.txt`，填写发行说明。Sparkle 和手动下载均使用这些 DMG。
8. 确认 Release 附件可下载后，用生成的清单替换 `Distribution/Updates/appcast.xml` 并合入远程 `main`。待 GitHub 原始文件缓存刷新，在上表的地址核对新构建号、附件地址和签名。客户端下次检查时即可读取新条目。

`build-release.sh` 生成本地双架构应用，并自动运行 `preflight.py --app` 检查产物。为 GitHub Releases 准备可直接下载的应用时，再使用 `check-update-config.py --distribution` 验证 Developer ID 签名、公证票据和 Sparkle 配置。

## 后续版本

- 保持正式 Bundle Identifier、应用文件名 `Bookshelf.app`、更新清单地址和签名密钥稳定。
- 修改 `MARKETING_VERSION` 并递增 `CURRENT_PROJECT_VERSION`。0.1.1 的构建号为 10，后续版本应高于已分发构建及清单中的构建号。
- 从当前主分支的更新清单生成新清单，以保留以前的版本条目。正式更新包必须与对应 Git 标签的源码一致。
- 重复测试、归档、签名、公证、打包；先上传 Release 附件，再发布新清单。已发布附件和其签名不可单独替换。
- 发布后用已启用 Sparkle 的旧构建和测试书库验证发现更新、下载、安装、重启及数据保留。检查断网、取消和损坏包处理。两种处理器分别验证。

## 构建与发布工作流

- `.github/workflows/ci.yml`：默认分支推送、PR 和手动触发时运行发布工具测试、XCTest、双架构未签名构建与 Sparkle 嵌入检查。源码发布阶段只保留检查结果，应用安装包由正式签名发布流程提供。
- `.github/workflows/pages.yml` 可按需将清单镜像到 GitHub Pages。应用使用上表中的原始文件地址。
- 自动签名、公证与 Release 上传暂未接入 CI；待首个正式包人工验证通过后再配置受保护的发布环境。

## 密钥与工具

运行 `verify-project.sh` 后，Sparkle 工具位于构建根目录的 `SwiftPMBuild/artifacts/sparkle/Sparkle/bin/`。`prepare-update.sh` 自动使用此位置，也可用 `SPARKLE_BIN` 覆盖。

```sh
# 查看已有公钥；不会导出私钥
"$SPARKLE_BIN/generate_keys" --account io.github.medicoderhz.bookshelf -p
```

首次正式发布前应将钥匙串里的更新私钥安全备份到密码管理器或离线加密介质。不要将私钥、`.p12`、`.p8`、认证令牌放入源码、构建日志、Release 附件或普通 CI artifact；`.gitignore` 只能辅助防误提交，不能保护已追踪的文件。更换电脑或签名账户时先恢复同一密钥，不要给现有用户随意生成新公钥。

Apple 证书缺失时，可以完成源码构建和本地接入测试，但正式分发预检会拒绝未签名、临时签名、无公证票据或仍关闭更新的应用。

## 数据兼容

当前版本在 Sparkle 更新获准继续前创建完整备份，安装重启和待退出安装路径通过更新委托与应用退出委托补做最新备份。备份失败时停止或暂停升级，取消或跳过更新后恢复正常退出。回调依据 [Sparkle 更新委托文档](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html) 接入；线上完整安装链路仍需在签名发布后验收。

应用版本／构建号改变或首次启用此保护时，在创建 `ModelContainer` 前使用 SQLite backup API 生成现有数据库的独立快照，包含 WAL 中已提交的数据；备份失败不进入迁移。日常本机安装脚本也会在替换应用前执行同样的快照校验。定时与手动快照包含 JSON、数据库及可用的恢复草稿，升级前快照独立保留 10 份。具体使用见[自动备份与历史恢复](USER-GUIDE.md#自动备份与历史恢复)。

此前验证版使用不同的 Bundle Identifier，与正式版容器隔离。当前开发机已备份并合并旧书库到 `io.github.medicoderhz.bookshelf`，并完成正文、关联和重启读取检查；原容器与备份保留在本机，不纳入 Git。

后续本机安装统一使用 `scripts/install-local.sh`，固定入口为 `~/Applications/Bookshelf.app`，不再切换验证版书库。今后的正式更新保持 Bundle Identifier 不变，并继续通过现有 SwiftData 迁移与备份机制保留数据。其他机器若仍有旧容器，迁移前应先备份；JSON 导入会按已有导入规则匹配书目，不能直接当作无损数据库合并。

## 官方参考

- [Sparkle 接入](https://sparkle-project.org/documentation/)、[SwiftUI 接入](https://sparkle-project.org/documentation/programmatic-setup/)、[沙盒配置](https://sparkle-project.org/documentation/sandboxing/)、[发布更新](https://sparkle-project.org/documentation/publishing/)
- [Apple Developer ID](https://developer.apple.com/developer-id/)
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
