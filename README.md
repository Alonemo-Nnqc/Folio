# Folio

轻量、原生的 macOS 文献管理软件。AppKit 搭建窗口、工具栏、菜单和标签页，SwiftUI 承载检查器、设置和弹窗，界面采用系统 Liquid Glass 风格。

- 拖入 PDF 后几秒内自动识别元数据并创建条目：Zotero 识别服务 + Crossref / arXiv / OpenAlex / DBLP / CVF 开放获取
- 内置阅读器（与"预览"同一引擎 PDFKit）：论文以原生标签页打开；高亮、下划线、删除线、便签、文本框、手绘，批注直接写回 PDF，与"预览"互通；记住每篇论文的阅读位置
- 保留排版的整篇翻译（pdf2zh_next / BabelDOC），支持 20 多种翻译服务，译文与原文可对照阅读
- 每个条目一篇 Markdown 笔记，可以在阅读时把选中的文字一键加入笔记
- AI 接入：内置 MCP 服务器和命令行工具 `folio-cli`，以及教 AI 使用 Folio 的技能；在 设置 ▸ AI 中按各智能体官方的方式一键为 Claude Code、Claude 桌面版、Codex、Gemini CLI、Copilot CLI、Cursor CLI、Antigravity 等 11 种智能体添加或移除
- 浏览器插件（Safari、Chrome、Edge、Brave、Arc、Firefox 等）：在论文页面一键保存到 Folio，可选分组和标签，并可同时保存 PDF；搜索结果、arXiv 列表等页面可批量保存
- 两级分组（可自定义颜色）、彩色标签、回收站、全文搜索、阅读状态与星级评分
- 每个条目可以挂多个文件，并可指定默认打开的文件；也可以随时用"预览"或其他应用打开
- 支持复制 BibTeX、GB/T 7714-2015、APA、IEEE、MLA、Chicago、Harvard、Vancouver、Nature 引用，导出 BibTeX / RIS / CSL JSON
- 可以一键从 Zotero 导入（只读取数据库副本，不会修改 Zotero）
- 1000 个条目时冷启动约 0.35 s，内存约 110–130 MB

需求、开发计划、测试报告和问题记录都在 [`doc/`](doc/) 目录下。

## AI 接入

Folio.app 内附带 `folio-cli`（`Folio.app/Contents/MacOS/folio-cli`）：

- `folio-cli mcp`：stdio 方式的 MCP 服务器（支持 MCP 2026-07-28 以及 2025-11-25 及更早的握手版本），26 个工具：检索（可按作者、年份、类型、阅读状态、标签过滤，可搜全文并返回命中片段）、读取全文（可只返回与问题相关的段落及页码）与批注、9 种格式的参考文献与文中引用、BibTeX / RIS / CSL JSON 导入导出、按 DOI / arXiv / PDF / 网址添加（可下载开放获取 PDF）、给条目附加文件、分组与标签管理、笔记、移到回收站；3 个提示词（查找论文、引用论文、总结论文）。
- `folio-cli call <工具> '<JSON>'` 以及 `search`、`get`、`cite`、`export`、`add`、`open` 快捷命令，供只能运行命令的智能体使用；`folio-cli status` 检查文献库与权限，`folio-cli agents` 查看或更改各智能体的安装状态。
- Folio 技能（`folio-library/`：`SKILL.md` + `references/`）教智能体如何根据描述找到论文、准确引用、写 LaTeX / Markdown / Word 时如何引用和导出，以及哪些操作需要先问用户。

在 设置 ▸ AI 中，Folio 只列出本机真实可用的智能体（App 完整，或命令能在终端中运行并报告版本），每个智能体有"MCP""技能"两个开关，打开即按该智能体官方文档的方式写入（Claude Code、Codex 用它们自己的 `mcp add` 命令；其他应用只改动 Folio 自己的条目，保留原文件的顺序、格式和注释），关闭即移除。技能放在各智能体读取的目录中：Claude Code 为 `~/.claude/skills`，Codex、Gemini CLI、Cursor CLI、Copilot CLI、opencode 共用开放标准目录 `~/.agents/skills`，Kiro CLI、Cline CLI、Qwen Code、Antigravity 各有自己的目录。VS Code、Zed、Windsurf 等编辑器可用"拷贝 MCP 配置"手动添加。"检查"按钮会像智能体一样启动 folio-cli 并完成握手。也可以关闭"允许 AI 修改文献库"，只让 AI 读取（对正在运行的会话立即生效）。AI 写入后，正在运行的 Folio 会立即刷新。

