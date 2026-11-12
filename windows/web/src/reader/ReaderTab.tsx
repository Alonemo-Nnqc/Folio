import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { BookText, ChevronDown, ChevronUp, Columns2, Eraser, ScanText, SquarePen, Highlighter, MousePointer2, MoveHorizontal, NotebookPen, PanelRight, PenLine, Printer, Search, Strikethrough, StickyNote, Type, Underline, X, ZoomIn, ZoomOut } from "lucide-react";
import { CustomizeToolbarSheet, TOOLBAR_ITEMS, toolbarIds } from "./toolbar";
import { call, on } from "../rpc";
import { t } from "../i18n";
import { TranslateIcon } from "../ui/icons";
import { filesOf, getState, setSetting, setState, useStore, veilFor, type FileRec, type Item } from "../store";
import { translate } from "../commands";
import { openMenu, openMenuAt, sep, type MenuEntry } from "../ui/menu";
import { askText, openSheet, Sheet } from "../ui/sheet";
import { LEAD_ROOM, PanelToggle, SidebarButtons, Splitter, TabBar, TOGGLE_ROOM } from "../library/LibraryPage";
import { isEntering, useMoving, usePanelPhase } from "../ui/slide";
import { NoteEditor } from "../library/Inspector";
import { TranslationProgress } from "../library/ItemList";
import { useLayer, within } from "../ui/dismiss";
import { TranslateBadge, TranslatePopover, type Anchor, type Pinned } from "./SelectionTranslate";

/** "Alt+D": the modifiers and the key, as 设置 stores 划词翻译's shortcut. */
export function shortcutOf(k: { code: string; ctrl: boolean; alt: boolean; shift: boolean }) {
  const key = k.code.replace(/^Key|^Digit/, "");
  return [k.ctrl && "Ctrl", k.alt && "Alt", k.shift && "Shift", key].filter(Boolean).join("+");
}

/** One iframe with the pdf.js page. */
class Pane {
  ready = false;
  pending: unknown[] = [];
  session: string | null = null;
  fileId: string | null;
  preview: string | null = null;
  frame: HTMLIFrameElement | null = null;
  constructor(fileId: string | null) { this.fileId = fileId; }
  send(command: unknown) {
    if (this.ready && this.frame?.contentWindow) this.frame.contentWindow.postMessage(command, location.origin);
    else this.pending.push(command);
  }
  onReady() {
    this.ready = true;
    for (const c of this.pending) this.frame?.contentWindow?.postMessage(c, location.origin);
    this.pending = [];
  }
}

const TOOLS: { key: string; icon: any; tip: string; shortcut: string; group: number }[] = [
  { key: "select", icon: MousePointer2, tip: "选择", shortcut: "0", group: 0 }, { key: "highlight", icon: Highlighter, tip: "高亮", shortcut: "H", group: 0 },
  { key: "underline", icon: Underline, tip: "下划线", shortcut: "U", group: 0 }, { key: "strike", icon: Strikethrough, tip: "删除线", shortcut: "K", group: 0 },
  { key: "note", icon: StickyNote, tip: "便签", shortcut: "N", group: 1 }, { key: "textbox", icon: Type, tip: "文本框", shortcut: "T", group: 1 }, { key: "ink", icon: PenLine, tip: "手绘", shortcut: "D", group: 1 },
  { key: "eraser", icon: Eraser, tip: "橡皮擦", shortcut: "E", group: 1 },
];

/** The eraser's sizes (READER-30), as on the Mac: diameters 8, 16 and 32 pt; the ring is drawn in proportion. */
const ERASER_SIZES = [{ key: "small", title: "小", ring: 6 }, { key: "medium", title: "中", ring: 10 }, { key: "large", title: "大", ring: 15 }];

function EraserRing({ size }: { size: string }) {
  const ring = ERASER_SIZES.find((s) => s.key === size)?.ring ?? 10;
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
      <circle cx="9" cy="9" r={ring / 2} fill="currentColor" fillOpacity=".18" stroke="currentColor" strokeWidth="1.4" />
    </svg>
  );
}

let labels: Record<string, string> | null = null;
export async function readerLabels() { return (labels ??= await call("reader.labels")); }

export interface ReaderApi {
  handleKey(e: { key: string; code: string; ctrl: boolean; alt: boolean; shift: boolean }): boolean;
  toggleSidebar(): void;
  toggleNotes(): void;
  checkForChanges(): void;
  focusPage(): void;
  flush(): void;
}
export const readers = new Map<string, ReaderApi>();

function PasswordSheet({ wrong, close }: { wrong: boolean; close: (v?: string) => void }) {
  const [value, setValue] = useState("");
  return (
    <Sheet title={t("这个 PDF 需要密码")} width={380} onEscape={() => close()} actions={<><button className="btn" onClick={() => close()}>{t("取消")}</button><button className="btn primary" onClick={() => close(value)}>{t("好")}</button></>}>
      {wrong && <div style={{ color: "var(--red)", fontSize: 12, marginBottom: 6 }}>{t("密码不正确")}</div>}
      <input className="field" type="password" autoFocus placeholder={t("密码")} value={value} onChange={(e) => setValue(e.target.value)} onKeyDown={(e) => { e.stopPropagation(); if (e.key === "Enter") close(value); }} />
    </Sheet>
  );
}

