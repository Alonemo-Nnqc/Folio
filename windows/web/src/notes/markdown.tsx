import { useEffect, useRef } from "react";
import { Annotation, EditorSelection, EditorState, type Extension, Prec, type Range, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType, keymap, placeholder as placeholderText } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { indentUnit, syntaxTree } from "@codemirror/language";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { t } from "../i18n";
import { call } from "../rpc";
import { openMenuAt, sep, type MenuEntry } from "../ui/menu";
import { useStore } from "../store";
import { blockGutter, moveCaretBlock, setStyle, slashMenu, styleAt } from "./blocks";
import { codeTools, tokenClass } from "./code";
import { appendLine, backspace, deleteLines, selectedBlock, caretRules, completeSymbols, ctrlEnter, deleteForward, down, endsInBlock, enter, lineBreak, pasteLink, selectAll, tab, toggleTask } from "./edit";
import { codeAt, codeLanguage, codeText, infoAt, isEmpty, isList, levelOf, lineInfo, structureField, tableAt, type Code } from "./lines";
import { md, mdOf, sizeKey, stepZoom, wheelZoom, zoomKey } from "./prefs";
import { focusTable, markSelected, TableWidget, wrapCell } from "./table";

// The Markdown editor of notes and documents (MD-01), as on the Mac: headings, emphasis, code, links, quotes, lists, tasks,
// code blocks, tables and rules show as they read and are edited so; only symbols inside a line show, while the caret is at
// what they mark. Return continues a list or quote (an empty item ends it), Tab / Shift+Tab nest list items, Ctrl+B /
// Ctrl+I / Ctrl+K make bold, italic and a link, and a task box ticks with a click.

// MARK: Live preview

const hide = Decoration.replace({});

/** What stands before a line's text instead of its symbols: a bullet, a number, a task's box, or nothing. */
class Mark extends WidgetType {
  constructor(readonly kind: "none" | "bullet" | "number" | "task", readonly text: string, readonly done: boolean, readonly placeholder: string) { super(); }
  eq(o: Mark) { return o.kind === this.kind && o.text === this.text && o.done === this.done && o.placeholder === this.placeholder; }
  toDOM(view: EditorView) {
    const span = document.createElement("span");
    span.className = "cm-md-mark-box";
    if (this.kind === "bullet") { const dot = document.createElement("i"); dot.className = `cm-md-dot level${Number(this.text) % 3}`; span.append(dot); }
    if (this.kind === "number") { span.classList.add("number"); span.textContent = this.text; }
    if (this.kind === "task") {
      const box = document.createElement("span");
      box.className = `cm-md-task${this.done ? " done" : ""}`;
      box.setAttribute("role", "checkbox");
      box.setAttribute("aria-checked", String(this.done));
      // Ticked where it is, without moving the caret there.
      box.addEventListener("mousedown", (e) => {
        e.preventDefault();
        toggleTask(view, infoAt(view.state.doc, view.posAtDOM(span)));
      });
      span.append(box);
    }
    if (this.placeholder) span.dataset.placeholder = this.placeholder;
    if (this.kind === "none") span.classList.add("bare");
    return span;
  }
  ignoreEvent() { return this.kind === "task"; }
}

class Rule extends WidgetType {
  eq() { return true; }
  toDOM() {
    const hr = document.createElement("span");
    hr.className = "cm-md-hr";
    return hr;
  }
}

