// Folio's reader page: pdf.js's viewer components plus Folio's tools. Talks to its parent page (reader/ReaderTab.tsx) through
// window messages.
//
// Commands from the app: open, reload, tool, zoom, layout, find, findStep, goto, step, history, theme, shadows, sidebar,
// sidebarTab, scrollTo, selectAnnotation, print, clearSelection.
// Messages to the app: ready, error, loaded, page, position, scale, scroll, selection, markup, note, textbox, ink, link,
// contextMenu, annotationEdit, annotationDelete, annotationMoved, key, findCount, toolReset.

// The page runs in an iframe of the interface (reader/ReaderTab.tsx), which holds the app's end of the conversation.
const host = {
  postMessage: (message) => parent.postMessage({ folioReader: message }, location.origin),
  addEventListener: (type, listener) => window.addEventListener(type, (e) => { if (e.source === parent) listener(e); }),
};
const post = (message) => host.postMessage(message);
window.addEventListener("error", (e) => {
  if (String(e.message).startsWith("ResizeObserver loop")) return; // harmless, and normal while zooming
  post({ type: "error", message: String(e.message), detail: `${e.filename}:${e.lineno}` });
});
window.addEventListener("unhandledrejection", (e) => post({ type: "error", message: String(e.reason?.message ?? e.reason), detail: String(e.reason?.stack ?? "") }));

const pdfjsLib = await import("../pdfjs/build/pdf.min.mjs");
globalThis.pdfjsLib = pdfjsLib;
const { EventBus, PDFViewer, PDFLinkService, PDFFindController } = await import("../pdfjs/web/pdf_viewer.mjs");
pdfjsLib.GlobalWorkerOptions.workerSrc = "../pdfjs/build/pdf.worker.min.mjs";

const container = document.getElementById("viewerContainer");
const eventBus = new EventBus();
const linkService = new PDFLinkService({ eventBus, externalLinkTarget: pdfjsLib.LinkTarget?.BLANK ?? 2 });
const findController = new PDFFindController({ eventBus, linkService });
const viewer = new PDFViewer({
  container, eventBus, linkService, findController,
  textLayerMode: 1,
  // Reads the annotation storage: how annotations changed since loading are taken off the page (syncCanvas).
  annotationMode: pdfjsLib.AnnotationMode.ENABLE_STORAGE,
  annotationEditorMode: pdfjsLib.AnnotationEditorType.DISABLE,
  removePageBorders: false,
  imageResourcesPath: "../pdfjs/web/images/",
  maxCanvasPixels: 2 ** 26,
  enableHWA: true,
  // pdf.js would paint a selection of its own under Folio's (paintSelection).
  enableSelectionRendering: false,
});
linkService.setViewer(viewer);

let pdf = null;
let pendingPassword = null;
let oldTask = null;
let loadId = 0;
let tool = "select";
let color = "yellow";
let labels = {};
let suppressScroll = 0;
let autoFit = null; // the pdf.js scale keyword while the zoom follows the window
let pageAnnotations = new Map(); // page number -> Folio-editable annotations
let selected = null; // { page, id }
let annotationAuthor = "";
let originals = new Map(); // id -> the entry as the loaded file has it (drawn on the canvas by pdf.js)
let hiddenOnCanvas = new Set();
const undoStack = [], redoStack = [];

const colors = {
  yellow: "rgb(255,217,51)", green: "rgb(115,217,102)", blue: "rgb(102,178,255)",
  pink: "rgb(255,140,191)", purple: "rgb(191,140,255)", red: "rgb(255,89,89)",
};
const editableTypes = new Set(["Highlight", "Underline", "StrikeOut", "Squiggly", "Text", "FreeText", "Ink", "Square", "Circle", "Line"]);
const movableTypes = new Set(["Text", "FreeText", "Ink", "Square", "Circle", "Line"]);

const label = (key, fallback = "") => labels[key] ?? fallback;

// MARK: Opening

async function open({ url, page, scale, top, left, layout, zoom, keepPanes, author }) {
  const id = ++loadId;
  performance.clearMarks();
  performance.mark("open-start");
  if (author !== undefined) annotationAuthor = author;
  // A tab that just came forward may not have its size yet.
  for (let i = 0; i < 90 && container.clientWidth === 0; i++) await new Promise((r) => setTimeout(r, 16));
  let doc, task;
  try {
    task = pdfjsLib.getDocument({
      url, cMapUrl: "../pdfjs/cmaps/", cMapPacked: true,
      standardFontDataUrl: "../pdfjs/standard_fonts/", wasmUrl: "../pdfjs/wasm/",
      enableXfa: false, isEvalSupported: false,
    });
    task.onPassword = (update, reason) => {
      pendingPassword = { update, task };
      post({ type: "password", wrong: reason === pdfjsLib.PasswordResponses?.INCORRECT_PASSWORD });
    };
    doc = await task.promise;
  } catch (e) {
    post({ type: "error", fatal: true, name: e?.name ?? "", message: String(e?.message ?? e) });
    showMessage(e?.name === "PasswordException" ? label("encrypted") : label("openFailed"));
    return;
  }
  if (id !== loadId) { task.destroy(); return; }
  const old = pdf;
  pdf = doc;
  showMessage("");
  pageAnnotations = new Map();
  originals = new Map();
  hiddenOnCanvas = new Set();
  undoStack.length = redoStack.length = 0;
  selected = null;
  const ready = new Promise((resolve) => eventBus.on("pagesinit", resolve, { once: true }));
  viewer.setDocument(pdf);
  linkService.setDocument(pdf, null);
  await ready;
  if (old) oldTask?.destroy();
  oldTask = task;
  if (layout) viewer.spreadMode = layout === "twoUp" ? 1 : 0;
  if (scale) { viewer.currentScale = scale; autoFit = null; }
  else {
    autoFit = zoom === "actualSize" ? "page-actual" : "page-width";
    viewer.currentScaleValue = autoFit === "page-actual" ? "page-actual" : autoFit;
    if (autoFit === "page-actual") autoFit = null;
  }
  if (page) {
    viewer.scrollPageIntoView({ pageNumber: Math.min(page, pdf.numPages), destArray: top != null ? [null, { name: "XYZ" }, left ?? 0, top, null] : undefined });
  }
  post({ type: "loaded", pages: pdf.numPages });
  post({ type: "page", page: viewer.currentPageNumber, pages: pdf.numPages });
  // The first page matters most: thumbnails, outline and the annotation scan wait until it is on screen.
  const panes = keepPanes ? scrollTops() : null;
  let begun = false;
  const begin = () => {
    if (begun) return;
    begun = true;
    eventBus.off("pagerendered", begin);
    performance.mark("first-page");
    setTimeout(async () => {
      if (id !== loadId) return;
      buildThumbnails();
      buildOutline();
      await refreshAnnotations();
      if (panes) restoreScrollTops(panes);
      if (lastQuery) find(lastQuery, false, true);
    }, 30);
  };
  eventBus.on("pagerendered", begin);
  setTimeout(begin, 1200);
}

function showMessage(text) {
  const box = document.getElementById("message");
  box.textContent = text;
  box.hidden = !text;
}

/** Reload after the app wrote into the file: same place and zoom, and the old picture stays up until the new one is drawn. */
async function reload(url) {
  if (!pdf) return open({ url });
  const position = currentPosition();
  const freeze = freezeVisiblePages();
  suppressScroll++;
  const keepAuto = autoFit;
  selected = null;
  try {
    await open({ url, page: position.page, scale: viewer.currentScale, top: position.top, left: position.left, keepPanes: true });
    autoFit = keepAuto;
    container.scrollLeft = position.scrollLeft;
    container.scrollTop = position.scrollTop;
  } finally {
    suppressScroll--;
    releaseFreeze(freeze);
  }
}

function freezeVisiblePages() {
  const overlay = document.createElement("div");
  overlay.className = "freeze";
  const box = container.getBoundingClientRect();
  overlay.style.cssText = `left:${box.left}px;top:${box.top}px;width:${box.width}px;height:${box.height}px`;
  for (const canvas of container.querySelectorAll(".page canvas")) {
    if (canvas.closest(".ink-preview")) continue;
    const r = canvas.getBoundingClientRect();
    if (r.bottom < box.top || r.top > box.bottom || r.width === 0) continue;
    const copy = document.createElement("canvas");
    copy.width = canvas.width; copy.height = canvas.height;
    try { copy.getContext("2d").drawImage(canvas, 0, 0); } catch { continue; }
    copy.style.cssText = `left:${r.left - box.left}px;top:${r.top - box.top}px;width:${r.width}px;height:${r.height}px`;
    overlay.appendChild(copy);
  }
  overlay.style.background = getComputedStyle(container).backgroundColor;
  document.body.appendChild(overlay);
  return overlay;
}

function releaseFreeze(overlay) {
  let done = false;
  const finish = () => { if (done) return; done = true; eventBus.off("pagerendered", finish); overlay.remove(); };
  eventBus.on("pagerendered", finish);
  setTimeout(finish, 1500);
}

function currentPosition() {
  const page = viewer.currentPageNumber;
  const view = viewer.getPageView(page - 1);
  let top = null, left = null;
  if (view?.div) {
    const rect = view.div.getBoundingClientRect();
    const box = container.getBoundingClientRect();
    [left, top] = view.viewport.convertToPdfPoint(box.left - rect.left, box.top - rect.top);
  }
  return { page, top, left, scale: viewer.currentScale, autoScale: autoFit != null, scrollTop: container.scrollTop, scrollLeft: container.scrollLeft };
}

