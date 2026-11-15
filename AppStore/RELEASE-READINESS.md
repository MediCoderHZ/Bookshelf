# Mac App Store 发布准备

本地检查日期：2026-11-12。工作名称为“书架”；用户已确认正式名称和定价稍后决定。当前版本仍为 0.1.0 (1)，没有创建商店记录或上传。

## 已完成的本地准备

- Release 独立配置与本地覆盖模板；保留沙盒，权限限于网络客户端和用户选择的文件读写。
- PrivacyInfo.xcprivacy 已打包，声明不跟踪及应用内偏好设置的 UserDefaults 理由 CA92.1。
- 隐私正文与搜索界面说明查询词、IP 地址等网络信息；点击搜索后向所选来源查询。
- 设置显示版本/构建号，发布配置支持提供支持页与在线隐私政策入口。
- 书库启动失败显示错误，不自动删除或重建数据库。
- 商店中文文案、英文审核说明、支持页正文和截图分镜已备齐草案。
- 预检区分本地技术检查与正式提交检查。
- 通用网页 Translator 系统：网址匹配、优先级与检测回退、统一网络和预览；内置豆瓣与 Goodreads 适配器，自定义 JSON 规则导入/导出/替换/移除和独立测试。隐私与审核草案同步说明。
- 书名/ISBN 搜索支持豆瓣、Goodreads、Open Library 单站或并行查询；各来源独立返回结果，选择候选后读取详情，缺失或不同 ISBN 提示核对。启用状态同时约束搜索。
- 高级组合筛选和动态智能文件夹，规则随 schemaVersion 9 备份保存，兼容旧版 1–8。
- 批量编辑标签与常用出版信息，默认保持原样，逐本预览、过期预览保护和整批撤销/重做。
- RIS 图书导入/导出和 CSV 清单导出，范围与笔记选项预览、导入冲突和跳过提示；只读取用户选择的文件，不加载 RIS 附件或网址。
- 现有功能按 Zotero 核心职责完成原生分层：统一事务写入、提交后通知、命令与查询、窗口状态隔离；Web / Search / Import / Export 共用注册与启停。架构边界检查纳入 Release 构建，195 项回归中 186 项通过、9 项可选检查跳过。详见 [架构说明](../Docs/ARCHITECTURE.md)和 [VALIDATION.md](VALIDATION.md)。

- 右侧笔记编辑与本地自动保存：新建、查看、编辑共用面板；保存冲突保留草稿并支持另存，原生文本撤销与书库操作撤销各自保留。
- 原生书籍/笔记层级列表：子笔记显示在书籍下方，支持展开、选择详情、独立右键操作和搜索定位。
- 子文件夹层级与独立/书籍子笔记，原生编辑、搜索、回收站和撤销；新版备份保存空文件夹、父子关系与笔记关联，导入前预览并保护本地冲突。详见[文件夹与笔记](../Docs/ORGANIZATION.md)。

- 原生所见即所得笔记编辑：Markdown 输入自动转换，工具栏直接修改正文，列表续写、链接小面板、代码块及独立格式撤销；无模式切换，标题可选，旧标题保留。富文本与 Markdown 往返、输入法组合保护和备份测试通过。

## 发布配置

1. 将 Config/Release.local.xcconfig.example 复制为 Config/Release.local.xcconfig；本地文件已忽略，不存私钥。
2. 填写正式名称、注册的 Bundle ID、Team ID、版权、版本/构建号、支持/隐私网址及开发者联系邮箱。
3. URL 使用模板中的 https:/$()/ 写法，避免 xcconfig 将双斜杠当注释。
4. Debug 保持旧开发标识。最终 Bundle ID 改变会改变沙盒位置；先从旧版本导出 JSON，再在正式版恢复，不假定自动迁移。
5. Release.local 覆盖 Release.xcconfig；不要在 Target Build Settings 填写重复覆盖值。

## 验证命令

在项目目录运行：

    bash scripts/build-release.sh
    bash scripts/verify-project.sh

Release 脚本打印实际产物路径，默认为系统临时构建目录下的 `ReleaseCheck/Build/Products/Release/Bookshelf.app`，目标包含 arm64 和 x86_64。工具链及目录覆盖方法见[构建与测试](../Docs/BUILDING.md)。
此产物关闭了代码签名，仅用于本地构建检查，不是商店安装包，也不能证明实际签名沙盒行为。

检查源文件：

    python3 scripts/preflight.py

检查最终分发 .app：

    python3 scripts/preflight.py --app "/absolute/path/Bookshelf.app" --submission

正式模式检查分发签名和 AppStore/submission-checklist.json；有待办时返回失败。
只在完成且有证据后修改 confirmed。脚本不能替代网页内容检查、账号协议和 Organizer 在线校验。

## 提交待办

| 项目 | 状态 | 完成方式 |
| --- | --- | --- |
| 名称、定价、销售地区 | 用户稍后决定 | 名称可用性、最终品牌和价格 |
| 开发者身份与签名 | 未提供 | 付费账号、Team ID、注册标识、分发证书 |
| 支持/隐私公开网址 | 未提供、未发布 | 发布最终正文，实测免登录访问和联系渠道 |
| 第三方数据处理 | 待核实 | 查询/IP 日志保留、用途、身份关联 |
| 接口与内容权利 | 待确认 | 用途登记、接口条件和内容权利 |
| 最终截图 | 只有分镜 | 最终品牌、真实应用、有权使用的示例内容 |
| 商店问卷 | 未提交 | 年龄分级、出口合规、地区要求、可访问性 |
| 签名版验收 | 待完成 | 真实沙盒网络、文件选择、重启、升级 |
| 最低系统/Intel 运行 | 未实机验证 | macOS 14 与 Intel 实测；编译不等于运行验证 |
| Organizer/TestFlight | 未执行 | 完成身份后归档、验证并安排测试 |

