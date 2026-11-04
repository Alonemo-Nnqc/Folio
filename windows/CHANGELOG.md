# Folio for Windows 更新日志

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
Windows 版的版本号与 macOS 版相互独立，发布时推送 `win-v<版本号>` 标签（例如 `win-v1.0.0`），
`.github/workflows/release-windows.yml` 会把对应小节作为发布说明。

## [Unreleased]

## [1.0.0] - 2026-11-04

首个 Windows 版本，与 macOS 版使用同一套数据格式（文献库文件夹可在两个平台间直接打开）。

- 文献库：两级分组（可自定义颜色）、彩色标签、回收站、全文搜索、阅读状态与星级评分、一个条目多个文件
- 拖入 PDF 自动识别元数据（Zotero 识别服务、Crossref、arXiv、OpenAlex、DBLP、CVF），找不到时可手动匹配
- 内置阅读器：标签页打开论文，高亮、下划线、删除线、便签、文本框、手绘，批注直接写回 PDF，记住阅读位置
- 笔记、引用（GB/T 7714、APA、IEEE 等）与 BibTeX / RIS / CSL JSON 导入导出
- 浏览器插件（Chrome、Edge、Brave、Firefox 等）一键保存到 Folio
- 应用内自动更新
