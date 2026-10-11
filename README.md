# Folio

轻量、原生的 macOS 文献管理软件。AppKit 搭建窗口、工具栏、菜单和标签页，SwiftUI 承载检查器、设置和弹窗，界面采用系统 Liquid Glass 风格。

- 拖入 PDF 后几秒内自动识别元数据并创建条目：Zotero 识别服务 + Crossref / arXiv / OpenAlex / DBLP / CVF 开放获取
- 内置阅读器（与"预览"同一引擎 PDFKit）：论文以原生标签页打开；高亮、下划线、删除线、便签、文本框、手绘，批注直接写回 PDF，与"预览"互通；记住每篇论文的阅读位置
- 保留排版的整篇翻译（pdf2zh_next / BabelDOC），支持 20 多种翻译服务，译文与原文可对照阅读
- 每个条目一篇 Markdown 笔记，可以在阅读时把选中的文字一键加入笔记
- 两级分组、彩色标签、回收站、全文搜索、阅读状态与星级评分
- 每个条目可以挂多个文件，并可指定默认打开的文件；也可以随时用"预览"或其他应用打开
- 支持复制 BibTeX / GB/T 7714-2015 / APA 引用，导出 `.bib`
- 可以一键从 Zotero 导入（只读取数据库副本，不会修改 Zotero）
- 1000 个条目时冷启动约 0.35 s，内存约 110–130 MB

需求、开发计划、测试报告和问题记录都在 [`doc/`](doc/) 目录下。

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
| `Folio/Views` | 检查器、弹窗、标签、设置、列表单元格等 SwiftUI / AppKit 视图 |
| `Packages/FolioCore/Sources/FolioCore` | 数据层：模型、SQLite（GRDB）、导入去重、分组、回收站、标签、快照、视图计算、全文索引 |
| `Packages/FolioCore/Sources/FolioMetadata` | 元数据检索引擎：PDF 信息提取、标识符识别、标题猜测、多数据源并行检索与打分 |
| `Packages/FolioCore/Sources/FolioCitation` | BibTeX 生成；借助 citeproc-js 生成 GB/T 7714 / APA 格式 |
| `Packages/FolioCore/Sources/FolioZotero` | Zotero 数据库读取 |
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