注意：Gemini CLI 只在受信任的文件夹中启用 MCP 服务器；Claude 桌面版的技能需要用"导出技能包"上传。

## 浏览器插件

Folio 运行时在 `127.0.0.1:23120` 提供本地连接服务，只接受浏览器扩展的请求（网页无法调用，并校验 Host 防止 DNS 重绑定），可在 设置 ▸ 浏览器 中关闭。在论文页面点工具栏上的 Folio 按钮（或 ⌘⇧S）：

- 自动识别标题、作者、期刊、DOI / arXiv 编号（Highwire `citation_*`、Dublin Core、PRISM、COinS、JSON-LD、IEEE Xplore、ScienceDirect 等）；有标识符时由 Folio 的检索引擎补全元数据
- 选择保存到哪个分组（默认 Folio 当前选中的分组）、添加标签、同时保存 PDF（由浏览器下载，可使用登录状态，自动跟随出版社的中转页；结果在弹窗和 Folio 中都会提示）
- 搜索结果、arXiv 列表等包含多篇文献的页面：勾选后一次保存，可同时下载开放获取的 PDF
- 在 PDF、DOI 或 arXiv 链接上右键"保存链接到 Folio"
- 已有的文献不会重复创建，只加入所选分组；当前页是 PDF 时直接导入该文件

安装（设置 ▸ 浏览器 中有分步引导，并会自动检测是否安装成功）：

- **Safari**：扩展随 Folio.app 提供。因为 Folio 使用开发证书签名，需要先在 Safari 设置 ▸ 高级 中打开"显示网页开发者功能"，再在 开发者 中勾选"允许未签名的扩展"（每次重新打开 Safari 后需再次勾选），然后在 扩展 中勾选"Folio 文献保存"。使用 Developer ID 签名并公证后可省去这一步。
- **Chrome / Edge / Brave / Arc / Opera 等**：点"安装…"，Folio 把扩展放到 `~/Library/Application Support/Folio/BrowserExtension/chromium`（路径已拷贝）并打开扩展页面；打开"开发者模式"，点"加载已解压的扩展程序"，在选择窗口中按 ⌘⇧G 粘贴路径。扩展 ID 固定为 `ljlmdoodaogoghgikjgdbpigeamnjejd`。Folio 更新后扩展文件会自动更新，浏览器重启或在扩展页点"重新加载"后生效。
- **Firefox**：在 `about:debugging` 中"临时载入附加组件"，选择 `…/BrowserExtension/firefox/manifest.json`（重启 Firefox 后需重新载入）。
- `script/package-extensions.sh` 生成上传 Chrome 应用商店的 `.zip` 和提交 Firefox 签名的 `.xpi`（需要你自己的开发者账号）。

扩展源码在 `BrowserExtension/`（`shared/` 为共用代码，各浏览器的 `manifest.json` 分别放在 `chromium/`、`firefox/`、`safari/`），Safari 扩展的原生部分在 `SafariExtension/`，页面识别的回归测试在 `BrowserExtensionTests/`。

## 环境

- macOS 26 及以上；Xcode 27（Swift 6.4）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- 使用 Apple Development 证书签名（Team `2WJC7GTSV4`，见 `project.yml`）

## 构建与运行

```bash
script/build_and_run.sh              # 生成工程 → 构建 Debug → 启动
script/build_and_run.sh --build-only # 只构建
script/build_and_run.sh --release    # 构建 Release（不启动），产物在 build/DerivedData/Build/Products/Release/Folio.app
```

文献库默认位于 `~/Folio`，可以在设置中更改。开发时如果想用临时文献库，可以这样启动：

```bash
FOLIO_LIBRARY=/tmp/my-test-library script/build_and_run.sh
```

## 工程结构

