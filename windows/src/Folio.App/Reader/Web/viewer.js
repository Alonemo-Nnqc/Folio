// Folio's reader page: pdf.js's viewer components plus Folio's tools. Talks to the app (ReaderView.cs) through
// WebView2 messages. Commands from the app: open, reload, tool, zoom, layout, find, goto, theme, sidebar, scrollSync.
// Messages to the app: ready, loaded, page, position, selection, markup, note, textbox, ink, annotationClicked, scroll.

const pdfjsLib = await import("../../Assets/pdfjs/build/pdf.min.mjs");
globalThis.pdfjsLib = pdfjsLib;
const { EventBus, PDFViewer, PDFLinkService, PDFFindController } = await import("../../Assets/pdfjs/web/pdf_viewer.mjs");
pdfjsLib.GlobalWorkerOptions.workerSrc = "../../Assets/pdfjs/build/pdf.worker.min.mjs";

const host = window.chrome?.webview;
const post = (message) => host?.postMessage(message);

const container = document.getElementById("viewerContainer");
const eventBus = new EventBus();
const linkService = new PDFLinkService({ eventBus, externalLinkTarget: 2 });
const findController = new PDFFindController({ eventBus, linkService });
const viewer = new PDFViewer({
  container, eventBus, linkService, findController,
  textLayerMode: 1,
  annotationMode: pdfjsLib.AnnotationMode.ENABLE,
  removePageBorders: false,
});
linkService.setViewer(viewer);

let pdf = null;
let tool = "select";
let color = "yellow";
let labels = {};
let suppressScroll = false;

const colors = {
  yellow: "rgb(255,217,51)", green: "rgb(115,217,102)", blue: "rgb(102,178,255)",
  pink: "rgb(255,140,191)", purple: "rgb(191,140,255)", red: "rgb(255,89,89)",
};

// MARK: Opening

async function open({ url, page, scale, top, left, layout, zoom }) {
  const task = pdfjsLib.getDocument({
    url, cMapUrl: "../../Assets/pdfjs/cmaps/", cMapPacked: true,
    standardFontDataUrl: "../../Assets/pdfjs/standard_fonts/", wasmUrl: "../../Assets/pdfjs/wasm/",
    enableXfa: false,
  });
  const doc = await task.promise;
  if (pdf) pdf.destroy();
  pdf = doc;
  viewer.setDocument(pdf);
  linkService.setDocument(pdf, null);
  await new Promise((resolve) => eventBus.on("pagesinit", resolve, { once: true }));
  viewer.spreadMode = layout === "twoUp" ? 1 : 0;
  if (scale) viewer.currentScale = scale;
  else viewer.currentScaleValue = zoom === "actualSize" ? "page-actual" : "page-width";
  if (page) {
    viewer.scrollPageIntoView({ pageNumber: page, destArray: top != null ? [null, { name: "XYZ" }, left ?? 0, top, null] : undefined });
  }
  post({ type: "loaded", pages: pdf.numPages });
  buildThumbnails();
  buildOutline();
  refreshAnnotations();
}

// Reload after the app wrote into the file, keeping the reading position.
async function reload(url) {
  const position = currentPosition();
  suppressScroll = true;
  await open({ url, page: position.page, scale: viewer.currentScale, top: position.top, left: position.left });
  suppressScroll = false;
}

function currentPosition() {
  const page = viewer.currentPageNumber;
  const view = viewer.getPageView(page - 1);
  let top = null, left = null;
  if (view) {
    const rect = view.div.getBoundingClientRect();
    const box = container.getBoundingClientRect();
    [left, top] = view.viewport.convertToPdfPoint(box.left - rect.left, box.top - rect.top);
  }
  return { page, top, left, scale: viewer.currentScale, autoScale: viewer.currentScaleValue === "page-width" };
}

// MARK: Events to the app

