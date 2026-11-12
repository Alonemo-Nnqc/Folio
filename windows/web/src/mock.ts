// Development in a plain browser: the look of the library with made-up data. Never part of what the app runs through its host.
const items = [
  ["SDSFusion: A Semantic-Aware Fusion Network", "IEEE Transactions on Multimedia", "Chen, Jun & Yan, Tao", 2025, []],
  ["Mamba as a Bridge: Where Vision Meets Language", "CVPR", "Zhang, Xin & Tang, Yu", 2025, ["t3"]],
  ["SCSA: Exploring the Synergistic Effects of Attention", "arXiv", "Si, Yunzhong & Xu, Huiying", 2024, []],
  ["Stronger, Fewer, & Superior: Harnessing Vision Foundation Models", "arXiv", "Wei, Zhixiang et al.", 2024, ["t5"]],
  ["RVS-FDSC: A retinal vessel segmentation method", "Biomedical Signal Processing", "Kong, Linfeng & Wu, Yun", 2024, ["t1", "t2"]],
  ["Multimodal self-supervised retinal vessel segmentation", "Neural Networks", "Yin, Pengshuai & Cai, Hongmin", 2026, ["t4"]],
  ["Semantic Nighttime Image Segmentation", "2021 IEEE International Conference", "Peng, Junhan et al.", 2021, []],
  ["Serp-Mamba: Advancing High-Resolution Retinal Vessel Segmentation", "IEEE Transactions on Medical Imaging", "Wang, Hongqiu et al.", 2025, ["t2", "t3"]],
  ["Night-Time Scene Parsing With a Large Real Dataset", "IEEE Transactions on Image Processing", "Tan, Xin et al.", 2021, ["t1"]],
  ["UNet++: A Nested U-Net Architecture", "arXiv", "Zhou, Zongwei et al.", 2018, []],
  ["Spectral Dynamic Attention Network for Hyperspectral Image Super-Resolution", "arXiv", "Zhang, Tengya; Gao, Feng; Qi, Lin", 2026, ["t1", "t2", "t3", "t4"]],
] as const;

const MOCK_METRICS = [
  { rank: "1 区 Top", impactFactor: "9.7", summary: "中科院 1 区 Top · JCR Q1 · IF 9.7", badges: [
    { kind: "cas1", text: "中科院 1 区 Top", detail: "中科院分区（升级版）：计算机科学 1 区，Top 期刊", emphasized: true },
    { kind: "q1", text: "JCR Q1", detail: "JCR 分区（Clarivate）：Q1", emphasized: false },
    { kind: "if", text: "IF 9.7", detail: "影响因子（JCR）：9.7", emphasized: false }, { kind: "if5", text: "5 年 IF 10.2", detail: "5 年影响因子（JCR）：10.2", emphasized: false },
    { kind: "ccf", text: "CCF A", detail: "中国计算机学会推荐：A 类", emphasized: false }] },
  { rank: "2 区", impactFactor: "4.9", summary: "中科院 2 区 · JCR Q2 · IF 4.9", badges: [
    { kind: "cas2", text: "中科院 2 区", detail: "中科院分区（升级版）：医学 2 区", emphasized: false },
    { kind: "q2", text: "JCR Q2", detail: "JCR 分区（Clarivate）：Q2", emphasized: false },
    { kind: "if", text: "IF 4.9", detail: "影响因子（JCR）：4.9", emphasized: false }, { kind: "index", text: "EI", detail: "EI 检索", emphasized: false }] },
  { badges: [], summary: "" },
  null,
];

function now(i: number) { return Date.UTC(2026, 9, 15) + i * 1000; }