| 路径 | 内容 |
| --- | --- |
| `Folio/App` | 入口、AppDelegate、菜单栏、AppModel（状态与操作）、设置项 |
| `Folio/Library` | 文献库窗口：分栏、工具栏、侧栏、条目列表、搜索范围栏 |
| `Folio/Reader` | 内置阅读器：标签页、批注工具、保存、阅读位置、侧栏、对照阅读 |
| `Folio/Notes` | Markdown 笔记编辑器 |
| `Folio/Translation` | 整篇翻译的队列、设置页 |
| `Folio/Connector` | 浏览器连接服务（本地 HTTP）、浏览器检测与扩展安装、设置 ▸ 浏览器 |
| `Folio/Views` | 检查器、弹窗、标签、设置、列表单元格等 SwiftUI / AppKit 视图 |
| `Packages/FolioCore/Sources/FolioCore` | 数据层：模型、SQLite（GRDB）、导入去重、分组、回收站、标签、快照、视图计算、全文索引 |
| `Packages/FolioCore/Sources/FolioMetadata` | 元数据检索引擎：PDF 信息提取、标识符识别、标题猜测、多数据源并行检索与打分 |
| `Packages/FolioCore/Sources/FolioCitation` | BibTeX 生成；借助 citeproc-js 生成 GB/T 7714 / APA 格式 |
| `Packages/FolioCore/Sources/FolioZotero` | Zotero 数据库读取 |
| `Packages/FolioCore/Sources/FolioAgent` | AI 接入：工具目录、MCP 服务器、folio-cli、技能、智能体配置；浏览器连接协议 |
| `BrowserExtension/`、`SafariExtension/` | 浏览器扩展（Manifest V3）与 Safari Web Extension |
| `BrowserExtensionTests/` | 页面识别回归测试（固定样例页 + 在浏览器中运行的测试页） |
| `Packages/FolioCore/Sources/FolioSeed` | 开发工具：生成演示用和性能测试用的文献库 |
| `FolioTests/` | App 层单元测试（菜单规则、拖放规则、引用服务） |
| `FolioUITests/` | XCUITest 界面测试 |

## 测试

```bash
# 代码层测试（不操作界面）
cd Packages/FolioCore && swift test
xcodebuild -project Folio.xcodeproj -scheme Folio -destination 'platform=macOS' test -only-testing:FolioTests

# 在线测试（需要网络、PDF 样本和 Zotero 数据副本）
FOLIO_LIVE=1 FOLIO_EVAL_DIR=<PDF 目录> FOLIO_EVAL_TRUTH=<真值 JSON> swift test --filter LiveEvaluation
FOLIO_LIVE=1 FOLIO_ZOTERO_DIR=<Zotero 数据目录副本> swift test --filter Zotero

# 界面截图检查（App 在后台启动，不操作鼠标键盘）
swift run --package-path Packages/FolioCore folio-seed demo /tmp/folio-demo
script/preview.sh /tmp/shot.png /tmp/folio-demo -FolioPreviewSelect "Spectral" -FolioPreviewExpand YES

# 阅读器与翻译自测（不操作鼠标键盘）
script/preview.sh /tmp/r.png <文献库> -FolioPreviewOpenReader "<标题开头>" -FolioReaderSelfTest /tmp/reader.log
open -g -n build/DerivedData/Build/Products/Debug/Folio.app --args -FolioLibraryPath <文献库> -FolioUITesting YES \
  -FolioTranslatorDirectory <已安装的翻译组件目录> -FolioPreviewSelect "<标题开头>" -FolioTranslateSelfTest /tmp/trans.log
FOLIO_LIVE=1 swift test --package-path Packages/FolioCore --filter ZoteroCorpusEvaluation   # 检索引擎新旧对比
FOLIO_LIVE=1 swift test --package-path Packages/FolioCore --filter FolioTranslateTests.LiveTests  # 翻译组件真实安装与翻译

# 性能测试
swift run --package-path Packages/FolioCore folio-seed bulk /tmp/folio-bulk 1000
script/build_and_run.sh --release && script/perf.sh /tmp/folio-bulk

# 浏览器插件页面识别回归测试：在仓库根目录运行 python3 -m http.server 8767，浏览器打开
# http://127.0.0.1:8767/BrowserExtensionTests/ ，标题显示 PASSED / FAILED

# 会操作鼠标键盘的测试（运行期间请不要动鼠标）
script/ui-test.sh
script/drag-tests.sh
```

`script/preview.sh` 支持的启动参数（例如切换视图、选中条目、打开弹窗）见 `Folio/App/PreviewHooks.swift`。

## 第三方组件

- [GRDB.swift](https://github.com/groue/GRDB.swift)：MIT 许可
- [pdf2zh_next / BabelDOC](https://github.com/PDFMathTranslate/PDFMathTranslate-next)：AGPL-3.0，不随 App 打包，首次使用整篇翻译时按需下载到 `~/Library/Application Support/Folio/Translator`
- Zotero 识别服务（`services.zotero.org/recognizer`）：PDF 识别时调用，可在设置中关闭
- [citeproc-js](https://github.com/Juris-M/citeproc-js)：CPAL-1.0 / AGPL-1.0 许可
- [CSL 样式与 locale 文件](https://citationstyles.org)：CC BY-SA 3.0 许可

资源文件的详细出处见 `Packages/FolioCore/Sources/FolioCitation/Resources/LICENSES.md`。
