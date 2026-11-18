import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { ChevronDown, ChevronUp, Columns2, Eraser, ScanText, SquarePen, Highlighter, MousePointer2, MoveHorizontal, NotebookPen, PanelRight, Pen, Printer, Search, Strikethrough, Type, Underline, X, ZoomIn, ZoomOut } from "lucide-react";
import { CustomizeToolbarSheet, TOOLBAR_ITEMS, toolbarIds } from "./toolbar";
import { call, on } from "../rpc";
import { t } from "../i18n";
import { FullTextTranslateIcon, NoteToolIcon, TranslateIcon } from "../ui/icons";
import { filesOf, getState, setSetting, setState, useStore, veilFor, type FileRec, type Item } from "../store";
import { translate } from "../commands";
import { openMenu, openMenuAt, sep, type MenuEntry } from "../ui/menu";
import { askText, openSheet, Sheet } from "../ui/sheet";
import { LEAD_ROOM, PanelToggle, SidebarButtons, Splitter, TabBar, TOGGLE_ROOM } from "../library/LibraryPage";
import { isEntering, useMoving, usePanelPhase } from "../ui/slide";
import { NoteEditor } from "../library/Inspector";
import { TranslationProgress } from "../library/ItemList";
import { TranslateBadge, TranslatePopover, type Anchor, type Pinned } from "./SelectionTranslate";
import { NoteCard, pickColor, TextBoxField, type CardColor } from "./AnnotationEditors";

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
  { key: "note", icon: NoteToolIcon, tip: "便签", shortcut: "N", group: 1 }, { key: "textbox", icon: Type, tip: "文本框", shortcut: "T", group: 1 }, { key: "ink", icon: Pen, tip: "手绘", shortcut: "D", group: 1 },
  { key: "eraser", icon: Eraser, tip: "橡皮擦", shortcut: "E", group: 1 },
];

/** Each tool's colours, its usual one first (as on the Mac): no black highlighter, no yellow pen. */
const PALETTES: Record<string, string[]> = {
  highlight: ["yellow", "green", "blue", "pink", "purple", "orange"], note: ["yellow", "green", "blue", "pink", "purple", "orange"],
  underline: ["red", "blue", "green", "purple", "orange", "black"], strike: ["black", "red", "blue", "green", "purple", "orange"],
  textbox: ["black", "red", "blue", "green", "purple", "orange"], ink: ["black", "red", "blue", "green", "purple", "orange"],
};
/** Tools whose colour shows on their toolbar button (as on the Mac): the ones picked up and put down all the time. The
 *  others choose theirs where they are used (the note's card, the text box's bar) or in their menu. */
const SHOWS_COLOR = new Set(["highlight", "underline", "ink"]);

/** A tool's colour on the toolbar, for the light and the dark theme: a black pen in the dark, or a pale colour in the
 *  light, is taken toward the toolbar's text colour until it shows (as on the Mac). */
function toolTint(hex: string): React.CSSProperties {
  const n = parseInt(hex.replace("#", "").padEnd(6, "0").slice(0, 6), 16);
  const rgb = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((v) => v / 255);
  const lin = (v: number) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  const luminance = 0.2126 * lin(rgb[0]) + 0.7152 * lin(rgb[1]) + 0.0722 * lin(rgb[2]);
  const mix = (toward: number, f: number) => `rgb(${rgb.map((v) => Math.round((v + (toward - v) * f) * 255)).join(", ")})`;
  const light = luminance > 0.45 ? mix(0, Math.min(0.5, ((luminance - 0.45) / 0.55) * 0.6)) : mix(0, 0);
  const dark = luminance < 0.12 ? mix(1, Math.min(1, ((0.12 - luminance) / 0.12) * 0.85)) : mix(0, 0);
  return { ["--tint-light" as any]: light, ["--tint-dark" as any]: dark };
}
const isHex = (key: string | null | undefined): key is string => !!key && /^#[0-9a-f]{6}$/i.test(key);
const hexOfRgb = (rgb: number[]) => `#${rgb.map((x) => Math.round(x).toString(16).padStart(2, "0")).join("")}`.toUpperCase();
/** A note's or a text box's size, in points: an upright card, as on the Mac. */
const NOTE_SIZE = { width: 16, height: 19.2 };
/** The tool that makes an annotation of a PDF type (for the colours offered when it is recoloured). */
const SUBTYPE_TOOL: Record<string, string> = { Highlight: "highlight", Underline: "underline", Squiggly: "underline", StrikeOut: "strike", Text: "note", FreeText: "textbox", Ink: "ink" };
/** The pen's widths and the text box's sizes the tools' menus offer, in points. */
const INK_WIDTHS = [{ title: "细", width: 1 }, { title: "中", width: 2 }, { title: "粗", width: 3.5 }, { title: "特粗", width: 6 }];
export const TEXT_SIZES = [{ title: "小", size: 11 }, { title: "中", size: 13 }, { title: "大", size: 16 }, { title: "特大", size: 20 }];