/** Names the language of a code block in its fence ("": found from the code). */
export function setLanguage(view: EditorView, code: Code, language: string) {
  const line = view.state.doc.sliceString(code.from, code.openTo), fence = /^\s*(`{3,}|~{3,})/.exec(line);
  if (fence) view.dispatch({ changes: { from: code.from + fence[0].length, to: code.openTo, insert: language }, userEvent: "input" });
}

export function languageMenu(view: EditorView, code: Code): MenuEntry[] {
  const { doc } = view.state, { id, detected } = codeLanguage(code, doc), body = codeText(code, doc);
  const found = codeTools.detect(doc.sliceString(body.from, body.to));
  return [
    { label: found ? t("自动检测（%@）", codeTools.names[found] ?? found) : t("自动检测"), checked: detected, action: () => setLanguage(view, code, "") },
    sep,
    ...codeTools.languages.map(([key, title]): MenuEntry => ({ label: key === "plaintext" ? t("纯文本") : title, checked: !detected && id === key, action: () => setLanguage(view, code, key) })),
  ];
}

/** The top of a code block: its language, chosen from a menu (or found from the code), and a button that copies it. */
class CodeHeader extends WidgetType {
  constructor(readonly title: string) { super(); }
  eq(o: CodeHeader) { return o.title === this.title; }
  get estimatedHeight() { return 36; }
  toDOM(view: EditorView) {
    const dom = document.createElement("div");
    dom.className = "md-code-head";
    const language = document.createElement("button"), copy = document.createElement("button");
    language.className = "language";
    language.title = t("语言");
    language.innerHTML = '<span></span><svg width="9" height="9" viewBox="0 0 9 9" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M1.5 3l3 3 3-3"/></svg>';
    language.querySelector("span")!.textContent = this.title;
    copy.className = "copy";
    copy.title = t("拷贝代码");
    copy.setAttribute("aria-label", copy.title);
    const icon = '<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"><rect x="4.5" y="4.5" width="7.5" height="8" rx="1.6"/><path d="M9.5 4.5V3.1A1.6 1.6 0 0 0 7.9 1.5H3.6A1.6 1.6 0 0 0 2 3.1v5.3A1.6 1.6 0 0 0 3.6 10h.9"/></svg>';
    copy.innerHTML = icon;
    const code = () => codeAt(view.state, view.posAtDOM(dom));
    language.addEventListener("click", () => { const c = code(); if (c) openMenuAt(language, languageMenu(view, c)); });
    copy.addEventListener("click", () => {
      const c = code();
      if (!c) return;
      const body = codeText(c, view.state.doc);
      navigator.clipboard.writeText(view.state.doc.sliceString(body.from, body.to));
      copy.innerHTML = '<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7.5l2.8 2.8L11 4.5"/></svg>';
      setTimeout(() => { copy.innerHTML = icon; }, 1400);
    });
    dom.addEventListener("mousedown", (e) => {
      e.preventDefault();
      const c = code();
      // Between the buttons it is the block's: a click puts the caret on its first line.
      if (c && e.target === dom) { view.focus(); view.dispatch({ selection: EditorSelection.cursor(codeText(c, view.state.doc).from) }); }
    });
    dom.append(language, copy);
    return dom;
  }
  updateDOM(dom: HTMLElement) {
    dom.querySelector(".language span")!.textContent = this.title;
    return true;
  }
  ignoreEvent() { return true; }
}

class CodeFoot extends WidgetType {
  eq() { return true; }
  get estimatedHeight() { return 14; }
  toDOM() { const dom = document.createElement("div"); dom.className = "md-code-foot"; return dom; }
}

/** Lines as they read: what their symbols mean instead of the symbols, code blocks with their header, tables. */
function blocks(state: EditorState): DecorationSet {
  const { doc } = state, { codes, tables } = state.field(structureField);
  const main = state.selection.main, caretLine = main.empty ? doc.lineAt(main.head).number : 0;
  const out: Range<Decoration>[] = [];
  let code = 0, table = 0;
  for (let n = 1; n <= doc.lines; n++) {
    while (code < codes.length && codes[code].last < n) code++;
    while (table < tables.length && tables[table].last < n) table++;
    const c = codes[code], tb = tables[table];
    if (tb && n === tb.first) {
      out.push(Decoration.replace({ widget: new TableWidget(tb.data), block: true }).range(tb.from, tb.to));
      n = tb.last;
      continue;
    }
    if (c && n >= c.first) {
      const language = codeLanguage(c, doc);
      const title = language.id ? codeTools.names[language.id] ?? language.id : c.info || t("自动检测");
      const closed = c.closeFrom != null;
      if (closed) out.push(Decoration.replace({ widget: new CodeHeader(language.id === "plaintext" ? t("纯文本") : title), block: true }).range(c.from, c.openTo));
      else out.push(Decoration.line({ class: "cm-md-codeblock cm-md-fence" }).range(c.from));
      const end = closed ? c.last - 1 : c.last;
      for (let k = c.first + 1; k <= end; k++) out.push(Decoration.line({ class: "cm-md-codeblock", attributes: { spellcheck: "false" } }).range(doc.line(k).from));
      const body = codeText(c, doc);
      if (language.id && body.to > body.from && md("markdownHighlightsCode")) {
        const tokens = codeTools.tokens(doc.sliceString(body.from, body.to), language.id);
        for (let i = 0; i + 2 < tokens.length; i += 3) {
          const cls = tokenClass(tokens[i + 2] as string), from = body.from + (tokens[i] as number), to = Math.min(body.from + (tokens[i + 1] as number), doc.length);
          if (cls && to > from) out.push(Decoration.mark({ class: cls }).range(from, to));
        }
      }
      if (closed) out.push(Decoration.replace({ widget: new CodeFoot(), block: true }).range(c.closeFrom!, c.to));
      n = c.last;
      continue;
    }
    const line = lineInfo(doc, n);
    if (line.kind === "rule") {
      if (n !== caretLine) out.push(Decoration.replace({ widget: new Rule() }).range(line.from, line.to));
      continue;
    }
    if (line.textStart === line.from) continue;
    const classes = [], styles = [];
    let step = 0, kind: Mark["kind"] = "none", text = "", hint = line.quoteDepth ? t("引用块") : "";
    if (line.quoteDepth) { classes.push("cm-md-quote"); styles.push(`--depth: ${line.quoteDepth}`); }
    if (line.kind === "heading") { classes.push(`cm-md-h cm-md-h${line.value}`); hint = t("标题 %lld", line.value); }
    if (isList(line) || line.kind === "continuation") {
      const level = levelOf(doc, line);
      step = level + 1;
      classes.push("cm-md-item");
      if (line.kind === "bullet") { kind = "bullet"; text = String(level); hint = t("列表"); }
      if (line.kind === "numbered") { kind = "number"; text = doc.sliceString(line.markerFrom, line.markerTo); hint = t("列表"); }
      if (line.kind === "task") { kind = "task"; hint = t("待办事项"); }
    }
    styles.push(`--step: ${step}`);
    out.push(Decoration.line({ class: classes.join(" ") + " cm-md-block", attributes: { style: styles.join(";") } }).range(line.from));
    out.push(Decoration.replace({ widget: new Mark(kind, text, line.done, isEmpty(line) && n === caretLine ? hint : "") }).range(line.from, line.textStart));
    if (line.done && line.textStart < line.to) out.push(Decoration.mark({ class: "cm-md-done" }).range(line.textStart, line.to));
  }
  return Decoration.set(out, true);
}

const blockField = StateField.define<DecorationSet>({
  create: blocks,
  update(value, tr) {
    const line = (s: EditorState) => (s.selection.main.empty ? s.doc.lineAt(s.selection.main.head).number : 0);
    return tr.docChanged || (tr.selection && line(tr.startState) !== line(tr.state)) ? blocks(tr.state) : value;
  },
  provide: (f) => EditorView.decorations.from(f),
});

/** What is in a line: its symbols show while the caret is at what they mark. */
function decorate(view: EditorView): DecorationSet {
  const { state } = view, { doc } = state, { codes, tables } = state.field(structureField);
  const main = state.selection.main, focused = view.hasFocus && doc.lineAt(main.from).number === doc.lineAt(main.to).number;
  const at = (from: number, to: number) => focused && main.from <= to && main.to >= from;
  const inBlock = (pos: number) => codes.some((c) => pos >= c.from && pos <= c.to) || tables.some((x) => pos >= x.from && pos <= x.to);
  const out: Range<Decoration>[] = [];
  // Only within a line, and never into a table or a code block: a decoration across their edges breaks the editor.
  const oneLine = (from: number, to: number) => to <= doc.lineAt(from).to && !inBlock(from);
  const replace = (from: number, to: number) => { if (to > from && oneLine(from, to)) out.push(hide.range(from, to)); };
  const mark = (cls: string, from: number, to: number) => {
    for (let at = from; at < to;) {
      const line = doc.lineAt(at), end = Math.min(line.to, to);
      if (end > at && !inBlock(at)) out.push(Decoration.mark({ class: cls }).range(at, end));
      at = line.to + 1;
    }
  };
  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from, to,
      enter: (node) => {
        const name = node.name;
        if (name === "FencedCode" || name === "CodeBlock" || name === "Table") return false;
        const parent = node.node.parent;
        const cls = { Emphasis: "cm-md-em", StrongEmphasis: "cm-md-strong", Strikethrough: "cm-md-strike", InlineCode: "cm-md-code" }[name];
        if (cls) {
          const inner = node.node.getChildren(name === "InlineCode" ? "CodeMark" : name === "Strikethrough" ? "StrikethroughMark" : "EmphasisMark");
          mark(cls, inner[0]?.to ?? node.from, inner[inner.length - 1]?.from ?? node.to);
          return;
        }
        if (name === "EmphasisMark" || name === "StrikethroughMark" || (name === "CodeMark" && parent?.name === "InlineCode")) {
          if (at(parent!.from, parent!.to)) mark("cm-md-fence", node.from, node.to); else replace(node.from, node.to);
          return;
        }
        if (name === "Link" || name === "Image") {
          const marks = node.node.getChildren("LinkMark");
          if (marks.length < 2) return;
          mark("cm-md-link", marks[0].to, marks[1].from);
          if (at(node.from, node.to) || !oneLine(node.from, node.to)) mark("cm-md-fence", marks[1].from, node.to);
          else { replace(marks[0].from, marks[0].to); replace(marks[1].from, node.to); }
          return false;
        }
        if (name === "URL") mark("cm-md-link", node.from, node.to);
      },
    });
  }
  // ==highlights==, which Markdown's own grammar does not have.
  for (const { from, to } of view.visibleRanges) {
    for (let n = doc.lineAt(from).number; n <= doc.lineAt(to).number; n++) {
      const line = doc.line(n);
      if (!line.text.includes("==") || inBlock(line.from)) continue;
      for (const m of line.text.matchAll(/==(?=\S)(.+?)(?<=\S)==/g)) {
        const start = line.from + m.index!, end = start + m[0].length;
        if (/Code/.test(syntaxTree(state).resolveInner(start + 1, 1).name)) continue;
        out.push(Decoration.mark({ class: "cm-md-mark" }).range(start + 2, end - 2));
        const shown = at(start, end);
        for (const [a, b] of [[start, start + 2], [end - 2, end]]) out.push(shown ? Decoration.mark({ class: "cm-md-fence" }).range(a, b) : hide.range(a, b));
      }
    }
  }
  return Decoration.set(out, true);
}

const livePreview: Extension = [
  structureField,
  blockField,
  ViewPlugin.fromClass(class {
    decorations: DecorationSet;
    constructor(view: EditorView) { this.decorations = decorate(view); }
    update(update: ViewUpdate) {
      if (update.docChanged || update.selectionSet || update.viewportChanged || update.focusChanged) this.decorations = decorate(update.view);
      if (update.selectionSet || update.docChanged || update.viewportChanged) { const { view } = update; queueMicrotask(() => markSelected(view)); }
      // The caret that comes to a table goes on in its cells.
      if ((update.selectionSet || update.docChanged) && update.view.hasFocus) {
        const main = update.state.selection.main, table = main.empty && tableAt(update.state, main.head);
        if (table) {
          const before = update.startState.selection.main.head, { view } = update;
          queueMicrotask(() => {
            const now = view.state.selection.main;
            if (view.hasFocus && now.empty && now.head === main.head) focusTable(view, now.head, before > table.to || now.head > table.from + 1);
          });
        }
      }
      if (update.transactions.some((tr) => tr.isUserEvent("input.type")) && update.docChanged && !update.view.composing) {
        const head = update.state.selection.main.head, typed = update.state.doc.sliceString(head - 1, head);
        if (typed === " " || typed === "　") { const { view } = update; queueMicrotask(() => { if (view.state.selection.main.head === head) completeSymbols(view); }); }
      }
    }
  }, { decorations: (v) => v.decorations }),
];

// MARK: Keys

/** Wraps the selection in marker (or unwraps it); with nothing selected, puts the caret between a pair. */
function wrap(marker: string) {
  return (view: EditorView) => {
    const m = marker.length;
    view.dispatch(view.state.changeByRange((range) => {
      const doc = view.state.doc;
      const text = doc.sliceString(range.from, range.to);
      if (text.length >= 2 * m && text.startsWith(marker) && text.endsWith(marker)) {
        return { changes: { from: range.from, to: range.to, insert: text.slice(m, -m) }, range: EditorSelection.range(range.from, range.to - 2 * m) };
      }
      if (doc.sliceString(range.from - m, range.from) === marker && doc.sliceString(range.to, range.to + m) === marker) {
        return { changes: [{ from: range.from - m, to: range.from }, { from: range.to, to: range.to + m }], range: EditorSelection.range(range.from - m, range.to - m) };
      }
      return { changes: [{ from: range.from, insert: marker }, { from: range.to, insert: marker }], range: EditorSelection.range(range.from + m, range.to + m) };
    }));
    return true;
  };
}

function link(view: EditorView) {
  view.dispatch(view.state.changeByRange((range) => {
    const text = view.state.doc.sliceString(range.from, range.to);
    const insert = `[${text}](https://)`;
    const selection = text ? EditorSelection.range(range.from + text.length + 3, range.from + text.length + 11) : EditorSelection.cursor(range.from + 1);
    return { changes: { from: range.from, to: range.to, insert }, range: selection };
  }));
  return true;
}

