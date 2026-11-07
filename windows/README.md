# Folio for Windows

与 macOS 版功能、界面一一对应的 Windows 版，和 macOS 版使用同一套文献库格式：同一个文献库文件夹（例如放在同步盘中）在两个平台上都能直接打开。

## 安装

系统要求：Windows 10 2004（19041）及以上，x64 或 ARM64。

1. 在 [Releases](https://github.com/Alonemo-Nnqc/Folio/releases?q=win-v) 下载与电脑架构相符的 `Folio-win-x64-Setup.exe` 或 `Folio-win-arm64-Setup.exe`，不想安装也可以用 `Portable.zip`
2. 运行安装程序，按向导选择安装位置（默认 `%LocalAppData%\Programs\Folio`）和是否创建桌面快捷方式。Folio 目前没有代码签名，SmartScreen 可能提示“已保护你的电脑”，点 **更多信息 ▸ 仍要运行**
3. 不需要管理员权限，也不需要另外安装 .NET。阅读器依赖 Microsoft Edge WebView2 运行时：Windows 11 已自带，个别 Windows 10 上如果缺少，安装程序会自动安装；便携版则由 Folio 提示下载地址
4. 关闭窗口后 Folio 留在通知区域继续运行；在托盘图标或左上角菜单中选择“退出 Folio”才会彻底退出。卸载在“设置 ▸ 应用”中进行，文献库和设置不会被删除

之后的版本会通过应用内更新自动安装。

## 结构

| 目录 | 内容 |
| --- | --- |
| `src/Folio.Core` | 与界面无关的全部逻辑：文献库数据库、元数据检索、引用、PDF 批注、自研翻译引擎（`Translate/`）、AI 接口（`Agent/`）、Zotero 导入（`Zotero/`）。在 macOS 上也能编译和测试 |
| `web` | 界面（React + TypeScript）：文献库、阅读器（pdf.js）、设置、翻译、AI、Zotero 导入、欢迎向导，构建到 `src/Folio.Desktop/wwwroot` |
| `src/Folio.Desktop` | 薄壳（WinForms + WebView2，.NET 10，自包含发布）：窗口与标题栏、系统对话框、单实例、自动更新，把 `Folio.Core` 通过 JSON 消息提供给界面 |
| `src/Folio.Cli` | `folio-cli`：MCP 服务器和命令行，随应用一起发布在 `Folio.exe` 旁边 |
| `tests/Folio.Core.Tests` | 核心库测试（xUnit v3） |

界面文字直接读取 macOS 版的 `.xcstrings`（简体中文为源语言，附英文翻译），在 `web` 中写作 `t("中文")`；Windows 独有的文字在 `src/Folio.Core/Resources/Windows.xcstrings`。

## 构建与测试

需要 .NET 10 SDK、Node 22 和 pnpm。

```powershell
dotnet test --project tests/Folio.Core.Tests          # 核心库测试（Windows / macOS 均可）
pnpm --dir web install; pnpm --dir web build           # 界面（Windows / macOS 均可）
dotnet build src/Folio.Desktop -p:Platform=x64         # 外壳（仅 Windows）
dotnet publish src/Folio.Desktop -c Release -r win-x64 -p:Platform=x64 -o publish
dotnet publish src/Folio.Cli -c Release -r win-x64 --self-contained -o publish
```

一些测试在设置环境变量后才会运行，用于和 macOS 版对比：`FOLIO_MAC_LIBRARY`（读取 macOS 版写的文献库）、`FOLIO_SAMPLE_PDF` 加 `FOLIO_LAYOUT_DUMP` / `FOLIO_FAKE_OUT`（版面分析与排版结果对比）、`FOLIO_TRANSLATE_OUT`（用真实翻译服务翻译前两页）。

界面可以脱离外壳开发：`pnpm --dir web dev` 用模拟数据在浏览器中运行（http://localhost:5199），方便和 macOS 版截图对比。

## 发布

版本号与 macOS 版相互独立。在 `CHANGELOG.md` 中写好 `## [x.y.z]` 小节后推送 `win-vx.y.z` 标签，`.github/workflows/release-windows.yml` 会为 x64 和 ARM64 打包：Velopack 生成便携版和增量更新包，Inno Setup（`installer/Folio.iss`）再把便携版做成带向导的安装程序，并发布为 GitHub Release（不标记为 latest，以免影响 macOS 版的 Sparkle 更新源）。应用内更新只看 `win-v*` 发布。

可选：在仓库 Secrets 中配置 `WINDOWS_PFX_BASE64` 和 `WINDOWS_PFX_PASSWORD` 为代码签名证书，可去掉 SmartScreen 的“未知发布者”提示。