## 隐私与外部服务审查

本地 SwiftData、笔记和偏好设置未上传开发者服务器；无第三方 SDK、登录、广告或分析代码。
Open Library 接收查询请求，能看到 IP 地址及应用标识等信息。仅凭“可选搜索”不能认定符合 Apple 的可选披露豁免，也不能直接勾选“未收集数据”。

豆瓣解析器直连 book.douban.com；站点可能限制直连，本版提供浏览器保存 HTML 后本地导入的路径。核实豆瓣网页提取、简介的使用条件，以及相应日志用途和保留。解析器以 Swift + 系统 libxml2 独立实现，参考 Zotero 架构，没有加载或复制 Zotero 的 GPL translator 脚本。隐私说明包含来源记录与本地 HTML 访问，不能因本地回退功能而忽略可选网络请求的披露。

自定义 JSON 规则仅声明域名、路径和 XPath 字段映射；没有可执行脚本、远程代码更新或任意文件访问。导入前展示目标域名，安装本身不联网。上线材料需说明用户可配置其他网站以及对应请求数据；检查真实站点内容使用条件，不能把示例域名当作已支持服务。内置适配器随 App 更新，自定义规则由用户显式导入更新。

Goodreads 适配器请求 www.goodreads.com。只读取公开 HTML 中的书目数据，不登录账号、不使用页面认证字段调用 API。页面提取、简介的使用条件，以及服务方日志处理同样属于发布前核实范围。

隐私清单已描述 API 使用，但暂未填写 NSPrivacyCollectedDataTypes；这不是最终“无收集”结论。需核实服务方是否将请求数据保留超过实时处理所需时间，并依实际用途确定 Search History 等类别、是否关联用户及用途。然后同步清单、公开正文与商店问卷，不猜测日志期限或替第三方作承诺。

应用仅通过系统框架使用 HTTPS，无自定义加密实现。出口合规仍需依实际问卷与销售地区确认，未自动填写 ITSAppUsesNonExemptEncryption。

Open Library 建议应用标识、开发者联系信息、缓存及人类触发的请求。本版使用内存缓存并阻止同一窗口重叠搜索；正式用途登记、规模评估和服务方确认尚未完成。API 可访问不等于无限商业服务。

## 签名和提交顺序

1. 确定产品与公开网页，在 Xcode Accounts 登录自己的开发者账号，选 Team。
2. 导出旧书库备份。使用 Release / Any Mac 归档，选 App Store Connect 分发，先 Validate。
3. 在 Organizer 检查签名权限、隐私报告、版本与 Bundle ID，处理所有错误。
4. 对实际分发产物运行 --submission；Developer ID 与临时签名不属于商店分发签名。
5. 确认后上传、完成 TestFlight，再填写审核信息。不要上传未签名的 ReleaseCheck 产物。
6. 账号持有人确认定价、地区、协议、税务和发布。上传、提交审核、发布是不同步骤。

## 人工验收

- 干净安装、已有书库升级、退出重启后的数据持久化。
- 新增编辑删除、重复提示、两种布局、多选和组合筛选。
- 多文件夹加入/移除；编辑后保留其他归属。
- 文件选择取消、权限错误及旧格式兼容。
- JSON 导出/导入/重复导入、无效 JSON、未知版本、旧格式兼容。
- 导入冲突默认跳过、逐条处理、不同 ISBN 保护、取消不写入与导入撤销。
- 回收站批量恢复、重启持久化、永久删除确认；合并字段选择、笔记分类保留与撤销/重做。
- 搜索和网页结果逐字段核对、默认仅补空白、取消编辑、保存后撤销；输入框与书库撤销快捷键区分。
- 在线搜索空结果、离线、超时、取消、重复点击和服务限流。
- 豆瓣详情/首页提取、访问限制、禁用解析器、HTML 导入、来源记录。
- Goodreads 当前版本匹配、作者角色、缺失字段、详情/列表与 HTML 导入。
- 最终签名权限与新 Bundle ID 的 JSON 迁移。
- macOS 14、当前系统、Apple Silicon/Intel，键盘、VoiceOver、深浅色与窄窗口。
- 公开网页与内置政策一致，商店不承诺未实现的阅读器或账号同步。

## 截图分镜

Apple 当前 Mac 规格为 16:10：1280×800、1440×900、2560×1600 或 2880×1800。建议统一 1440×900，使用真实窗口与无私人内容的测试书库。

1. 书籍列表：8–12 本自制示例元信息；“让藏书一目了然”。
2. 表格与详情：作者、出版社、日期；“每一本书，信息井然有序”。
3. 文件夹与标签组合筛选：“按你的方式整理”。
4. 笔记和阅读状态：“留下每一次阅读的想法”。
5. 实际书名/ISBN 候选结果：“搜索并补全书籍信息”，注明各结果来源。

不使用用户真实笔记；不把虚构界面当截图。名称未确定前保留分镜，最终图片需再次校验尺寸、品牌及内容权利。

## 官方依据

- [Apple 审核准备](https://developer.apple.com/app-store/review/)
- [隐私清单](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [API 允许理由](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons)
- [隐私标签定义](https://developer.apple.com/app-store/app-privacy-details/)
- [Mac 截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [出口合规](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- [Open Library 接口要求](https://openlibrary.org/developers/api)
- [Open Library 许可说明](https://openlibrary.org/developers/licensing)