// The zoom follows the window while it is on "fit width", also when the tab first shows (a hidden tab has no size).
new ResizeObserver(() => {
  if (!pdf || container.clientWidth === 0) return;
  if (hold) { followHold(); return; }
  if (autoFit) viewer.currentScaleValue = autoFit;
  viewer.update();
}).observe(container);

// While the panes beside the pages slide, refitting for real on every frame would redraw them all. pdf.js stretches what it has drawn
// (the same way as during a pinch), and draws afresh once, at the end.
const HOLD_MS = 220;
const FIT_PADDING = 40; // what pdf.js leaves beside a page when it fits the width
let hold = null;

function holdFit() {
  clearTimeout(hold?.timer);
  document.body.classList.add("moving");
  hold = {
    scale: hold?.scale ?? viewer.currentScale,
    width: hold?.width ?? container.clientWidth,
    timer: setTimeout(() => {
      hold = null;
      document.body.classList.remove("moving");
      if (!pdf || container.clientWidth === 0) return;
      if (autoFit) viewer.currentScaleValue = autoFit;
      viewer.update();
    }, HOLD_MS),
  };
}

function followHold() {
  if (autoFit !== "page-width" || hold.width <= FIT_PADDING) return;
  const target = hold.scale * Math.max(1, container.clientWidth - FIT_PADDING) / (hold.width - FIT_PADDING);
  const factor = target / viewer.currentScale;
  if (Math.abs(factor - 1) < 0.005) return;
  const box = container.getBoundingClientRect();
  viewer.updateScale({ scaleFactor: factor, origin: [box.left + box.width / 2, box.top + box.height / 2], drawingDelay: HOLD_MS * 2 });
}

// MARK: Events to the app

let positionTimer = 0;
container.addEventListener("scroll", () => {
  if (suppressScroll) return;
  clearTimeout(positionTimer);
  positionTimer = setTimeout(() => post({ type: "position", ...currentPosition() }), 400);
  const view = viewer.getPageView(viewer.currentPageNumber - 1);
  if (view?.div) {
    const fraction = (container.scrollTop - view.div.offsetTop) / Math.max(1, view.div.clientHeight);
    post({ type: "scroll", page: viewer.currentPageNumber, fraction });
  }
}, { passive: true });

eventBus.on("pagechanging", (e) => {
  post({ type: "page", page: e.pageNumber, pages: pdf?.numPages ?? 0 });
  document.querySelectorAll(".thumb").forEach((t) => {
    const current = +t.dataset.page === e.pageNumber;
    t.classList.toggle("current", current);
    if (current && document.getElementById("thumbnails").classList.contains("active")) t.scrollIntoView({ block: "nearest" });
  });
});
eventBus.on("scalechanging", (e) => post({ type: "scale", scale: e.scale }));
eventBus.on("pagerendered", ({ pageNumber, source }) => {
  drawSelection(pageNumber, source);
  drawMarks(pageNumber, source);
  restoreSelection();
  paintSelection();
});
eventBus.on("pagerender", ({ pageNumber, source }) => drawMarks(pageNumber, source));
eventBus.on("annotationlayerrendered", ({ pageNumber }) => hideSections(viewer.getPageView(pageNumber - 1)));

// MARK: Selection and markup

/**
 * The current selection as lines, per page, in the page's own CSS pixels. Text runs of a line become one rectangle, so
 * the gaps between words (which belong to no run) are covered, and lines are as tall as their text, so neighbouring
 * lines do not overlap.
 */
function selectionLines() {
  const selection = document.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;
  const range = selection.getRangeAt(0);
  const common = range.commonAncestorContainer;
  const root = common.nodeType === Node.ELEMENT_NODE ? common : common.parentElement;
  if (!root?.closest?.("#viewerContainer") && !root?.querySelector?.(".textLayer")) return null;
  const byPage = new Map();
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const first = common.nodeType === Node.TEXT_NODE ? common : walker.nextNode();
  for (let node = first; node; node = walker.nextNode()) {
    if (!range.intersectsNode(node) || !node.textContent.trim()) continue;
    const span = node.parentElement;
    if (!span?.closest(".textLayer")) continue;
    const pageDiv = span.closest(".page");
    if (!pageDiv) continue;
    const piece = document.createRange();
    piece.setStart(node, node === range.startContainer ? range.startOffset : 0);
    piece.setEnd(node, node === range.endContainer ? range.endOffset : node.textContent.length);
    const origin = pageDiv.getBoundingClientRect();
    const box = span.getBoundingClientRect();
    const number = +pageDiv.dataset.pageNumber;
    const lines = byPage.get(number) ?? [];
    byPage.set(number, lines);
    const vertical = isVerticalRun(span, box);
    for (const rect of piece.getClientRects()) {
      if (rect.width < 0.5 || rect.height < 0.5) continue;
      // Along the text the range is exact; across it the range gives the font's whole line box, so the run's own box is used.
      const fragment = vertical
        ? { left: box.left - origin.left, right: box.right - origin.left, top: rect.top - origin.top, bottom: rect.bottom - origin.top }
        : { left: rect.left - origin.left, right: rect.right - origin.left, top: box.top - origin.top, bottom: box.bottom - origin.top };
      addToLine(lines, fragment, vertical);
    }
  }
  if (!byPage.size) return null;
  for (const lines of byPage.values()) meetLines(lines);
  return byPage;
}

/** Text running up or down the page, such as arXiv's stamp in the margin. A narrow run like "[" or "a" is not: it is the transform that tells. */
function isVerticalRun(span, box) {
  if (box.height <= box.width) return false;
  const own = new DOMMatrix(getComputedStyle(span).transform);
  const pageTurned = (+span.closest(".textLayer")?.dataset.mainRotation || 0) % 180 !== 0;
  return (Math.abs(own.b) > Math.abs(own.a)) !== pageTurned;
}

/** Joins a piece of text to the line it belongs to. A line keeps the height of its longest text, so a superscript or a tall symbol leaves no bump. */
function addToLine(lines, f, vertical) {
  const [start, end, near, far] = vertical ? ["top", "bottom", "left", "right"] : ["left", "right", "top", "bottom"];
  const length = f[end] - f[start];
  const thickness = f[far] - f[near];
  const line = lines.find((l) => {
    if (l.vertical !== vertical) return false;
    const overlap = Math.min(l[far], f[far]) - Math.max(l[near], f[near]);
    return overlap > 0.5 * Math.min(l[far] - l[near], thickness) && f[start] - l[end] < thickness * 1.5 && l[start] - f[end] < thickness * 1.5;
  });
  if (!line) { lines.push({ ...f, vertical, longest: length }); return; }
  line[start] = Math.min(line[start], f[start]);
  line[end] = Math.max(line[end], f[end]);
  if (length > line.longest) {
    line.longest = length;
    line[near] = f[near];
    line[far] = f[far];
  }
}

/** Lines of a paragraph never overlap, and `paintBottom` closes the stripe between them. */
function meetLines(lines) {
  const rows = lines.filter((l) => !l.vertical).sort((a, b) => a.top - b.top);
  rows.forEach((row, i) => {
    row.paintBottom = row.bottom;
    const next = rows.slice(i + 1).find((other) => other.left < row.right && row.left < other.right);
    if (!next) return;
    if (row.bottom > next.top) row.bottom = next.top = row.paintBottom = (row.bottom + next.top) / 2;
    else if (next.top - row.bottom < (row.bottom - row.top) * 0.6) row.paintBottom = next.top;
  });
}

/** The current text selection: text plus quads (PDF space, per page). */
function selectionInfo() {
  const byPage = selectionLines();
  if (!byPage) return null;
  const pages = [];
  for (const [page, lines] of byPage) {
    const view = viewer.getPageView(page - 1);
    const quads = lines.map((l) => {
      const [x1, y1] = view.viewport.convertToPdfPoint(l.left, l.top);
      const [x2, y2] = view.viewport.convertToPdfPoint(l.right, l.bottom);
      const left = Math.min(x1, x2), right = Math.max(x1, x2), top = Math.max(y1, y2), bottom = Math.min(y1, y2);
      return [left, top, right, top, left, bottom, right, bottom];
    });
    pages.push({ page, quads });
  }
  const text = document.getSelection().toString().replace(/-\s*\n\s*/g, "").replace(/\s+/g, " ").trim();
  return { text, pages };
}

// The browser only paints a selection over text runs, which leaves holes between words; Folio paints it itself.
let selectionFrame = 0;
// pdf.js hides the text layer while it redraws a page at a new scale, and the browser then drops the selection: it comes back afterwards.
let keptSelection = null;
document.addEventListener("selectionchange", () => {
  const selection = document.getSelection();
  if (selection?.rangeCount && !selection.isCollapsed) {
    const { startContainer, startOffset, endContainer, endOffset } = selection.getRangeAt(0);
    if (startContainer.parentElement?.closest(".textLayer")) keptSelection = { startContainer, startOffset, endContainer, endOffset };
  }
  cancelAnimationFrame(selectionFrame);
  selectionFrame = requestAnimationFrame(paintSelection);
});
document.addEventListener("pointerdown", (e) => { if (e.button === 0) keptSelection = null; }, true);

function clearSelection() {
  keptSelection = null;
  document.getSelection()?.removeAllRanges();
}