let positionTimer = 0;
container.addEventListener("scroll", () => {
  if (suppressScroll) return;
  clearTimeout(positionTimer);
  positionTimer = setTimeout(() => post({ type: "position", ...currentPosition() }), 400);
  post({ type: "scroll", ratio: container.scrollTop / Math.max(1, container.scrollHeight - container.clientHeight) });
});
eventBus.on("pagechanging", (e) => {
  post({ type: "page", page: e.pageNumber, pages: pdf?.numPages ?? 0 });
  document.querySelectorAll(".thumb").forEach((t) => t.classList.toggle("current", +t.dataset.page === e.pageNumber));
});
eventBus.on("scalechanging", (e) => post({ type: "scale", scale: e.scale }));
eventBus.on("updatefindmatchescount", ({ matchesCount }) => {
  document.getElementById("searchStatus").textContent = matchesCount.total ? `${matchesCount.current} / ${matchesCount.total}` : (labels.noMatches ?? "");
  post({ type: "findCount", current: matchesCount.current, total: matchesCount.total });
});

// MARK: Selection and markup

/** Quads (PDF space, per page) covering the current selection. */
function selectionQuads() {
  const selection = document.getSelection();
  if (!selection || selection.isCollapsed) return null;
  const range = selection.getRangeAt(0);
  const rects = [...range.getClientRects()].filter((r) => r.width > 1 && r.height > 1);
  const byPage = new Map();
  for (const rect of rects) {
    const cx = rect.left + rect.width / 2, cy = rect.top + rect.height / 2;
    const pageDiv = document.elementsFromPoint(cx, cy).find((el) => el.classList?.contains("page"));
    if (!pageDiv) continue;
    const pageNumber = +pageDiv.dataset.pageNumber;
    const view = viewer.getPageView(pageNumber - 1);
    const origin = pageDiv.getBoundingClientRect();
    const [x1, y1] = view.viewport.convertToPdfPoint(rect.left - origin.left, rect.top - origin.top);
    const [x2, y2] = view.viewport.convertToPdfPoint(rect.right - origin.left, rect.bottom - origin.top);
    const left = Math.min(x1, x2), right = Math.max(x1, x2), top = Math.max(y1, y2), bottom = Math.min(y1, y2);
    const quads = byPage.get(pageNumber) ?? [];
    // Merge pieces of one line (pdf.js splits text runs).
    const same = quads.find((q) => Math.abs(q[1] - top) < 2 && Math.abs(q[5] - bottom) < 2 && left - q[2] < 6);
    if (same) { same[2] = same[6] = Math.max(same[2], right); }
    else quads.push([left, top, right, top, left, bottom, right, bottom]);
    byPage.set(pageNumber, quads);
  }
  if (!byPage.size) return null;
  return { text: selection.toString().replace(/\s+/g, " ").trim(), pages: [...byPage.entries()].map(([page, quads]) => ({ page, quads })) };
}

document.addEventListener("mouseup", () => {
  setTimeout(() => {
    const found = selectionQuads();
    if (!found) { post({ type: "selection", text: "" }); return; }
    if (["highlight", "underline", "strike"].includes(tool)) {
      const subtype = { highlight: "Highlight", underline: "Underline", strike: "StrikeOut" }[tool];
      post({ type: "markup", subtype, color, text: found.text, pages: found.pages });
      document.getSelection().removeAllRanges();
    } else {
      post({ type: "selection", text: found.text, pages: found.pages });
    }
  }, 0);
});

// Notes and text boxes: a click on a page.
container.addEventListener("click", (e) => {
  if (tool !== "note" && tool !== "textbox") return;
  const pageDiv = e.target.closest?.(".page");
  if (!pageDiv) return;
  const view = viewer.getPageView(+pageDiv.dataset.pageNumber - 1);
  const origin = pageDiv.getBoundingClientRect();
  const [x, y] = view.viewport.convertToPdfPoint(e.clientX - origin.left, e.clientY - origin.top);
  post({ type: tool, page: +pageDiv.dataset.pageNumber, x, y, color });
});