// MARK: Formatting (the document toolbar)

/** The lines the selection touches. */
function selectedLines(view: EditorView) {
  const { state } = view;
  const first = state.doc.lineAt(state.selection.main.from), last = state.doc.lineAt(state.selection.main.to);
  const lines: string[] = [];
  for (let n = first.number; n <= last.number; n++) lines.push(state.doc.line(n).text);
  return { from: first.from, to: last.to, lines };
}

function replaceLines(view: EditorView, from: number, to: number, lines: string[]) {
  const insert = lines.join("\n");
  view.dispatch({ changes: { from, to, insert }, selection: EditorSelection.cursor(from + insert.length), scrollIntoView: true });
  view.focus();
}

/** What the document toolbar does to the editor. */
export const format = {
  wrap(view: EditorView, marker: string) { if (wrapCell(view, marker)) return; wrap(marker)(view); view.focus(); },
  link(view: EditorView) { link(view); view.focus(); },
  /** A list, a task list or a quote for the lines touched (plain lines again when they all are one already). */
  lines(view: EditorView, style: "bullet" | "numbered" | "task" | "quote") {
    const { state } = view, first = state.doc.lineAt(state.selection.main.from).number, last = state.doc.lineAt(state.selection.main.to).number;
    let already = true;
    for (let n = first; n <= last; n++) if (styleAt(view, state.doc.line(n).from) !== style) already = false;
    if (already && style === "quote") {
      const { from, to, lines } = selectedLines(view);
      replaceLines(view, from, to, lines.map((l) => l.replace(/^[ \t]*>[ \t]?/, "")));
    } else setStyle(view, already ? "text" : style);
  },
  /** A block (a code block, a table, a rule) on lines of its own after the caret's line; caret offset inside it. */
  block(view: EditorView, block: string, caret?: number) {
    const { state } = view;
    const line = state.doc.lineAt(state.selection.main.head);
    const empty = !line.text.trim();
    const insert = (empty ? "" : "\n\n") + block + "\n";
    const at = empty ? line.from : line.to;
    const start = at + (empty ? 0 : 2);
    view.dispatch({ changes: { from: at, to: empty ? line.to : at, insert }, selection: EditorSelection.cursor(caret != null ? start + caret : at + insert.length), scrollIntoView: true });
    view.focus();
  },
  codeBlock(view: EditorView) {
    if (view.state.selection.main.empty) { format.block(view, "```\n\n```", 4); return; }
    const { from, to, lines } = selectedLines(view);
    replaceLines(view, from, to, ["```", ...lines, "```"]);
  },
};

