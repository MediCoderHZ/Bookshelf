# GitHub 分发与 Sparkle 更新

Bookshelf 采用 MIT 许可证，通过 GitHub 提供源码与 macOS 应用。0.1.0（构建 9）以 DMG 提供手动安装与更新。应用和磁盘映像均经过 Developer ID 签名、Apple 公证并附有公证票据。[下载与校验文件](https://github.com/MediCoderHZ/Bookshelf/releases/tag/v0.1.0) · [从源码构建](BUILDING.md)

## 已配置的身份与渠道

| 项目 | 配置 |
| --- | --- |
| 正式 Bundle Identifier | `io.github.medicoderhz.bookshelf` |
| Debug Bundle Identifier | `io.github.medicoderhz.bookshelf.debug` |
| 安装包 | `https://github.com/MediCoderHZ/Bookshelf/releases` |
| 更新清单 | `https://medicoderhz.github.io/Bookshelf/appcast.xml` |
| Sparkle | 2.10.1，SwiftPM 与 Xcode 均固定版本并提交锁文件 |
| 更新签名密钥账户 | macOS 钥匙串中的 `io.github.medicoderhz.bookshelf` |

`Config/Release.xcconfig` 保存公开配置，包括 Ed25519 公钥。私钥由 Sparkle 官方工具生成，保存在本机登录钥匙串中，没有导出到仓库或日志。Apple Developer ID 签名与 Sparkle 更新签名用途不同，两者都应保留。

`BOOKSHELF_UPDATES_ENABLED` 暂为 `NO`，因为线上清单尚未发布；应用可正常使用，“检查更新…”会说明更新服务尚未启用。配置完整且该值为 `YES` 时，应用启动 Sparkle，自动检查前由 Sparkle 请求用户许可，默认不静默安装、不上传系统分析。用户可以从应用菜单选择“检查更新…”。

## 首次发布支持 Sparkle 自动更新的应用

1. 将审核后的源码推送至仓库的默认分支 `main`。本地历史原为 `master`；可以在确认后重命名，也可以明确推送 `master:main`。不要强推覆盖已有远程历史。保留基准标签 `baseline-2026-11-15`。
2. GitHub 仓库 Settings → Pages → Source 选择 **GitHub Actions**。在 Actions 中手动运行 **Publish update feed**，仅发布 `Distribution/Updates/`。初始 `appcast.xml` 是空清单，不含虚构安装包。
3. 确认更新清单 HTTPS 地址可读取且返回有效 RSS XML，再将 `BOOKSHELF_UPDATES_ENABLED` 改为 `YES`。首次公开安装包必须已包含更新器、公钥和正确清单地址。
4. 配置自己的 Apple Developer Program 团队、Developer ID Application 证书和必要联系信息。本机签名设置使用被忽略的 `Config/Release.local.xcconfig`。不要直接复制仍含 `REPLACE_*` 的示例进行发布，也不要覆盖已确定的应用身份和公钥。
5. 执行完整测试与本地双架构构建。使用 Xcode 的 Release Archive，Distribute App → Developer ID 路线签名并提交公证。使用 Xcode 的签名嵌入流程处理 Sparkle、其 XPC 服务和 Updater；保持 Release Hardened Runtime 和 App Sandbox 开启。导出的最终 `.app` 必须装订公证票据。
6. 对最终产物执行：

   ```sh
   python3 scripts/preflight.py --app /path/to/Bookshelf.app
   python3 scripts/check-update-config.py --app /path/to/Bookshelf.app --distribution
   bash scripts/prepare-update.sh /path/to/Bookshelf.app dist/sparkle-release
   ```

   打包脚本要求新的输出目录，会验证公钥与钥匙串匹配，使用 `ditto` 保留框架符号链接，生成 ZIP、SHA256SUMS.txt 和带更新包签名的 appcast，并再次验证签名。脚本不会上传或发布。
7. 在启用 Sparkle 的版本所对应的 GitHub Release 中上传更新清单引用的 ZIP 和校验文件，填写更新说明。用户手动安装时下载 DMG。
8. 确认安装包下载地址有效后，将生成的 `appcast.xml` 替换 `Distribution/Updates/appcast.xml`，提交并推送，再手动运行 **Publish update feed**。不要先发布指向尚不存在附件的更新条目。

`build-release.sh` 生成本地双架构应用，并自动运行 `preflight.py --app` 检查产物。为 GitHub Releases 准备可直接下载的应用时，再使用 `check-update-config.py --distribution` 验证 Developer ID 签名、公证票据和 Sparkle 配置。

## 后续版本

- 保持正式 Bundle Identifier、应用文件名 `Bookshelf.app`、更新清单地址和签名密钥稳定。
- 修改 `MARKETING_VERSION`（如 `0.1.1`）并递增 `CURRENT_PROJECT_VERSION`（如 `2`）。构建号必须高于现有清单中的所有构建号，脚本会拒绝覆盖或降级。
- 从当前主分支的更新清单生成新清单，以保留以前的版本条目。正式更新包必须与对应 Git 标签的源码一致。
- 重复测试、归档、签名、公证、打包；先上传 Release 附件，再发布新清单。已发布附件和其签名不可单独替换。
- 发布前在旧版的独立测试书库中创建书籍与笔记，验证发现更新、下载、安装、重启、数据保留；同时测试断网、取消和损坏包拒绝。首次跨版本在线升级仍需在渠道上线后实际验收。

## 构建与发布工作流

- `.github/workflows/ci.yml`：默认分支推送、PR 和手动触发时运行发布工具测试、XCTest、双架构未签名构建与 Sparkle 嵌入检查。源码发布阶段只保留检查结果，应用安装包由正式签名发布流程提供。
- `.github/workflows/pages.yml`：仅由维护者在默认分支手动运行，发布更新清单。仓库需先启用 Pages 的 GitHub Actions 来源。
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
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)、[配置 GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)