// Ink: strokes drawn on a canvas over the page, sent in PDF space when the pen lifts.
eventBus.on("pagerendered", ({ source, pageNumber }) => {
  const div = source.div;
  if (div.querySelector(".ink-layer")) return;
  const canvas = document.createElement("canvas");
  canvas.className = "ink-layer";
  div.appendChild(canvas);
  let stroke = null;
  const point = (e) => {
    const r = canvas.getBoundingClientRect();
    return [e.clientX - r.left, e.clientY - r.top];
  };
  canvas.addEventListener("pointerdown", (e) => {
    if (tool !== "ink") return;
    canvas.width = canvas.clientWidth; canvas.height = canvas.clientHeight;
    canvas.setPointerCapture(e.pointerId);
    stroke = [point(e)];
  });
  canvas.addEventListener("pointermove", (e) => {
    if (!stroke) return;
    const p = point(e);
    const ctx = canvas.getContext("2d");
    ctx.strokeStyle = colors[color]; ctx.lineWidth = 2 * viewer.currentScale; ctx.lineCap = "round";
    ctx.beginPath(); ctx.moveTo(...stroke[stroke.length - 1]); ctx.lineTo(...p); ctx.stroke();
    stroke.push(p);
  });
  canvas.addEventListener("pointerup", () => {
    if (!stroke) return;
    const view = viewer.getPageView(pageNumber - 1);
    const pdfPoints = stroke.flatMap(([x, y]) => view.viewport.convertToPdfPoint(x, y));
    stroke = null;
    if (pdfPoints.length >= 4) post({ type: "ink", page: pageNumber, color, strokes: [pdfPoints] });
  });
});

// Clicking an existing annotation selects it in the app (to recolour or delete it).
container.addEventListener("click", (e) => {
  const section = e.target.closest?.(".annotationLayer section[data-annotation-id]");
  if (!section || tool !== "select") return;
  const pageDiv = section.closest(".page");
  post({ type: "annotationClicked", page: +pageDiv.dataset.pageNumber, id: section.dataset.annotationId });
});

// MARK: Sidebar

async function buildThumbnails() {
  const pane = document.getElementById("thumbnails");
  pane.textContent = "";
  const observer = new IntersectionObserver(async (entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting || entry.target.dataset.done) continue;
      entry.target.dataset.done = "1";
      const page = await pdf.getPage(+entry.target.dataset.page);
      const viewport = page.getViewport({ scale: 150 / page.getViewport({ scale: 1 }).width });
      const canvas = entry.target;
      canvas.width = viewport.width * devicePixelRatio; canvas.height = viewport.height * devicePixelRatio;
      canvas.style.width = `${viewport.width}px`; canvas.style.height = `${viewport.height}px`;
      await page.render({ canvasContext: canvas.getContext("2d"), viewport: page.getViewport({ scale: viewport.scale * devicePixelRatio }) }).promise;
    }
  }, { root: pane });
  for (let i = 1; i <= pdf.numPages; i++) {
    const canvas = document.createElement("canvas");
    canvas.className = "thumb" + (i === viewer.currentPageNumber ? " current" : "");
    canvas.dataset.page = i;
    canvas.style.width = "150px"; canvas.style.height = "194px";
    canvas.onclick = () => { viewer.currentPageNumber = i; };
    const label = document.createElement("div");
    label.className = "thumb-label";
    label.textContent = i;
    pane.append(canvas, label);
    observer.observe(canvas);
  }
}

async function buildOutline() {
  const pane = document.getElementById("outline");
  pane.textContent = "";
  const outline = await pdf.getOutline();
  if (!outline?.length) { pane.textContent = labels.noOutline ?? ""; return; }
  const render = async (items, parent) => {
    for (const item of items) {
      const row = document.createElement("div");
      row.className = "outline-item";
      const title = document.createElement("span");
      title.textContent = item.title;
      const page = document.createElement("span");
      page.className = "page";
      row.append(title, page);
      row.onclick = () => item.dest ? linkService.goToDestination(item.dest) : item.url && post({ type: "link", url: item.url });
      parent.appendChild(row);
      try {
        const dest = typeof item.dest === "string" ? await pdf.getDestination(item.dest) : item.dest;
        if (dest) page.textContent = (await pdf.getPageIndex(dest[0])) + 1;
      } catch { /* no page number */ }
      if (item.items?.length) {
        const children = document.createElement("div");
        children.className = "outline-children";
        parent.appendChild(children);
        await render(item.items, children);
      }
    }
  };
  await render(outline, pane);
}