// MARK: Editor

const loading = Annotation.define<boolean>();

/** Not over what is being composed with an input method: the hints of an empty line go as it begins. */
const composing = EditorView.domEventHandlers({
  compositionstart: (_e, view) => { view.dom.classList.add("composing"); return false; },
  compositionend: (_e, view) => { view.dom.classList.remove("composing"); return false; },
  blur: (_e, view) => { view.dom.classList.remove("composing"); return false; },
});

const zoom = (panel: boolean, by: 1 | -1 | 0) => (view: EditorView) => { stepZoom(view, by, panel); return true; };

function extensions(placeholder: string, gutter: boolean, readOnly: boolean, panel: boolean, onChange: () => void, onBlur: () => void, onUpdate: (view: EditorView) => void): Extension {
  return [
    readOnly ? [EditorState.readOnly.of(true), EditorView.editable.of(false), EditorState.changeFilter.of(() => false)] : [],
    composing,
    EditorView.contentAttributes.of(() => ({ spellcheck: String(md("markdownChecksSpelling")) })),
    slashMenu,
    gutter ? blockGutter : [],
    EditorView.updateListener.of((u) => { if (u.docChanged || u.selectionSet) onUpdate(u.view); }),
    history(),
    indentUnit.of("  "),
    EditorView.lineWrapping,
    markdown({ base: markdownLanguage, addKeymap: false }),
    livePreview,
    caretRules,
    Prec.high(EditorView.domEventHandlers({
      paste: pasteLink,
      // A table or code block selected whole is cut whole.
      cut: (e, view) => {
        const block = selectedBlock(view.state);
        if (!block) return false;
        e.preventDefault();
        e.clipboardData?.setData("text/plain", view.state.doc.sliceString(block.from, block.to));
        deleteLines(view, block.from, block.to);
        return true;
      },
      // Below a document that ends in a table or a code block there is nowhere to write: a line is added.
      mousedown: (e, view) => {
        if (e.button !== 0 || !endsInBlock(view.state) || (e.target as HTMLElement).closest(".md-table, .md-code-head")) return false;
        if (e.clientY <= view.documentTop + view.contentHeight - 24) return false;
        e.preventDefault();
        appendLine(view);
        return true;
      },
    })),
    placeholderText(placeholder),
    keymap.of([
      { key: "Enter", run: enter, shift: lineBreak },
      { key: "Mod-Enter", run: ctrlEnter },
      { key: "Backspace", run: backspace },
      { key: "Delete", run: deleteForward },
      { key: "Tab", run: tab(1), shift: tab(-1) },
      { key: "ArrowDown", run: down },
      { key: "Mod-a", run: selectAll },
      { key: "Mod-b", run: wrap("**") },
      { key: "Mod-i", run: wrap("*") },
      { key: "Mod-k", run: link },
      { key: "Mod-=", run: zoom(panel, 1) }, { key: "Mod-+", run: zoom(panel, 1) }, { key: "Mod--", run: zoom(panel, -1) }, { key: "Mod-0", run: zoom(panel, 0) },
      { key: "Alt-ArrowUp", run: moveCaretBlock(-1) },
      { key: "Alt-ArrowDown", run: moveCaretBlock(1) },
      ...historyKeymap,
      ...defaultKeymap,
    ]),
    EditorView.updateListener.of((u) => { if (u.docChanged && !u.transactions.some((tr) => tr.annotation(loading))) onChange(); }),
    EditorView.domEventHandlers({ blur: () => { onBlur(); return false; } }),
    // Links open in the browser with Ctrl+click.
    EditorView.domEventHandlers({
      click: (e, view) => {
        if (!e.ctrlKey && !readOnly) return false;
        if (readOnly && !(e.target as HTMLElement).closest(".cm-md-link")) return false;
        const at = view.posAtCoords({ x: e.clientX, y: e.clientY });
        if (at == null) return false;
        const line = view.state.doc.lineAt(at);
        const url = [...line.text.matchAll(/(?:https?|folio):\/\/[^\s)>\]]+/g)].sort((a, b) => Math.abs(a.index! - (at - line.from)) - Math.abs(b.index! - (at - line.from)))[0];
        if (url) { call("shell.open", { target: url[0] }); return true; }
        return false;
      },
    }),
  ];
}