function restoreSelection(tries = 10) {
  if (!keptSelection || !document.getSelection()?.isCollapsed) return;
  const { startContainer, startOffset, endContainer, endOffset } = keptSelection;
  if (!startContainer.isConnected || !endContainer.isConnected) { keptSelection = null; return; }
  const hidden = (node) => node.parentElement?.closest(".textLayer")?.hidden;
  if (hidden(startContainer) || hidden(endContainer)) {
    if (tries > 0) setTimeout(() => restoreSelection(tries - 1), 50);
    return;
  }
  document.getSelection().setBaseAndExtent(startContainer, startOffset, endContainer, endOffset);
}

function paintSelection() {
  document.querySelectorAll(".selection-layer").forEach((layer) => layer.remove());
  const byPage = selectionLines();
  if (!byPage) return;
  for (const [page, lines] of byPage) {
    const view = viewer.getPageView(page - 1);
    if (!view?.div) continue;
    const layer = document.createElement("div");
    layer.className = "selection-layer";
    // In shares of the page, so it stays in place while a pinch resizes the page.
    const { width, height } = view.div.getBoundingClientRect();
    for (const l of lines) {
      const box = document.createElement("div");
      const bottom = l.paintBottom ?? l.bottom;
      box.style.cssText = `left:${100 * l.left / width}%;top:${100 * l.top / height}%;width:${100 * (l.right - l.left) / width}%;height:${100 * (bottom - l.top) / height}%`;
      layer.appendChild(box);
    }
    const wrapper = view.div.querySelector(".canvasWrapper");
    if (wrapper) wrapper.after(layer); else view.div.prepend(layer);
  }
}

let lastSelection = null;
let tempCounter = 0;
const tempId = () => `pending-${++tempCounter}`;

function addMarkup(subtype, found) {
  const pages = found.pages.map(({ page, quads }) => ({ page, quads, temp: tempId() }));
  const changes = pages.map(({ page, quads, temp }) => {
    const flat = quads.flat();
    return { page, before: null, after: {
      id: temp, page, subtype, quads: flat, rect: boundsOf(flat), strokes: null, colorKey: color, colorRgb: rgbOfKey(color),
      contents: "", quoted: found.text, author: annotationAuthor, live: true,
    } };
  });
  commit(changes);
  post({ type: "markup", subtype, color, pages });
}

document.addEventListener("mouseup", (e) => {
  if (e.button !== 0) return;
  setTimeout(() => {
    const found = selectionInfo();
    if (!found) { post({ type: "selection", text: "" }); return; }
    if (["highlight", "underline", "strike"].includes(tool)) {
      addMarkup({ highlight: "Highlight", underline: "Underline", strike: "StrikeOut" }[tool], found);
      clearSelection();
      post({ type: "selection", text: "" });
    } else {
      post({ type: "selection", text: found.text, pages: found.pages, done: true, ...selectionGeometry(), clickCount: e.detail });
    }
  }, 0);
});

/** Where the selection is on screen (this page's coordinates): all of it, and the end of its last line (for 划词翻译). */
function selectionGeometry() {
  const selection = document.getSelection();
  if (!selection?.rangeCount) return {};
  const rects = [...selection.getRangeAt(0).getClientRects()].filter((r) => r.width > 0.5 && r.height > 0.5);
  if (!rects.length) return {};
  const visible = rects.filter((r) => r.bottom > 0 && r.top < innerHeight);
  const use = visible.length ? visible : rects;
  const last = use[use.length - 1];
  const union = use.reduce((a, r) => ({ left: Math.min(a.left, r.left), top: Math.min(a.top, r.top), right: Math.max(a.right, r.right), bottom: Math.max(a.bottom, r.bottom) }),
    { left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity });
  return { rect: union, end: { x: last.right, y: last.top, bottom: last.bottom } };
}
document.addEventListener("pointerdown", (e) => { if (e.button === 0) post({ type: "pointerDown" }); }, true);
container.addEventListener("scroll", () => post({ type: "viewMoved" }), { passive: true });

// MARK: Annotations added or changed since the file was loaded
//
// A change goes into the file at once, but the document on screen is not reloaded: that would redraw every page. New and
// changed annotations are drawn by Folio in a layer over the page; those pdf.js drew from the file are taken off its
// canvas (one page is redrawn, and only when such an old one changes).

function boundsOf(flat) {
  let l = Infinity, b = Infinity, r = -Infinity, t = -Infinity;
  for (let i = 0; i + 1 < flat.length; i += 2) {
    l = Math.min(l, flat[i]); r = Math.max(r, flat[i]);
    b = Math.min(b, flat[i + 1]); t = Math.max(t, flat[i + 1]);
  }
  return [l, b, r, t];
}

function rgbOfKey(key) { return (colors[key] ?? colors.yellow).match(/\d+/g).map(Number); }

function commit(changes) {
  applyChanges(changes, "after");
  undoStack.push(changes);
  redoStack.length = 0;
}

function applyChanges(changes, side) {
  const pages = new Set();
  for (const change of changes) {
    const list = pageAnnotations.get(change.page) ?? [];
    pageAnnotations.set(change.page, list);
    const target = change[side], other = change[side === "after" ? "before" : "after"];
    const id = (target ?? other).id;
    const index = list.findIndex((a) => a.id === id);
    if (target) { if (index >= 0) list[index] = target; else list.push(target); }
    else if (index >= 0) list.splice(index, 1);
    pages.add(change.page);
  }
  for (const page of pages) {
    syncCanvas(page);
    drawMarks(page);
    repaintThumbnail(page);
  }
  renderAnnotationList();
  if (selected) drawSelection(selected.page);
}

/** Old annotations that were changed or deleted must not show from the canvas any more; undoing brings them back. */
function syncCanvas(page) {
  if (!pdf) return;
  const list = pageAnnotations.get(page) ?? [];
  let changed = false;
  for (const original of originals.values()) {
    if (original.page !== page) continue;
    const hide = !list.includes(original);
    if (hide === hiddenOnCanvas.has(original.id)) continue;
    if (hide) hiddenOnCanvas.add(original.id); else hiddenOnCanvas.delete(original.id);
    pdf.annotationStorage.setValue(original.id, { noView: hide });
    changed = true;
  }
  if (!changed) return;
  const view = viewer.getPageView(page - 1);
  if (!view) return;
  view.reset({ keepAnnotationLayer: true, keepTextLayer: true, keepCanvasWrapper: true });
  viewer.update();
  hideSections(view);
}

/** Notes without a drawing are HTML in pdf.js's annotation layer. */
function hideSections(view) {
  view?.div?.querySelectorAll(".annotationLayer section[data-annotation-id]").forEach((section) => {
    const id = section.dataset.annotationId;
    section.style.display = hiddenOnCanvas.has(id) ? "none" : "";
    // Text boxes have the same tint as while they are being added.
    const entry = originals.get(id);
    if (entry?.subtype === "FreeText") section.style.backgroundColor = `rgba(${entry.colorRgb.join(",")},.25)`;
  });
}

const SVG = "http://www.w3.org/2000/svg";

function drawMarks(page, source) {
  const view = source ?? viewer.getPageView(page - 1);
  if (!view?.div || !view.viewport) return;
  const live = (pageAnnotations.get(page) ?? []).filter((a) => a.live);
  let svg = view.div.querySelector(".folio-marks");
  if (!live.length) { svg?.remove(); return; }
  const base = view.viewport.clone({ scale: 1 });
  if (!svg) svg = document.createElementNS(SVG, "svg");
  svg.setAttribute("class", "folio-marks");
  svg.setAttribute("viewBox", `0 0 ${base.width} ${base.height}`);
  svg.setAttribute("preserveAspectRatio", "none");
  svg.textContent = "";
  const wrapper = view.div.querySelector(".canvasWrapper");
  if (svg.parentElement !== view.div || svg.previousElementSibling !== wrapper) {
    if (wrapper) wrapper.after(svg); else view.div.prepend(svg);
  }
  const P = (x, y) => base.convertToViewportPoint(x, y);
  const make = (name, attributes, parent = svg) => {
    const element = document.createElementNS(SVG, name);
    for (const [k, v] of Object.entries(attributes)) element.setAttribute(k, v);
    parent.appendChild(element);
    return element;
  };
  for (const a of live) {
    const fill = `rgb(${a.colorRgb.join(",")})`;
    // One transparency for a whole annotation: where its lines touch, it does not get darker.
    const shapes = a.subtype === "Highlight" ? make("g", { opacity: 0.5 }) : svg;
    if (a.subtype === "Ink") {
      for (const stroke of a.strokes ?? []) {
        const points = [];
        for (let i = 0; i + 1 < stroke.length; i += 2) points.push(P(stroke[i], stroke[i + 1]).join(","));
        make("polyline", { points: points.join(" "), fill: "none", stroke: fill, "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round", style: "mix-blend-mode:normal" });
      }
    } else if (a.quads?.length) {
      for (let i = 0; i + 7 < a.quads.length; i += 8) {
        const q = a.quads;
        const [x1, y1] = P(q[i], q[i + 1]), [x2, y2] = P(q[i + 2], q[i + 3]), [x3, y3] = P(q[i + 4], q[i + 5]), [x4, y4] = P(q[i + 6], q[i + 7]);
        if (a.subtype === "Highlight") {
          make("path", { d: `M${x1} ${y1}L${x2} ${y2}L${x4} ${y4}L${x3} ${y3}Z`, fill }, shapes);
        } else {
          const t = a.subtype === "Underline" ? 0.92 : 0.5;
          make("line", { x1: x1 + (x3 - x1) * t, y1: y1 + (y3 - y1) * t, x2: x2 + (x4 - x2) * t, y2: y2 + (y4 - y2) * t, stroke: fill, "stroke-width": Math.max(0.7, Math.hypot(x3 - x1, y3 - y1) * 0.07) });
        }
      }
    } else if (a.subtype === "FreeText") {
      const [x1, y1] = P(a.rect[0], a.rect[3]), [x2, y2] = P(a.rect[2], a.rect[1]);
      const object = make("foreignObject", { x: Math.min(x1, x2), y: Math.min(y1, y2), width: Math.abs(x2 - x1), height: Math.abs(y2 - y1) });
      const box = document.createElement("div");
      box.className = "free-text";
      box.style.background = `rgba(${a.colorRgb.join(",")},.25)`;
      box.textContent = a.contents;
      object.appendChild(box);
    } else if (a.subtype === "Text") {
      const [x1, y1] = P(a.rect[0], a.rect[3]);
      const size = Math.abs(P(a.rect[2], a.rect[3])[0] - x1);
      const group = make("g", { transform: `translate(${x1} ${y1}) scale(${size / 20})` });
      make("rect", { x: 1, y: 1, width: 18, height: 18, rx: 3, fill, stroke: "rgba(0,0,0,.45)", "stroke-width": 1 }, group);
      make("path", { d: "M5 7h10M5 10.5h10M5 14h7", stroke: "rgba(0,0,0,.6)", "stroke-width": 1.2, fill: "none" }, group);
    }
  }
}

