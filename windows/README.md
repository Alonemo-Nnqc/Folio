# Folio for Windows

与 macOS 版功能、界面一一对应的 Windows 版，和 macOS 版使用同一套文献库格式：同一个文献库文件夹（例如放在同步盘中）在两个平台上都能直接打开。

## 结构

| 目录 | 内容 |
| --- | --- |
| `src/Folio.Core` | 与界面无关的全部逻辑：文献库数据库、元数据检索、引用、PDF 批注、自研翻译引擎（`Translate/`）、AI 接口（`Agent/`）、Zotero 导入（`Zotero/`）。在 macOS 上也能编译和测试 |
| `src/Folio.App` | WinUI 3 应用（文献库、阅读器、设置、翻译、AI、Zotero 导入），基于 Windows App SDK，自包含发布 |
| `src/Folio.Cli` | `folio-cli`：MCP 服务器和命令行，随应用一起发布在 `Folio.exe` 旁边 |
| `tests/Folio.Core.Tests` | 核心库测试（xUnit v3） |
| `scripts/fetch-pdfjs.ps1` | 下载并校验阅读器使用的 pdf.js（构建时自动运行） |

界面文字直接读取 macOS 版的 `.xcstrings`（简体中文为源语言，附英文翻译），Windows 独有的文字在 `src/Folio.Core/Resources/Windows.xcstrings`；测试会检查每条界面文字都有英文翻译。

## 构建与测试

需要 .NET 10 SDK。

```powershell
dotnet test --project tests/Folio.Core.Tests          # 核心库测试（Windows / macOS 均可）
dotnet build src/Folio.App -p:Platform=x64             # 应用（仅 Windows：XAML 编译器需要 Windows）
dotnet publish src/Folio.App -c Release -r win-x64 -p:Platform=x64 -o publish
dotnet publish src/Folio.Cli -c Release -r win-x64 --self-contained -o publish
```

一些测试在设置环境变量后才会运行，用于和 macOS 版对比：`FOLIO_MAC_LIBRARY`（读取 macOS 版写的文献库）、`FOLIO_SAMPLE_PDF` 加 `FOLIO_LAYOUT_DUMP` / `FOLIO_FAKE_OUT`（版面分析与排版结果对比）、`FOLIO_TRANSLATE_OUT`（用真实翻译服务翻译前两页）。

## 发布

版本号与 macOS 版相互独立。在 `CHANGELOG.md` 中写好 `## [x.y.z]` 小节后推送 `win-vx.y.z` 标签，`.github/workflows/release-windows.yml` 会为 x64 和 ARM64 打包（Velopack 安装程序、便携版和增量更新包），并发布为 GitHub Release（不标记为 latest，以免影响 macOS 版的 Sparkle 更新源）。应用内更新只看 `win-v*` 发布。

可选：在仓库 Secrets 中配置 `WINDOWS_PFX_BASE64` 和 `WINDOWS_PFX_PASSWORD` 为代码签名证书，可去掉 SmartScreen 的“未知发布者”提示。