const library = () => ({
  full: true, root: "/Users/demo/Folio",
  items: [
    { id: "s0", kind: "standalone", type: "other", typeName: "其他", title: "扫描版讲义 第三章.pdf", authors: [], authorsList: "", rating: 0, readStatus: 0, readStatusName: "未读", defaultFileId: "fs0", metadataState: "Failed", dateAdded: now(0), dateModified: now(0), trashed: false, retrieving: false },
    ...items.map(([title, source, authors, year], i) => ({
      id: `i${i}`, kind: "regular", type: "journalArticle", typeName: "期刊论文", title, source, authorsList: authors, authors: authors.split(/; | & /).map((a) => ({ family: a.split(",")[0], full: a })), year,
      citationKey: `${authors.split(",")[0].toLowerCase()}${year}`, doi: i === 10 ? "10.48550/arxiv.2604.27326" : undefined, rating: i === 10 ? 4 : 0, readStatus: i === 10 ? 1 : 0, readStatusName: i === 10 ? "在读" : "未读",
      abstract: i === 10 ? "Hyperspectral image super-resolution is essential for enhancing the spatial fidelity of HSI data, yet existing deep learning methods often struggle." : undefined,
      defaultFileId: `f${i}`, metadataState: "Resolved", dateAdded: now(i + 1), dateModified: now(i + 1), trashed: false, retrieving: false,
      hasJournal: source !== "arXiv", journalMetrics: source === "arXiv" ? null : MOCK_METRICS[i % MOCK_METRICS.length],
    })),
  ],
  files: [
    { id: "fs0", itemId: "s0", fileName: "扫描版讲义 第三章.pdf", isPdf: true, sha: "x", dateAdded: now(0), title: "原文", tabTitle: "扫描版讲义 第三章", tabTip: "" },
    ...items.map(([title], i) => ({ id: `f${i}`, itemId: `i${i}`, fileName: `${title}.pdf`, isPdf: true, sha: "x", dateAdded: now(i), title: "原文", tabTitle: title.split(":")[0], tabTip: title })),
  ],
  filesByItem: Object.fromEntries([["s0", ["fs0"]], ...items.map((_, i) => [`i${i}`, [`f${i}`]])]),
  groups: [{ id: "g1", name: "2026美赛B题" }, { id: "g1a", parentId: "g1", name: "参考文献" }, { id: "g1b", parentId: "g1", name: "数据集" }, { id: "g1a1", parentId: "g1a", name: "综述" }, { id: "g1a1a", parentId: "g1a1", name: "医学图像" }, { id: "g2", name: "夜间场景" }, { id: "g3", name: "医学图像分割" }, { id: "g4", name: "论文辅导" }],
  topGroups: ["g1", "g2", "g3", "g4"], childGroups: { g1: ["g1a", "g1b"], g1a: ["g1a1"], g1a1: ["g1a1a"] },
  tags: [{ id: "t1", name: "必读", color: "#FF3B30" }, { id: "t2", name: "待复现", color: "#FF9500" }, { id: "t3", name: "Mamba", color: "#AF52DE" }, { id: "t4", name: "视网膜血管分割方法", color: "#34C759" }, { id: "t5", name: "综述", color: "#007AFF" }],
  itemTags: Object.fromEntries(items.map(([, , , , tags], i) => [`i${i}`, [...tags]])),
  itemGroups: { i10: ["g1a"] }, noted: [], removedItems: [], removedFiles: [],
  counts: { all: 12, unfiled: 2, trash: 2, "group:g1": 4, "group:g1a": 3, "group:g1b": 1, "group:g1a1": 1, "group:g1a1a": 1, "group:g2": 3, "group:g3": 4, "tag:t1": 3, "tag:t2": 2, "tag:t3": 3, "tag:t4": 3, "tag:t5": 1 },
});

const settings: Record<string, unknown> = {
  libraryPath: "/Users/demo/Folio", openWithMode: "folio", includeSubgroupItems: true, autoRenameFiles: true, autoPurgeTrash: true, readerZoom: "fitWidth", readerLayout: "single", reopenReaderTabs: true,
  highlightColor: "yellow", useZoteroRecognizer: true, markReadingOnOpen: true, readerPageShadows: true, annotationAuthor: "demo", autoRetrieveOnImport: true, aiAllowWrites: true, browserConnectorEnabled: true,
  appearance: "system", language: "", citationStyle: "gbt7714", autoCheckUpdates: true, updatePrereleases: false, onboardingDone: true, openReaderTabs: [], columnWidths: {}, visibleColumns: ["title", "source", "authors", "year", "journalRank", "impactFactor", "tags", "dateAdded"],
  sidebarWidth: 210, inspectorWidth: 270, inspectorVisible: true, sidebarVisible: true, settingsPane: "general", readerSidebarWidth: 220,
};