/** The same marks on a plain canvas: thumbnails and printing. */
function paintMarks(ctx, viewport, page) {
  for (const a of (pageAnnotations.get(page) ?? []).filter((x) => x.live)) {
    const P = (x, y) => viewport.convertToViewportPoint(x, y);
    const fill = `rgb(${a.colorRgb.join(",")})`;
    ctx.save();
    if (a.subtype === "Ink") {
      ctx.strokeStyle = fill; ctx.lineWidth = 2 * viewport.scale; ctx.lineCap = "round"; ctx.lineJoin = "round";
      for (const stroke of a.strokes ?? []) {
        ctx.beginPath();
        for (let i = 0; i + 1 < stroke.length; i += 2) { const [x, y] = P(stroke[i], stroke[i + 1]); i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y); }
        ctx.stroke();
      }
    } else if (a.quads?.length) {
      for (let i = 0; i + 7 < a.quads.length; i += 8) {
        const q = a.quads;
        const [x1, y1] = P(q[i], q[i + 1]), [x2, y2] = P(q[i + 2], q[i + 3]), [x3, y3] = P(q[i + 4], q[i + 5]), [x4, y4] = P(q[i + 6], q[i + 7]);
        if (a.subtype === "Highlight") {
          ctx.globalCompositeOperation = "multiply"; ctx.globalAlpha = 0.5; ctx.fillStyle = fill;
          ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.lineTo(x4, y4); ctx.lineTo(x3, y3); ctx.closePath(); ctx.fill();
        } else {
          const t = a.subtype === "Underline" ? 0.92 : 0.5;
          ctx.strokeStyle = fill; ctx.lineWidth = Math.max(0.7, Math.hypot(x3 - x1, y3 - y1) * 0.07);
          ctx.beginPath(); ctx.moveTo(x1 + (x3 - x1) * t, y1 + (y3 - y1) * t); ctx.lineTo(x2 + (x4 - x2) * t, y2 + (y4 - y2) * t); ctx.stroke();
        }
      }
    } else {
      const [x1, y1] = P(a.rect[0], a.rect[3]), [x2, y2] = P(a.rect[2], a.rect[1]);
      ctx.globalAlpha = a.subtype === "FreeText" ? 0.25 : 1; ctx.fillStyle = fill;
      ctx.fillRect(Math.min(x1, x2), Math.min(y1, y2), Math.abs(x2 - x1), Math.abs(y2 - y1));
      if (a.subtype === "FreeText") {
        ctx.globalAlpha = 1; ctx.fillStyle = "#000"; ctx.font = `${12 * viewport.scale}px sans-serif`; ctx.textBaseline = "top";
        ctx.fillText(a.contents, Math.min(x1, x2) + 3 * viewport.scale, Math.min(y1, y2) + 3 * viewport.scale, Math.abs(x2 - x1));
      }
    }
    ctx.restore();
  }
}

async function repaintThumbnail(page) {
  const canvas = document.querySelector(`.thumb[data-page="${page}"]`);
  if (!canvas?.dataset.done || !pdf) return;
  const doc = pdf;
  const pdfPage = await doc.getPage(page);
  if (doc !== pdf) return;
  const scale = (parseFloat(canvas.style.width) * devicePixelRatio) / pdfPage.getViewport({ scale: 1 }).width;
  const viewport = pdfPage.getViewport({ scale });
  try { await pdfPage.render({ canvas, canvasContext: canvas.getContext("2d"), viewport, annotationMode: pdfjsLib.AnnotationMode.ENABLE_STORAGE }).promise; } catch { return; }
  paintMarks(canvas.getContext("2d"), viewport, page);
}

function findEntry(page, id) { return (pageAnnotations.get(page) ?? []).find((a) => a.id === id); }

function changedCopy(entry, change) {
  const copy = { ...entry, ...change, live: true };
  return copy;
}

function shifted(entry, dx, dy) {
  const offset = (values) => values && Array.from(values, (v, i) => v + (i % 2 === 0 ? dx : dy));
  return changedCopy(entry, {
    rect: [entry.rect[0] + dx, entry.rect[1] + dy, entry.rect[2] + dx, entry.rect[3] + dy],
    quads: offset(entry.quads),
    strokes: entry.strokes?.map(offset) ?? null,
  });
}

// MARK: Pointer tools: notes, text boxes, ink, selecting and moving annotations

const isPending = (id) => String(id).startsWith("pending-");

function pageAt(event) {
  const pageDiv = event.target.closest?.(".page");
  if (!pageDiv) return null;
  const number = +pageDiv.dataset.pageNumber;
  const view = viewer.getPageView(number - 1);
  const origin = pageDiv.getBoundingClientRect();
  const [x, y] = view.viewport.convertToPdfPoint(event.clientX - origin.left, event.clientY - origin.top);
  return { div: pageDiv, number, view, x, y, cssX: event.clientX - origin.left, cssY: event.clientY - origin.top };
}

function annotationAt(hit) {
  const list = pageAnnotations.get(hit.number) ?? [];
  const within = (l, b, r, t) => hit.x >= l - 3 && hit.x <= r + 3 && hit.y >= b - 3 && hit.y <= t + 3;
  for (let i = list.length - 1; i >= 0; i--) {
    const quads = list[i].quads;
    if (quads?.length >= 8) {
      // Markup is its lines: the text beside a short first or last line stays selectable.
      for (let q = 0; q + 7 < quads.length; q += 8) {
        const [l, b, r, t] = boundsOf(quads.slice(q, q + 8));
        if (within(l, b, r, t)) return list[i];
      }
    } else {
      const [l, b, r, t] = list[i].rect;
      if (within(l, b, r, t)) return list[i];
    }
  }
  return null;
}

function select(annotation, pageNumber) {
  const previous = selected;
  selected = annotation ? { page: pageNumber, id: annotation.id } : null;
  if (previous) drawSelection(previous.page);
  if (selected) drawSelection(selected.page);
}

function drawSelection(pageNumber, source) {
  const view = source ?? viewer.getPageView(pageNumber - 1);
  if (!view?.div) return;
  view.div.querySelector(".annotation-selection")?.remove();
  if (selected?.page !== pageNumber) return;
  const annotation = (pageAnnotations.get(pageNumber) ?? []).find((a) => a.id === selected.id);
  if (!annotation) return;
  const [x1, y1] = view.viewport.convertToViewportPoint(annotation.rect[0], annotation.rect[1]);
  const [x2, y2] = view.viewport.convertToViewportPoint(annotation.rect[2], annotation.rect[3]);
  const box = document.createElement("div");
  box.className = "annotation-selection";
  box.style.cssText = `left:${Math.min(x1, x2) - 3}px;top:${Math.min(y1, y2) - 3}px;width:${Math.abs(x2 - x1) + 6}px;height:${Math.abs(y2 - y1) + 6}px`;
  view.div.appendChild(box);
}

let drag = null;
let stroke = null;

// MARK: Moving the page with the mouse
//
// Dragging from an empty part of the page moves it, as with a hand tool, while dragging from text still selects it. The
// middle button moves the page from anywhere.

let pan = null;

/** Text on this row at the point or close beside it: a drag from there is a selection (from a margin, say). */
function textBeside(x, y) {
  for (const dx of [0, -18, 18, -36, 36]) {
    const element = document.elementFromPoint(x + dx, y);
    if (element?.closest?.(".textLayer") && element.tagName === "SPAN") return true;
  }
  return false;
}

const canScroll = () => container.scrollHeight > container.clientHeight + 1 || container.scrollWidth > container.clientWidth + 1;
const overScrollbar = (e) => {
  const box = container.getBoundingClientRect();
  return e.clientX - box.left >= container.clientWidth || e.clientY - box.top >= container.clientHeight;
};

function startPan(e) {
  pan = { x: e.clientX, y: e.clientY, left: container.scrollLeft, top: container.scrollTop };
  container.setPointerCapture(e.pointerId);
  document.body.classList.add("panning");
}