async function refreshAnnotations() {
  const pane = document.getElementById("annotations");
  pane.textContent = "";
  let count = 0;
  for (let i = 1; i <= pdf.numPages; i++) {
    const page = await pdf.getPage(i);
    for (const a of await page.getAnnotations()) {
      if (!["Highlight", "Underline", "StrikeOut", "Squiggly", "Text", "FreeText", "Ink"].includes(a.subtype)) continue;
      count++;
      const card = document.createElement("div");
      card.className = "annotation-card";
      const c = a.color ? `rgb(${a.color[0]},${a.color[1]},${a.color[2]})` : "#ffd60a";
      card.style.borderLeftColor = c;
      card.textContent = a.contentsObj?.str || a.textContent?.join(" ") || (labels[a.subtype] ?? a.subtype);
      const meta = document.createElement("div");
      meta.className = "meta";
      meta.textContent = (labels.page ?? "%d").replace("%d", i) + (a.titleObj?.str ? ` · ${a.titleObj.str}` : "");
      card.appendChild(meta);
      card.onclick = () => viewer.scrollPageIntoView({ pageNumber: i, destArray: [null, { name: "XYZ" }, a.rect[0], a.rect[3] + 40, null] });
      pane.appendChild(card);
    }
  }
  if (!count) pane.textContent = labels.noAnnotations ?? "";
}

document.querySelectorAll("#sidebarTabs button").forEach((button) => {
  button.onclick = () => {
    document.querySelectorAll("#sidebarTabs button, .pane").forEach((el) => el.classList.remove("active"));
    button.classList.add("active");
    document.getElementById(button.dataset.pane).classList.add("active");
    if (button.dataset.pane === "search") document.getElementById("searchBox").focus();
  };
});

const searchBox = document.getElementById("searchBox");
searchBox.addEventListener("keydown", (e) => {
  if (e.key === "Enter") find(searchBox.value, e.shiftKey);
});

function find(query, previous = false) {
  eventBus.dispatch("find", { source: null, type: previous ? "again" : (query === lastQuery ? "again" : ""), query, phraseSearch: true,
    caseSensitive: false, entireWord: false, highlightAll: true, findPrevious: previous, matchDiacritics: false });
  lastQuery = query;
}
let lastQuery = "";

// MARK: Commands from the app

host?.addEventListener("message", async (e) => {
  const m = e.data;
  switch (m.cmd) {
    case "open": labels = m.labels ?? labels; await open(m); break;
    case "reload": await reload(m.url); break;
    case "tool":
      tool = m.tool; color = m.color ?? color;
      document.body.className = document.body.className.replace(/\btool-\S+/g, "").trim() + ` tool-${tool}`;
      break;
    case "zoom":
      if (m.value === "in") viewer.increaseScale();
      else if (m.value === "out") viewer.decreaseScale();
      else viewer.currentScaleValue = m.value;
      break;
    case "layout": viewer.spreadMode = m.value === "twoUp" ? 1 : 0; break;
    case "find": find(m.query, m.previous); break;
    case "goto": viewer.currentPageNumber = m.page; break;
    case "theme": document.documentElement.dataset.theme = m.dark ? "dark" : "light"; break;
    case "shadows": document.body.classList.toggle("no-shadows", !m.on); break;
    case "sidebar": document.body.classList.toggle("no-sidebar", !m.visible); break;
    case "scrollTo": suppressScroll = true; container.scrollTop = m.ratio * (container.scrollHeight - container.clientHeight); setTimeout(() => (suppressScroll = false), 50); break;
    case "refreshAnnotations": refreshAnnotations(); break;
  }
});

post({ type: "ready" });
