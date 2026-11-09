# Folio for Windows 更新日志

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
Windows 版与 macOS 版一起发布，版本号相同：推送 `v<版本号>` 标签（例如 `v1.1.0`）后，
`.github/workflows/release.yml` 会把本文件和仓库根目录 `CHANGELOG.md` 中对应的小节合成发布说明。

## [Unreleased]

### 新增
- 划词翻译（选中文字后显示翻译按钮 / 自动翻译 / Alt+D），可单独选择翻译服务和快捷键。
- 快速预览：列表中按空格或中键（三指点按）预览论文。
- 阅读器工具栏可自定义按钮和顺序。
- 背景透明度（Windows 11 亚克力背景）；“更新”按钮与自动下载更新。

### 变更
- 设置按钮移到侧栏左下角；AI 设置页使用官方智能体图标；对话框打开时窗口按钮颜色与页面一致；翻译服务列表隐藏未安装的智能体；选中文字后切换标注工具直接标注。

## [1.1.0] - 2026-11-07

首个 Windows 版本，与 macOS 版功能、界面一一对应，并使用同一套数据格式：同一个文献库文件夹（例如放在同步盘中）在两个平台上都能直接打开。

### 文献管理

- 两级分组（可自定义颜色）、彩色标签、回收站、全文搜索、阅读状态与星级评分、一个条目多个文件
- 拖入 PDF 自动识别元数据（Zotero 识别服务、Crossref、arXiv、OpenAlex、DBLP、CVF），找不到时可手动匹配
- 笔记、引用（GB/T 7714、APA、IEEE 等）与 BibTeX / RIS / CSL JSON 导入导出
- 从 Zotero 导入：分组、标签（含颜色）、PDF 和 pdf2zh 译文一并导入，只读取 Zotero 数据库的副本

### 阅读

- 标签页打开论文，高亮、下划线、删除线、便签、文本框、手绘，批注直接写回 PDF，记住阅读位置
- 对照阅读：原文与译文左右并排，翻译进行中即可阅读已完成的页面
- 触控板捏合与 Ctrl+滚轮缩放、查找、目录、缩略图、打印

### 翻译

- 与 macOS 版同一套自研引擎，按原版面排入译文，公式、图表和链接保持原样，生成纯译文和左右对照两种 PDF
- 支持 Google / Microsoft 免费翻译、Ollama / LM Studio、OpenAI、DeepSeek、通义千问、DeepL 等接口，以及本机已登录的 Claude Code、Codex、Gemini CLI、pi、DeepSeek Harness 等智能体；API Key 用 Windows 账户加密保存

### AI 与浏览器

- 内置 MCP 服务器和 `folio-cli`，在 设置 ▸ AI 中一键为 Claude Code、Codex、Gemini CLI、Cursor、Claude 桌面版等智能体添加 Folio
- 浏览器插件（Chrome、Edge、Brave、Firefox 等）一键保存到 Folio，在 设置 ▸ 浏览器 中安装

### Windows

- 窗口按钮、Snap Layouts、资源管理器、文件对话框和 Ctrl 快捷键都是 Windows 自己的
- 关闭窗口后 Folio 留在通知区域继续运行（翻译不中断），从托盘菜单“退出 Folio”才会彻底退出
- 安装向导可选择安装位置和桌面快捷方式，不需要管理员权限；缺少 WebView2 运行时的电脑会自动安装
- 应用内自动更新：下载新的安装程序，校验后在重新启动或退出时静默安装
- 支持 x64 和 ARM64