function panFromEmptySpace(e) {
  if (tool !== "select" || !canScroll() || overScrollbar(e) || e.target.closest?.("a, .linkAnnotation") || textBeside(e.clientX, e.clientY)) return;
  clearSelection();
  startPan(e);
}

// Text selection and the browser's own middle-button scrolling start from the mouse event that follows.
container.addEventListener("mousedown", (e) => { if (pan) e.preventDefault(); }, true);

container.addEventListener("pointermove", (e) => {
  if (pan) {
    container.scrollLeft = pan.left - (e.clientX - pan.x);
    container.scrollTop = pan.top - (e.clientY - pan.y);
  } else if (!e.buttons) {
    // A hand over what a drag would move.
    const hand = tool === "select" && canScroll() && !overScrollbar(e) && !e.target.closest?.("a, .linkAnnotation") && !textBeside(e.clientX, e.clientY);
    document.body.classList.toggle("can-pan", hand);
  }
}, true);
container.addEventListener("pointerleave", () => document.body.classList.remove("can-pan"));

function endPan() {
  if (!pan) return false;
  pan = null;
  document.body.classList.remove("panning");
  return true;
}

// MARK: Following a selection to the edge of the view
//
// Past the edge the browser scrolls by itself; this does it already on the way there, and brings the selection along.

const edgeBand = 44;
let selecting = false;
let selectPoint = null;
let edgeFrame = 0;

function followSelection() {
  edgeFrame = 0;
  if (!selecting || !selectPoint || pan) return;
  const box = container.getBoundingClientRect();
  const { x, y } = selectPoint;
  const speed = (toEdge) => toEdge >= edgeBand ? 0 : 1 + 7 * (1 - Math.max(toEdge, 0) / edgeBand);
  const down = speed(box.top + container.clientHeight - y) - speed(y - box.top);
  const right = speed(box.left + container.clientWidth - x) - speed(x - box.left);
  if (down || right) {
    const before = [container.scrollLeft, container.scrollTop];
    container.scrollBy(right, down);
    const moved = container.scrollLeft !== before[0] || container.scrollTop !== before[1];
    const inside = x > box.left && x < box.left + container.clientWidth && y > box.top && y < box.top + container.clientHeight;
    // The pointer has not moved, so the browser will not extend the selection over what just came under it.
    if (moved && inside) {
      const at = document.caretPositionFromPoint?.(x, y);
      if (at?.offsetNode?.parentElement?.closest?.(".textLayer")) document.getSelection()?.extend(at.offsetNode, at.offset);
    }
  }
  edgeFrame = requestAnimationFrame(followSelection);
}

document.addEventListener("pointermove", (e) => {
  if (!selecting) return;
  selectPoint = { x: e.clientX, y: e.clientY };
  if (!edgeFrame) edgeFrame = requestAnimationFrame(followSelection);
}, true);
for (const type of ["pointerup", "pointercancel"]) {
  document.addEventListener(type, () => {
    selecting = false;
    cancelAnimationFrame(edgeFrame);
    edgeFrame = 0;
  }, true);
}

container.addEventListener("pointerdown", (e) => {
  if (e.button === 1 && e.pointerType === "mouse") {
    e.preventDefault();
    startPan(e);
    return;
  }
  if (e.button !== 0) return;
  const hit = pageAt(e);
  if (!hit) {
    if (tool === "select") select(null);
    panFromEmptySpace(e);
    return;
  }
  if (tool === "note" || tool === "textbox") {
    e.preventDefault();
    clearSelection();
    post({ type: tool, page: hit.number, x: hit.x, y: hit.y, clientX: e.clientX, clientY: e.clientY, color });
    return;
  }
  if (tool === "ink") {
    e.preventDefault();
    container.setPointerCapture(e.pointerId);
    const canvas = document.createElement("canvas");
    canvas.className = "ink-preview";
    canvas.width = hit.div.clientWidth * devicePixelRatio; canvas.height = hit.div.clientHeight * devicePixelRatio;
    hit.div.appendChild(canvas);
    stroke = { canvas, hit, points: [[hit.cssX, hit.cssY]] };
    return;
  }
  if (tool !== "select") { select(null); return; }
  const annotation = annotationAt(hit);
  if (!annotation) {
    select(null);
    panFromEmptySpace(e);
    if (!pan) selecting = true;
    return;
  }
  // An annotation under the pointer wins over text selection, as in the macOS reader.
  e.preventDefault();
  clearSelection();
  select(annotation, hit.number);
  if (isPending(annotation.id)) return; // Still being written: a moment later it can be edited.
  if (e.detail === 2 && (annotation.subtype === "Text" || annotation.subtype === "FreeText")) {
    post({ type: "annotationEdit", page: hit.number, id: annotation.id, subtype: annotation.subtype, contents: annotation.contents, clientX: e.clientX, clientY: e.clientY });
  } else if (movableTypes.has(annotation.subtype)) {
    container.setPointerCapture(e.pointerId);
    drag = { annotation, hit, startX: e.clientX, startY: e.clientY, moved: false, box: hit.div.querySelector(".annotation-selection") };
  }
}, true);

container.addEventListener("pointermove", (e) => {
  if (stroke) {
    const origin = stroke.hit.div.getBoundingClientRect();
    const p = [e.clientX - origin.left, e.clientY - origin.top];
    const ctx = stroke.canvas.getContext("2d");
    ctx.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
    ctx.strokeStyle = colors[color]; ctx.lineWidth = 2 * viewer.currentScale; ctx.lineCap = "round"; ctx.lineJoin = "round";
    ctx.beginPath(); ctx.moveTo(...stroke.points[stroke.points.length - 1]); ctx.lineTo(...p); ctx.stroke();
    stroke.points.push(p);
  } else if (drag) {
    const dx = e.clientX - drag.startX, dy = e.clientY - drag.startY;
    drag.moved = drag.moved || Math.abs(dx) + Math.abs(dy) > 2;
    if (drag.box) drag.box.style.transform = `translate(${dx}px, ${dy}px)`;
    const section = drag.hit.div.querySelector(`[data-annotation-id="${drag.annotation.id}"]`);
    if (section) section.style.transform = `translate(${dx}px, ${dy}px)`;
  }
}, true);

// What a note or a comment says, when the pointer rests on it (pdf.js's own popups would run off the page).
const tip = document.getElementById("tip");
let tipTimer = 0;
container.addEventListener("pointermove", (e) => {
  clearTimeout(tipTimer);
  tip.hidden = true;
  if (drag || stroke || tool !== "select" || e.buttons) return;
  const hit = pageAt(e);
  const annotation = hit && annotationAt(hit);
  if (!annotation?.contents) return;
  tipTimer = setTimeout(() => {
    tip.textContent = annotation.contents;
    tip.hidden = false;
    const x = Math.min(e.clientX + 12, innerWidth - tip.offsetWidth - 8), y = Math.min(e.clientY + 16, innerHeight - tip.offsetHeight - 8);
    tip.style.left = `${x}px`; tip.style.top = `${y}px`;
  }, 350);
});
container.addEventListener("pointerleave", () => { clearTimeout(tipTimer); tip.hidden = true; });

function finishPointer(e) {
  if (endPan()) return;
  if (stroke) {
    const { canvas, hit, points } = stroke;
    stroke = null;
    const flat = points.flatMap(([x, y]) => hit.view.viewport.convertToPdfPoint(x, y));
    canvas.remove();
    if (points.length > 1) {
      const temp = tempId();
      commit([{ page: hit.number, before: null, after: {
        id: temp, page: hit.number, subtype: "Ink", quads: null, strokes: [flat], rect: boundsOf(flat), colorKey: color, colorRgb: rgbOfKey(color),
        contents: "", quoted: "", author: annotationAuthor, live: true,
      } }]);
      post({ type: "ink", page: hit.number, color, strokes: [flat], temp });
    }
  } else if (drag) {
    const { annotation, hit, moved, startX, startY, box } = drag;
    drag = null;
    if (box) box.style.transform = "";
    const section = hit.div.querySelector(`[data-annotation-id="${annotation.id}"]`);
    if (section) section.style.transform = "";
    if (moved && !isPending(annotation.id)) {
      const [x1, y1] = hit.view.viewport.convertToPdfPoint(0, 0);
      const [x2, y2] = hit.view.viewport.convertToPdfPoint(e.clientX - startX, e.clientY - startY);
      const dx = x2 - x1, dy = y2 - y1;
      commit([{ page: hit.number, before: annotation, after: shifted(annotation, dx, dy) }]);
      post({ type: "annotationMoved", page: hit.number, id: annotation.id, dx, dy });
      const current = findEntry(hit.number, annotation.id);
      if (current) select(current, hit.number);
    }
  }
}
container.addEventListener("pointerup", finishPointer, true);
container.addEventListener("pointercancel", finishPointer, true);

// The menus are the app's own.
document.addEventListener("contextmenu", (e) => {
  e.preventDefault();
  if (e.target.closest?.("input, textarea")) return;
  const hit = e.target.closest?.("#viewerContainer") ? pageAt(e) : null;
  const message = { type: "contextMenu", clientX: e.clientX, clientY: e.clientY, kind: "none" };
  if (hit) {
    const annotation = annotationAt(hit);
    const info = selectionInfo();
    lastSelection = info;
    if (annotation && !isPending(annotation.id)) {
      select(annotation, hit.number);
      Object.assign(message, { kind: "annotation", page: hit.number, id: annotation.id, subtype: annotation.subtype, contents: annotation.contents, quoted: annotation.quoted, colorKey: annotation.colorKey });
    } else if (info?.text) {
      Object.assign(message, { kind: "selection", text: info.text, pages: info.pages, ...selectionGeometry() });
    } else {
      Object.assign(message, { kind: "page", page: hit.number });
    }
  }
  post(message);
});

