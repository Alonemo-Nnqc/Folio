# Folio 产品主页

<https://alonemo-nnqc.github.io/Folio/> 的源文件：纯静态页面，没有构建步骤和依赖。推送到 `main` 后由 `.github/workflows/pages.yml` 发布到 GitHub Pages。

```bash
python3 -m http.server 8000 --directory website   # 本地预览：http://localhost:8000
```

- `index.html`：页面结构与简体中文文案；英文文案在 `assets/js/main.js` 的 `EN` 中，按浏览器语言自动切换，导航栏可手动切换
- `docs.html`：使用文档（简体中文），样式在 `assets/css/docs.css`，目录高亮、搜索、图片放大与界面导览热点在 `assets/js/docs.js`；截图在 `assets/img/docs/`，Windows 界面截图由 `windows/web` 的界面和模拟数据在无头 Chrome 中渲染
- `assets/css/style.css`：样式与动画（`prefers-reduced-motion` 时关闭动画）
- `assets/js/main.js`：滚动驱动的动画、引用格式轮播、终端打字效果、语言切换；下载按钮通过 GitHub API 按访客的系统指向最新的 macOS 或 Windows 安装包，请求失败时指向 Releases 页面
- `assets/img/`：Mac 截图取自宣传片素材（Folio 的真实窗口截图）；`library_windows.webp` 由 `windows/web` 的界面和模拟数据渲染；均已转为 WebP
- `assets/video/folio-promo.mp4`：宣传片（1080p60，H.264），由宣传片成片重新编码以减小体积
