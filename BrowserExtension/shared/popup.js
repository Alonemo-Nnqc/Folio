// Folio popup: read the page, pick a group, save (WEB-02…04).
const $ = (id) => document.getElementById(id);
const browserAPI = globalThis.browser ?? globalThis.chrome;
const preview = !browserAPI?.tabs; // opened as a plain page (design preview)

const TYPE_NAMES = {
  journalArticle: "期刊文章", conferencePaper: "会议论文", preprint: "预印本", book: "图书", bookChapter: "图书章节",
  thesis: "学位论文", report: "报告", webpage: "网页", dataset: "数据集",
};

let page = null;
let tabId = null;
let savedItemId = null;

function show(id) {
  for (const section of ["loading", "offline", "form", "done"]) $(section).hidden = section !== id;
  if (id === "offline" || id === "loading") $("connection").hidden = true;
}

async function readPage() {
  if (preview) {
    return {
      title: "Night-Time Scene Parsing With a Large Real Dataset", authors: ["Tan, Xin", "Xu, Ke", "Cao, Ying"],
      date: "2021", venue: "IEEE Transactions on Image Processing", doi: "10.1109/TIP.2021.3122004", type: "journalArticle",
      pdfUrl: "https://example.org/paper.pdf", isReference: true, url: "https://ieeexplore.ieee.org/document/9591338",
    };
  }
  const [tab] = await browserAPI.tabs.query({ active: true, currentWindow: true });
  tabId = tab?.id;
  try {
    const [result] = await browserAPI.scripting.executeScript({ target: { tabId }, files: ["extract.js"] });
    return result?.result || { title: tab.title, url: tab.url };
  } catch {
    // Browser pages (settings, the new-tab page) cannot be read.
    return { title: tab?.title || "", url: tab?.url || "", unreadable: true };
  }
}

async function loadCollections() {
  if (preview) {
    return {
      groups: [{ id: "a", name: "2026美赛B题", depth: 0 }, { id: "b", name: "参考文献", depth: 1 }, { id: "c", name: "夜间场景", depth: 0 },
               { id: "d", name: "医学图像分割", depth: 0 }],
      currentGroupId: "c", tags: ["必读", "待复现", "Mamba"],
    };
  }
  const response = await folioRequest("/collections");
  if (!response.ok) throw new Error("folio-offline");
  return response.data;
}

function authorLine(authors) {
  const names = (authors || []).map((a) => (typeof a === "string" ? a.split(",")[0] : a.family)).filter(Boolean);
  if (names.length === 0) return "";
  if (names.length <= 2) return names.join("、");
  return `${names[0]} 等`;
}

function render(collections) {
  const year = (page.date || "").slice(0, 4);
  const kind = page.isPDF && !page.isReference ? "PDF 文件" : TYPE_NAMES[page.type] || (page.isReference ? "文献" : "网页");
  $("kind").textContent = kind;
  $("title").textContent = page.title || "（无标题）";
  $("meta").textContent = [authorLine(page.authors), year, page.venue].filter(Boolean).join(" · ") || page.url || "";
  const note = $("note");
  if (page.unreadable) {
    note.textContent = "此页面无法读取，将只保存标题和网址。";
    note.hidden = false;
  } else if (!page.isReference && !page.isPDF) {
    note.textContent = "没有识别到论文信息，将作为网页保存。";
    note.hidden = false;
  } else if (page.doi || page.arxiv) {
    note.hidden = true;
  }

  // Groups: Folio's current group first, else the last choice, else none.
  const select = $("group");
  select.replaceChildren(new Option("不放入分组", ""));
  for (const group of collections.groups || []) {
    select.add(new Option(`${group.depth ? " " : ""}${group.name}`, group.id));
  }
  const remembered = localStorage.getItem("folio.lastGroup");
  const ids = new Set((collections.groups || []).map((g) => g.id));
  select.value = collections.currentGroupId && ids.has(collections.currentGroupId) ? collections.currentGroupId
    : remembered && ids.has(remembered) ? remembered : "";

  const list = $("tag-list");
  list.replaceChildren(...(collections.tags || []).map((tag) => new Option(tag)));

  $("pdf-row").hidden = !page.pdfUrl || (page.isPDF && !page.isReference);
  $("connection").textContent = "已连接";
  $("connection").hidden = false;
  show("form");
  $("save").focus();
}