// MARK: Zoom gestures

let pendingZoom = 1;
let zoomOrigin = null;
let zoomFrame = 0;
let zoomSaved = 0;

function zoomBy(factor, x, y) {
  if (!pdf) return;
  pendingZoom *= factor;
  zoomOrigin = [x, y];
  if (zoomFrame) return;
  zoomFrame = requestAnimationFrame(() => {
    zoomFrame = 0;
    const before = viewer.currentScale;
    // pdf.js rounds its scale to 1%: the tiny steps of a slow pinch would each be lost, so they add up here until they count.
    if (Math.round(before * pendingZoom * 100) === Math.round(before * 100)) return;
    autoFit = null;
    viewer.updateScale({ scaleFactor: pendingZoom, origin: zoomOrigin, drawingDelay: 150 });
    const reached = viewer.currentScale;
    pendingZoom = reached <= 0.1 || reached >= 25 ? 1 : before * pendingZoom / reached;
    clearTimeout(zoomSaved);
    zoomSaved = setTimeout(() => post({ type: "position", ...currentPosition() }), 200);
  });
}

// A touchpad pinch arrives as Ctrl + a fine-grained wheel, where a scale of s is a delta of 100·ln(s); a mouse wheel moves in big notches.
container.addEventListener("wheel", (e) => {
  if (!e.ctrlKey) return;
  e.preventDefault();
  const delta = e.deltaY * (e.deltaMode === WheelEvent.DOM_DELTA_LINE ? 40 : 1);
  zoomBy(Math.exp(-delta / (Math.abs(delta) >= 50 ? 800 : 100)), e.clientX, e.clientY);
}, { passive: false });
// Outside the pages (the sidebar) a pinch must not scale the whole interface.
document.addEventListener("wheel", (e) => { if (e.ctrlKey) e.preventDefault(); }, { passive: false });

// Two fingers on a touch screen.
let touchGap = 0;
const fingers = (e) => {
  const [a, b] = e.touches;
  return { gap: Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY), x: (a.clientX + b.clientX) / 2, y: (a.clientY + b.clientY) / 2 };
};
container.addEventListener("touchstart", (e) => {
  if (e.touches.length !== 2) return;
  e.preventDefault();
  touchGap = fingers(e).gap;
}, { passive: false });
container.addEventListener("touchmove", (e) => {
  if (e.touches.length !== 2 || !touchGap) return;
  e.preventDefault();
  const { gap, x, y } = fingers(e);
  if (gap > 0) zoomBy(gap / touchGap, x, y);
  touchGap = gap;
}, { passive: false });
container.addEventListener("touchend", (e) => { if (e.touches.length < 2) touchGap = 0; });

// MARK: Keyboard (keys pressed inside the web view would never reach the app's accelerators)

document.addEventListener("keydown", (e) => {
  const typing = e.target.closest?.("input, textarea");
  if (e.key === "Escape") {
    if (selected) select(null);
    else if (tool !== "select") post({ type: "toolReset" });
    else if (lastQuery && !typing) { /* the search stays until it is cleared in its box */ }
    e.preventDefault();
    return;
  }
  if (!typing && (e.key === "Delete" || e.key === "Backspace") && selected) {
    const entry = findEntry(selected.page, selected.id);
    if (entry && !isPending(entry.id)) {
      const page = selected.page;
      select(null);
      commit([{ page, before: entry, after: null }]);
      post({ type: "annotationDelete", page, id: entry.id });
    }
    e.preventDefault();
    return;
  }
  if (!typing && !e.ctrlKey && !e.altKey && !e.metaKey) {
    const step = { ArrowDown: 60, ArrowUp: -60, " ": container.clientHeight * 0.9, PageDown: container.clientHeight * 0.9, PageUp: -container.clientHeight * 0.9 }[e.key];
    if (step && !e.shiftKey) { container.scrollTop += step; e.preventDefault(); return; }
    if (e.key === "Home") { viewer.currentPageNumber = 1; e.preventDefault(); return; }
    if (e.key === "End" && pdf) { viewer.currentPageNumber = pdf.numPages; e.preventDefault(); return; }
    if (e.key === "ArrowLeft" && viewer.currentScaleValue?.startsWith?.("page")) { viewer.previousPage(); e.preventDefault(); return; }
    if (e.key === "ArrowRight" && viewer.currentScaleValue?.startsWith?.("page")) { viewer.nextPage(); e.preventDefault(); return; }
  }
  if (e.key === "F3" || e.key === "F11" || e.ctrlKey || e.altKey) {
    if (["Control", "Alt", "Shift", "Meta"].includes(e.key)) return;
    // Windows' own: closing the window, its system menu.
    if (e.altKey && !e.ctrlKey && (e.key === "F4" || e.key === " ")) return;
    // Clipboard and text editing keep working where the browser handles them.
    if (e.ctrlKey && !e.altKey && !e.shiftKey && ["c", "x", "v", "a"].includes(e.key.toLowerCase())) {
      if (e.key.toLowerCase() === "a" && !typing) { e.preventDefault(); selectAllOnPage(); }
      return;
    }
    e.preventDefault();
    post({ type: "key", key: e.key, code: e.code, ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey });
  }
});

function selectAllOnPage() {
  const layer = viewer.getPageView(viewer.currentPageNumber - 1)?.div?.querySelector(".textLayer");
  if (!layer) return;
  const range = document.createRange();
  range.selectNodeContents(layer);
  const selection = document.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

// MARK: Sidebar

async function buildThumbnails() {
  const pane = document.getElementById("thumbnails");
  pane.textContent = "";
  const doc = pdf;
  const first = await doc.getPage(1);
  if (doc !== pdf) return;
  const firstViewport = first.getViewport({ scale: 1 });
  // As wide as the sidebar allows: 150 in the reader's usual 220, more in a wider one (快速预览).
  const sidebarWidth = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--sidebar-width")) || 220;
  const width = Math.round(Math.max(120, Math.min(200, sidebarWidth - 70))), placeholderHeight = Math.round(width * firstViewport.height / firstViewport.width);
  const observer = new IntersectionObserver(async (entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting || entry.target.dataset.done) continue;
      entry.target.dataset.done = "1";
      const page = await doc.getPage(+entry.target.dataset.page);
      if (doc !== pdf) return;
      const scale = width / page.getViewport({ scale: 1 }).width;
      const viewport = page.getViewport({ scale });
      const canvas = entry.target;
      canvas.width = viewport.width * devicePixelRatio; canvas.height = viewport.height * devicePixelRatio;
      canvas.style.width = `${viewport.width}px`; canvas.style.height = `${viewport.height}px`;
      const drawn = page.getViewport({ scale: scale * devicePixelRatio });
      try {
        await page.render({ canvas, canvasContext: canvas.getContext("2d"), viewport: drawn, annotationMode: pdfjsLib.AnnotationMode.ENABLE_STORAGE }).promise;
        paintMarks(canvas.getContext("2d"), drawn, page.pageNumber);
      } catch { /* replaced meanwhile */ }
    }
  }, { root: pane, rootMargin: "400px" });
  for (let i = 1; i <= doc.numPages; i++) {
    const canvas = document.createElement("canvas");
    canvas.className = "thumb" + (i === viewer.currentPageNumber ? " current" : "");
    canvas.dataset.page = i;
    canvas.style.width = `${width}px`; canvas.style.height = `${placeholderHeight}px`;
    canvas.onclick = () => { remember(); viewer.currentPageNumber = i; };
    const number = document.createElement("div");
    number.className = "thumb-label";
    number.textContent = i;
    pane.append(canvas, number);
    observer.observe(canvas);
  }
}

async function buildOutline() {
  const pane = document.getElementById("outline");
  pane.textContent = "";
  const doc = pdf;
  const outline = await doc.getOutline();
  if (doc !== pdf) return;
  if (!outline?.length) { placeholder(pane, label("noOutline"), label("noOutlineDetail")); return; }
  const render = async (items, parent) => {
    for (const item of items) {
      const row = document.createElement("div");
      row.className = "outline-item";
      const chevron = document.createElement("span");
      chevron.className = "chevron";
      const title = document.createElement("span");
      title.className = "title";
      title.textContent = item.title;
      const page = document.createElement("span");
      page.className = "page";
      row.append(chevron, title, page);
      row.onclick = () => {
        if (item.dest) { remember(); linkService.goToDestination(item.dest); }
        else if (item.url) post({ type: "link", url: item.url });
      };
      parent.appendChild(row);
      try {
        const dest = typeof item.dest === "string" ? await doc.getDestination(item.dest) : item.dest;
        if (dest) page.textContent = (typeof dest[0] === "object" ? await doc.getPageIndex(dest[0]) : dest[0]) + 1;
      } catch { /* no page number */ }
      if (item.items?.length) {
        const children = document.createElement("div");
        children.className = "outline-children";
        parent.appendChild(children);
        chevron.textContent = "›";
        row.classList.add("open");
        chevron.onclick = (e) => {
          e.stopPropagation();
          children.hidden = !children.hidden;
          row.classList.toggle("open", !children.hidden);
        };
        await render(item.items, children);
      }
    }
  };
  await render(outline, pane);
}

