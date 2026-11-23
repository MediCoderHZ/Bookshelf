# 参与贡献

欢迎通过 [Issues](https://github.com/MediCoderHZ/Bookshelf/issues) 报告问题、提出建议，通过 Pull Request 提交修改。提交贡献表示同意以本项目的 [MIT 许可证](LICENSE) 分发这些贡献。

## 本地开发

1. Fork 并克隆仓库，安装支持 Swift 6 的完整版 Xcode，完成首次启动设置。
2. 打开 `Bookshelf.xcodeproj`，使用 `Bookshelf` Scheme。首次构建会下载固定版本的 Sparkle。
3. 阅读 [目录约定](Docs/PROJECT-STRUCTURE.md) 和 [架构说明](Docs/ARCHITECTURE.md)，将修改放入相应功能目录。
4. 提交前运行 `bash scripts/verify-project.sh` 和 `python3 -m unittest discover -s scripts/tests`；改动应用、配置或资源时，再运行 `bash scripts/build-release.sh`。

具体工具链与缓存设置见 [构建与测试](Docs/BUILDING.md)。本机日常体验先退出“Bookshelf”，运行 `bash scripts/install-local.sh` 更新固定的 `~/Applications/Bookshelf.app`，再打开同一入口，继续使用现有书库。Debug 配置使用独立的 `.debug` 数据容器，日常验证不另外启动它；自动测试使用临时数据。数据迁移前应先备份，具体兼容说明见 [分发与更新](Docs/DISTRIBUTION.md#数据兼容)。

## 修改与反馈

- 说明具体问题、预期行为、实际行为、macOS 与应用版本，并提供最小复现步骤。
- 为数据写入、版本迁移、更新配置等行为增加有意义的回归验证；保留已有迁移样本。
- 不要上传真实书库、含个人信息的备份、认证信息、签名私钥或本机配置。使用脱敏的最小样本。
- 新增应用 Swift 文件时同步 Xcode Sources；SwiftPM 会递归发现测试文件。
- 修改依赖时同时更新 `Package.swift`、Xcode 包引用和两份 `Package.resolved`，保留第三方许可。
- Pull Request 说明改动目的和验证结果。构建验证产物未经正式签名、公证，不作为公开发行包。

## Fork 与自行发布

自行发行时请使用自己的 Bundle Identifier、仓库地址、更新清单和 Sparkle 密钥；不要沿用原项目的更新渠道。公开配置可以提交，签名私钥只保存在钥匙串或受保护的 CI Secrets 中。发布流程见 [GitHub 分发与更新](Docs/DISTRIBUTION.md)。
