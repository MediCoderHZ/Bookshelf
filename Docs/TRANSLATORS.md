# 元信息 Translator 系统

本系统借鉴 [Zotero translator 的描述信息、target、detectWeb、doWeb 与优先级回退](https://www.zotero.org/support/dev/translators)，用于提取书籍元信息。内置适配器包括豆瓣和 Goodreads。普通网站可通过导入 JSON 规则扩展，复杂 DOM 可通过 Swift 适配器扩展。界面、网络和书籍保存不依赖具体网站。

## 四类统一能力

`TranslatorRegistry` 是统一注册中心，`TranslationEngine` 负责派发；能力由协议实现推导。豆瓣和 Goodreads 实现 Web + Search，Open Library 实现 Search，RIS 实现 Import + Export，CSV 实现 Export。`TranslatorStore.catalog` 包含全部能力；`registry` 是为既有网页代码保留的 Web 投影。

文件适配器实现 `FileImportTranslator`（扩展名、`detectImport`、`doImport`）或 `FileExportTranslator`（扩展名、格式说明、`doExport`）。导入返回 `BibliographicImportResult` 并进入冲突预览；导出接收书籍值快照。新增文件或独立搜索适配器加入 `BuiltinTranslators.catalog`，新增网页适配器仍可加入 `BuiltinTranslators.all`，它会自动进入总注册中心。设置统一保存所有类别的启停状态，导出窗口按已启用能力生成格式列表。

网络通过可注入的 `TranslationHost` 提供，解析器不接触数据库。完整分层见 [架构说明](ARCHITECTURE.md)。

## 网页处理流程

```mermaid
flowchart LR
  A[网址或本地 HTML] --> B[Registry: 匹配网址及启用状态]
  B --> C[按 priority、ID 排序]
  C --> D[detectWeb: book / multiple / nil]
  D -->|nil| C
  D -->|识别| E[doWeb: 提取统一字段或候选图书]
  E --> F[主程序校验来源]
  F --> G[预览]
  G --> H[解析器测试展示结果]
```

在线请求由 `WebMetadataClient` 发出；检测与解析不发请求。同一文档按优先级检测，`nil` 才继续尝试下一适配器；实际提取错误会显示，不静默吞掉。候选列表去重并限制为 60 本，用户选择后才读取下一页。来源由主程序记录。

| 部件 | 职责 |
| --- | --- |
| `TranslatorDescriptor` | 稳定 ID、名称、版本、作者、目标说明、优先级 |
| `WebMetadataTranslator` | `canonicalURL`、`detectWeb`、`doWeb` 协议 |
| `WebTranslatorRegistry` | 动态注册、启用筛选、优先级、检测回退、统一输出校验 |
| `HTMLMetadataDocument` | libxml2 DOM、XPath、文本与段落工具；不运行页面代码 |
| `RuleBasedWebTranslator` | 将声明式 JSON 映射成协议实现 |
| `TranslatorStore` | 本机安装、同 ID 替换、移除、启用状态和损坏文件诊断 |
| `WebMetadataClient` | 统一网络会话、类型/体积限制、取消和重定向限制 |
| `TranslatorSettingsView` | 管理、导入预览、模板导出、规则导出和独立测试 |
| `WebMetadataImportView` | 设置中的解析器测试：网址输入、自动匹配、预览和 HTML 导入 |

## 最快验证：导入第二个网站的规则

1. 打开设置 → 元信息解析器 → 管理元信息解析器 → 导入解析规则。
2. 选择 `Examples/Translators/publisher-example.json`，确认名称、版本与目标域名后导入。
3. 点击“示例出版社”的“测试”，输入 `https://books.example.org/book/123`。
4. 点击“导入已保存网页”，选择同目录的 `detail.html`，可看到作者甲/作者乙、译者丙、出版社等。此步骤不访问示例网站，也不写入书库。
5. 以 `https://books.example.org/catalog` 和 `list.html` 可测试列表。示例域名仅作本地演示，列表选书会触发真实请求，因此请用详情 HTML 测试详情提取。

这个示例不假装支持一个真实出版社。接入实际网站时，需按它的公开 HTML 修改域名、路径与 XPath，再用保存的真实页面核对结果。实际在线可用性还受站点策略影响。

## JSON 规则格式 v1

可在管理界面“导出规则模板”，或复制示例 JSON。

| 字段 | 说明 |
| --- | --- |
| `schemaVersion` | 当前为 `1`，未知格式版本拒绝导入 |
| `id` | 3–64 位，以小写字母开头，仅小写字母、数字、`.`、`-`；同 ID 导入会显示替换确认，内置 ID 不可覆盖 |
| `name` / `author` / `version` | 显示名称、作者和 `1.0.0` 形式版本；版本用于识别，允许用户显式替换为旧版本 |
| `priority` | 1–10000，数字越小越优先；相同优先级按稳定 ID 排序 |
| `targets` | 精确小写域名 `host` + 路径前缀 `pathPrefix`；可选 `exactPath: true` 表示路径必须完全相等 |
| `book.detect` | 返回节点集合的 XPath，匹配书籍特有结构；还需 title 有内容才判定为书籍 |
| `book.fields` | 字段到 XPath 的映射；title 必需，其余可省略；可选 `splitBy` 分隔一段文字中的多个人名 |
| `list` | 可省略；`detect` 检测列表，`items` 找候选节点，`title` 与 `url` 相对每个候选节点求值 |

支持的书籍字段为 `title`、`subtitle`、`originalTitle`、`authors`、`translators`、`publisher`、`publicationDate`、`isbn`、`pageCount`、`languageCode`、`description`。旧版 `coverHosts` 和 `book.fields.coverURL` 会在解码前忽略；其他未知书籍字段拒绝导入。作者/译者读取所有匹配节点；简介将各节点用空行连接；其他字段读取第一个值。`pageCount` 应为纯正整数，出版日期保留站点原文。ISBN 会清理连字符并按长度区分 10/13 位，仍需人工核对版本。

XPath 必须返回节点集合，例如 `//h1`、`//meta[@name='isbn']/@content`、列表内的 `@href`。不使用 `string(...)` 或 `boolean(...)` 等标量表达式。文本会去除多余空白、解码 HTML 实体；目前不支持正则替换、任意脚本或异步接口调用。规则文件上限 256 KB，导入会检查必需字段、域名、版本和 XPath。

规则目标匹配保留查询参数、移除片段，HTTP 地址规范化为 HTTPS。列表链接必须仍匹配当前解析器目标；需要多个路径或域名时显式添加 target。普通前缀 `/book` 也会匹配 `/bookstore`，推荐以 `/book/` 表达目录。

## Swift 适配器扩展

复杂布局可实现 `WebMetadataTranslator`。参考 `Bookshelf/Translation/DoubanBookTranslator.swift`：

```swift
var descriptor: TranslatorDescriptor { /* ID、名称、版本、作者、目标、优先级 */ }
func canonicalURL(for url: URL) -> URL? // 只接受本网站支持的页面
func detectWeb(in document: HTMLMetadataDocument, url: URL) throws -> WebPageKind?
func doWeb(in document: HTMLMetadataDocument, url: URL, kind: WebPageKind) throws -> TranslatedWebPage
```

把新适配器加入 `BuiltinTranslators.all`，并把 Swift 文件加入 Xcode target，即完成注册。管理界面、启用设置、候选选择、网络请求和预览自动复用。SPM 自动发现源码文件。新增适配器应提供详情、列表、缺失字段、验证/错误页和 URL 边界测试。

协议约定：网址匹配和检测应轻量；`detectWeb` 返回 `.book`、`.multiple` 或 `nil`；`doWeb` 返回统一元信息或候选列表，不能直接写书库。主程序负责填充来源。系统不是 Zotero JavaScript 运行环境，不能直接导入其 `.js` 文件；已实现原生 Import/Export 类型；浏览器 Connector 尚未实现。原生解析器可实现下述可选搜索能力。

### 书名与 ISBN 搜索

`BookSearchTranslator` 扩展网页协议，提供 `searchURL(for:)` 和 `searchResults(in:url:)`。注册后自动成为搜索来源；停用状态同时约束搜索和详情。自定义 JSON v1 仍只提供网页提取，不会因为启用就自动参与关键词搜索。

豆瓣 v1.2.0 使用 www.douban.com/search?cat=1001&q=… 的公开 HTML；搜索结果中的 link2 包装在本地解码，只接受 book.douban.com/subject/ 图书链接，不请求任意跳转目标。Goodreads v1.1.0 使用 /search?q=…&search_type=books，解析结果表格，忽略推荐区域。候选仅提供标题与页面摘要；选择后复用原详情 translator，避免将搜索页署名或作品首次出版年混入版本字段。每站首批最多 20 个候选，不自动翻页或批量下载详情。

`MetadataSearchService` 统一三个来源，结果 ID 包含来源，部分失败不会清空其他站结果。Goodreads ISBN 查询若跳到详情，可直接预览已读取的结果。搜索特有的重定向最多 3 次，仅允许同主机 HTTPS 且仍匹配该 translator 的路径；登录、站外、降级或循环跳转失败。编辑查询、切换来源、停用解析器或关闭窗口会取消任务，并用请求标识丢弃过期结果。ISBN 缺失或不同会提示核对，不把查询号码伪装成页面提供的 ISBN。

`BOOKSHELF_LIVE_SEARCH=1 swift test --filter MetadataSearchTests` 可显式验证两站的书名与 ISBN 查询到详情的完整链路。普通测试使用自制样本和可注入网络服务，覆盖部分失败、取消、启用状态、重定向边界、候选去重和版本核对。

## 安装、隐私与维护

### Goodreads 适配器

`goodreads-books` 以独立 Swift 文件注册，无网站专属界面。支持 www.goodreads.com/goodreads.com 的 `/book/show/<ID>-slug`、旧式 `<ID>.Title`、首页、`/search`、`/search/index`、`/list/show/...` 和 `/shelf/show/...`。详情页清理跟踪参数，搜索保留 q/search_type/page。列表按图书 ID 去重，最多 60 本。

新版 Goodreads 的当前版本数据来自 `__NEXT_DATA__` 中的 Apollo 缓存；适配器按网址中的 legacyId 精确选择 Book，解析作者/译者角色与 Book.details。推荐书目、其他版本、编辑/朗读者不会混入作者；Work.details 只提供原书名，不用其首次出版日期填充版本日期。嵌入认证、广告和用户对象不参与字段解码，不使用其中的 token 请求接口。JSON 以原始文本读取，避免空白处理破坏内容。

无可用缓存时回退到匹配图书的 JSON-LD；明确属于其他 ID 的结构化元信息不会被选中。ISBN、出版信息或语言缺失时不猜测。保存的 HTML 与输入图书 ID 不符时提示错误。

新增测试覆盖精确版本、作者角色、缺失字段、JSON-LD @graph、验证页和域名边界。`BOOKSHELF_LIVE_GOODREADS=1 swift test --filter GoodreadsTranslatorTests/testLiveGoodreadsWhenRequested` 可显式检查详情和首页；普通测试不联网。真实网页样本只用于本机检查，仓库内仅保留自制的小型测试数据。

### 本机规则维护

自定义规则保存于应用 Application Support 下的 `Bookshelf/Translators/<id>.json`，采用原子写入。同 ID 替换保留启用状态，损坏文件只影响自身，管理界面会报告原因。启用状态按 ID 保存；旧版豆瓣停用偏好会迁移。规则不包含在书库 JSON 备份中，可逐项导出。

导入规则不会发出网络请求。页面请求必须匹配已启用规则；使用临时会话，不读取浏览器 Cookie，不执行网页或规则脚本。普通提取不跟随重定向，搜索仅允许上述受限跳转。不接受 IP 地址、常见本地域名、带凭据的 URL 或非标准端口。页面限制 3 MB；HTML 本地导入不加载关联资源。自定义网站也会收到请求网址、IP 与应用标识，数据处理以对应服务政策为准。

JavaScript 动态渲染的页面可能没有可解析的静态内容；验证码、认证、网站结构变化与限流也可能阻止提取。解析器不会绕过这些限制。需修改规则或手动录入，不能把“可以导入规则”理解成“任意网站均可自动提取”。内置适配器随 App 更新，自定义规则由用户手动导入更新，目前没有远程更新源。

## 测试

`swift test --scratch-path work/SwiftPMBuild` 默认离线，覆盖注册回退、版本与规则校验、第二站点详情/列表、域名边界、规则持久化/替换/移除、损坏文件隔离及豆瓣回归。管理界面的“测试”可验证实际 HTML，不保存书籍；在线提取仍会请求相应网站。

豆瓣与 Goodreads 网络测试均为显式可选，避免常规测试依赖站点可用性。所有自定义网站接入后都应自行增加页面样本和字段断言。