function placeholder(pane, title, detail) {
  pane.textContent = "";
  const box = document.createElement("div");
  box.className = "placeholder";
  const heading = document.createElement("div");
  heading.textContent = title ?? "";
  box.appendChild(heading);
  if (detail) {
    const small = document.createElement("small");
    small.textContent = detail;
    box.appendChild(small);
  }
  pane.appendChild(box);
}

const rgb = (c) => (c ? `rgb(${c[0]},${c[1]},${c[2]})` : "#ffd60a");

/** The nearest of the six colours, for the menu's current mark. */
function nearestColorKey(c) {
  if (!c) return null;
  let best = null, bestDistance = 1e9;
  for (const [key, value] of Object.entries(colors)) {
    const [r, g, b] = value.match(/\d+/g).map(Number);
    const d = (r - c[0]) ** 2 + (g - c[1]) ** 2 + (b - c[2]) ** 2;
    if (d < bestDistance) { best = key; bestDistance = d; }
  }
  return bestDistance < 2500 ? best : null;
}

function quotedText(content, annotation) {
  const quads = annotation.quadPoints;
  if (!quads || !content) return "";
  // One rectangle per line of the markup; pdf.js gives them as flat x,y lists.
  const rects = [];
  const flat = Array.from(quads);
  for (let i = 0; i + 7 < flat.length; i += 8) {
    const xs = [flat[i], flat[i + 2], flat[i + 4], flat[i + 6]], ys = [flat[i + 1], flat[i + 3], flat[i + 5], flat[i + 7]];
    rects.push([Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)]);
  }
  let text = "";
  for (const [l, b, r, t] of rects) {
    for (const piece of content.items) {
      if (!piece.str) continue;
      const x = piece.transform[4], y = piece.transform[5];
      const midY = y + (piece.height || 0) / 2;
      if (midY < b || midY > t || x + (piece.width || 0) < l || x > r) continue;
      // Whole runs are kept simple: characters are cut in proportion to the overlap.
      const start = piece.width ? Math.max(0, Math.round((l - x) / piece.width * piece.str.length)) : 0;
      const end = piece.width ? Math.min(piece.str.length, Math.round((r - x) / piece.width * piece.str.length)) : piece.str.length;
      text += piece.str.slice(start, end);
    }
    text += " ";
  }
  return text.replace(/\s+/g, " ").trim();
}

/** Reads the file's annotations, a few pages at a time so the page stays responsive. */
async function refreshAnnotations() {
  const doc = pdf;
  for (let i = 1; i <= doc.numPages; i++) {
    if (i % 6 === 0) await new Promise((r) => setTimeout(r));
    const page = await doc.getPage(i);
    if (doc !== pdf) return;
    const annotations = (await page.getAnnotations()).filter((a) => editableTypes.has(a.subtype));
    if (doc !== pdf) return;
    const content = annotations.some((a) => a.quadPoints) ? await page.getTextContent() : null;
    if (doc !== pdf) return;
    const list = annotations.map((a) => {
      const entry = {
        id: a.id, page: i, subtype: a.subtype, rect: Array.from(a.rect), quads: a.quadPoints ? Array.from(a.quadPoints) : null,
        strokes: a.inkLists ? a.inkLists.map((l) => Array.from(l)) : null,
        colorRgb: a.color ? Array.from(a.color) : rgbOfKey("yellow"), colorKey: nearestColorKey(a.color),
        contents: a.contentsObj?.str ?? a.contents ?? "", quoted: quotedText(content, a), author: a.titleObj?.str ?? "", live: false,
      };
      originals.set(entry.id, entry);
      return entry;
    });
    // Anything added meanwhile stays.
    pageAnnotations.set(i, [...list, ...(pageAnnotations.get(i) ?? []).filter((x) => x.live)]);
  }
  renderAnnotationList();
  if (selected) drawSelection(selected.page);
  for (let i = 1; i <= doc.numPages; i++) hideSections(viewer.getPageView(i - 1));
}

function renderAnnotationList() {
  const pane = document.getElementById("annotations");
  const fragment = document.createDocumentFragment();
  let count = 0;
  for (const i of [...pageAnnotations.keys()].sort((a, b) => a - b)) {
    for (const a of pageAnnotations.get(i)) {
      count++;
      const card = document.createElement("div");
      card.className = "annotation-card";
      card.style.borderLeftColor = rgb(a.colorRgb);
      const main = document.createElement("div");
      main.textContent = a.quoted || a.contents || label(a.subtype, a.subtype);
      card.appendChild(main);
      if (a.quoted && a.contents) {
        const comment = document.createElement("div");
        comment.className = "comment";
        comment.textContent = a.contents;
        card.appendChild(comment);
      }
      const meta = document.createElement("div");
      meta.className = "meta";
      meta.textContent = label("page", "%d").replace("%d", i) + (a.author ? ` · ${a.author}` : "");
      card.appendChild(meta);
      card.onclick = () => {
        remember();
        viewer.scrollPageIntoView({ pageNumber: i, destArray: [null, { name: "XYZ" }, a.rect[0], a.rect[3] + 40, null] });
        select(a, i);
      };
      fragment.appendChild(card);
    }
  }
  const top = pane.scrollTop;
  pane.textContent = "";
  if (count) pane.appendChild(fragment);
  else placeholder(pane, label("noAnnotations"), label("noAnnotationsDetail"));
  pane.scrollTop = top;
}

function scrollTops() {
  return ["thumbnails", "outline", "annotations", "hits"].map((id) => [id, document.getElementById(id).scrollTop]);
}
function restoreScrollTops(values) {
  for (const [id, top] of values) document.getElementById(id).scrollTop = top;
}

function showSidebarTab(pane) {
  document.querySelectorAll("#sidebarTabs button, .pane").forEach((el) => el.classList.remove("active"));
  document.querySelector(`#sidebarTabs button[data-pane="${pane}"]`)?.classList.add("active");
  document.getElementById(pane)?.classList.add("active");
}

document.querySelectorAll("#sidebarTabs button").forEach((button) => {
  button.onclick = () => showSidebarTab(button.dataset.pane);
});

// The sidebar's width follows its divider.
const divider = document.getElementById("sidebarDivider");
divider.addEventListener("pointerdown", (e) => {
  divider.setPointerCapture(e.pointerId);
  const move = (m) => {
    const width = Math.max(150, Math.min(420, m.clientX));
    document.documentElement.style.setProperty("--sidebar-width", `${width}px`);
    post({ type: "sidebarWidth", width });
  };
  const up = () => { divider.removeEventListener("pointermove", move); divider.removeEventListener("pointerup", up); };
  divider.addEventListener("pointermove", move);
  divider.addEventListener("pointerup", up);
});

// MARK: Search

let lastQuery = "";
let hitIndex = -1;
let hits = [];

function find(query, previous = false, restore = false) {
  const changed = query !== lastQuery || restore;
  lastQuery = query;
  if (!query) {
    hits = [];
    eventBus.dispatch("findbarclose", { source: null });
    renderHits();
    post({ type: "findCount", current: 0, total: 0, query: "" });
    return;
  }
  eventBus.dispatch("find", {
    source: null, type: changed ? "" : "again", query, phraseSearch: true,
    caseSensitive: false, entireWord: false, highlightAll: true, findPrevious: previous, matchDiacritics: false,
  });
}

function collectHits() {
  hits = [];
  const matches = findController.pageMatches ?? [];
  // pdf.js's offsets count the page's original text while its stored text is normalized, so the snippets are found
  // afresh in the normalized text, in the same order.
  const pattern = new RegExp(lastQuery.trim().split(/\s+/).map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("\\s*"), "giu");
  matches.forEach((offsets, pageIndex) => {
    if (!offsets?.length) return;
    const content = findController._pageContents?.[pageIndex] ?? "";
    const found = [...content.matchAll(pattern)];
    offsets.forEach((_, matchIndex) => {
      const m = found[matchIndex];
      const offset = m?.index ?? 0;
      const length = m?.[0].length ?? 0;
      const start = Math.max(0, offset - 28);
      hits.push({
        pageIndex, matchIndex,
        before: m ? (start > 0 ? "…" : "") + content.slice(start, offset) : lastQuery,
        match: content.slice(offset, offset + length),
        after: content.slice(offset + length, offset + length + 48),
      });
    });
  });
}

function renderHits() {
  const pane = document.getElementById("hits");
  pane.textContent = "";
  if (!hits.length) {
    if (lastQuery) placeholder(pane, label("noMatches"));
    else placeholder(pane, label("searchHint"));
    return;
  }
  const fragment = document.createDocumentFragment();
  hits.slice(0, 2000).forEach((hit) => {
    const row = document.createElement("div");
    row.className = "hit";
    const text = document.createElement("div");
    text.append(hit.before);
    const mark = document.createElement("mark");
    mark.textContent = hit.match;
    text.append(mark, hit.after);
    const page = document.createElement("span");
    page.className = "page";
    page.textContent = hit.pageIndex + 1;
    row.append(text, page);
    row.onclick = () => showHit(hit);
    hit.row = row;
    fragment.appendChild(row);
  });
  pane.appendChild(fragment);
  markCurrentHit();
}

function markCurrentHit() {
  const current = findController.selected;
  document.querySelectorAll(".hit.current").forEach((r) => r.classList.remove("current"));
  const hit = hits.find((h) => h.pageIndex === current?.pageIdx && h.matchIndex === current?.matchIdx);
  if (hit?.row) { hit.row.classList.add("current"); hit.row.scrollIntoView({ block: "nearest" }); }
}

