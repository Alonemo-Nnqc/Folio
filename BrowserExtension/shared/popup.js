// Folio popup: read the page, pick a group, save (WEB-02…04); batch save for pages listing several works.
const $ = (id) => document.getElementById(id);
const browserAPI = globalThis.browser ?? globalThis.chrome;
const preview = !browserAPI?.tabs; // opened as a plain page (design preview)
const params = new URLSearchParams(location.search);

const TYPE_NAMES = {
  journalArticle: "期刊文章", conferencePaper: "会议论文", preprint: "预印本", book: "图书", bookChapter: "图书章节",
  thesis: "学位论文", report: "报告", webpage: "网页", dataset: "数据集",
};

let page = null;
let tab = null;
let savedItemId = null;

function show(id) {
  for (const section of ["loading", "offline", "form", "done"]) $(section).hidden = section !== id;
  if (id === "offline" || id === "loading") $("connection").hidden = true;
}

/** Reads the page; pages the extension may not script (PDF viewers, browser pages) fall back to the tab's URL. */
async function readPage() {
  if (preview) return previewPage();
  [tab] = await browserAPI.tabs.query({ active: true, currentWindow: true });
  try {
    const [result] = await browserAPI.scripting.executeScript({ target: { tabId: tab.id }, files: ["extract.js"] });
    if (result?.result) return result.result;
  } catch { /* not scriptable */ }
  const url = tab?.url || "";
  if (/\.pdf($|[?#])/i.test(url) || /arxiv\.org\/pdf\//i.test(url)) {
    const arxiv = url.match(/arxiv\.org\/pdf\/([\w.\-/]+?)(v\d+)?(\.pdf)?$/i);
    return { url, isPDF: true, pdfUrl: url, title: tab.title || url.split("/").pop(), arxiv: arxiv ? arxiv[1] : "" };
  }
  return { title: tab?.title || "", url, unreadable: true };
}

async function loadFolio() {
  if (preview) return previewCollections();
  const [collections, ping] = await Promise.all([folioRequest("/collections"), folioRequest("/ping").catch(() => null)]);
  if (!collections.ok) throw new Error("folio-offline");
  return { ...collections.data, ping: ping?.data || {} };
}

function authorLine(authors) {
  const names = (authors || []).map((a) => (typeof a === "string" ? a.split(",")[0] : a.family)).filter(Boolean);
  if (names.length === 0) return "";
  if (names.length <= 2) return names.join("、");
  return `${names[0]} 等`;
}

function versionNumber(text) {
  return String(text || "0").split(".").map((part) => parseInt(part, 10) || 0).reduce((sum, part) => sum * 1000 + part, 0);
}

function render(folio) {
  const multi = !page.isReference && !page.isPDF && Array.isArray(page.candidates) && page.candidates.length >= 2;
  document.querySelector(".card").hidden = multi;
  $("multi").hidden = !multi;
  if (multi) renderCandidates();
  else renderSingle();

  // Groups: Folio's current group first, else the last choice, else none.
  const select = $("group");
  select.replaceChildren(new Option("不放入分组", ""));
  for (const group of folio.groups || []) {
    select.add(new Option(`${group.depth ? " " : ""}${group.name}`, group.id));
  }
  const remembered = localStorage.getItem("folio.lastGroup");
  const ids = new Set((folio.groups || []).map((g) => g.id));
  select.value = folio.currentGroupId && ids.has(folio.currentGroupId) ? folio.currentGroupId
    : remembered && ids.has(remembered) ? remembered : "";

  $("tag-list").replaceChildren(...(folio.tags || []).map((tag) => new Option(tag)));

  // A newer extension ships with Folio (Chrome / Edge / Firefox load it from a folder).
  const bundled = folio.ping?.extensionVersion;
  const installed = preview ? "1.0.0" : browserAPI.runtime.getManifest().version;
  if (bundled && versionNumber(bundled) > versionNumber(installed)) {
    $("update").textContent = `Folio 带有新版扩展（${bundled}）：请在浏览器的扩展页面点"重新加载"，或在 Folio ▸ 设置 ▸ 浏览器 中重新安装。`;
    $("update").hidden = false;
  }
  $("connection").textContent = folio.ping?.library ? `已连接 · ${folio.ping.library}` : "已连接";
  $("connection").hidden = false;
  show("form");
  $("save").focus();
}

function renderSingle() {
  const year = (page.date || "").slice(0, 4);
  const kind = page.isPDF && !page.isReference ? "PDF 文件" : TYPE_NAMES[page.type] || (page.isReference ? "文献" : "网页");
  $("kind").textContent = kind;
  $("title").textContent = page.title || "（无标题）";
  $("meta").textContent = [authorLine(page.authors), year, page.venue].filter(Boolean).join(" · ")
    || [page.doi && `DOI ${page.doi}`, page.arxiv && `arXiv ${page.arxiv}`].filter(Boolean).join(" · ") || page.url || "";
  const note = $("note");
  note.hidden = true;
  if (page.unreadable) {
    note.textContent = "此页面无法读取，将只保存标题和网址。";
    note.hidden = false;
  } else if (!page.isReference && !page.isPDF) {
    note.textContent = "没有识别到论文信息，将作为网页保存。";
    note.hidden = false;
  } else if (page.isReference && (page.doi || page.arxiv) && !(page.authors || []).length) {
    note.textContent = "将按标识符从 Folio 的数据源获取完整信息。";
    note.hidden = false;
  }
  $("pdf-row").hidden = !page.pdfUrl || (page.isPDF && !page.isReference);
  $("pdf-label").textContent = "同时保存 PDF";
  $("save").textContent = "保存";
}

function renderCandidates() {
  const list = $("candidates");
  list.replaceChildren(...page.candidates.map((candidate, index) => {
    const item = document.createElement("li");
    const label = document.createElement("label");
    const box = document.createElement("input");
    box.type = "checkbox";
    box.checked = true;
    box.dataset.index = String(index);
    box.addEventListener("change", updateCount);
    const text = document.createElement("span");
    const title = document.createElement("span");
    title.className = "candidate-title";
    title.textContent = candidate.title || candidate.identifier;
    const id = document.createElement("span");
    id.className = "candidate-id secondary";
    id.textContent = `${candidate.kind} ${candidate.identifier}`;
    text.append(title, id);
    label.append(box, text);
    item.append(label);
    return item;
  }));
  $("select-all").onchange = (event) => {
    for (const box of list.querySelectorAll("input")) box.checked = event.target.checked;
    updateCount();
  };
  const arxivOnly = page.candidates.some((c) => c.kind === "arXiv");
  $("pdf-row").hidden = false;
  $("pdf").checked = arxivOnly;
  $("pdf-label").textContent = "同时下载可公开获取的 PDF（arXiv 等）";
  updateCount();
}

function chosenCandidates() {
  return [...$("candidates").querySelectorAll("input:checked")].map((box) => page.candidates[Number(box.dataset.index)]);
}

function updateCount() {
  const total = page.candidates.length;
  const chosen = chosenCandidates().length;
  $("multi-count").textContent = `此页面有 ${total} 篇文献，已选 ${chosen} 篇`;
  $("select-all").checked = chosen === total;
  $("select-all").indeterminate = chosen > 0 && chosen < total;
  $("save").textContent = chosen ? `保存 ${chosen} 篇` : "保存";
  $("save").disabled = chosen === 0;
}

function selectedGroup() {
  return { id: $("group").value, name: $("group").value ? $("group").selectedOptions[0]?.textContent.trim() : "" };
}

function tagsInput() {
  return $("tags").value.split(/[,，;；]/).map((t) => t.trim()).filter(Boolean);
}

async function save() {
  const button = $("save");
  if (button.disabled) return;
  button.disabled = true;
  const group = selectedGroup();
  localStorage.setItem("folio.lastGroup", group.id);
  try {
    if (!$("multi").hidden) return await saveCandidates(group);
    button.textContent = "正在保存…";
    if (preview) { finish("created", page.title, group.name, previewPDF()); return; }
    // A bare PDF: Folio imports the file and looks up its metadata itself.
    if (page.isPDF && !page.isReference) {
      button.textContent = "正在下载 PDF…";
      const reply = await sendMessage({ type: "sendPDF", pdfUrl: page.pdfUrl, target: { groupId: group.id }, tabId: tab?.id });
      if (!reply?.ok) throw new Error(reply?.error || "无法保存 PDF");
      finish("pdf", page.title, group.name, null);
      return;
    }
    const item = { ...page, type: page.isReference ? page.type : "webpage" };
    delete item.candidates;
    const response = await folioRequest("/save", { method: "POST", json: { item, groupId: group.id || null, tags: tagsInput() } });
    if (!response.ok) throw new Error(response.data?.error || `保存失败（${response.status}）`);
    savedItemId = response.data.itemId;
    const withPDF = !$("pdf-row").hidden && $("pdf").checked;
    // The background worker keeps downloading even if this popup closes; Folio reports the result too.
    const pdf = withPDF ? sendMessage({ type: "sendPDF", pdfUrl: page.pdfUrl, target: { itemId: savedItemId }, tabId: tab?.id }) : null;
    finish(response.data.status, response.data.title, response.data.group, pdf);
  } catch (error) {
    if (String(error.message) === "folio-offline") { show("offline"); return; }
    show("form");
    button.disabled = false;
    button.textContent = "保存";
    $("note").textContent = String(error.message || error);
    $("note").hidden = false;
    document.querySelector(".card").hidden = false;
  }
}

async function saveCandidates(group) {
  const chosen = chosenCandidates();
  $("loading-text").textContent = `正在检索并保存 ${chosen.length} 篇文献…`;
  show("loading");
  const response = preview ? previewBatch(chosen)
    : await folioRequest("/saveItems", {
      method: "POST", timeout: 600000,
      json: { items: chosen.map(({ identifier, title, url }) => ({ identifier, title, url })), groupId: group.id || null,
              tags: tagsInput(), pdf: $("pdf").checked },
    });
  if (!response.ok) throw new Error(response.data?.error || `保存失败（${response.status}）`);
  const results = response.data.results || [];
  const count = (status) => results.filter((r) => r.status === status).length;
  const failed = results.filter((r) => r.status === "failed");
  savedItemId = results.find((r) => r.itemId)?.itemId || null;
  $("done-symbol").textContent = failed.length === results.length ? "!" : "✓";
  $("done-symbol").classList.toggle("success", failed.length < results.length);
  $("done-title").textContent = failed.length === results.length ? "没有保存任何文献" : `已保存到${group.name ? `「${group.name}」` : "文献库"}`;
  $("done-detail").textContent = [`新增 ${count("created")} 篇`, count("duplicate") && `已有 ${count("duplicate")} 篇`,
    failed.length && `未找到 ${failed.length} 篇`].filter(Boolean).join("，") + "。";
  $("pdf-status").hidden = true;
  const failures = $("failures");
  failures.replaceChildren(...failed.slice(0, 8).map((r) => {
    const li = document.createElement("li");
    li.textContent = `${r.title || r.identifier}：${r.error || "未找到"}`;
    return li;
  }));
  failures.hidden = failed.length === 0;
  $("reveal").hidden = !savedItemId;
  show("done");
  $("close").focus();
}

function sendMessage(message) {
  return new Promise((resolve) => {
    try {
      const pending = browserAPI.runtime.sendMessage(message, resolve);
      if (pending?.then) pending.then(resolve, () => resolve(null));
    } catch { resolve(null); }
  });
}

function finish(status, title, group, pdf) {
  const duplicate = status === "duplicate";
  $("done-symbol").textContent = duplicate ? "ℹ︎" : "✓";
  $("done-symbol").classList.toggle("success", !duplicate);
  $("done-title").textContent = duplicate ? "文献库中已有这篇文献" : status === "pdf" ? "已交给 Folio 导入" : "已保存";
  const where = group ? `「${group}」` : "文献库";
  const parts = [duplicate ? (group ? `已加入${where}。` : "") : `「${title}」已保存到${where}。`];
  if (status === "pdf") parts.push("Folio 会自动检索元数据。");
  $("done-detail").textContent = parts.filter(Boolean).join("");
  $("failures").hidden = true;
  const pdfStatus = $("pdf-status");
  pdfStatus.hidden = !pdf;
  if (pdf) {
    pdfStatus.className = "pdf-status pending";
    pdfStatus.textContent = "正在下载 PDF…（关闭此窗口也会继续）";
    Promise.resolve(pdf).then((reply) => {
      const ok = reply?.ok && reply?.data?.status !== "failed";
      pdfStatus.className = `pdf-status ${ok ? "ok" : "failed"}`;
      pdfStatus.textContent = ok
        ? reply.data?.status === "duplicate" ? "PDF 已在文献库中。" : "PDF 已附加到条目。"
        : `PDF 未保存：${reply?.error || "下载失败"}。可以稍后在 Folio 中手动添加。`;
    });
  }
  $("reveal").hidden = !savedItemId && !preview;
  show("done");
  $("close").focus();
}

/** Opens Folio through its URL scheme in the current tab, which stays where it is (no blank tab). */
function launchFolio() {
  if (preview) return;
  const update = browserAPI.tabs.update(tab?.id, { url: "folio://open" });
  update?.catch?.(() => {});
}

async function reveal() {
  if (!savedItemId || preview) return window.close();
  const response = await folioRequest(`/reveal?item=${encodeURIComponent(savedItemId)}`, { method: "POST" }).catch(() => null);
  if (!response?.ok) browserAPI.tabs.update(tab?.id, { url: `folio://select?item=${encodeURIComponent(savedItemId)}` })?.catch?.(() => {});
  window.close();
}

async function start() {
  show("loading");
  $("loading-text").textContent = "正在读取页面…";
  try {
    page = await readPage();
    render(await loadFolio());
  } catch (error) {
    show("offline");
  }
}

$("save").addEventListener("click", save);
$("cancel").addEventListener("click", () => window.close());
$("close").addEventListener("click", () => window.close());
$("retry").addEventListener("click", start);
$("launch").addEventListener("click", () => { launchFolio(); setTimeout(start, 3000); });
$("reveal").addEventListener("click", reveal);
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") window.close();
  if (event.key === "Enter" && !$("form").hidden && document.activeElement?.id !== "tags"
      && document.activeElement?.type !== "checkbox") save();
});

