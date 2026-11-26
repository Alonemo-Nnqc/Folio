import { EditorSelection, Prec, type Extension } from "@codemirror/state";
import { EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { flushSync } from "react-dom";
import { t } from "../i18n";
import { openMenu, sep, type MenuEntry } from "../ui/menu";
import { getState } from "../store";
import { BlockMenu, commandIcon, type MenuItem } from "./BlockMenu";
import { deleteLines, renumber } from "./edit";
import { codeAt, codeText, isList, lineInfo, structureOf } from "./lines";
import { md, scaleOf } from "./prefs";
import { languageMenu } from "./markdown";
import { focusTable, tableViewAt } from "./table";

// The blocks of a Markdown document, as on the Mac (MarkdownCommands.swift, MarkdownBlockMenu.swift, MarkdownGutter.swift):
// the menu "/" opens, the handles beside the line under the pointer, and moving lines with what belongs to them.

export type BlockStyle = "text" | "h1" | "h2" | "h3" | "bullet" | "numbered" | "task" | "quote" | "code";

export interface Command {
  id: string;
  section: "style" | "list" | "block" | "insert";
  title: () => string;
  /** The Markdown it stands for. */
  hint: string;
  /** What else finds it: pinyin and its initials, English. */
  keywords: string[];
  style?: BlockStyle;
}

export const commands: Command[] = [
  { id: "text", section: "style", title: () => t("正文"), hint: "", keywords: ["zhengwen", "zw", "text", "paragraph", "plain"], style: "text" },
  { id: "h1", section: "style", title: () => t("标题 1"), hint: "#", keywords: ["biaoti1", "bt1", "heading1", "h1"], style: "h1" },
  { id: "h2", section: "style", title: () => t("标题 2"), hint: "##", keywords: ["biaoti2", "bt2", "heading2", "h2"], style: "h2" },
  { id: "h3", section: "style", title: () => t("标题 3"), hint: "###", keywords: ["biaoti3", "bt3", "heading3", "h3"], style: "h3" },
  { id: "bullet", section: "list", title: () => t("项目列表"), hint: "-", keywords: ["xiangmuliebiao", "xmlb", "liebiao", "lb", "bullet", "list", "ul"], style: "bullet" },
  { id: "numbered", section: "list", title: () => t("编号列表"), hint: "1.", keywords: ["bianhaoliebiao", "bhlb", "liebiao", "lb", "numbered", "ordered", "ol"], style: "numbered" },
  { id: "task", section: "list", title: () => t("任务列表"), hint: "[ ]", keywords: ["renwuliebiao", "rwlb", "renwu", "daiban", "todo", "task", "checklist"], style: "task" },
  { id: "quote", section: "block", title: () => t("引用块"), hint: ">", keywords: ["yinyong", "yy", "quote", "blockquote"], style: "quote" },
  { id: "code", section: "block", title: () => t("代码块"), hint: "```", keywords: ["daimakuai", "dmk", "daima", "code"], style: "code" },
  { id: "table", section: "block", title: () => t("表格"), hint: "| |", keywords: ["biaoge", "bg", "table"] },
  { id: "rule", section: "block", title: () => t("分隔线"), hint: "---", keywords: ["fengexian", "fgx", "divider", "rule", "hr"] },
  { id: "cite", section: "insert", title: () => t("引用文献…"), hint: "", keywords: ["yinyongwenxian", "yywx", "wenxian", "wx", "cite", "reference", "paper"] },
  { id: "link", section: "insert", title: () => t("链接"), hint: "Ctrl+K", keywords: ["lianjie", "lj", "link", "url"] },
  { id: "date", section: "insert", title: () => t("今天的日期"), hint: "", keywords: ["jintianderiqi", "jtdrq", "riqi", "rq", "date", "today"] },
];

const normalized = (s: string) => s.toLowerCase().replace(/[\s'’‘]/g, "");

/** What typing query after "/" finds, best first: titles, then the start of a keyword, then anywhere in a title. */
export function matching(query: string): Command[] {
  const q = normalized(query);
  if (!q) return commands;
  const rank = (c: Command) => normalized(c.title()).startsWith(q) ? 0 : c.keywords.some((k) => k.startsWith(q)) ? 1 : normalized(c.title()).includes(q) ? 2 : 9;
  return commands.map((c, n) => ({ c, n, r: rank(c) })).filter((x) => x.r < 9).sort((a, b) => a.r - b.r || a.n - b.n).map((x) => x.c);
}

/** Papers to cite, the most recently added first; query finds title, authors, publication and year. */
export function references(query: string) {
  const terms = query.toLowerCase().split(/[\s'’]+/).filter(Boolean);
  const items = [...getState().items.values()].filter((i) => i.kind === "regular" && !i.trashed).sort((a, b) => b.dateModified - a.dateModified);
  const found: { id: string; title: string; detail: string; markdown: string }[] = [];
  for (const i of items) {
    const text = [i.title, i.authorsList, i.source, i.year].filter(Boolean).join(" ").toLowerCase();
    if (!terms.every((x) => text.includes(x))) continue;
    const family: string[] = i.authors.map((a) => a.family).filter(Boolean);
    const chinese = /[一-鿿]/.test(i.title ?? "");
    const names = family.length === 0 ? "" : family.length === 1 ? family[0] : family.length === 2 ? family[0] + (chinese ? "、" : " & ") + family[1] : family[0] + (chinese ? " 等" : " et al.");
    const label = [names, i.year].filter(Boolean).join(", ") || i.title;
    found.push({ id: i.id, title: i.title, detail: [names, i.year, i.source].filter(Boolean).join(" · "), markdown: `[${String(label).replace(/\[/g, "(").replace(/\]/g, ")")}](folio://open?item=${i.id})` });
    if (found.length === 30) break;
  }
  return found;
}

// MARK: Lines

const FENCE = /^\s*(`{3,}|~{3,})/;

/** Fenced code blocks, by line numbers. */
export function codeBlocks(view: EditorView): { from: number; to: number }[] { return structureOf(view.state).codes.map((c) => ({ from: c.first, to: c.last })); }

export function styleAt(view: EditorView, pos: number): BlockStyle {
  const line = view.state.doc.lineAt(pos);
  if (codeBlocks(view).some((b) => line.number >= b.from && line.number <= b.to)) return "code";
  const h = /^(#{1,6})[ \t]/.exec(line.text);
  if (h) return (h[1].length <= 3 ? `h${h[1].length}` : "h3") as BlockStyle;
  if (/^[ \t]*[-*+][ \t]+\[[ xX]\]/.test(line.text)) return "task";
  if (/^[ \t]*[-*+][ \t]/.test(line.text)) return "bullet";
  if (/^[ \t]*\d{1,9}[.)][ \t]/.test(line.text)) return "numbered";
  if (/^[ \t]{0,3}>/.test(line.text)) return "quote";
  return "text";
}

const MARKER = /^([ \t]*)(?:#{1,6}[ \t]+|[-*+][ \t]+\[[ xX]\][ \t]*|[-*+][ \t]+|\d{1,9}[.)][ \t]+|>[ \t]?)/;

/** Makes the lines from…to this kind of block, whatever they were (the caret at their end). */
export function setStyle(view: EditorView, style: BlockStyle, from = view.state.selection.main.from, to = view.state.selection.main.to) {
  const doc = view.state.doc;
  let first = doc.lineAt(from).number, last = doc.lineAt(to).number;
  let lines: string[] = [];
  const code = codeBlocks(view).find((b) => first >= b.from && first <= b.to);
  if (code && style === "code") return;
  if (code) { first = code.from; last = code.to; }
  for (let n = first; n <= last; n++) lines.push(doc.line(n).text);
  if (code) {
    lines.shift();
    if (lines.length && FENCE.test(lines[lines.length - 1])) lines.pop();
    if (!lines.length) lines = [""];
  }
  const start = doc.line(first).from, end = doc.line(last).to;
  if (style === "code") {
    const empty = lines.every((l) => !l.trim());
    const insert = empty ? "```\n\n```" : ["```", ...lines, "```"].join("\n");
    view.dispatch({ changes: { from: start, to: end, insert }, selection: EditorSelection.cursor(empty ? start + 4 : start + insert.length), scrollIntoView: true });
    view.focus();
    return;
  }
  let number = 0;
  const insert = lines.map((line) => {
    let body = line;
    for (let m = MARKER.exec(body); m; m = MARKER.exec(body)) body = m[1] + body.slice(m[0].length);
    const indent = /^[ \t]*/.exec(body)![0], text = body.slice(indent.length);
    number++;
    switch (style) {
      case "text": return text;
      case "h1": case "h2": case "h3": return "#".repeat(Number(style[1])) + " " + text;
      case "bullet": return indent + "- " + text;
      case "numbered": return indent + `${number}. ` + text;
      case "task": return indent + "- [ ] " + text;
      default: return "> " + text;
    }
  }).join("\n");
  // The caret stays in its text, the line's new symbols before it or not.
  const fromEnd = lines.length === 1 ? Math.max(end - Math.max(view.state.selection.main.to, start), 0) : 0;
  view.dispatch({ changes: { from: start, to: end, insert }, selection: EditorSelection.cursor(start + insert.length), scrollIntoView: true });
  if (fromEnd > 0) {
    const line = lineInfo(view.state.doc, view.state.doc.lineAt(start).number);
    view.dispatch({ selection: EditorSelection.cursor(Math.max(line.to - fromEnd, line.textStart)) });
  }
  renumber(view);
  view.focus();
}

/** A block on lines of its own after the caret's line; caret offset inside it. */
export function insertBlock(view: EditorView, block: string, caret?: number) {
  const line = view.state.doc.lineAt(view.state.selection.main.head);
  const empty = !line.text.trim();
  const insert = (empty ? "" : "\n\n") + block + "\n";
  const at = empty ? line.from : line.to, start = at + (empty ? 0 : 2);
  view.dispatch({ changes: { from: at, to: empty ? line.to : at, insert }, selection: EditorSelection.cursor(caret != null ? start + caret : at + insert.length), scrollIntoView: true });
  view.focus();
}

export const insertTable = (view: EditorView) => {
  insertBlock(view, `|  |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |`, 2);
  const at = view.state.selection.main.head;
  requestAnimationFrame(() => focusTable(view, at));
};

function today() {
  const d = new Date(), two = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}`;
}

/** The lines that go together with line n: a whole code block or table, a list item with what is nested under it. */
export function blockAt(view: EditorView, n: number): { from: number; to: number } {
  const doc = view.state.doc;
  const code = codeBlocks(view).find((b) => n >= b.from && n <= b.to);
  if (code) return code;
  const table = structureOf(view.state).tables.find((x) => n >= x.first && n <= x.last);
  if (table) return { from: table.first, to: table.last };
  const item = lineInfo(doc, n);
  if (isList(item)) {
    let to = n;
    while (to < doc.lines) { const below = lineInfo(doc, to + 1); if (below.kind !== "continuation" && !(isList(below) && below.indent > item.indent)) break; to++; }
    return { from: n, to };
  }
  return { from: n, to: n };
}

type Block = { from: number; to: number };

/** Takes the lines out and puts them before line `before` (lines + 1: at the end), in one step for undo. */
export function moveBlock(view: EditorView, block: Block, before: number) {
  const doc = view.state.doc;
  if (before >= block.from && before <= block.to + 1) return;
  const lines = (a: number, b: number) => { const out: string[] = []; for (let n = a; n <= b; n++) out.push(doc.line(n).text); return out; };
  const moved = lines(block.from, block.to);
  const up = before < block.from;
  const first = up ? before : block.from, last = up ? block.to : before - 1;
  const others = up ? lines(before, block.from - 1) : lines(block.to + 1, before - 1);
  const result = up ? [...moved, ...others] : [...others, ...moved];
  const from = doc.line(first).from;
  const start = from + (up ? 0 : others.join("\n").length + 1);
  view.dispatch({ changes: { from, to: doc.line(last).to, insert: result.join("\n") }, selection: EditorSelection.cursor(start + moved.join("\n").length), scrollIntoView: true, userEvent: "move.line" });
  renumber(view, Math.min(start, view.state.doc.length));
  view.focus();
}

export function moveBy(view: EditorView, block: Block, step: 1 | -1) {
  if (step < 0 && block.from > 1) moveBlock(view, block, blockAt(view, block.from - 1).from);
  else if (step > 0 && block.to < view.state.doc.lines) moveBlock(view, block, blockAt(view, block.to + 1).to + 1);
}

/** The caret's block past its neighbour (Alt+↑, Alt+↓). */
export const moveCaretBlock = (step: 1 | -1) => (view: EditorView) => {
  moveBy(view, blockAt(view, view.state.doc.lineAt(view.state.selection.main.head).number), step);
  return true;
};

function blockMenu(view: EditorView, block: Block): MenuEntry[] {
  const doc = view.state.doc, first = doc.line(block.from), last = doc.line(block.to);
  const text = doc.sliceString(first.from, last.to);
  const current = styleAt(view, first.from);
  const insertLine = (at: number, caret: number) => { view.dispatch({ changes: { from: at, insert: "\n" }, selection: EditorSelection.cursor(caret) }); view.focus(); };
  const code = codeAt(view.state, first.from), table = tableViewAt(view, first.from);
  return [
    ...(code ? [
      { label: t("语言"), icon: commandIcon("code"), submenu: languageMenu(view, code) },
      { label: t("拷贝代码"), icon: commandIcon("copy"), action: () => { const b = codeText(code, doc); navigator.clipboard.writeText(doc.sliceString(b.from, b.to)); } },
      sep,
    ] as MenuEntry[] : []),
    ...(table ? [
      { label: t("添加一行"), action: () => table.insertRow(table.data.rows.length) },
      { label: t("添加一列"), action: () => table.insertColumn(table.data.alignments.length) },
      sep,
    ] as MenuEntry[] : [
      { kind: "title", label: t("转换为") },
      ...commands.filter((c) => c.style).map((c): MenuEntry => ({ label: c.title(), icon: commandIcon(c.id), checked: current === c.style, action: () => setStyle(view, c.style!, first.from, last.to) })),
      sep,
    ] as MenuEntry[]),
    { label: t("在下方添加…"), icon: commandIcon("add"), action: () => addBelow(view, block) },
    { label: t("在上方插入一行"), icon: commandIcon("above"), action: () => insertLine(first.from, first.from) },
    { label: t("在下方插入一行"), icon: commandIcon("below"), action: () => insertLine(last.to, last.to + 1) },
    sep,
    { label: t("上移"), icon: commandIcon("up"), key: "Alt+↑", disabled: block.from === 1, action: () => moveBy(view, block, -1) },
    { label: t("下移"), icon: commandIcon("down"), key: "Alt+↓", disabled: block.to === doc.lines, action: () => moveBy(view, block, 1) },
    { label: t("创建副本"), icon: commandIcon("duplicate"), action: () => { view.dispatch({ changes: { from: last.to, insert: "\n" + text }, selection: EditorSelection.cursor(last.to + 1 + text.length) }); view.focus(); } },
    { label: t("拷贝"), icon: commandIcon("copy"), action: () => { navigator.clipboard.writeText(text); } },
    sep,
    { label: t("删除"), icon: commandIcon("delete"), action: () => deleteLines(view, first.from, last.to) },
  ];
}

// MARK: The menu "/" opens

class SlashMenu {
  /** Where the "/" is, while the menu is open. */
  private at: number | null = null;
  /** The "/" was put there by a button, not typed: it goes again when nothing is picked. */
  private ours = false;
  private citing = false;
  private selected = 0;
  private items: MenuItem[] = [];
  private host: HTMLElement | null = null;
  private root: Root | null = null;

  constructor(readonly view: EditorView) {}

  get isOpen() { return this.at != null; }

  open(citing = false) {
    const pos = this.view.state.selection.main.head;
    this.view.focus();
    this.view.dispatch({ changes: { from: pos, insert: "/" }, selection: EditorSelection.cursor(pos + 1), scrollIntoView: true });
    this.start(pos, true, citing);
  }

  private start(at: number, ours: boolean, citing = false) {
    this.at = at;
    this.ours = ours;
    this.citing = citing;
    this.selected = 0;
    this.refresh();
  }

  update(u: ViewUpdate) {
    if (u.docChanged && this.at != null) this.at = u.changes.mapPos(this.at, -1);
    if (u.docChanged && this.at == null && u.transactions.some((tr) => tr.isUserEvent("input"))) {
      const head = u.state.selection.main.head;
      const typed = head > 0 ? u.state.doc.sliceString(head - 1, head) : "";
      let single = false;
      u.changes.iterChanges((_fa, _ta, fromB, toB) => { if (toB === head && toB - fromB === 1) single = true; });
      if (single && this.opens(typed, head - 1)) { const at = head - 1; queueMicrotask(() => this.start(at, false)); return; }
    }
    if (this.at != null && (u.docChanged || u.selectionSet)) queueMicrotask(() => this.refresh());
    if (u.focusChanged && !u.view.hasFocus) queueMicrotask(() => this.close());
  }

  /** "/" (or the "、" a Chinese input method types on that key) at the start of a line or after a space, outside code. */
  private opens(typed: string, at: number) {
    if (!md("markdownSlashMenu") || !["/", "、", "／"].includes(typed)) return false;
    const line = this.view.state.doc.lineAt(at);
    const before = line.text.slice(0, at - line.from);
    const atStart = /^[ \t]*(?:>[ \t]?)*(?:[-*+][ \t]+(?:\[[ xX]\][ \t]+)?|\d{1,9}[.)][ \t]+|#{1,6}[ \t]+)?$/.test(before);
    if (!atStart && !(typed === "/" && /\s$/.test(before))) return false;
    return styleAt(this.view, at) !== "code";
  }

  private refresh() {
    const at = this.at;
    if (at == null) return;
    const { state } = this.view;
    const head = state.selection.main.head;
    if (at >= state.doc.length || head <= at || !state.selection.main.empty) return this.close();
    const query = state.doc.sliceString(at + 1, head);
    if (query.includes("\n") || query.length > 60) return this.close();
    const before = this.items.map((i) => i.id).join();
    if (this.citing) this.items = references(query).map((r) => ({ kind: "reference" as const, id: r.id, title: r.title, detail: r.detail, markdown: r.markdown }));
    else {
      // "/ " is a slash in a sentence, not a menu.
      if (query.startsWith(" ")) return this.close();
      this.items = matching(query).map((c) => ({ kind: "command" as const, id: c.id, title: c.title(), detail: c.hint, section: query ? undefined : c.section }));
      if (!this.items.length) return this.close();
    }
    if (before !== this.items.map((i) => i.id).join()) this.selected = 0;
    this.render();
  }

  private render() {
    if (this.at == null) return;
    if (!this.host) {
      this.host = document.createElement("div");
      document.body.appendChild(this.host);
      this.root = createRoot(this.host);
    }
    const coords = this.view.coordsAtPos(this.at);
    if (!coords) return this.close();
    flushSync(() => this.root!.render(createElement(BlockMenu, {
      items: this.items, selected: this.selected, citing: this.citing, x: coords.left - 8, top: coords.top, bottom: coords.bottom,
      onPick: (n: number) => this.pick(n), onHover: (n: number) => { if (n !== this.selected) { this.selected = n; this.render(); } },
    })));
  }

  close() {
    const at = this.at;
    if (at == null) return;
    this.at = null;
    this.items = [];
    const root = this.root, host = this.host;
    this.root = null;
    this.host = null;
    queueMicrotask(() => { root?.unmount(); host?.remove(); });
    const { state } = this.view;
    if (this.ours && state.selection.main.head === at + 1 && state.doc.sliceString(at, at + 1) === "/") this.view.dispatch({ changes: { from: at, to: at + 1 } });
  }

  pick(index: number) {
    const at = this.at, item = this.items[index];
    if (at == null || !item) return;
    const head = this.view.state.selection.main.head;
    if (item.kind === "command" && item.id === "cite") {
      // On to the papers: what was typed to find 引用文献 goes, the "/" stays for what is typed next.
      this.citing = true;
      this.ours = true;
      this.selected = 0;
      if (head > at + 1) this.view.dispatch({ changes: { from: at + 1, to: head }, selection: EditorSelection.cursor(at + 1) });
      else this.refresh();
      this.view.focus();
      return;
    }
    this.ours = false;
    this.close();
    const markdown = item.kind === "reference" ? item.markdown! : item.id === "date" ? today() : "";
    this.view.dispatch({ changes: { from: at, to: head, insert: markdown }, selection: EditorSelection.cursor(at + markdown.length) });
    this.view.focus();
    if (item.kind === "reference") return;
    const command = commands.find((c) => c.id === item.id)!;
    if (command.style) setStyle(this.view, command.style);
    else if (command.id === "table") insertTable(this.view);
    else if (command.id === "rule") insertBlock(this.view, "---");
    else if (command.id === "link") {
      this.view.dispatch({ changes: { from: at, insert: "[](https://)" }, selection: EditorSelection.cursor(at + 1) });
    }
  }

  /** Keys while it is open. True when it took the key. */
  key(e: KeyboardEvent): boolean {
    if (this.at == null || e.isComposing) return false;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      if (this.items.length) { this.selected = (this.selected + (e.key === "ArrowDown" ? 1 : this.items.length - 1)) % this.items.length; this.render(); }
      return true;
    }
    if (e.key === "Enter" || e.key === "Tab") { if (this.items.length) this.pick(this.selected); else this.close(); return true; }
    if (e.key === "Escape") { this.close(); return true; }
    return false;
  }

  destroy() {
    this.at = null;
    const root = this.root, host = this.host;
    queueMicrotask(() => { root?.unmount(); host?.remove(); });
  }
}

const slashPlugin = ViewPlugin.fromClass(SlashMenu);

/** Opens the menu of tools at the caret (the toolbar's +, 引用文献). */
export function openSlashMenu(view: EditorView, citing = false) { view.plugin(slashPlugin)?.open(citing); }

/** The menu "/" opens, in every Markdown editor. */
export const slashMenu: Extension = [
  slashPlugin,
  Prec.highest(EditorView.domEventHandlers({
    keydown: (e, view) => {
      if (!view.plugin(slashPlugin)?.key(e)) return false;
      e.preventDefault();
      return true;
    },
    mousedown: (_e, view) => { view.plugin(slashPlugin)?.close(); return false; },
  })),
];

// MARK: The handles beside a line

/** An empty line below the block, with the menu of tools open on it. */
function addBelow(view: EditorView, block: Block) {
  const line = view.state.doc.line(block.to);
  if (view.state.doc.sliceString(view.state.doc.line(block.from).from, line.to).trim()) view.dispatch({ changes: { from: line.to, insert: "\n" }, selection: EditorSelection.cursor(line.to + 1), scrollIntoView: true });
  else view.dispatch({ selection: EditorSelection.cursor(line.to), scrollIntoView: true });
  openSlashMenu(view);
}

class Gutter {
  private dom = document.createElement("div");
  private drop = document.createElement("div");
  private block: Block | null = null;
  private area: HTMLElement | null = null;
  private dragging = false;

  constructor(readonly view: EditorView) {
    this.dom.className = "md-gutter";
    const add = document.createElement("button"), grip = document.createElement("button");
    add.title = t("在下方添加（点按）");
    add.setAttribute("aria-label", add.title);
    add.innerHTML = '<svg width="15" height="15" viewBox="0 0 15 15" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M7.5 2.5v10M2.5 7.5h10"/></svg>';
    grip.title = t("点按打开菜单，拖动移动");
    grip.setAttribute("aria-label", grip.title);
    grip.className = "grip";
    grip.innerHTML = '<svg width="10" height="16" viewBox="0 0 10 16" fill="currentColor">' + [2, 8].flatMap((x) => [3, 8, 13].map((y) => `<circle cx="${x}" cy="${y}" r="1.5"/>`)).join("") + "</svg>";
    this.dom.append(add, grip);
    this.drop.className = "md-drop";
    view.dom.append(this.dom, this.drop);
    add.addEventListener("mousedown", (e) => e.preventDefault());
    add.addEventListener("click", () => this.addBelow());
    grip.addEventListener("pointerdown", (e) => this.press(e, grip));
    requestAnimationFrame(() => {
      this.area = view.dom.closest<HTMLElement>(".md-tab-body") ?? view.dom;
      this.area.addEventListener("mousemove", this.move);
      this.area.addEventListener("mouseleave", this.hide);
      this.area.addEventListener("scroll", this.hide, true);
    });
  }

  private lineAt(y: number): number | null {
    const { view } = this;
    const content = view.contentDOM.getBoundingClientRect();
    if (y < content.top - 4 || y > content.bottom) return null;
    const block = view.lineBlockAtHeight(y - view.documentTop);
    return view.state.doc.lineAt(block.from).number;
  }

  private move = (e: MouseEvent) => {
    if (this.dragging || e.buttons) return;
    if (!md("markdownShowsHandles")) return this.hide();
    const n = this.lineAt(e.clientY);
    if (n == null) return this.hide();
    const block = blockAt(this.view, n);
    this.block = block;
    const line = this.view.state.doc.line(block.from);
    // Beside a table's first row, a code block's header.
    const { codes, tables } = structureOf(this.view.state);
    const tall = tables.some((x) => x.first === block.from) ? 24 : codes.some((c) => c.first === block.from && c.closeFrom != null) ? 22 : 0;
    const top = this.view.lineBlockAt(line.from).top + this.view.documentTop;
    const coords = tall ? { top: top + tall - 1, bottom: top + tall + 1 } : this.view.coordsAtPos(lineInfo(this.view.state.doc, block.from).textStart);
    if (!coords) return this.hide();
    const box = this.view.dom.getBoundingClientRect();
    this.dom.style.top = `${Math.round(((coords.top + coords.bottom) / 2 - box.top) / scaleOf(this.view.dom) - 12)}px`;
    this.dom.classList.add("on");
  };

  private hide = () => { if (!this.dragging) { this.dom.classList.remove("on"); this.block = null; } };

  private addBelow() { if (this.block) addBelow(this.view, this.block); }

  private press(e: PointerEvent, grip: HTMLElement) {
    if (e.button !== 0 || !this.block) return;
    e.preventDefault();
    const block = this.block, { view } = this;
    const x = e.clientX, y = e.clientY;
    let target: number | null = null, moved = false;
    grip.setPointerCapture(e.pointerId);
    const mark = (on: boolean) => {
      for (let n = block.from; n <= block.to; n++) {
        const at = view.domAtPos(view.state.doc.line(n).from).node;
        (at instanceof Element ? at : at.parentElement)?.closest(".cm-line")?.classList.toggle("md-moving", on);
      }
    };
    const onMove = (m: PointerEvent) => {
      if (!moved && Math.hypot(m.clientX - x, m.clientY - y) < 4) return;
      if (!moved) { moved = true; this.dragging = true; this.dom.classList.remove("on"); mark(true); document.body.classList.add("md-grabbing"); }
      const area = this.area!.getBoundingClientRect();
      if (m.clientY < area.top + 30) this.area!.scrollBy(0, -14);
      if (m.clientY > area.bottom - 30) this.area!.scrollBy(0, 14);
      const content = view.contentDOM.getBoundingClientRect();
      const n = this.lineAt(Math.min(Math.max(m.clientY, content.top), content.bottom - 1));
      if (n == null) return;
      const under = blockAt(view, n);
      const top = view.lineBlockAt(view.state.doc.line(under.from).from).top + view.documentTop, bottom = view.lineBlockAt(view.state.doc.line(under.to).from).bottom + view.documentTop;
      const before = m.clientY < (top + bottom) / 2;
      target = before ? under.from : under.to + 1;
      const idle = target >= block.from && target <= block.to + 1;
      this.drop.style.top = `${((before ? top : bottom) - view.dom.getBoundingClientRect().top) / scaleOf(view.dom) - 1}px`;
      this.drop.classList.toggle("on", !idle);
    };
    const end = (commit: boolean) => {
      grip.removeEventListener("pointermove", onMove);
      grip.removeEventListener("pointerup", onUp);
      grip.removeEventListener("pointercancel", onCancel);
      window.removeEventListener("keydown", onKey, true);
      document.body.classList.remove("md-grabbing");
      this.drop.classList.remove("on");
      if (moved) mark(false);
      this.dragging = false;
      if (!commit) return;
      if (moved) { if (target != null) moveBlock(view, block, target); }
      else {
        const first = view.state.doc.line(block.from), last = view.state.doc.line(block.to);
        view.focus();
        view.dispatch({ selection: EditorSelection.range(first.from, last.to) });
        const r = grip.getBoundingClientRect();
        openMenu(blockMenu(view, block), r.left, r.bottom + 4);
      }
    };
    const onUp = () => end(true), onCancel = () => end(false);
    const onKey = (k: KeyboardEvent) => { if (k.key === "Escape") { k.preventDefault(); k.stopPropagation(); end(false); } };
    grip.addEventListener("pointermove", onMove);
    grip.addEventListener("pointerup", onUp);
    grip.addEventListener("pointercancel", onCancel);
    window.addEventListener("keydown", onKey, true);
  }

  update(u: ViewUpdate) { if (u.docChanged) this.hide(); }

  destroy() {
    this.area?.removeEventListener("mousemove", this.move);
    this.area?.removeEventListener("mouseleave", this.hide);
    this.area?.removeEventListener("scroll", this.hide, true);
    this.dom.remove();
    this.drop.remove();
  }
}

/** The handles beside the line under the pointer. */
export const blockGutter: Extension = ViewPlugin.define((view) => new Gutter(view));

// MARK: The document

export function headings(view: EditorView): { level: number; title: string; from: number }[] {
  const doc = view.state.doc, code = codeBlocks(view), out: { level: number; title: string; from: number }[] = [];
  for (let n = 1; n <= doc.lines; n++) {
    const line = doc.line(n);
    const m = /^(#{1,6})[ \t]+(\S.*)$/.exec(line.text);
    if (!m || code.some((b) => n >= b.from && n <= b.to)) continue;
    out.push({ level: m[1].length, title: m[2].replace(/\[([^\]]*)\]\([^)]*\)/g, "$1").replace(/[*_`~=]+/g, "").trim(), from: line.from });
  }
  return out;
}

/** Characters of Chinese (and the like) and words of other scripts, as a word processor counts them. */
export function wordCount(text: string) {
  return (text.match(/[぀-ヿ㐀-鿿가-힯]|[^\s぀-ヿ㐀-鿿가-힯]+/g) ?? []).filter((w) => /[\p{L}\p{N}]/u.test(w)).length;
}