function showHit(hit) {
  remember();
  findController._selected.pageIdx = hit.pageIndex;
  findController._selected.matchIdx = hit.matchIndex;
  findController._offset.pageIdx = hit.pageIndex;
  findController._offset.matchIdx = hit.matchIndex;
  findController._offset.wrapped = false;
  findController._scrollMatches = true;
  viewer.currentPageNumber = hit.pageIndex + 1;
  eventBus.dispatch("updatetextlayermatches", { source: findController, pageIndex: -1 });
  markCurrentHit();
  post({ type: "findCount", current: hits.indexOf(hit) + 1, total: hits.length, query: lastQuery });
}

let hitsTimer = 0;
eventBus.on("updatefindmatchescount", ({ matchesCount }) => {
  post({ type: "findCount", current: matchesCount.current, total: matchesCount.total, query: lastQuery });
  clearTimeout(hitsTimer);
  hitsTimer = setTimeout(() => { collectHits(); renderHits(); }, 120);
});
eventBus.on("updatefindcontrolstate", ({ state, matchesCount }) => {
  post({ type: "findCount", current: matchesCount.current, total: matchesCount.total, query: lastQuery, state });
  markCurrentHit();
  clearTimeout(hitsTimer);
  hitsTimer = setTimeout(() => { collectHits(); renderHits(); }, 120);
});

// MARK: History (links, outline, thumbnails, annotations: 后退 / 前进)

const back = [], forward = [];
function remember() {
  if (!pdf) return;
  back.push(currentPosition());
  if (back.length > 100) back.shift();
  forward.length = 0;
}
function goTo(position) {
  viewer.scrollPageIntoView({ pageNumber: position.page, destArray: position.top != null ? [null, { name: "XYZ" }, position.left ?? 0, position.top, null] : undefined });
}
container.addEventListener("click", (e) => { if (e.target.closest?.(".linkAnnotation a")) remember(); }, true);

// MARK: Printing: every page as an image, handed to the browser's print dialog

async function print() {
  if (!pdf) return;
  const box = document.getElementById("printContainer");
  box.textContent = "";
  document.body.classList.add("preparing-print");
  try {
    for (let i = 1; i <= pdf.numPages; i++) {
      const page = await pdf.getPage(i);
      const viewport = page.getViewport({ scale: 150 / 72 });
      const canvas = document.createElement("canvas");
      canvas.width = viewport.width; canvas.height = viewport.height;
      await page.render({ canvas, canvasContext: canvas.getContext("2d"), viewport, intent: "print", annotationMode: pdfjsLib.AnnotationMode.ENABLE_STORAGE }).promise;
      paintMarks(canvas.getContext("2d"), viewport, i);
      const image = new Image();
      image.src = canvas.toDataURL("image/jpeg", 0.92);
      await image.decode();
      box.appendChild(image);
    }
    window.print();
  } finally {
    document.body.classList.remove("preparing-print");
    box.textContent = "";
  }
}

// MARK: Commands from the app

host.addEventListener("message", async (e) => {
  const m = e.data;
  switch (m.cmd) {
    case "open": labels = m.labels ?? labels; applyLabels(); await open(m); break;
    case "reload": await reload(m.url); break;
    case "resolved":
      // The file now holds these: they get their real names.
      for (const { temp, id } of m.map) {
        for (const changes of [...undoStack, ...redoStack]) {
          for (const c of changes) for (const entry of [c.before, c.after]) if (entry?.id === temp) entry.id = id;
        }
        for (const list of pageAnnotations.values()) for (const entry of list) if (entry.id === temp) entry.id = id;
        if (selected?.id === temp) selected.id = id;
      }
      break;
    case "undone": {
      const changes = undoStack.pop();
      if (changes) { applyChanges([...changes].reverse(), "before"); redoStack.push(changes); }
      break;
    }
    case "redone": {
      const changes = redoStack.pop();
      if (changes) { applyChanges(changes, "after"); undoStack.push(changes); }
      break;
    }
    case "addEntry":
      commit([{ page: m.page, before: null, after: {
        id: m.temp, page: m.page, subtype: m.subtype, rect: m.rect, quads: null, strokes: null, colorKey: m.color, colorRgb: rgbOfKey(m.color),
        contents: m.contents ?? "", quoted: "", author: annotationAuthor, live: true,
      } }]);
      break;
    case "modifyEntry": {
      const entry = findEntry(m.page, m.id);
      if (!entry) break;
      const change = {};
      if (m.color) { change.colorKey = m.color; change.colorRgb = rgbOfKey(m.color); }
      if (m.contents != null) change.contents = m.contents;
      const copy = changedCopy(entry, change);
      commit([{ page: m.page, before: entry, after: copy }]);
      if (selected?.id === m.id) select(copy, m.page);
      break;
    }
    case "removeEntry": {
      const entry = findEntry(m.page, m.id);
      if (!entry) break;
      if (selected?.id === m.id) select(null);
      commit([{ page: m.page, before: entry, after: null }]);
      break;
    }
    case "translateSelection": {
      // 划词翻译 by shortcut or menu: the selection as it is now, with where it is.
      const found = selectionInfo() ?? lastSelection;
      if (found?.text) post({ type: "translateSelection", text: found.text, page: found.pages?.[0]?.page ?? 1, ...selectionGeometry() });
      break;
    }
    case "markSelection": {
      if (!lastSelection) break;
      addMarkup(m.subtype, lastSelection);
      clearSelection();
      post({ type: "selection", text: "" });
      break;
    }
    case "insets":
      document.documentElement.style.setProperty("--top-inset", `${m.top}px`);
      document.documentElement.style.setProperty("--sidebar-top", `${m.sidebarTop}px`);
      if (m.sidebarWidth) document.documentElement.style.setProperty("--sidebar-width", `${m.sidebarWidth}px`);
      break;
    case "surface":
      document.documentElement.style.setProperty("--surface-alpha", m.alpha);
      break;
    case "password":
      if (m.value != null) pendingPassword?.update(m.value);
      else { pendingPassword?.task.destroy(); showMessage(label("encrypted")); }
      pendingPassword = null;
      break;
    case "tool": {
      const changed = m.tool !== tool;
      tool = m.tool; color = m.color ?? color;
      document.body.className = document.body.className.replace(/\btool-\S+/g, "").trim() + ` tool-${tool}`;
      if (tool !== "select") select(null);
      // Choosing a markup tool with text already selected marks that text right away, as in the macOS reader.
      const markup = { highlight: "Highlight", underline: "Underline", strike: "StrikeOut" }[tool];
      if (changed && markup) {
        const found = selectionInfo();
        if (found) { addMarkup(markup, found); clearSelection(); post({ type: "selection", text: "" }); }
      }
      break;
    }
    case "zoom":
      if (m.value === "in") { autoFit = null; viewer.increaseScale(); }
      else if (m.value === "out") { autoFit = null; viewer.decreaseScale(); }
      else {
        autoFit = m.value === "page-width" ? "page-width" : null;
        viewer.currentScaleValue = m.value;
      }
      post({ type: "position", ...currentPosition() });
      break;
    case "layout": viewer.spreadMode = m.value === "twoUp" ? 1 : 0; if (autoFit) viewer.currentScaleValue = autoFit; break;
    case "find": showSidebarIfNeeded(m.query); find(m.query ?? "", !!m.previous); break;
    case "goto":
      remember();
      if (m.top != null) viewer.scrollPageIntoView({ pageNumber: m.page, destArray: [null, { name: "XYZ" }, m.left ?? 0, m.top, null] });
      else viewer.currentPageNumber = m.page;
      break;
    case "step":
      if (m.value === "next") viewer.nextPage();
      else if (m.value === "previous") viewer.previousPage();
      else if (m.value === "first") viewer.currentPageNumber = 1;
      else if (m.value === "last" && pdf) viewer.currentPageNumber = pdf.numPages;
      break;
    case "history": {
      const from = m.value === "back" ? back : forward, to = m.value === "back" ? forward : back;
      const position = from.pop();
      if (position) { to.push(currentPosition()); goTo(position); }
      break;
    }
    case "theme": document.documentElement.dataset.theme = m.dark ? "dark" : "light"; break;
    case "shadows": document.body.classList.toggle("no-shadows", !m.on); break;
    case "sidebar":
      if (m.animate) holdFit();
      document.body.classList.toggle("no-sidebar", !m.visible);
      break;
    case "hold": holdFit(); break;
    case "sidebarTab": showSidebarTab(m.value); break;
    case "scrollTo": {
      const view = viewer.getPageView((m.page ?? 1) - 1);
      if (!view?.div) break;
      suppressScroll++;
      container.scrollTop = view.div.offsetTop + m.fraction * view.div.clientHeight;
      setTimeout(() => suppressScroll--, 60);
      break;
    }
    case "selectAnnotation": select(null); break;
    case "flushPosition": if (pdf) post({ type: "position", ...currentPosition() }); break;
    case "clearSelection": clearSelection(); break;
    case "print": await print(); break;
  }
});

function showSidebarIfNeeded(query) {
  if (query) showSidebarTab("hits");
}

function applyLabels() {
  for (const [pane, key] of [["thumbnails", "thumbnails"], ["outline", "outline"], ["annotations", "annotations"], ["hits", "hits"]]) {
    const button = document.querySelector(`#sidebarTabs button[data-pane="${pane}"]`);
    if (button && labels[key]) button.title = labels[key];
  }
  renderHits();
}

renderHits();
post({ type: "ready" });