// ---- Design preview: popup.html?preview=single|multi|offline|done|update shows each state without a browser.
function previewPage() {
  if (params.get("preview") === "multi") {
    return {
      title: "Computer Vision and Pattern Recognition", isReference: false, url: "https://arxiv.org/list/cs.CV/recent",
      candidates: [
        { identifier: "2610.13947", kind: "arXiv", title: "Towards Physically Grounded Articulated 3D Assets: A Multi-Agent Pipeline and Benchmark" },
        { identifier: "2610.13944", kind: "arXiv", title: "InstantFusion: A Shared Latent Interface for Heterogeneous Image Generators" },
        { identifier: "2610.13941", kind: "arXiv", title: "Images Talk Back: Guiding MMDiTs by Suppressing Image-to-Text Feedback" },
        { identifier: "10.1109/TIP.2021.3122004", kind: "DOI", title: "Night-Time Scene Parsing With a Large Real Dataset" },
      ],
    };
  }
  return {
    title: "Night-Time Scene Parsing With a Large Real Dataset", authors: ["Tan, Xin", "Xu, Ke", "Cao, Ying"],
    date: "2021", venue: "IEEE Transactions on Image Processing", doi: "10.1109/TIP.2021.3122004", type: "journalArticle",
    pdfUrl: "https://example.org/paper.pdf", isReference: true, url: "https://ieeexplore.ieee.org/document/9591338",
  };
}

function previewCollections() {
  return {
    groups: [{ id: "a", name: "2026美赛B题", depth: 0 }, { id: "b", name: "参考文献", depth: 1 }, { id: "c", name: "夜间场景", depth: 0 },
             { id: "d", name: "医学图像分割", depth: 0 }],
    currentGroupId: "c", tags: ["必读", "待复现", "Mamba"],
    ping: { library: "Folio", extensionVersion: params.get("preview") === "update" ? "9.9.9" : "1.0.0" },
  };
}

function previewPDF() {
  return new Promise((resolve) => setTimeout(() => resolve({ ok: false, error: "需要登录或订阅才能下载 PDF" }), 1200));
}

function previewBatch(chosen) {
  return { ok: true, data: { results: chosen.map((c, i) => ({ identifier: c.identifier, title: c.title,
    status: i === 0 ? "duplicate" : i === 3 ? "failed" : "created", itemId: "x", error: i === 3 ? "未找到" : "" })) } };
}

const previewState = params.get("preview");
if (preview && previewState === "offline") show("offline");
else if (preview && previewState === "done") {
  page = {};
  savedItemId = "x";
  finish("created", "Night-Time Scene Parsing With a Large Real Dataset", "夜间场景", previewPDF());
} else start();
