# 参与贡献

感谢你愿意改进 Folio！提交 Issue 或 Pull Request 之前，请花几分钟读完本文。参与本项目即表示你同意遵守 [行为准则](CODE_OF_CONDUCT.md)。

## 报告问题与建议

- **Bug**：使用 [Bug 报告模板](https://github.com/Alonemo-Nnqc/Folio/issues/new?template=bug_report.yml)，写明 Folio 版本（设置 ▸ 通用 ▸ 软件更新）、macOS 版本和复现步骤。
- **新功能**：使用 [功能建议模板](https://github.com/Alonemo-Nnqc/Folio/issues/new?template=feature_request.yml)，先说明要解决的问题，再说明设想的方案。
- **安全漏洞**：请勿公开提交，见 [SECURITY.md](SECURITY.md)。

## 开发环境

- macOS 26 及以上，Xcode 27 及以上
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`

`Folio.xcodeproj` 由 `project.yml` 生成，**修改工程设置请改 `project.yml`**，然后运行 `xcodegen generate`。

### 签名

克隆下来即可构建：默认使用“本地运行签名”（ad-hoc），不需要 Apple 开发者账号。如果想用自己的证书签名（例如调试 Safari 扩展），复制一份本地配置并填入你的 Team ID：

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

`Config/Local.xcconfig` 已被 `.gitignore` 忽略，不会被提交。

## 构建与运行

```bash
script/build_and_run.sh               # 生成工程 → 构建 Debug → 启动
script/build_and_run.sh --build-only  # 只构建
script/build_and_run.sh --logs        # 启动并输出日志
```

开发时建议使用临时文献库，不影响你自己的数据：

```bash
FOLIO_LIBRARY=/tmp/folio-dev script/build_and_run.sh
swift run --package-path Packages/FolioCore folio-seed demo /tmp/folio-demo   # 生成演示文献库
```

## 工程结构

| 路径 | 内容 |
| --- | --- |
| `Folio/App` | 入口、AppDelegate、菜单栏、AppModel（状态与操作）、设置项、软件更新 |
| `Folio/Library` | 文献库窗口：分栏、工具栏、侧栏、条目列表 |
| `Folio/Reader` | 内置阅读器：标签页、批注、阅读位置、对照阅读 |
| `Folio/Notes` | Markdown 笔记编辑器 |
| `Folio/Translation` | 整篇翻译的队列与设置页 |
| `Folio/Connector` | 浏览器连接服务（本地 HTTP）、浏览器检测与扩展安装 |
| `Folio/Views` | 检查器、弹窗、标签、设置等 SwiftUI / AppKit 视图 |
| `Packages/FolioCore/Sources/FolioCore` | 数据层：模型、SQLite（GRDB）、导入去重、分组、标签、全文索引 |
| `Packages/FolioCore/Sources/FolioMetadata` | 元数据检索引擎：PDF 信息提取、标识符识别、多数据源检索与打分 |
| `Packages/FolioCore/Sources/FolioCitation` | BibTeX 与 citeproc-js 引用生成 |
| `Packages/FolioCore/Sources/FolioZotero` | Zotero 数据库读取 |
| `Packages/FolioCore/Sources/FolioTranslate` | pdf2zh_next 翻译组件的安装与调用 |
| `Packages/FolioCore/Sources/FolioAgent` | AI 接入：MCP 服务器、`folio-cli`、技能、智能体配置 |
| `BrowserExtension/`、`SafariExtension/` | 浏览器扩展（Manifest V3）与 Safari Web Extension |
| `BrowserExtensionTests/` | 页面识别回归测试 |
| `FolioTests/`、`FolioUITests/` | App 层单元测试与 XCUITest 界面测试 |
| `script/` | 构建、测试、截图、发布脚本 |

## 测试

提交 Pull Request 前请至少运行前两项（CI 也会运行）：

```bash
swift test --package-path Packages/FolioCore
xcodebuild -project Folio.xcodeproj -scheme Folio -destination 'platform=macOS' test -only-testing:FolioTests
```

其他测试：

```bash
# 在线测试（需要网络，以及 PDF 样本或 Zotero 数据副本）
FOLIO_LIVE=1 FOLIO_EVAL_DIR=<PDF 目录> FOLIO_EVAL_TRUTH=<真值 JSON> swift test --package-path Packages/FolioCore --filter LiveEvaluation
FOLIO_LIVE=1 FOLIO_ZOTERO_DIR=<Zotero 数据目录副本> swift test --package-path Packages/FolioCore --filter Zotero

# 界面截图检查（后台启动，不操作鼠标键盘；参数见 Folio/App/PreviewHooks.swift）
script/preview.sh /tmp/shot.png /tmp/folio-demo -FolioPreviewSelect "Spectral"

# 性能
swift run --package-path Packages/FolioCore folio-seed bulk /tmp/folio-bulk 1000
script/build_and_run.sh --release && script/perf.sh /tmp/folio-bulk

# 会操作鼠标键盘的界面测试（运行期间不要动鼠标）
script/ui-test.sh
script/drag-tests.sh
```

浏览器插件页面识别测试：在仓库根目录运行 `python3 -m http.server 8767`，浏览器打开 <http://127.0.0.1:8767/BrowserExtensionTests/>，标题显示 PASSED / FAILED。

## 提交规范

- 从 `main` 新建分支：`feat/<简述>`、`fix/<简述>`、`docs/<简述>`
- 提交信息遵循 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)：`feat(reader): 支持双页显示`、`fix(import): …`、`docs: …`、`refactor`、`test`、`chore`、`ci`
- 一个 Pull Request 只做一件事；涉及界面的改动请附截图
- 用户可感知的变更请在 [CHANGELOG.md](CHANGELOG.md) 的 `[Unreleased]` 下补一行

## 发布流程（维护者）

1. 把 `CHANGELOG.md` 中 `[Unreleased]` 的内容移到新版本小节，例如 `## [1.2.0] - 2026-11-01`，并更新底部链接
2. 提交后打标签并推送：

   ```bash
   git tag v1.2.0 && git push origin main v1.2.0
   ```

3. [Release 工作流](.github/workflows/release.yml) 会构建、打包 `Folio-1.2.0.dmg` / `.zip`、用 Sparkle 密钥签名更新、生成 `appcast.xml`，并创建 GitHub Release。已安装的 Folio 会在一天内自动发现新版本。

版本号中带 `-`（如 `v1.3.0-beta.1`）会发布为预发布版本，不会推送给普通用户。

首次配置仓库时需要把 Sparkle 私钥存入仓库 Secret（私钥保存在维护者的钥匙串中，切勿提交）：

```bash
script/setup-release-secret.sh
```

本地试打包：`script/release.sh 1.2.0`（产物在 `dist/`）。
