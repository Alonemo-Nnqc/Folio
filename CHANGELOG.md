# Changelog

本文件记录 Folio 每个版本的重要变更，格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

发布新版本时，把 `[Unreleased]` 中的内容移到新的版本小节下，`script/release.sh` 会把该小节作为发布说明，并显示在应用内的更新窗口中。

## [Unreleased]

## [1.0.1] - 2026-11-03

### 新增

- 在条目上三指轻点（或用力点按，取决于 系统设置 ▸ 触控板 ▸ 查询与数据检测器）即可快速查看，和按空格一样

### 修复

- 修复 1.0.0 在开启了系统完整性保护（SIP）的 Mac 上一启动就退出的问题（崩溃报告显示 `Library not loaded: @rpath/Sparkle.framework`）。打不开 1.0.0 的用户请从 Releases 重新下载安装
- 欢迎向导首次启动时显示在文献库窗口前面，不会再被挡住；它是一个普通的独立窗口，切换到其他软件时不会消失
- 欢迎向导底部的按钮不再被窗口边缘遮挡；“允许 AI 修改文献库”开关不再需要滚动才能看到
- 欢迎向导没走完就关闭时，下次打开 Folio 会从离开的那一页继续（只会再出现一次）
- 从 Zotero 导入 pdf2zh 插件生成的对照翻译时，按附件标题识别翻译服务（Google、DeepSeek、Gemini 等），不再变成“… 2.pdf”“… 3.pdf”。之前已经这样导入的，再从 Zotero 导入一次即可修正
- 在欢迎向导或设置中启用 Safari 扩展时，勾选“允许未签名的扩展”后会自动跳到 Safari 的扩展设置

### 变更

- 欢迎向导的页面图标改用系统原生的 SF Symbols
- 条目下的文件改为显示“原文”“双语对照 · Google”“译文 · DeepSeek · deepseek-chat”，不再显示作者、年份和标题；文献库文件夹中的译文文件名以“（双语对照 · Google）”结尾，而不是编号

## [1.0.0] - 2026-10-15

首个公开版本。

### 新增

- 拖入 PDF 后自动识别元数据并创建条目（Zotero 识别服务 + Crossref / arXiv / OpenAlex / DBLP / CVF）
- 内置 PDF 阅读器：标签页、高亮 / 下划线 / 便签 / 文本框 / 手绘批注，批注直接写回 PDF，记住阅读位置
- 保留排版的整篇翻译（pdf2zh_next / BabelDOC），支持 20 多种翻译服务，可对照阅读
- 每个条目一篇 Markdown 笔记，阅读时可把选中文字一键加入笔记
- AI 接入：MCP 服务器与命令行工具 `folio-cli`，可一键配置 Claude Code、Codex、Gemini CLI 等 11 种智能体
- 浏览器插件（Safari、Chrome、Edge、Firefox 等），在论文页面一键保存，支持批量保存
- 两级分组、彩色标签、回收站、全文搜索、阅读状态与星级评分
- 9 种引用格式（含 GB/T 7714-2015），导出 BibTeX / RIS / CSL JSON；从 Zotero 一键导入
- 应用内检查更新：自动下载并在重新启动后完成安装
- 首次启动的欢迎向导：从 Zotero 导入、安装浏览器插件、为 AI 智能体添加 MCP 与技能、配置翻译组件
- 中英双语界面（默认跟随系统语言，可在设置中切换），浏览器插件同样支持英文
- 支持 macOS 14 Sonoma 及以上；在 macOS 26 上使用 Liquid Glass 外观

[Unreleased]: https://github.com/Alonemo-Nnqc/Folio/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/Alonemo-Nnqc/Folio/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Alonemo-Nnqc/Folio/releases/tag/v1.0.0