async function save() {
  const button = $("save");
  button.disabled = true;
  button.textContent = "正在保存…";
  const groupId = $("group").value;
  localStorage.setItem("folio.lastGroup", groupId);
  const tags = $("tags").value.split(/[,，;；]/).map((t) => t.trim()).filter(Boolean);
  const groupName = $("group").selectedOptions[0]?.textContent.trim();
  try {
    if (preview) {
      finish("created", "Night-Time Scene Parsing With a Large Real Dataset", groupId ? groupName : "", true);
      return;
    }
    // A bare PDF: Folio imports the file and looks up its metadata itself.
    if (page.isPDF && !page.isReference) {
      const reply = await sendMessage({ type: "sendPDF", pdfUrl: page.pdfUrl, target: { groupId }, tabId });
      if (!reply?.ok) throw new Error(reply?.data?.error || reply?.error || "无法保存 PDF");
      finish("pdf", page.title, groupId ? groupName : "", false);
      return;
    }
    const item = { ...page, type: page.isReference ? page.type : "webpage" };
    const response = await folioRequest("/save", { method: "POST", json: { item, groupId: groupId || null, tags } });
    if (!response.ok) throw new Error(response.data?.error || `保存失败（${response.status}）`);
    savedItemId = response.data.itemId;
    const withPDF = !$("pdf-row").hidden && $("pdf").checked;
    if (withPDF) {
      // The background worker keeps downloading even if this popup closes.
      sendMessage({ type: "sendPDF", pdfUrl: page.pdfUrl, target: { itemId: savedItemId }, tabId });
    }
    finish(response.data.status, response.data.title, response.data.group, withPDF);
  } catch (error) {
    if (String(error.message) === "folio-offline") { show("offline"); return; }
    button.disabled = false;
    button.textContent = "保存";
    $("note").textContent = String(error.message || error);
    $("note").hidden = false;
  }
}

function sendMessage(message) {
  return new Promise((resolve) => {
    try {
      const pending = browserAPI.runtime.sendMessage(message, resolve);
      if (pending?.then) pending.then(resolve, () => resolve(null));
    } catch { resolve(null); }
  });
}

function finish(status, title, group, withPDF) {
  const duplicate = status === "duplicate";
  $("done-symbol").textContent = duplicate ? "ℹ︎" : "✓";
  $("done-symbol").classList.toggle("success", !duplicate);
  $("done-title").textContent = duplicate ? "文献库中已有这篇文献" : status === "pdf" ? "已交给 Folio 导入" : "已保存";
  const where = group ? `「${group}」` : "文献库";
  const parts = [duplicate ? (group ? `已加入${where}。` : "") : `「${title}」已保存到${where}。`];
  if (withPDF) parts.push("PDF 正在后台下载，完成后会附加到条目。");
  if (status === "pdf") parts.push("Folio 会自动检索元数据。");
  $("done-detail").textContent = parts.filter(Boolean).join("");
  $("reveal").hidden = !savedItemId && !preview;
  show("done");
  $("close").focus();
}

function openFolio(link) {
  const url = link || "folio://select";
  if (preview) return;
  browserAPI.tabs.create({ url, active: false }).catch?.(() => {});
}

async function start() {
  show("loading");
  try {
    page = await readPage();
    render(await loadCollections());
  } catch (error) {
    show("offline");
  }
}

$("save").addEventListener("click", save);
$("cancel").addEventListener("click", () => window.close());
$("close").addEventListener("click", () => window.close());
$("retry").addEventListener("click", start);
$("launch").addEventListener("click", () => { openFolio("folio://open"); setTimeout(start, 2500); });
$("reveal").addEventListener("click", () => { openFolio(`folio://select?item=${encodeURIComponent(savedItemId)}`); window.close(); });
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") window.close();
  if (event.key === "Enter" && !$("form").hidden && document.activeElement?.id !== "tags") save();
});

// Design preview: popup.html?preview=offline|done shows the other states.
const previewState = new URLSearchParams(location.search).get("preview");
if (preview && previewState === "offline") show("offline");
else if (preview && previewState === "done") { page = {}; finish("created", "Night-Time Scene Parsing With a Large Real Dataset", "夜间场景", true); }
else start();