export async function mockCall(method: string, params: any): Promise<any> {
  switch (method) {
    case "app.boot": return {
      isEnglish: false, settings, version: "1.0.0", channel: "win-x64", captionWidth: 138, windowState: "normal", library: library(), jobs: {},
      rows: { rows: ["s0", ...items.map((_, i) => `i${i}`)], scope: "all", searchText: "", sortAscending: true },
      annotationColors: [{ key: "yellow", title: "黄色", hex: "#FFD933" }, { key: "green", title: "绿色", hex: "#73D966" }, { key: "blue", title: "蓝色", hex: "#66B3FF" }, { key: "pink", title: "粉色", hex: "#FF8CBF" }, { key: "purple", title: "紫色", hex: "#BF8CFF" }, { key: "red", title: "红色", hex: "#FF5959" }],
      tagPresets: [["红", "#FF3B30"], ["橙", "#FF9500"], ["黄", "#FFCC00"], ["绿", "#34C759"], ["薄荷", "#00C7BE"], ["青", "#32ADE6"], ["蓝", "#007AFF"], ["靛", "#5856D6"], ["紫", "#AF52DE"], ["粉", "#FF2D55"]].map(([name, hex]) => ({ name, hex })),
      citationStyles: [{ raw: "gbt7714", name: "GB/T 7714-2015" }, { raw: "apa", name: "APA" }, { raw: "ieee", name: "IEEE" }],
      referenceFormats: [{ raw: "bibtex", name: "BibTeX" }, { raw: "ris", name: "RIS" }],
      itemTypes: [{ raw: "journalArticle", name: "期刊论文" }, { raw: "preprint", name: "预印本" }],
      statuses: [{ raw: 0, name: "未读" }, { raw: 1, name: "在读" }, { raw: 2, name: "已读" }], homeFolder: "/Users/demo", userName: "demo",
    };
    case "translation.services": return { groups: [{ title: "免费", services: [{ id: "google", label: "Google 翻译" }] }], current: "google", languages: [{ code: "en", name: "英语" }, { code: "zh", name: "简体中文" }], options: { langIn: "en", langOut: "zh", outputs: "both", dualLayout: "sideBySide", translateTables: true, translateReferences: false, duplicates: "keepBoth", ignoreCache: false }, detail: { id: "google", name: "Google 翻译", category: "free", isAgent: false, supportsProfiles: false, profiles: [], fields: [], advanced: [] } };
    case "ai.detect": return [{ id: "claude", name: "Claude Code", location: "~/.local/bin/claude", version: "2.1", mcp: false, skill: false, mcpAvailable: true, skillAvailable: true, skillNote: "" }];
    case "ai.info": return { cliPath: "C:\\Program Files\\Folio\\folio-cli.exe", cliExists: true, catalog: "Claude Code" };
    case "browser.state": return { connector: { state: "running", message: "正在运行（127.0.0.1:23120）" }, browsers: [{ id: "edge", name: "Microsoft Edge", installed: false, status: "未安装" }] };
    case "note.get": return "";
    case "annotations.read": return [];
    case "zotero.locate": return null;
    case "pick.file": return [];
    case "settings.set": settings[params.key] = params.value; return null;
    case "journalMetrics.state": case "journalMetrics.setKey": case "journalMetrics.setAutoFetch":
      return { key: "demo-key", hasKey: true, autoFetch: true, pending: 2, status: "正在获取 2 个期刊的指标…", attention: false, keyPage: "https://www.easyscholar.cc/console/user/open" };
    case "journalMetrics.test": return { ok: true, text: "连接成功：Nature 中科院 1 区 Top · JCR Q1 · IF 48.5" };
    case "journalMetrics.refresh": return { needsKey: false };
    default: return null;
  }
}