/** The eraser's sizes (READER-30), as on the Mac: diameters 8, 16 and 32 pt; the ring is drawn in proportion. */
const ERASER_SIZES = [{ key: "small", title: "小", ring: 6 }, { key: "medium", title: "中", ring: 10 }, { key: "large", title: "大", ring: 15 }];


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
  // Each tool's colour, remembered from one paper to the next (as on the Mac); 默认高亮颜色 before 1.4 is the highlighter's.
  // 删除线 is black by default since 1.3.1: a red one from before (the old default) becomes black, once.
  useState(() => {
    try {
      if (localStorage.getItem("folio.strikeBlack")) return;
      localStorage.setItem("folio.strikeBlack", "1");
      const stored = getState().settings.annotationToolColors ?? {};
      if (stored.strike === "red") { const { strike, ...rest } = stored; setSetting("annotationToolColors", rest); }
    } catch {}
  });
  const [toolColors, setToolColors] = useState<Record<string, string>>(() => ({
    ...(settings.highlightColor ? { highlight: settings.highlightColor } : {}), ...(getState().settings.annotationToolColors ?? {}),
  }));
  const toolColorsRef = useRef(toolColors); toolColorsRef.current = toolColors;
  const toolRef = useRef(tool); toolRef.current = tool;
  const colorFor = (key: string) => {
    const palette = PALETTES[key];
    if (!palette) return "yellow";
    const chosen = toolColorsRef.current[key];
    return chosen && (palette.includes(chosen) || isHex(chosen)) ? chosen : palette[0];
  };
  const colorRef = { get current() { return colorFor(toolRef.current); } };
  const hexOf = (key: string) => (isHex(key) ? key.toUpperCase() : colors.find((c) => c.key === key)?.hex ?? "#FFD933");
  const titleOf = (key: string) => (isHex(key) ? t("自定义颜色") : colors.find((c) => c.key === key)?.title ?? key);
  // Colours mixed with 自定义颜色…, newest first: every tool offers them after its own.
  const [customColors, setCustomColors] = useState<string[]>(() => (settings.annotationCustomColors ?? []).filter(isHex));
  const rememberCustom = (hex: string) => {
    const next = [hex, ...customColors.filter((c) => c.toUpperCase() !== hex.toUpperCase())].slice(0, 5);
    setCustomColors(next);
    setSetting("annotationCustomColors", next);
  };
  /** The colours a tool offers: its own, then the mixed ones, and what it has now if that is neither. */
  const choicesFor = (key: string, current?: string | null) => {
    const list = [...(PALETTES[key] ?? PALETTES.highlight), ...customColors];
    if (current && !list.some((c) => c.toUpperCase() === current.toUpperCase())) list.push(current);
    return list;
  };
  const cardPalette = (key: string, current?: string | null): CardColor[] => choicesFor(key, current).map((c) => ({ key: c, title: titleOf(c), hex: hexOf(c) }));
  /** 自定义颜色…: the system's picker; what is mixed is remembered for every tool. */
  const mix = (initial: string, apply: (hex: string) => void) => pickColor(hexOf(initial), (hex) => { rememberCustom(hex); apply(hex); });
  /** What the page is told about the tools: the chosen one, every tool's colour, the pen's width and the text size. */
  const toolCommand = (next: string) => ({
    cmd: "tool", tool: next, color: colorFor(next), eraserSize: eraserSizeRef.current,
    colors: Object.fromEntries(Object.keys(PALETTES).map((k) => [k, colorFor(k)])),
    inkWidth: getState().settings.inkLineWidth ?? 2, textSize: getState().settings.textBoxFontSize ?? 13,
  });
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
  const [editor, setEditorState] = useState<EditorState | null>(null);
  const editorRef = useRef<EditorState | null>(null);
  editorRef.current = editor;
  /** The card or the text box being written stays with its place on the page: the page says where it is as it scrolls
   *  and zooms (`tracked`). */
  const trackedPane = useRef<Pane | null>(null);
  const setEditor = (next: EditorState | null, track?: { pane: Pane; page: number; rect: number[] }) => {
    editorRef.current = next;
    setEditorState(next);
    if (track) { trackedPane.current = track.pane; track.pane.send({ cmd: "track", page: track.page, rect: track.rect, key: next?.id }); }
    else if (!next && trackedPane.current) { trackedPane.current.send({ cmd: "track" }); trackedPane.current = null; }
  };
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

  const applyTool = (next: string) => {
    // A tool ends 编辑 PDF 文字: annotating and editing the text are not done at once.
    if (editingRef.current) setEditing(false);
    setTool(next);
    toolRef.current = next;
    main.send(toolCommand(next));
  };
  /** A tool's colour from now on (remembered from one paper to the next). */
  const keepColor = (key: string, value: string) => {
    const next = { ...toolColorsRef.current, [key]: value };
    toolColorsRef.current = next;
    setToolColors(next);
    setSetting("annotationToolColors", next);
  };
  /** A colour chosen in a tool's menu: the tool takes it, and is chosen. */
  const chooseColor = (key: string, value: string) => { keepColor(key, value); applyTool(key); };
  /** A row of a tool's or an annotation's colours, as circles; the last, many-coloured one mixes a colour of one's own. */
  const colorRow = (key: string, current: string | null | undefined, pick: (color: string) => void): MenuEntry => ({
    kind: "row", label: t("颜色"), choices: [
      ...choicesFor(key, current).map((c) => ({ title: titleOf(c), look: { color: hexOf(c) }, selected: c === current, action: () => pick(c) })),
      { title: t("自定义颜色…"), look: { custom: true as const }, action: () => mix(current ?? "yellow", pick) },
    ],
  });
  /** A tool's menu: its colours, and the pen's width, the text size or the eraser's size, each shown as it looks. */
  const toolMenu = (key: string): MenuEntry[] => {
    if (key === "eraser") return eraserMenu();
    const palette = PALETTES[key];
    if (!palette) return [];
    const tip = TOOLS.find((x) => x.key === key)?.tip ?? "";
    const current = colorFor(key);
    const entries: MenuEntry[] = [{ kind: "title", label: key === "textbox" ? t("文字颜色") : t("%@颜色", t(tip)) }, colorRow(key, current, (c) => chooseColor(key, c))];
    if (key === "ink") {
      const width = getState().settings.inkLineWidth ?? 2;
      entries.push(sep, { kind: "title", label: t("粗细") }, { kind: "row", label: t("粗细"), choices: INK_WIDTHS.map((w) => ({
        title: t(w.title), look: { dot: w.width * 2 + 2, color: hexOf(current) }, selected: width === w.width,
        action: () => { setSetting("inkLineWidth", w.width); setTimeout(() => applyTool("ink")); },
      })) });
    }
    if (key === "textbox") {
      const size = getState().settings.textBoxFontSize ?? 13;
      entries.push(sep, { kind: "title", label: t("字号") }, { kind: "row", label: t("字号"), choices: TEXT_SIZES.map((x) => ({
        title: `${t(x.title)}（${x.size} pt）`, look: { letter: x.size - 1 }, selected: size === x.size,
        action: () => { setSetting("textBoxFontSize", x.size); setTimeout(() => applyTool("textbox")); },
      })) });
    }
    return entries;
  };
  // 编辑 PDF 文字 (EDIT-01).
  const [editing, setEditingState] = useState(false);
  const editingRef = useRef(false);
  const setEditing = (on: boolean) => {
    editingRef.current = on;
    setEditingState(on);
    if (on) { setTool("select"); toolRef.current = "select"; main.send(toolCommand("select")); }
    main.send({ cmd: "editMode", on });
  };
  /** A size is chosen to erase with: the eraser becomes the tool, and the size is remembered. */
  const chooseEraserSize = (size: string) => {
    setEraserSize(size);
    eraserSizeRef.current = size;
    setSetting("readerEraserSize", size);
    applyTool("eraser");
  };
  const eraserMenu = (): MenuEntry[] => [{ kind: "title", label: t("橡皮擦大小") }, { kind: "row", label: t("橡皮擦大小"), choices: ERASER_SIZES.map((s) => ({
    title: t(s.title), look: { ring: s.ring * 1.6 }, selected: s.key === eraserSizeRef.current, action: () => chooseEraserSize(s.key),
  })) }, sep, { label: t("按 [ 或 ] 调整大小"), disabled: true }];
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
      // 设置 ▸ 阅读 ▸ 记住每篇论文的阅读位置 off: every paper opens at its top, at the usual zoom.
      const st = isMain && s.settings.rememberReadingPosition !== false ? r.state : null;
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
    } else if (result.cmd === "pageChanged") {
      // 编辑 PDF 文字: only that page is read again and drawn again.
      const url = pane.preview ? await call("reader.previewUrl", { path: pane.preview }) : await call("reader.url", { session: pane.session });
      pane.send({ cmd: "pageChanged", page: result.page, url });
    } else pane.send(result);
  };

  /** Opens an annotation for writing: a text box in place, anything else on its card. */
  const editAnnotation = (pane: Pane, m: any) => {
    const frame = pane.frame?.getBoundingClientRect();
    const fx = frame?.left ?? 0, fy = frame?.top ?? 0;
    if (m.subtype === "FreeText" && m.box) {
      const scale = m.scale ?? 1, inset = 2 * scale;
      const colorKey = m.colorKey && (isHex(m.colorKey) || colors.some((c) => c.key === m.colorKey)) ? m.colorKey : hexOfRgb(m.textRgb ?? [0, 0, 0]);
      pane.send({ cmd: "editingBox", id: m.id, page: m.page });
      const widthPt = Math.max(m.box.width - 2 * inset, 8) / scale;
      setEditor({ kind: "text", id: m.id, left: fx + m.box.left + inset, top: fy + m.box.top + inset, width: widthPt * scale, widthPt, scale,
        size: m.fontSize ?? 12, colorKey, palette: cardPalette("textbox", colorKey), text: m.contents ?? "",
        done: (text, box, style) => {
          pane.send({ cmd: "editingBox", id: null, page: m.page });
          if (!text.trim()) { removeAnnotation(pane, m, false); return; }
          const moved = style.moved.dx !== 0 || style.moved.dy !== 0;
          if (text === (m.contents ?? "") && !style.changed && !moved) return;
          // The box keeps its width and top (where it was dragged); its height follows the text.
          const s = style.scale, dx = style.moved.dx, dy = -style.moved.dy;
          const height = box.height / s + 4;
          const rect = [m.rect[0] + dx, m.rect[3] + dy - height, m.rect[2] + dx, m.rect[3] + dy];
          const change = { contents: text, rect, ...(style.changed ? { color: style.colorKey, fontSize: style.size } : {}) };
          pane.send({ cmd: "modifyEntry", page: m.page, id: m.id, ...change });
          call("reader.modify", { session: pane.session, page: m.page, id: m.id, ...change }).then((r) => applyResult(pane, r));
        } }, { pane, page: m.page, rect: [m.rect[0] + 2, m.rect[3] - 2, m.rect[0] + 2, m.rect[3] - 2] });
      return;
    }
    const kind = SUBTYPE_TOOL[m.subtype] ?? "highlight";
    // The card stands beside the annotation, and stays with it.
    const anchor = m.anchor
      ? { left: fx + m.anchor.left, top: fy + m.anchor.top, right: fx + m.anchor.right, bottom: fy + m.anchor.bottom }
      : { left: fx + (m.clientX ?? 0), top: fy + (m.clientY ?? 0), right: fx + (m.clientX ?? 0), bottom: fy + (m.clientY ?? 0) };
    const original = m.contents ?? "";
    let shown = original;
    setEditor({ kind: "note", id: m.id, anchor, text: original, quote: m.subtype === "Text" ? undefined : (m.quoted ?? ""),
      author: m.author, date: shortDate(m.modified), colorKey: m.colorKey, tool: kind,
      onColor: (key) => setAnnotationColor(pane, m, key),
      onText: (text) => {
        // The note shows whether it has words as they are typed; the change is recorded once, when the card closes.
        if (m.subtype !== "Text" || !text.trim() === !shown.trim()) return;
        shown = text;
        pane.send({ cmd: "modifyEntry", silent: true, page: m.page, id: m.id, contents: text });
      },
      onDelete: () => removeAnnotation(pane, m, false),
      done: (text) => {
        if (shown !== original) pane.send({ cmd: "modifyEntry", silent: true, page: m.page, id: m.id, contents: original });
        if (text !== original) setContents(pane, m, text);
      } }, m.rect ? { pane, page: m.page, rect: m.rect } : undefined);
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
      openMenu(eraserMenu(), x, y);
      return;
    }
    if (m.kind === "annotation") {
      const textual = m.subtype === "Text" || m.subtype === "FreeText";
      const contents = m.contents ?? "";
      const text = m.quoted || contents;
      entries = [
        colorRow(SUBTYPE_TOOL[m.subtype] ?? "highlight", m.colorKey, (key) => setAnnotationColor(pane, m, key)),
        sep,
        { label: m.subtype === "FreeText" ? t("编辑文字") : textual ? t("打开便签") : contents ? t("编辑评论…") : t("添加评论…"), action: () => editAnnotation(pane, m) },
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
        // The sidebar opens on the page last chosen (缩略图、目录或批注).
        if (pane === main) pane.send({ cmd: "sidebarPane", value: getState().settings.readerSidebarTab ?? "thumbnails" });
        break;
      case "sidebarTab":
        if (pane === main && m.pane !== "hits") setSetting("readerSidebarTab", m.pane);
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
      // A paragraph edited in place: its changes go to the app as they are typed, and it is written when it is left.
      case "paragraph":
        call(`reader.${m.op}`, { session: pane.session, ...m.args })
          .then((result) => pane.send({ cmd: "paragraphResult", req: m.req, result }))
          .catch((e) => pane.send({ cmd: "paragraphResult", req: m.req, error: e?.message ?? String(e) }));
        break;
      case "paragraphCommit":
        call("reader.paragraphCommit", { session: pane.session, id: m.id })
          .then((r) => (r ? applyResult(pane, r) : pane.send({ cmd: "paragraphSettled", page: m.page })))
          .catch((e) => {
            call("toast.show", { message: t("无法修改这段文字：%@", e?.message ?? String(e)), icon: "warning" });
            pane.send({ cmd: "paragraphSettled", page: m.page });
          });
        break;
      case "editRefused": call("toast.show", { message: t("这里不能编辑：%@", m.reason), icon: "warning" }); break;
      case "leaveEditing": if (editingRef.current) setEditing(false); break;
      case "erase": call("reader.erase", { session: pane.session, page: m.page, ids: m.ids, paths: m.paths, radius: m.radius, results: m.results }).then((r) => applyResult(pane, r)); break;
      case "eraserStep": {
        const index = ERASER_SIZES.findIndex((s) => s.key === eraserSizeRef.current);
        const next = ERASER_SIZES[Math.min(Math.max(index + m.step, 0), ERASER_SIZES.length - 1)];
        if (next.key !== eraserSizeRef.current) chooseEraserSize(next.key);
        break;
      }
      case "ink": call("reader.ink", { session: pane.session, page: m.page, color: m.color ?? colorRef.current, width: m.width ?? 2, strokes: m.strokes, temp: m.temp }).then((r) => applyResult(pane, r)); break;
      case "note": {
        // The note is put down at once, where it was clicked, and its card opens beside it. It stays, written in or not
        // (as on the Mac); it is recorded for 撤销 once, with its words, when the card closes.
        if (getState().settings.returnToSelectAfterPlacing !== false) applyTool("select");
        const frame = pane.frame?.getBoundingClientRect();
        const scale = m.scale ?? 1;
        const { width: w, height: h } = NOTE_SIZE;
        const rect = [m.x - w / 2, m.y - h / 2, m.x + w / 2, m.y + h / 2];
        const draft = `pending-${crypto.randomUUID().replace(/-/g, "")}`;
        let color: string = m.color ?? colorFor("note");
        let written = false;
        pane.send({ cmd: "addEntry", silent: true, temp: draft, page: m.page, subtype: "Text", rect, color, contents: "" });
        const cx = (frame?.left ?? 0) + m.clientX, cy = (frame?.top ?? 0) + m.clientY;
        setEditor({ kind: "note", id: draft, anchor: { left: cx - (w / 2) * scale, top: cy - (h / 2) * scale, right: cx + (w / 2) * scale, bottom: cy + (h / 2) * scale },
          text: "", colorKey: color, tool: "note", author: settings.annotationAuthor ?? "", date: shortDate(new Date()),
          onColor: (key) => { color = key; keepColor("note", key); pane.send({ cmd: "modifyEntry", silent: true, page: m.page, id: draft, color: key }); },
          onText: (text) => {
            if (!!text.trim() === written) return;
            written = !!text.trim();
            pane.send({ cmd: "modifyEntry", silent: true, page: m.page, id: draft, contents: text });
          },
          onDelete: () => pane.send({ cmd: "removeEntry", silent: true, page: m.page, id: draft }),
          done: (text) => {
            pane.send({ cmd: "removeEntry", silent: true, page: m.page, id: draft });
            const temp = `pending-${crypto.randomUUID().replace(/-/g, "")}`;
            pane.send({ cmd: "addEntry", temp, page: m.page, subtype: "Text", rect, color, contents: text });
            call("reader.addText", { session: pane.session, page: m.page, subtype: "Text", rect, color, contents: text, temp }).then((res) => applyResult(pane, res));
          } }, { pane, page: m.page, rect });
        break;
      }
      case "textbox": {
        // Written in place: the field starts where the click was (the first line's middle there) and widens as it is typed.
        if (getState().settings.returnToSelectAfterPlacing !== false) applyTool("select");
        const frame = pane.frame?.getBoundingClientRect();
        const size = m.textSize ?? 13, scale = m.scale ?? 1, color = m.color ?? colorFor("textbox");
        const line = size * 1.22;
        const id = `new-text-${Date.now()}`;
        setEditor({ kind: "text", id, left: (frame?.left ?? 0) + m.clientX, top: (frame?.top ?? 0) + m.clientY - (line / 2) * scale, scale,
          size, colorKey: color, palette: cardPalette("textbox", color), text: "", done: (text, box, style) => {
            // A colour or size chosen on the bar is the text box's from now on.
            if (style.changed) {
              keepColor("textbox", style.colorKey);
              setSetting("textBoxFontSize", style.size);
              setTimeout(() => main.send(toolCommand(toolRef.current)));
            }
            if (!text.trim()) return;
            // Where it was dragged to (page points), from where it was put.
            const s = style.scale, dx = style.moved.dx, dy = -style.moved.dy;
            const width = box.width / s + 6, height = box.height / s + 4;
            const top = m.y + line / 2 + 2 + dy;
            const r = [m.x - 2 + dx, top - height, m.x - 2 + dx + width, top];
            const temp = `pending-${crypto.randomUUID().replace(/-/g, "")}`;
            pane.send({ cmd: "addEntry", temp, page: m.page, subtype: "FreeText", rect: r, color: style.colorKey, contents: text, fontSize: style.size });
            call("reader.addText", { session: pane.session, page: m.page, subtype: "FreeText", rect: r, color: style.colorKey, contents: text, fontSize: style.size, temp }).then((res) => applyResult(pane, res));
          } }, { pane, page: m.page, rect: [m.x, m.y + line / 2, m.x, m.y + line / 2] });
        break;
      }
      case "annotationEdit": editAnnotation(pane, m); break;
      case "tracked": {
        const current = editorRef.current;
        if (!current || current.id !== m.key) break;
        const frame = pane.frame?.getBoundingClientRect();
        const fx = frame?.left ?? 0, fy = frame?.top ?? 0;
        const anchor = { left: fx + m.anchor.left, top: fy + m.anchor.top, right: fx + m.anchor.right, bottom: fy + m.anchor.bottom };
        if (current.kind === "note") setEditorState({ ...current, anchor });
        else setEditorState({ ...current, left: anchor.left, top: anchor.top, scale: m.scale, width: current.widthPt ? current.widthPt * m.scale : undefined });
        break;
      }
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
    main.send(toolCommand("select"));
    openPane(main, file, null);
    return () => {
      main.send({ cmd: "flushPosition" });
      if (main.session) call("reader.close", { session: main.session });
      if (parallelRef.current?.session) call("reader.close", { session: parallelRef.current.session });
    };
  }, [opened]);

  useEffect(() => { main.send({ cmd: "theme", dark }); parallelRef.current?.send({ cmd: "theme", dark }); }, [dark]);
  useEffect(() => { main.send({ cmd: "shadows", on: settings.readerPageShadows }); }, [settings.readerPageShadows]);
  useEffect(() => { main.send({ cmd: "tooltips", on: settings.showAnnotationTooltips !== false }); }, [settings.showAnnotationTooltips]);
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
      case "editText": return plain(t("编辑 PDF 中的文字"), SquarePen, () => setEditing(!editingRef.current), editing ? " on" : "");
      case "translate": return <button className="glass-button" title={t("保留排版翻译全文、对照阅读")} onClick={(e) => openMenuAt(e.currentTarget, translateMenu())}><FullTextTranslateIcon size={17} /></button>;
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
                    {(() => {
                      // The highlighter, the underline and the pen are drawn in their colour (as on the Mac), a little
                      // lighter or darker where it would not stand out from the toolbar. Clicking a tool chooses it;
                      // clicking it again (or right-clicking it) opens its menu.
                      const hasMenu = !!PALETTES[x.key] || x.key === "eraser";
                      const tip = hasMenu ? t("%@（Ctrl+Alt+%@）：再点一次选择颜色和样式", t(x.tip), x.shortcut) : `${t(x.tip)}（Ctrl+Alt+${x.shortcut}）`;
                      return (
                        <button className={`tool${tool === x.key ? " on" : ""}${SHOWS_COLOR.has(x.key) ? " tinted" : ""}`}
                          style={SHOWS_COLOR.has(x.key) ? toolTint(hexOf(colorFor(x.key))) : undefined} title={tip} aria-label={t(x.tip)} aria-pressed={tool === x.key} aria-haspopup={hasMenu ? "menu" : undefined}
                          onClick={(e) => { if (hasMenu && tool === x.key) openMenuAt(e.currentTarget, toolMenu(x.key)); else applyTool(x.key); }}
                          onContextMenu={(e) => { if (!hasMenu) return; e.preventDefault(); e.stopPropagation(); openMenuAt(e.currentTarget, toolMenu(x.key)); }}>
                          <Icon size={16} strokeWidth={1.8} />
                        </button>
                      );
                    })()}
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
      {(ocr || (isScan && !scanDismissed)) && (
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
      {editor?.kind === "note" && <NoteCard key={editor.id} anchor={editor.anchor} text={editor.text} quote={editor.quote} author={editor.author} date={editor.date}
        colorKey={editor.colorKey} palette={cardPalette(editor.tool, editor.colorKey)} onColor={editor.onColor} onText={editor.onText}
        onMix={(apply) => mix(editor.colorKey ?? "yellow", apply)} onDelete={editor.onDelete} done={editor.done}
        close={() => { setEditor(null); main.frame?.contentWindow?.focus(); }} />}
      {editor?.kind === "text" && <TextBoxField key={editor.id} left={editor.left} top={editor.top} width={editor.width} scale={editor.scale} size={editor.size} colorKey={editor.colorKey}
        palette={cardPalette("textbox", editor.colorKey)} text={editor.text} onMix={(apply) => mix(editor.colorKey, apply)}
        done={editor.done} close={() => { setEditor(null); main.frame?.contentWindow?.focus(); }} />}
    </div>
  );
}

type EditorState =
  | { kind: "note"; id: string; anchor: { left: number; top: number; right: number; bottom: number }; text: string; quote?: string; author?: string; date?: string;
      colorKey?: string | null; tool: string; onColor: (key: string) => void; onText?: (text: string) => void; onDelete: () => void; done: (text: string) => void }
  | { kind: "text"; id: string; left: number; top: number; width?: number; widthPt?: number; scale: number; size: number; colorKey: string; palette: CardColor[]; text: string;
      done: (text: string, box: { width: number; height: number }, style: { colorKey: string; size: number; changed: boolean; moved: { dx: number; dy: number }; scale: number }) => void };

/** When a note was written, short ("11月15日"; who wrote it shows on hover). */
function shortDate(value: unknown) {
  const date = value instanceof Date ? value : typeof value === "string" || typeof value === "number" ? new Date(value) : null;
  if (!date || isNaN(date.getTime())) return undefined;
  return date.toLocaleDateString(document.documentElement.lang || undefined, { month: "short", day: "numeric" });
}