export interface MarkdownSource {
  /** What is being edited ("note:<item>", "file:<file>"): another key loads afresh. */
  key: string | null;
  load: () => Promise<string>;
  save: (text: string) => void;
}

/** The live Markdown editor on a note or a .md file. Saved a moment after typing stops (not while a word is being
 *  composed with an input method); when someone else changes the text, what is being typed here is not overwritten. */
export function MarkdownEditor({ source, placeholder, inputRef, viewRef, focus, className, gutter = false, readOnly = false, panel = false, onUpdate }: {
  /** In a side panel: the text has the size of 侧栏字号. */
  panel?: boolean;
  /** Only to be read (快速预览): no caret, nothing changes, links open with a click. */
  readOnly?: boolean;
  /** Handles beside the line under the pointer; told of every change of the text or the caret. */
  gutter?: boolean; onUpdate?: (view: EditorView) => void;
  source: MarkdownSource; placeholder: string; inputRef?: React.MutableRefObject<{ focus: () => void } | null>;
  viewRef?: React.MutableRefObject<EditorView | null>; focus?: boolean; className?: string;
}) {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<EditorView | null>(null);
  const saved = useRef("");
  const shown = useRef<MarkdownSource | null>(null);
  const timer = useRef(0);
  const version = useStore((s) => s.libraryVersion);

  // Another size or spacing: what is in sight stays there. Another way of showing code or checking spelling: set anew.
  const look = useStore((s) => JSON.stringify([mdOf(s.settings, sizeKey(panel)), mdOf(s.settings, "markdownLineHeight"), mdOf(s.settings, "markdownParagraphSpacing"), mdOf(s.settings, "markdownTypeface"), mdOf(s.settings, "markdownHeadingScale"), mdOf(s.settings, "markdownCodeScale"), mdOf(s.settings, "markdownReadableWidth"), mdOf(s.settings, zoomKey(panel))]));
  const parts = useStore((s) => `${mdOf(s.settings, "markdownHighlightsCode")}${mdOf(s.settings, "markdownChecksSpelling")}`);
  useEffect(() => { view.current?.requestMeasure(); }, [look]);
  // Pinching, or Ctrl + the wheel, anywhere on the page.
  useEffect(() => {
    if (readOnly) return;
    const area = host.current!.closest<HTMLElement>(".md-tab-body") ?? host.current!;
    const zoomed = wheelZoom(() => view.current, panel);
    area.addEventListener("wheel", zoomed, { passive: false });
    return () => area.removeEventListener("wheel", zoomed);
  }, []);
  const firstParts = useRef(parts);
  useEffect(() => {
    const v = view.current;
    if (!v || parts === firstParts.current) return;
    firstParts.current = parts;
    const { selection } = v.state, value = v.state.doc.toString();
    v.setState(EditorState.create({ doc: value, selection, extensions: extensions(placeholder, gutter, readOnly, panel, schedule, flush, (x) => updated.current?.(x)) }));
  }, [parts]);

  const updated = useRef(onUpdate);
  updated.current = onUpdate;

  const text = () => view.current?.state.doc.toString() ?? "";
  const flush = () => {
    clearTimeout(timer.current);
    const current = shown.current;
    if (!current?.key || !view.current) return;
    const value = text();
    if (value !== saved.current) {
      saved.current = value;
      current.save(value);
    }
  };
  const schedule = () => {
    clearTimeout(timer.current);
    timer.current = window.setTimeout(function save() {
      if (view.current?.composing) { timer.current = window.setTimeout(save, 400); return; }
      flush();
    }, 700);
  };
  const show = (value: string) => {
    const v = view.current;
    if (!v) return;
    // A fresh state: the undo history belongs to the text it was typed in.
    v.setState(EditorState.create({ doc: value, extensions: extensions(placeholder, gutter, readOnly, panel, schedule, flush, (v) => updated.current?.(v)) }));
    updated.current?.(v);
  };

  useEffect(() => {
    const v = new EditorView({ parent: host.current!, state: EditorState.create({ doc: "", extensions: extensions(placeholder, gutter, readOnly, panel, schedule, flush, (v) => updated.current?.(v)) }) });
    view.current = v;
    if (inputRef) inputRef.current = { focus: () => v.focus() };
    if (viewRef) viewRef.current = v;
    return () => { flush(); v.destroy(); view.current = null; if (viewRef) viewRef.current = null; };
  }, []);

  useEffect(() => {
    flush();
    shown.current = source;
    if (!source.key) { saved.current = ""; show(""); return; }
    let live = true;
    source.load().then((value) => {
      if (!live) return;
      saved.current = value;
      show(value);
      if (focus) requestAnimationFrame(() => {
        const v = view.current;
        if (!v) return;
        v.focus();
        v.dispatch({ selection: EditorSelection.cursor(v.state.doc.length), annotations: loading.of(true) });
      });
    });
    return () => { live = false; };
  }, [source.key]);

  // Someone else changed it (a reader tab, an agent): reloaded unless it is being typed in here.
  useEffect(() => {
    const v = view.current;
    if (!source.key || !v || v.hasFocus || text() !== saved.current) return;
    source.load().then((value) => {
      if (value !== saved.current && !view.current?.hasFocus) { saved.current = value; show(value); }
    });
  }, [version]);

  return <div ref={host} className={`md-editor${readOnly ? " read-only" : ""}${panel ? " in-panel" : ""}${className ? " " + className : ""}`} onKeyDown={(e) => e.stopPropagation()} />;
}