export function ReaderTab({ tabKey, fileId, page, visible }: { tabKey: string; fileId: string; page?: number; visible: boolean }) {
  const file = useStore((s) => s.files.get(fileId)) as FileRec | undefined;
  const item = useStore((s) => (file ? s.items.get(file.itemId) : undefined)) as Item | undefined;
  const job = useStore((s) => (file ? s.jobs[file.itemId] : undefined));
  const captionWidth = useStore((s) => s.captionWidth);
  const colors = useStore((s) => s.statics.annotationColors);
  const settings = useStore((s) => s.settings);
  const dark = useStore((s) => s.dark);
  const fileRef = useRef(file);
  fileRef.current = file;

  const main = useMemo(() => new Pane(fileId), [fileId]);
  const [parallel, setParallel] = useState<Pane | null>(null);
  const parallelRef = useRef<Pane | null>(null);
  parallelRef.current = parallel;
  const following = useRef<string | null>(null);

  const [tool, setTool] = useState("select");
  const [color, setColor] = useState<string>(settings.highlightColor ?? "yellow");
  const toolRef = useRef(tool); toolRef.current = tool;
  const colorRef = useRef(color); colorRef.current = color;
  const [eraserSize, setEraserSize] = useState<string>(ERASER_SIZES.some((s) => s.key === settings.readerEraserSize) ? settings.readerEraserSize : "medium");
  const eraserSizeRef = useRef(eraserSize); eraserSizeRef.current = eraserSize;
  const [sidebarVisible, setSidebarVisible] = useState(true);
  const sidebarRef = useRef(true);
  const [sidebarWidth, setSidebarWidth] = useState<number>(settings.readerSidebarWidth ?? 220);
  const [notesVisible, setNotesVisible] = useState(false);
  const [notesWidth, setNotesWidth] = useState(300);
  const [pageLabel, setPageLabel] = useState("");
  const [query, setQuery] = useState("");
  const [searchOpen, setSearchOpen] = useState(false);
  const [findCount, setFindCount] = useState("");
  const searchRef = useRef<HTMLInputElement>(null);
  const noteBox = useRef<HTMLTextAreaElement | null>(null);
  const selection = useRef<any>(null);
  const pageCount = useRef(0);
  const [editor, setEditor] = useState<{ x: number; y: number; text: string; done: (text: string) => void } | null>(null);
  const [badge, setBadge] = useState<{ x: number; y: number; anchor: Anchor; text: string; page: number } | null>(null);
  const [translation, setTranslation] = useState<{ anchor: Anchor; text: string; page: number } | null>(null);
  // Dragged off its selection, the 划词翻译 window stays where it was put, and later selections are translated in it (SEL-21).
  const [pinned, setPinned] = useState<Pinned | null>(null);
  const pinnedRef = useRef(pinned);
  pinnedRef.current = pinned;
  const autoTranslate = useRef(0);
  const [opened, setOpened] = useState(false);

  // A tab left alone has no page until it is first shown.
  useEffect(() => { if (visible && !opened) setOpened(true); }, [visible, opened]);

  const send = (command: unknown) => main.send(command);
  const sendBoth = (command: unknown) => { main.send(command); parallelRef.current?.send(command); };

  const applyTool = (next: string, nextColor = colorRef.current) => {
    // A tool ends 编辑 PDF 文字: annotating and editing the text are not done at once.
    if (editingRef.current) setEditing(false);
    setTool(next);
    main.send({ cmd: "tool", tool: next, color: nextColor, eraserSize: eraserSizeRef.current });
  };
  // 编辑 PDF 文字 (EDIT-01).
  const [editing, setEditingState] = useState(false);
  const editingRef = useRef(false);
  const setEditing = (on: boolean) => {
    editingRef.current = on;
    setEditingState(on);
    if (on) { setTool("select"); main.send({ cmd: "tool", tool: "select", color: colorRef.current }); }
    main.send({ cmd: "editMode", on });
  };
  /** A size is chosen to erase with: the eraser becomes the tool, and the size is remembered. */
  const chooseEraserSize = (size: string) => {
    setEraserSize(size);
    eraserSizeRef.current = size;
    setSetting("readerEraserSize", size);
    applyTool("eraser");
  };
  const eraserSizeEntries = (): MenuEntry[] => ERASER_SIZES.map((s) => ({
    label: t(s.title), icon: <EraserRing size={s.key} />, checked: s.key === eraserSizeRef.current, action: () => chooseEraserSize(s.key),
  }));
  const zoom = (value: string) => sendBoth({ cmd: "zoom", value });
  const layout = (value: "single" | "twoUp") => { sendBoth({ cmd: "layout", value }); setSetting("readerLayout", value); };
  const step = (value: string) => send({ cmd: "step", value });
  const showSidebarTab = (value: string) => {
    if (!sidebarVisible) toggleSidebar();
    send({ cmd: "sidebarTab", value });
  };
  const toggleSidebar = () => { const v = !sidebarRef.current; sidebarRef.current = v; send({ cmd: "sidebar", visible: v, animate: true }); setSidebarVisible(v); };

  const goToPage = async () => {
    const text = await askText(t("前往页面"), pageCount.current > 0 ? t("页码（1–%lld）", pageCount.current) : t("页码"), "", t("前往"));
    const n = parseInt(text?.trim() ?? "", 10);
    if (n >= 1) send({ cmd: "goto", page: pageCount.current > 0 ? Math.min(n, pageCount.current) : n });
  };

  const focusSearch = () => { setSearchOpen(true); requestAnimationFrame(() => { searchRef.current?.focus(); searchRef.current?.select(); }); };
  const find = (previous: boolean) => { if (!query) focusSearch(); else send({ cmd: "find", query, previous }); };

  const addToNote = async (text: string, pageNumber: number) => {
    const f = fileRef.current;
    if (!f) return;
    setNotesVisible(true);
    const current = (await call<string>("note.get", { item: f.itemId })).trimEnd();
    const addition = t("%@\n> —— 第 %lld 页", "> " + text.replace(/\n/g, "\n> "), pageNumber);
    await call("note.set", { item: f.itemId, text: (current ? current + "\n\n" + addition : addition) + "\n" });
    call("toast.show", { message: t("已添加到笔记"), icon: "note" });
    requestAnimationFrame(() => noteBox.current?.focus());
  };
  const addSelectionToNote = () => {
    const sel = selection.current;
    if (!sel?.text) { call("toast.show", { message: t("先选中要摘录的文字"), icon: "info" }); return; }
    addToNote(sel.text, sel.pages?.[0]?.page ?? 1);
  };
  const copyAsCitation = (text: string, pageNumber: number) => {
    const it = fileRef.current && getState().items.get(fileRef.current.itemId);
    let reference = "";
    if (it?.kind === "regular") {
      const first = it.authors[0]?.family;
      const author = !first ? "" : it.authors.length > 1 ? `${first} et al.` : first;
      reference = [author, it.year].filter(Boolean).join(", ");
    }
    const citation = reference ? `${reference}, p. ${pageNumber}` : `p. ${pageNumber}`;
    call("shell.copy", { text: t("“%1$@”（%2$@）", text, citation) });
    call("toast.show", { message: t("已拷贝为引用"), icon: "cite" });
  };

  // MARK: 划词翻译

  /** A rectangle of the page in the iframe, in this window's coordinates. */
  const toWindow = (pane: Pane, r: Anchor): Anchor => {
    const f = pane.frame?.getBoundingClientRect();
    const dx = f?.left ?? 0, dy = f?.top ?? 0;
    return { left: r.left + dx, top: r.top + dy, right: r.right + dx, bottom: r.bottom + dy };
  };
  const openTranslation = (anchor: Anchor, text: string, page: number) => {
    clearTimeout(autoTranslate.current);
    setBadge(null);
    setTranslation({ anchor, text, page });
  };
  const addTranslationToNote = async (source: string, translated: string, pageNumber: number) => {
    const f = fileRef.current;
    if (!f) return;
    setNotesVisible(true);
    const current = (await call<string>("note.get", { item: f.itemId })).trimEnd();
    const addition = t("%@\n> —— 第 %lld 页", "> " + source.replace(/\n/g, "\n> "), pageNumber) + "\n\n" + translated;
    await call("note.set", { item: f.itemId, text: (current ? current + "\n\n" + addition : addition) + "\n" });
    call("toast.show", { message: t("已添加到笔记"), icon: "note" });
  };
  const onSelectionDone = (pane: Pane, m: any) => {
    const s = getState().settings;
    if (!s.selectionTranslationEnabled || toolRef.current !== "select" || !m.rect || !m.end) return;
    const anchor = toWindow(pane, m.rect);
    const end = toWindow(pane, { left: m.end.x, top: m.end.y, right: m.end.x, bottom: m.end.bottom });
    const page = m.pages?.[0]?.page ?? 1;
    if (s.selectionTranslationTrigger === "automatic") {
      // A double or triple click is still under way: wait for the selection to settle.
      clearTimeout(autoTranslate.current);
      autoTranslate.current = window.setTimeout(() => openTranslation(anchor, m.text, page), 220);
    } else if (s.selectionTranslationTrigger !== "shortcut") {
      setBadge({ x: end.right, y: (end.top + end.bottom) / 2 - 14, anchor, text: m.text, page });
    }
  };

  // MARK: Parallel reading

  const openPane = async (pane: Pane, target: FileRec | null, previewPath: string | null) => {
    const lbl = await readerLabels();
    const s = getState();
    const common = { labels: lbl, layout: s.settings.readerLayout === "twoUp" ? "twoUp" : "single", author: s.settings.annotationAuthor ?? "" };
    if (previewPath) {
      const r = await call("reader.openPreview", { path: previewPath });
      pane.session = r.session; pane.preview = previewPath;
      pane.send({ cmd: "open", url: r.url, zoom: "fitWidth", ...common });
    } else if (target) {
      const r = await call("reader.openFile", { file: target.id });
      pane.session = r.session; pane.fileId = target.id;
      const isMain = pane === main;
      const st = isMain ? r.state : null;
      pane.send({
        cmd: "open", url: r.url, page: (isMain ? page : undefined) ?? st?.page, scale: page === undefined ? st?.scale : undefined, top: page === undefined ? st?.top : undefined, left: page === undefined ? st?.left : undefined,
        zoom: s.settings.readerZoom === "actualSize" && isMain ? "actualSize" : "fitWidth", ...common,
      });
    }
  };

  const closeParallel = () => {
    following.current = null;
    const p = parallelRef.current;
    if (p?.session) call("reader.close", { session: p.session });
    setParallel(null);
  };

  const showParallel = (target: FileRec | null, previewPath: string | null) => {
    const p = parallelRef.current;
    if (p?.session) call("reader.close", { session: p.session });
    const pane = new Pane(target?.id ?? null);
    parallelRef.current = pane;
    setParallel(pane);
    openPane(pane, target, previewPath);
    pane.send({ cmd: "sidebar", visible: false });
    pane.send({ cmd: "insets", top: 86, sidebarTop: 0 });
    pane.send({ cmd: "theme", dark: getState().dark });
  };

  /** The newest translation, plain before side by side; from a translation, its original. */
  const translationFile = (): FileRec | undefined => {
    const f = fileRef.current;
    if (!f) return undefined;
    const s = getState();
    const files = filesOf(s, f.itemId);
    if (f.translationOf) return files.find((x) => x.id === f.translationOf);
    const list = files.filter((x) => x.translationOf === f.id).sort((a, b) => b.dateAdded - a.dateAdded);
    return list.find((x) => x.translationKind === "mono") ?? list[0];
  };

  const toggleParallel = () => {
    if (parallelRef.current) { closeParallel(); return; }
    const f = fileRef.current;
    if (!f) return;
    const running = getState().jobs[f.itemId];
    const translation = translationFile();
    if (!translation && running?.preview) {
      following.current = running.preview;
      showParallel(null, running.preview);
      return;
    }
    if (!translation) { call("toast.show", { message: t("这篇论文还没有译文。可以先\"翻译全文\""), icon: "translate" }); return; }
    showParallel(translation, null);
  };

  // 边翻边看: while this paper is being translated, 对照阅读 shows the pages done so far; when the translation is filed it switches to it.
  useEffect(() => {
    if (!following.current || !parallelRef.current) return;
    if (job?.preview) {
      if (job.preview !== following.current) { following.current = job.preview; showParallel(null, job.preview); following.current = job.preview; }
      else call("reader.previewUrl", { path: job.preview }).then((url) => parallelRef.current?.send({ cmd: "reload", url }));
    } else if (!job) {
      const finished = translationFile();
      closeParallel();
      if (finished) showParallel(finished, null);
    }
  }, [job?.fraction, job?.preview, !!job]);

  // MARK: Messages from the pages

  const applyResult = async (pane: Pane, result: any) => {
    if (!result) return;
    if (result.cmd === "reloadCurrent") {
      const url = pane.preview ? await call("reader.previewUrl", { path: pane.preview }) : await call("reader.url", { session: pane.session });
      pane.send({ cmd: "reload", url });
    } else pane.send(result);
  };

  const editAt = (pane: Pane, text: string, m: any, done: (text: string) => void) => {
    const rect = pane.frame?.getBoundingClientRect();
    setEditor({ x: (rect?.left ?? 0) + (m.clientX ?? 0), y: (rect?.top ?? 0) + (m.clientY ?? 0), text, done });
  };

  const setContents = (pane: Pane, m: any, text: string) => {
    pane.send({ cmd: "modifyEntry", page: m.page, id: m.id, contents: text });
    call("reader.modify", { session: pane.session, page: m.page, id: m.id, contents: text }).then((r) => applyResult(pane, r));
  };
  const setAnnotationColor = (pane: Pane, m: any, key: string) => {
    pane.send({ cmd: "modifyEntry", page: m.page, id: m.id, color: key });
    call("reader.modify", { session: pane.session, page: m.page, id: m.id, color: key }).then((r) => applyResult(pane, r));
  };
  const removeAnnotation = (pane: Pane, m: any, pageUpdated: boolean) => {
    if (!pageUpdated) pane.send({ cmd: "removeEntry", page: m.page, id: m.id });
    call("reader.remove", { session: pane.session, page: m.page, id: m.id }).then((r) => applyResult(pane, r));
  };

  const contextMenu = (pane: Pane, m: any) => {
    const rect = pane.frame?.getBoundingClientRect();
    const x = (rect?.left ?? 0) + m.clientX, y = (rect?.top ?? 0) + m.clientY;
    let entries: MenuEntry[] = [];
    if (m.kind === "eraser") {
      openMenu([{ kind: "title", label: t("橡皮擦大小") }, ...eraserSizeEntries()], x, y);
      return;
    }
    if (m.kind === "annotation") {
      const textual = m.subtype === "Text" || m.subtype === "FreeText";
      const contents = m.contents ?? "";
      const text = m.quoted || contents;
      entries = [
        { label: t("颜色"), submenu: colors.map((c) => ({ label: c.title, dot: c.hex, checked: c.key === m.colorKey, action: () => setAnnotationColor(pane, m, c.key) })) },
        sep,
        { label: textual ? t("编辑内容…") : contents ? t("编辑评论…") : t("添加评论…"), action: () => editAt(pane, contents, m, (v) => setContents(pane, m, v)) },
        ...(text ? [{ label: t("添加到笔记"), action: () => addToNote(text, m.page) } as MenuEntry, { label: t("拷贝文字"), action: () => call("shell.copy", { text }) } as MenuEntry] : []),
        sep,
        { label: t("删除批注"), action: () => removeAnnotation(pane, m, false) },
      ];
    } else if (m.kind === "selection") {
      const text: string = m.text;
      const pageNumber = m.pages?.[0]?.page ?? 1;
      const anchor = m.rect ? toWindow(pane, m.rect) : { left: x, top: y, right: x, bottom: y };
      entries = [
        { label: t("翻译"), action: () => openTranslation(anchor, text, pageNumber) },
        sep,
        { label: t("拷贝"), action: () => call("shell.copy", { text }) },
        { label: t("拷贝为引用"), action: () => copyAsCitation(text, pageNumber) },
        sep,
        ...([["Highlight", "高亮"], ["Underline", "下划线"], ["StrikeOut", "删除线"]] as const).map(([subtype, title]) => ({ label: t(title), action: () => pane.send({ cmd: "markSelection", subtype }) })),
        sep,
        { label: t("添加到笔记"), action: () => addToNote(text, pageNumber) },
      ];
    } else if (m.kind === "page") {
      entries = pageMenu();
    }
    if (entries.length) openMenu(entries, x, y);
  };

  const pageMenu = (): MenuEntry[] => [
    { label: t("放大"), key: "Ctrl+=", action: () => zoom("in") },
    { label: t("缩小"), key: "Ctrl+-", action: () => zoom("out") },
    { label: t("实际大小"), key: "Ctrl+0", action: () => zoom("page-actual") },
    { label: t("适合页宽"), key: "Ctrl+9", action: () => zoom("page-width") },
    sep,
    { label: t("单页连续"), checked: getState().settings.readerLayout !== "twoUp", action: () => layout("single") },
    { label: t("双页连续"), checked: getState().settings.readerLayout === "twoUp", action: () => layout("twoUp") },
  ];

  const viewMenu = (): MenuEntry[] => {
    const f = fileRef.current;
    return [
      ...pageMenu(),
      sep,
      { label: t("阅读边栏"), submenu: [
        { label: t("缩略图"), key: "Ctrl+Alt+2", action: () => showSidebarTab("thumbnails") }, { label: t("目录"), key: "Ctrl+Alt+3", action: () => showSidebarTab("outline") },
        { label: t("批注"), key: "Ctrl+Alt+4", action: () => showSidebarTab("annotations") }, { label: t("查找结果"), key: "Ctrl+Alt+5", action: () => showSidebarTab("hits") },
      ] },
      { label: t("前往"), submenu: [
        { label: t("上一页"), key: "Ctrl+Alt+↑", action: () => step("previous") }, { label: t("下一页"), key: "Ctrl+Alt+↓", action: () => step("next") },
        { label: t("第一页"), action: () => step("first") }, { label: t("最后一页"), action: () => step("last") }, sep,
        { label: t("后退"), key: "Alt+←", action: () => send({ cmd: "history", value: "back" }) }, { label: t("前进"), key: "Alt+→", action: () => send({ cmd: "history", value: "forward" }) }, sep,
        { label: t("前往页面…"), key: "Ctrl+Alt+G", action: goToPage },
      ] },
      sep,
      { label: t("添加到笔记"), key: "Ctrl+Alt+M", action: addSelectionToNote },
      { label: t("自定义工具栏…"), action: () => customizeToolbarRef.current() },
      { label: t("打印…"), key: "Ctrl+P", action: () => send({ cmd: "print" }) },
      ...(f ? [{ label: t("在资源管理器中显示"), action: () => call("file.reveal", { id: f.id }) } as MenuEntry] : []),
    ];
  };

  const translateMenu = (): MenuEntry[] => {
    const f = fileRef.current;
    if (!f) return [];
    const running = !!getState().jobs[f.itemId];
    return [
      ...(f.isPdf && !f.translationOf ? [{ label: t("翻译全文…"), disabled: running, action: () => translate([f.itemId], f) } as MenuEntry] : []),
      { label: t("对照阅读"), checked: !!parallelRef.current, action: toggleParallel },
      { label: t("取消翻译"), disabled: !running, action: () => call("translation.cancel", { item: f.itemId }) },
    ];
  };

  const handle = async (pane: Pane, m: any) => {
    switch (m.type) {
      case "ready":
        pane.onReady();
        break;
      case "error":
        if (m.fatal) call("toast.show", { message: m.name === "PasswordException" ? t("这个 PDF 需要密码") : t("无法打开这个 PDF"), icon: "warning" });
        break;
      case "password": {
        const value = await openSheet<string>((close) => <PasswordSheet wrong={!!m.wrong} close={close} />);
        pane.send({ cmd: "password", value: value ?? null });
        break;
      }
      case "loaded": if (pane === main) pageCount.current = m.pages; break;
      case "page": if (pane === main && m.pages > 0) setPageLabel(t("第 %lld / %lld 页", m.page, m.pages)); break;
      case "position":
        if (pane === main && pane.fileId) call("reader.savePosition", { file: pane.fileId, page: m.page, left: m.left ?? 0, top: m.top ?? 0, scale: m.scale ?? 1, autoScale: m.autoScale ?? true });
        break;
      case "scroll": (pane === main ? parallelRef.current : main)?.send({ cmd: "scrollTo", page: m.page, fraction: m.fraction }); break;
      case "selection":
        selection.current = m.text ? m : null;
        if (!m.text) { setBadge(null); clearTimeout(autoTranslate.current); }
        else if (m.done) onSelectionDone(pane, m);
        break;
      case "pointerDown":
        setBadge(null);
        if (!pinnedRef.current) setTranslation(null);
        clearTimeout(autoTranslate.current);
        // The service's connection is opened (and its token fetched) while the text is being chosen (SEL-20).
        call("translation.prewarm").catch(() => {});
        break;
      case "viewMoved": setBadge(null); break;
      case "translateSelection":
        if (m.rect) openTranslation(toWindow(pane, m.rect), m.text, m.page ?? 1);
        break;
      case "markup": call("reader.markup", { session: pane.session, subtype: m.subtype, color: m.color ?? colorRef.current, pages: m.pages }).then((r) => applyResult(pane, r)); break;
      case "needBlocks":
        call("reader.textBlocks", { session: pane.session, page: m.page })
          .then((blocks) => pane.send({ cmd: "textBlocks", page: m.page, blocks }))
          .catch((e) => {
            pane.send({ cmd: "textBlocks", page: m.page, blocks: [] });
            call("toast.show", { message: t("无法读取第 %lld 页的文字：%@", m.page, e?.message ?? String(e)), icon: "warning" });
          });
        break;
      case "editText":
        call("reader.editText", { session: pane.session, page: m.page, block: m.block, expected: m.expected, text: m.text })
          .then((r) => applyResult(pane, r))
          .catch((e) => { call("toast.show", { message: t("无法修改这段文字：%@", e.message ?? String(e)), icon: "warning" }); applyResult(pane, { cmd: "reloadCurrent" }); });
        break;
      case "editRefused": call("toast.show", { message: t("这里不能编辑：%@", m.reason), icon: "warning" }); break;
      case "leaveEditing": if (editingRef.current) setEditing(false); break;
      case "erase": call("reader.erase", { session: pane.session, page: m.page, ids: m.ids, paths: m.paths, radius: m.radius }).then((r) => applyResult(pane, r)); break;
      case "eraserStep": {
        const index = ERASER_SIZES.findIndex((s) => s.key === eraserSizeRef.current);
        const next = ERASER_SIZES[Math.min(Math.max(index + m.step, 0), ERASER_SIZES.length - 1)];
        if (next.key !== eraserSizeRef.current) chooseEraserSize(next.key);
        break;
      }
      case "ink": call("reader.ink", { session: pane.session, page: m.page, color: m.color ?? colorRef.current, strokes: m.strokes, temp: m.temp }).then((r) => applyResult(pane, r)); break;
      case "note":
      case "textbox": {
        const note = m.type === "note";
        applyTool("select");
        editAt(pane, "", m, (text) => {
          if (!text) return;
          const estimated = [...text].reduce((sum, c) => sum + (c.charCodeAt(0) > 0x2e80 ? 12 : 6.5), 0);
          const lines = Math.max(1, Math.ceil(estimated / 208) + (text.match(/\n/g)?.length ?? 0));
          const rect = note ? [m.x - 10, m.y - 10, m.x + 10, m.y + 10] : [m.x, m.y - Math.max(24, lines * 15 + 8), m.x + 220, m.y];
          const subtype = note ? "Text" : "FreeText";
          const temp = `pending-${crypto.randomUUID().replace(/-/g, "")}`;
          const entryColor = m.color ?? colorRef.current;
          pane.send({ cmd: "addEntry", temp, page: m.page, subtype, rect, color: entryColor, contents: text });
          call("reader.addText", { session: pane.session, page: m.page, subtype, rect, color: entryColor, contents: text, temp }).then((r) => applyResult(pane, r));
        });
        break;
      }
      case "annotationEdit": editAt(pane, m.contents ?? "", m, (text) => setContents(pane, m, text)); break;
      case "annotationDelete": removeAnnotation(pane, m, true); break;
      case "annotationMoved": call("reader.modify", { session: pane.session, page: m.page, id: m.id, dx: m.dx, dy: m.dy }).then((r) => applyResult(pane, r)); break;
      case "contextMenu": contextMenu(pane, m); break;
      case "findCount": if (pane === main) setFindCount(m.total > 0 ? `${m.current}/${m.total}` : ""); break;
      case "toolReset": applyTool("select"); break;
      case "key": window.dispatchEvent(new CustomEvent("folio-key", { detail: { key: m.key, code: m.code, ctrl: m.ctrl, alt: m.alt, shift: m.shift } })); break;
      case "link": call("shell.open", { target: m.url }); break;
      case "sidebarWidth":
        if (pane === main) { setSidebarWidth(m.width); clearTimeout(saveWidth.current); saveWidth.current = window.setTimeout(() => setSetting("readerSidebarWidth", m.width), 300); }
        break;
    }
  };
  const saveWidth = useRef(0);
  const handleRef = useRef(handle);
  handleRef.current = handle;

  useEffect(() => {
    const listener = (e: MessageEvent) => {
      const m = e.data?.folioReader;
      if (!m) return;
      if (e.source === main.frame?.contentWindow) handleRef.current(main, m);
      else if (parallelRef.current && e.source === parallelRef.current.frame?.contentWindow) handleRef.current(parallelRef.current, m);
    };
    window.addEventListener("message", listener);
    return () => window.removeEventListener("message", listener);
  }, [main]);

  // First load.
  useEffect(() => {
    if (!opened || !file) return;
    main.send({ cmd: "theme", dark: getState().dark });
    main.send({ cmd: "insets", top: 86, sidebarTop: 52, sidebarWidth });
    main.send({ cmd: "shadows", on: getState().settings.readerPageShadows });
    main.send({ cmd: "tool", tool: "select", color });
    openPane(main, file, null);
    return () => {
      main.send({ cmd: "flushPosition" });
      if (main.session) call("reader.close", { session: main.session });
      if (parallelRef.current?.session) call("reader.close", { session: parallelRef.current.session });
    };
  }, [opened]);

  useEffect(() => { main.send({ cmd: "theme", dark }); parallelRef.current?.send({ cmd: "theme", dark }); }, [dark]);
  useEffect(() => { main.send({ cmd: "shadows", on: settings.readerPageShadows }); }, [settings.readerPageShadows]);
  // 背景透明度: the grey around the pages and the reader's sidebar let the desktop through.
  const surface = veilFor(getState().statics.translucency ? settings.backgroundTranslucency ?? 0 : 0);
  useEffect(() => { main.send({ cmd: "surface", alpha: surface }); parallelRef.current?.send({ cmd: "surface", alpha: surface }); }, [surface, parallel]);
  useEffect(() => { if (page !== undefined && main.session) main.send({ cmd: "goto", page }); }, [page]);

  const checkForChanges = async () => {
    for (const pane of [main, parallelRef.current]) {
      if (!pane?.session || pane.preview) continue;
      if (await call<boolean>("reader.changedOnDisk", { session: pane.session })) pane.send({ cmd: "reload", url: await call("reader.url", { session: pane.session }) });
    }
  };

  useEffect(() => { if (visible) { checkForChanges(); requestAnimationFrame(() => main.frame?.contentWindow?.focus()); } }, [visible]);

  // 扫描件 (OCR-01): a banner offers to recognise the text; the file is reloaded once that is done.
  const [isScan, setIsScan] = useState(false);
  const [scanDismissed, setScanDismissed] = useState(false);
  const ocr = useStore((s) => (file ? s.ocr[file.id] : undefined));
  useEffect(() => {
    if (!opened || !file?.isPdf) return;
    let live = true;
    call<boolean>("ocr.isScanned", { file: file.id }).then((v) => { if (live) setIsScan(!!v); }).catch(() => {});
    return () => { live = false; };
  }, [opened, file?.id, file?.sha]);
  useEffect(() => on("ocr.recognized", (id: string) => {
    if (id !== file?.id) return;
    setIsScan(false);
    checkForChanges();
  }), [file?.id]);
  useEffect(() => on("window.active", (active) => { if (active && visible) checkForChanges(); }), [visible]);

  // Keys of the reader. True when the key was used.
  const handleKey: ReaderApi["handleKey"] = ({ code, ctrl, alt, shift }) => {
    const st = getState().settings;
    if (st.selectionTranslationEnabled && shortcutOf({ code, ctrl, alt, shift }) === (st.selectionTranslationShortcut || "Alt+D")) {
      if (translation) setTranslation(null); else main.send({ cmd: "translateSelection" });
      return true;
    }
    if (code === "F3") { find(shift); return true; }
    if (ctrl && alt) {
      const digit = code.startsWith("Digit") ? Number(code.slice(5)) : -1;
      if (digit >= 2 && digit <= 5) { showSidebarTab(["thumbnails", "outline", "annotations", "hits"][digit - 2]); return true; }
      if (code === "ArrowUp") { step("previous"); return true; }
      if (code === "ArrowDown") { step("next"); return true; }
      if (code === "KeyG") { goToPage(); return true; }
      if (code === "KeyM") { addSelectionToNote(); return true; }
      const letter = digit === 0 ? "0" : code.startsWith("Key") ? code.slice(3) : "";
      const hit = TOOLS.find((x) => x.shortcut === letter);
      if (hit) { applyTool(hit.key); return true; }
      return false;
    }
    if (alt && code === "ArrowLeft") { send({ cmd: "history", value: "back" }); return true; }
    if (alt && code === "ArrowRight") { send({ cmd: "history", value: "forward" }); return true; }
    if (!ctrl) return false;
    switch (code) {
      case "Equal": case "NumpadAdd": zoom("in"); return true;
      case "Minus": case "NumpadSubtract": zoom("out"); return true;
      case "Digit0": case "Numpad0": zoom("page-actual"); return true;
      case "Digit9": zoom("page-width"); return true;
      case "KeyZ": if (shift) redo(); else undo(); return true;
      case "KeyY": redo(); return true;
      case "KeyP": send({ cmd: "print" }); return true;
      case "KeyF": focusSearch(); return true;
      case "KeyG": find(shift); return true;
      case "BracketLeft": send({ cmd: "history", value: "back" }); return true;
      case "BracketRight": send({ cmd: "history", value: "forward" }); return true;
    }
    return false;

  };
  const undo = () => { if (main.session) call("reader.undo", { session: main.session }).then((r) => applyResult(main, r)); };
  const redo = () => { if (main.session) call("reader.redo", { session: main.session }).then((r) => applyResult(main, r)); };

  const toggleNotes = () => setNotesVisible((v) => !v);
  useEffect(() => {
    readers.set(tabKey, { handleKey: (e) => handleKeyRef.current(e), toggleSidebar: () => toggleSidebarRef.current(), toggleNotes, checkForChanges: () => checkRef.current(), focusPage: () => main.frame?.contentWindow?.focus(), flush: () => main.send({ cmd: "flushPosition" }) });
    return () => { readers.delete(tabKey); };
  }, [tabKey]);
  const customizeToolbarRef = useRef(() => {});
  const handleKeyRef = useRef(handleKey); handleKeyRef.current = handleKey;
  const toggleSidebarRef = useRef(toggleSidebar); toggleSidebarRef.current = toggleSidebar;
  const checkRef = useRef(checkForChanges); checkRef.current = checkForChanges;

  customizeToolbarRef.current = () => openSheet((close) => <CustomizeToolbarSheet current={toolbarIds(getState().settings.readerToolbar)} close={close} />);

  /** One of the toolbar's buttons other than the tools. */
  const toolbarButton = (id: string) => {
    const icon = (Icon: any, size = 17) => <Icon size={size} strokeWidth={1.7} />;
    const plain = (title: string, Icon: any, action: () => void, extra?: string) => <button className={`glass-button${extra ?? ""}`} title={title} onClick={action}>{icon(Icon)}</button>;
    switch (id) {
      case "view": return <button className="glass-button" style={{ width: 52 }} title={t("显示")} onClick={(e) => openMenuAt(e.currentTarget, viewMenu())}><ChevronDown size={14} /></button>;
      // While erasing, the colour button beside the tools picks the eraser's size instead.
      case "color": return tool === "eraser"
        ? <button className="glass-button" title={t("橡皮擦大小（[ 与 ] 调整）")} onClick={(e) => openMenuAt(e.currentTarget, eraserSizeEntries())}><EraserRing size={eraserSize} /></button>
        : <button className="glass-button" title={t("批注颜色")} onClick={(e) => openMenuAt(e.currentTarget, colors.map((c) => ({
        label: c.title, dot: c.hex, checked: c.key === color,
        action: () => { setColor(c.key); setSetting("highlightColor", c.key); main.send({ cmd: "tool", tool: toolRef.current, color: c.key }); },
      })))}><span className="color-dot" style={{ background: colorHex }} /></button>;
      case "editText": return plain(t("编辑 PDF 中的文字"), SquarePen, () => setEditing(!editingRef.current), editing ? " on" : "");
      case "translate": return <button className="glass-button" title={t("保留排版翻译全文、对照阅读")} onClick={(e) => openMenuAt(e.currentTarget, translateMenu())}><BookText size={17} strokeWidth={1.7} /></button>;
      case "selectionTranslate": return plain(t("翻译所选文字"), TranslateIcon, () => main.send({ cmd: "translateSelection" }));
      case "search": return searchOpen || query ? (
        <label className="search-field" style={{ flex: "0 1 200px", minWidth: 130 }}>
          <Search size={14} />
          <input ref={searchRef} value={query} placeholder={t("在文档中查找")} spellCheck={false}
            onChange={(e) => { setQuery(e.target.value); if (!e.target.value) send({ cmd: "find", query: "" }); }}
            onBlur={() => { if (!query) setSearchOpen(false); }}
            onKeyDown={(e) => {
              e.stopPropagation();
              if (e.key === "Enter") find(e.shiftKey);
              else if (e.key === "Escape") { setQuery(""); send({ cmd: "find", query: "" }); setSearchOpen(false); main.frame?.contentWindow?.focus(); }
            }} />
          {findCount && <span className="tabular" style={{ fontSize: 11, flex: "none" }}>{findCount}</span>}
          {query && <button className="clear-button" onMouseDown={(e) => { e.preventDefault(); setQuery(""); send({ cmd: "find", query: "" }); }}><X size={10} strokeWidth={3} /></button>}
        </label>
      ) : plain(t("在文档中查找"), Search, focusSearch);
      case "zoomOut": return plain(t("缩小"), ZoomOut, () => zoom("out"));
      case "zoomIn": return plain(t("放大"), ZoomIn, () => zoom("in"));
      case "fitWidth": return plain(t("适合页宽"), MoveHorizontal, () => zoom("page-width"));
      case "previousPage": return plain(t("上一页"), ChevronUp, () => step("previous"));
      case "nextPage": return plain(t("下一页"), ChevronDown, () => step("next"));
      case "parallel": return plain(t("对照阅读"), Columns2, toggleParallel, parallel ? " on" : "");
      case "addNote": return plain(t("添加到笔记"), NotebookPen, addSelectionToNote);
      case "notes": return plain(t("笔记"), PanelRight, toggleNotes, notesVisible ? " on" : "");
      case "print": return plain(t("打印…"), Printer, () => send({ cmd: "print" }));
    }
    return null;
  };

  if (!file) return null;
  const title = item?.kind === "regular" ? item.title : file.fileName;
  const sidebarPhase = usePanelPhase(sidebarVisible);
  const notesPhase = usePanelPhase(notesVisible);
  // The pages keep to their size while the panes around them move, and settle at the end.
  const moving = useMoving([sidebarVisible, notesVisible], () => sendBoth({ cmd: "hold" }));
  useLayoutEffect(() => { setState({ readerNotes: { ...getState().readerNotes, [tabKey]: notesVisible } }); }, [notesVisible]);

  const left = sidebarVisible ? sidebarWidth : 0;
  const right = notesVisible ? notesWidth : 0;
  const colorHex = colors.find((c) => c.key === color)?.hex ?? "#FFD933";
  const area = `calc(100% - ${right}px)`;
  const leftPaneWidth = parallel ? `calc(${left}px + (100% - ${left + right}px) / 2)` : area;
  const rightPaneWidth = `calc((100% - ${left + right}px) / 2)`;
  const running = !!job;

  return (
    <div className={`reader${moving ? " moving" : ""}`} style={{ display: visible ? "block" : "none" }}>
      {opened && <iframe ref={(el) => { main.frame = el; }} title="reader" src="reader/viewer.html" style={{ left: 0, width: leftPaneWidth }} />}
      {parallel && <iframe key={parallel.preview ?? parallel.fileId ?? "preview"} ref={(el) => { parallel.frame = el; }} title="parallel" src="reader/viewer.html" style={{ left: `calc(${left}px + (100% - ${left + right}px) / 2)`, width: rightPaneWidth, borderLeft: "1px solid var(--separator)" }} />}

      {sidebarPhase !== "closed" && (
        <div className={`reader-left-top drag${isEntering(sidebarPhase) ? " entering" : ""}`} style={{ width: sidebarWidth, transform: sidebarPhase === "closing" ? "translateX(-100%)" : undefined }} />
      )}

      <div className="reader-top" style={{ left, right }}>
        <div className="reader-head drag" onContextMenu={(e) => { e.preventDefault(); openMenu([{ label: t("自定义工具栏…"), action: () => customizeToolbarRef.current() }], e.clientX, e.clientY); }} style={{ paddingLeft: sidebarVisible ? undefined : LEAD_ROOM + 2, paddingRight: notesVisible ? undefined : captionWidth + TOGGLE_ROOM + 2 }}>
          <div className="reader-title">
            <div className="name ellipsis" title={title}>{title}</div>
            <div className="page tabular ellipsis">{pageLabel}</div>
          </div>
          {toolbarIds(settings.readerToolbar).reduce<{ id: string; tools: string[] }[]>((groups, id) => {
            const tool = TOOLBAR_ITEMS.find((x) => x.id === id)?.tool;
            const last = groups[groups.length - 1];
            if (tool && last?.tools.length) last.tools.push(id); else groups.push({ id, tools: tool ? [id] : [] });
            return groups;
          }, []).map((g) => g.tools.length ? (
            <div key={g.id} className="glass-group">
              {g.tools.map((id, i) => {
                const x = TOOLS.find((tt) => tt.key === id)!;
                const Icon = x.icon;
                const previous = i > 0 ? TOOLS.find((tt) => tt.key === g.tools[i - 1]) : undefined;
                return (
                  <span key={id} style={{ display: "contents" }}>
                    {previous && previous.group !== x.group && <span className="sep" />}
                    <button className={tool === x.key ? "on" : ""} title={`${t(x.tip)}（Ctrl+Alt+${x.shortcut}）`} onClick={() => applyTool(x.key)}><Icon size={16} strokeWidth={1.8} /></button>
                  </span>
                );
              })}
            </div>
          ) : <span key={g.id} style={{ display: "contents" }}>{toolbarButton(g.id)}</span>)}
        </div>
        <TabBar />
      </div>

      {notesPhase !== "closed" && (
        <div className={`reader-notes${isEntering(notesPhase) ? " entering" : ""}`} style={{ width: notesWidth, transform: notesPhase === "closing" ? "translateX(100%)" : undefined }}>
          <div className="titlebar-row drag" />
          <NoteEditor itemId={file.itemId} title={item?.title ?? file.fileName} inputRef={noteBox} />
          <Splitter side="right" width={notesWidth} min={220} max={560} onLive={setNotesWidth} onDone={setNotesWidth} />
        </div>
      )}

      <SidebarButtons visible={sidebarVisible} width={sidebarWidth} onToggle={toggleSidebar} />
      <PanelToggle onClick={toggleNotes} />

      {running && <div className="hud"><TranslationProgress itemId={file.itemId} /></div>}
      {editing && (
        <div className="scan-banner" role="status" style={{ left: `calc(${left}px + (100% - ${left + right}px) / 2)` }}>
          <SquarePen size={15} strokeWidth={1.8} />
          <span>{t("正在编辑 PDF 文字：点击文字块即可修改，Ctrl+Enter 完成一段")}</span>
          <button className="btn small primary" onClick={() => setEditing(false)}>{t("完成")}</button>
        </div>
      )}
      {!editing && (ocr || (isScan && !scanDismissed)) && (
        <div className="scan-banner" role="status" style={{ left: `calc(${left}px + (100% - ${left + right}px) / 2)` }}>
          <ScanText size={15} strokeWidth={1.8} />
          {ocr ? (
            <>
              <span className="tabular">{ocr.total > 0 ? t("正在识别文字（%lld/%lld 页）", ocr.done, ocr.total) : t("正在识别文字…")}</span>
              <span className="scan-bar"><i style={{ width: `${ocr.total ? (ocr.done / ocr.total) * 100 : 4}%` }} /></span>
              <button className="btn small" onClick={() => call("ocr.cancel", { file: file.id })}>{t("取消")}</button>
            </>
          ) : (
            <>
              <span>{t("这是扫描件，识别文字后即可选中、搜索与翻译")}</span>
              <button className="btn small primary" onClick={() => call("ocr.recognize", { files: [file.id] })}>{t("识别文字")}</button>
              <button className="scan-close" title={t("关闭")} onClick={() => setScanDismissed(true)}><X size={11} strokeWidth={2.6} /></button>
            </>
          )}
        </div>
      )}

      {badge && visible && <TranslateBadge x={badge.x} y={badge.y} onClick={() => openTranslation(badge.anchor, badge.text, badge.page)} />}
      {translation && visible && <TranslatePopover anchor={translation.anchor} text={translation.text} close={() => { setTranslation(null); setPinned(null); main.frame?.contentWindow?.focus(); }}
        pinned={pinned} onPin={setPinned} addToNote={(source, translated) => addTranslationToNote(source, translated, translation.page)} />}
      {editor && <NotePopover {...editor} close={() => { setEditor(null); main.frame?.contentWindow?.focus(); }} />}
    </div>
  );
}

function NotePopover({ x, y, text, done, close }: { x: number; y: number; text: string; done: (text: string) => void; close: () => void }) {
  const [value, setValue] = useState(text);
  const ref = useRef<HTMLDivElement>(null);
  const latest = useRef(value);
  latest.current = value;
  const finished = useRef(false);
  const finish = () => {
    if (finished.current) return;
    finished.current = true;
    const clean = latest.current.replace(/\r\n/g, "\n").trim();
    if (clean !== text.trim()) done(clean);
    close();
  };
  // Finished by a press anywhere else (the pages included), Esc, or the window going to the background (WIN-30).
  useLayer(true, { contains: (target) => within(ref.current, target), onPress: finish, onEscape: finish, onDeactivate: finish });
  const left = Math.min(x, innerWidth - 316), top = Math.min(y + 6, innerHeight - 170);
  return (
    <div ref={ref} className="note-pop" style={{ left, top }}>
      <textarea className="field" autoFocus value={value} spellCheck={false} onChange={(e) => setValue(e.target.value)} onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Escape" || (e.key === "Enter" && e.ctrlKey)) { e.preventDefault(); finish(); }
      }} />
    </div>
  );
}
