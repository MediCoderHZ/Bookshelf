# 元信息 Translator 系统

本系统借鉴 [Zotero translator 的描述信息、target、detectWeb、doWeb 与优先级回退](https://www.zotero.org/support/dev/translators)，用于提取书籍元信息。内置的豆瓣、Goodreads 和 Open Library 各使用一个 JavaScript 文件。普通网站可通过导入 JSON 规则扩展。界面、网络和书籍保存不依赖具体网站。

## 网页解析与搜索

`TranslatorRegistry` 是统一注册中心，`TranslationEngine` 负责派发；能力由协议实现推导。豆瓣和 Goodreads 实现 Web + Search，Open Library 实现 Search。`TranslatorStore.catalog` 包含全部能力；`registry` 是为既有网页代码保留的 Web 投影。

在「设置 → 文件与数据库 → 元信息解析器」中可以启用或停用来源。新增搜索适配器加入 `BuiltinTranslators.catalog`，网页适配器加入 `BuiltinTranslators.all` 后会自动注册。

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
| `TranslatorSettingsView` | 来源启停、打开目录、重新加载及自定义规则管理 |

## 安装示例规则

1. 在「设置 → 文件与数据库 → 管理元信息解析器…」打开「更多操作 → 导入解析规则…」。
2. 选择 `Examples/Translators/publisher-example.json`，核对名称、版本和目标域名后导入。
3. 在列表中找到「示例出版社」，用开关调整启用状态。右键该规则可以导出或移除。

开发者可运行 `bash scripts/verify-project.sh --filter TranslatorSystemTests`，用仓库中的详情页和列表页样本验证字段提取。示例域名仅用于离线验证。

## JSON 规则格式 v1

可复制示例 JSON 并按实际站点修改。

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

## 内置 JavaScript 解析器

应用启动时把三个脚本安装到 当前数据库 `default.store` 旁的 `translators/` 文件夹。在元信息解析器窗口点击「打开解析器目录」可以同时看到三个文件和自定义 JSON 规则。保留脚本文件名与头部 ID，编辑后点击「重新加载」即可使用本机修改。下表链接指向随应用分发的默认源码。

| 脚本 | 入口与用途 |
| --- | --- |
| [douban-books.js](../Bookshelf/Resources/Translators/douban-books.js) | `detectWeb` 识别详情与列表，`doWeb` 提取书目，`doSearch` 读取搜索结果 |
| [goodreads-books.js](../Bookshelf/Resources/Translators/goodreads-books.js) | 同样的网页入口，从当前版本缓存、JSON-LD 或 HTML 提取字段 |
| [open-library.js](../Bookshelf/Resources/Translators/open-library.js) | `requestURL` 生成书名或 ISBN 请求，`doSearch` 把 JSON 响应转换为书目 |

文件开头的注释含 JSON 元数据。`translatorID` 同时用于启停偏好和来源识别，更新时保留原值。`targets` 声明允许的网页域名、路径和查询参数，`search` 是供用户打开的搜索网址模板。网页入口收到只读的 `doc` 和规范化的网址信息。可通过 `doc.nodes` 和 `doc.first` 按 XPath 取节点，用 `doc.text`、`doc.attr`、`doc.lines` 或 `doc.raw` 读取内容。`detectWeb` 返回 `book`、`multiple` 或 `null`。Open Library 的搜索入口接收查询及原始 JSON 字符串。

主程序使用系统 JavaScriptCore 执行解析器目录中已加载的脚本，负责网络请求、网址校验和元信息预览。每次调用使用独立上下文，输入的 HTML 和 JSON 作为数据读取。第三方扩展入口继续接受 Bookshelf JSON 规则。Zotero 社区脚本使用的 `Zotero.Item`、`ZU` 和浏览器 DOM 属于另一套接口。

### 书名与 ISBN 搜索

`BookSearchTranslator` 扩展网页协议，提供 `searchURL(for:)` 和 `searchResults(in:url:)`。注册后自动成为搜索来源；停用状态同时约束搜索和详情。自定义 JSON v1 仍只提供网页提取，不会因为启用就自动参与关键词搜索。

豆瓣使用 www.douban.com/search?cat=1001&q=… 的公开 HTML；搜索结果中的 link2 包装在本地解码，只接受 book.douban.com/subject/ 图书链接，不请求任意跳转目标。Goodreads 使用 /search?q=…&search_type=books，解析结果表格，忽略推荐区域。候选仅提供标题与页面摘要；选择后复用原详情 translator，避免将搜索页署名或作品首次出版年混入版本字段。每站首批最多 20 个候选，不自动翻页或批量下载详情。

`MetadataSearchService` 统一三个来源，结果 ID 包含来源，部分失败不会清空其他站结果。Goodreads ISBN 查询若跳到详情，可直接预览已读取的结果。搜索特有的重定向最多 3 次，仅允许同主机 HTTPS 且仍匹配该 translator 的路径；登录、站外、降级或循环跳转失败。编辑查询、切换来源、停用解析器或关闭窗口会取消任务，并用请求标识丢弃过期结果。ISBN 缺失或不同会提示核对，不把查询号码伪装成页面提供的 ISBN。

`BOOKSHELF_LIVE_SEARCH=1 swift test --filter MetadataSearchTests` 可显式验证两站的书名与 ISBN 查询到详情的完整链路。普通测试使用自制样本和可注入网络服务，覆盖部分失败、取消、启用状态、重定向边界、候选去重和版本核对。

## 安装、隐私与维护

### Goodreads 适配器

`goodreads-books` 由独立的 JavaScript 文件提供，无网站专属界面。支持 www.goodreads.com/goodreads.com 的 `/book/show/<ID>-slug`、旧式 `<ID>.Title`、首页、`/search`、`/search/index`、`/list/show/...` 和 `/shelf/show/...`。详情页清理跟踪参数，搜索保留 q/search_type/page。列表按图书 ID 去重，最多 60 本。

新版 Goodreads 的当前版本数据来自 `__NEXT_DATA__` 中的 Apollo 缓存；适配器按网址中的 legacyId 精确选择 Book，解析作者/译者角色与 Book.details。推荐书目、其他版本、编辑/朗读者不会混入作者；Work.details 只提供原书名，不用其首次出版日期填充版本日期。嵌入认证、广告和用户对象不参与字段解码，不使用其中的 token 请求接口。JSON 以原始文本读取，避免空白处理破坏内容。

无可用缓存时回退到匹配图书的 JSON-LD；明确属于其他 ID 的结构化元信息不会被选中。ISBN、出版信息或语言缺失时不猜测。保存的 HTML 与输入图书 ID 不符时提示错误。

新增测试覆盖精确版本、作者角色、缺失字段、JSON-LD @graph、验证页和域名边界。`BOOKSHELF_LIVE_GOODREADS=1 swift test --filter GoodreadsTranslatorTests/testLiveGoodreadsWhenRequested` 可显式检查详情和首页；普通测试不联网。真实网页样本只用于本机检查，仓库内仅保留自制的小型测试数据。

### 本机规则维护

首次升级会将旧版应用支持目录 `Bookshelf/Translators/` 的内容复制并校验到当前书库。新目录已有的同名文件优先，旧目录保留供恢复。此后在设置中迁移数据库，会一并复制当前的 `translators/`。

自定义 JSON 规则保存在当前数据库 `default.store` 旁的 `translators/` 文件夹。点击「打开解析器目录」即可在 Finder 中添加或编辑文件。规则按 JSON 内的 `id` 识别，可自行命名文件。选择「更多操作 → 重新加载」、重新打开管理窗口，或从 Finder 切回已打开的管理窗口，均可应用修改。导入同 ID 的规则会更新原文件并保留启停状态。多个文件声明同一 ID 时，该 ID 暂停加载，窗口列出冲突文件供核对。更新 Bookshelf 时，仍与上次安装内容一致的脚本会更新，手动编辑过的文件会保留。缺失的默认脚本会在下次加载时补齐。语法错误会显示在管理窗口，其他来源仍可用。笔记模板保存在应用支持目录下的 `Bookshelf/Plugins/`。

导入规则不会发出网络请求。页面请求必须匹配已启用规则；使用临时会话，不读取浏览器 Cookie，不执行网页中的脚本。普通提取不跟随重定向，搜索仅允许上述受限跳转。不接受 IP 地址、常见本地域名、带凭据的 URL 或非标准端口。页面限制 3 MB；HTML 本地导入不加载关联资源。自定义网站也会收到请求网址、IP 与应用标识，数据处理以对应服务政策为准。

JavaScript 动态渲染的页面可能没有可解析的静态内容；验证码、认证、网站结构变化与限流也可能阻止提取。解析器不会绕过这些限制。需修改规则或手动录入，不能把“可以导入规则”理解成“任意网站均可自动提取”。可在同一目录单独备份脚本和规则。

## 测试

`swift test --scratch-path work/SwiftPMBuild` 默认离线，覆盖注册回退、版本与规则校验、第二站点详情/列表、域名边界、规则持久化/替换/移除、损坏文件隔离及豆瓣回归。

豆瓣与 Goodreads 网络测试均为显式可选，避免常规测试依赖站点可用性。所有自定义网站接入后都应自行增加页面样本和字段断言。
