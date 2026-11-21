import { useEffect, useRef } from "react";
import { Annotation, EditorSelection, EditorState, type Extension, type Range } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType, keymap, placeholder as placeholderText } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentLess, indentMore, insertTab } from "@codemirror/commands";
import { indentUnit, syntaxTree } from "@codemirror/language";
import { deleteMarkupBackward, insertNewlineContinueMarkup, markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { call } from "../rpc";
import { useStore } from "../store";

// The Markdown editor of notes and documents (MD-01), as on the Mac: headings, emphasis, code, links, quotes, lists, tasks,
// code blocks and rules show as they read, and only the lines being edited show their Markdown symbols. Return continues
// a list or quote (an empty item ends it), Tab / Shift+Tab nest list items, Ctrl+B / Ctrl+I / Ctrl+K make bold, italic
// and a link, and a task box ticks with a click.

// MARK: Live preview

const hide = Decoration.replace({});

class Bullet extends WidgetType {
  eq() { return true; }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-md-bullet";
    span.textContent = "•";
    return span;
  }
}

class TaskBox extends WidgetType {
  constructor(readonly done: boolean) { super(); }
  eq(other: TaskBox) { return other.done === this.done; }
  toDOM(view: EditorView) {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.className = "cm-md-task";
    box.checked = this.done;
    // Ticked where it is, without moving the caret there (which would show the line's symbols).
    box.addEventListener("mousedown", (e) => {
      e.preventDefault();
      const at = view.posAtDOM(box);
      const line = view.state.doc.lineAt(at);
      const mark = /\[([ xX])\]/.exec(line.text.slice(at - line.from));
      if (!mark) return;
      const pos = at + mark.index + 1;
      view.dispatch({ changes: { from: pos, to: pos + 1, insert: mark[1] === " " ? "x" : " " } });
    });
    return box;
  }
  ignoreEvent() { return true; }
}

class Rule extends WidgetType {
  eq() { return true; }
  toDOM() {
    const hr = document.createElement("span");
    hr.className = "cm-md-hr";
    return hr;
  }
}

function decorate(view: EditorView): DecorationSet {
  const { state } = view;
  const doc = state.doc;
  // The lines the caret or the selection is on show their symbols, while the editor has the keyboard.
  const active = new Set<number>();
  if (view.hasFocus) {
    for (const r of state.selection.ranges) {
      for (let n = doc.lineAt(r.from).number; n <= doc.lineAt(r.to).number; n++) active.add(n);
    }
  }
  const editing = (pos: number) => active.has(doc.lineAt(pos).number);
  const out: Range<Decoration>[] = [];
  const lineClass = (from: number, to: number, cls: string) => {
    for (let n = doc.lineAt(from).number; n <= doc.lineAt(to).number; n++) out.push(Decoration.line({ class: cls }).range(doc.line(n).from));
  };
  const hideWithSpace = (from: number, to: number) => {
    const next = doc.sliceString(to, to + 1);
    out.push(hide.range(from, next === " " || next === "\t" ? to + 1 : to));
  };
  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from, to,
      enter: (node) => {
        const name = node.name;
        const heading = /^ATXHeading(\d)$/.exec(name) ?? /^SetextHeading(\d)$/.exec(name);
        if (heading) { lineClass(node.from, node.to, `cm-md-h cm-md-h${heading[1]}`); return; }
        switch (name) {
          case "HeaderMark":
            if (!editing(node.from) && node.node.parent?.name.startsWith("ATX")) {
              if (node.from === doc.lineAt(node.from).from) hideWithSpace(node.from, node.to); else out.push(hide.range(node.from, node.to));
            }
            break;
          case "Emphasis": out.push(Decoration.mark({ class: "cm-md-em" }).range(node.from, node.to)); break;
          case "StrongEmphasis": out.push(Decoration.mark({ class: "cm-md-strong" }).range(node.from, node.to)); break;
          case "Strikethrough": out.push(Decoration.mark({ class: "cm-md-strike" }).range(node.from, node.to)); break;
          case "InlineCode": out.push(Decoration.mark({ class: "cm-md-code" }).range(node.from, node.to)); break;
          case "EmphasisMark": case "StrikethroughMark":
            if (!editing(node.from)) out.push(hide.range(node.from, node.to));
            break;
          case "CodeMark":
            if (node.node.parent?.name === "InlineCode") { if (!editing(node.from)) out.push(hide.range(node.from, node.to)); }
            else out.push(Decoration.mark({ class: "cm-md-fence" }).range(node.from, node.to));
            break;
          case "CodeInfo": out.push(Decoration.mark({ class: "cm-md-fence" }).range(node.from, node.to)); break;
          case "FencedCode": case "CodeBlock": lineClass(node.from, node.to, "cm-md-codeblock"); break;
          case "Link": {
            const link = node.node;
            const text = link.getChild("LinkMark");
            const close = link.getChildren("LinkMark")[1];
            if (text && close) out.push(Decoration.mark({ class: "cm-md-link" }).range(text.to, close.from));
            if (!editing(node.from)) {
              for (const part of link.getChildren("LinkMark")) out.push(hide.range(part.from, part.to));
              for (const part of [...link.getChildren("URL"), ...link.getChildren("LinkTitle")]) out.push(hide.range(part.from, part.to));
            }
            return false;
          }
          case "URL": out.push(Decoration.mark({ class: "cm-md-link" }).range(node.from, node.to)); break;
          case "Blockquote": lineClass(node.from, node.to, "cm-md-quote"); break;
          case "QuoteMark": if (!editing(node.from)) hideWithSpace(node.from, node.to); break;
          case "ListMark": {
            if (editing(node.from)) { out.push(Decoration.mark({ class: "cm-md-listmark" }).range(node.from, node.to)); break; }
            const item = node.node.parent;
            const task = item?.getChild("Task");
            if (task) hideWithSpace(node.from, node.to);
            else if (item?.parent?.name === "BulletList") out.push(Decoration.replace({ widget: new Bullet() }).range(node.from, node.to));
            else out.push(Decoration.mark({ class: "cm-md-listmark" }).range(node.from, node.to));
            break;
          }
          case "TaskMarker": {
            const done = /x/i.test(doc.sliceString(node.from, node.to));
            if (!editing(node.from)) {
              const next = doc.sliceString(node.to, node.to + 1);
              out.push(Decoration.replace({ widget: new TaskBox(done) }).range(node.from, node.to + (next === " " ? 1 : 0)));
            }
            if (done) {
              const line = doc.lineAt(node.from);
              if (node.to < line.to) out.push(Decoration.mark({ class: "cm-md-done" }).range(node.to, line.to));
            }
            break;
          }
          case "HorizontalRule":
            if (!editing(node.from)) out.push(Decoration.replace({ widget: new Rule() }).range(node.from, node.to));
            break;
        }
      },
    });
  }
  return Decoration.set(out, true);
}

const livePreview = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(view: EditorView) { this.decorations = decorate(view); }
  update(update: ViewUpdate) {
    if (update.docChanged || update.selectionSet || update.viewportChanged || update.focusChanged) this.decorations = decorate(update.view);
  }
}, { decorations: (v) => v.decorations });

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

const LIST_LINE = /^\s*([-*+]|\d{1,9}[.)])\s/;
/** Tab nests the list items the selection touches; elsewhere it types a tab. */
function tab(view: EditorView) {
  const { state } = view;
  const lines = state.selection.ranges.flatMap((r) => [state.doc.lineAt(r.from), state.doc.lineAt(r.to)]);
  return lines.every((l) => LIST_LINE.test(l.text)) ? indentMore(view) : insertTab(view);
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

const LIST_PREFIX = /^([ \t]*)(?:[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d{1,9}[.)][ \t]+)/;

/** What the document toolbar does to the editor. */
export const format = {
  /** 标题 1–3 for the lines touched; the same level again (or 0) makes them plain text. */
  heading(view: EditorView, level: number) {
    const { from, to, lines } = selectedLines(view);
    const marker = "#".repeat(level) + " ";
    const all = level > 0 && lines.every((l) => l.startsWith(marker));
    replaceLines(view, from, to, lines.map((l) => { const body = l.replace(/^#{1,6}[ \t]+/, ""); return all || level === 0 ? body : marker + body; }));
  },
  wrap(view: EditorView, marker: string) { wrap(marker)(view); view.focus(); },
  link(view: EditorView) { link(view); view.focus(); },
  /** A list, a task list or a quote for the lines touched (plain lines again when they all are one already). */
  lines(view: EditorView, style: "bullet" | "numbered" | "task" | "quote") {
    const { from, to, lines } = selectedLines(view);
    const already = lines.every((l) => style === "bullet" ? /^[ \t]*[-*+][ \t]+(?!\[[ xX]\])/.test(l)
      : style === "numbered" ? /^[ \t]*\d{1,9}[.)][ \t]+/.test(l)
      : style === "task" ? /^[ \t]*[-*+][ \t]+\[[ xX]\]/.test(l) : /^[ \t]*>/.test(l));
    let n = 0;
    replaceLines(view, from, to, lines.map((l) => {
      if (style === "quote") { const body = l.replace(/^[ \t]*>[ \t]?/, ""); return already ? body : "> " + body; }
      const body = l.replace(LIST_PREFIX, "$1");
      if (already) return body;
      const indent = /^[ \t]*/.exec(body)![0], text = body.slice(indent.length);
      n++;
      return indent + (style === "bullet" ? "- " : style === "numbered" ? `${n}. ` : "- [ ] ") + text;
    }));
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

function extensions(placeholder: string, onChange: () => void, onBlur: () => void): Extension {
  return [
    history(),
    indentUnit.of("  "),
    EditorView.lineWrapping,
    markdown({ base: markdownLanguage, addKeymap: false }),
    livePreview,
    placeholderText(placeholder),
    keymap.of([
      { key: "Enter", run: insertNewlineContinueMarkup },
      { key: "Backspace", run: deleteMarkupBackward },
      { key: "Tab", run: tab, shift: indentLess },
      { key: "Mod-b", run: wrap("**") },
      { key: "Mod-i", run: wrap("*") },
      { key: "Mod-k", run: link },
      ...historyKeymap,
      ...defaultKeymap,
    ]),
    EditorView.updateListener.of((u) => { if (u.docChanged && !u.transactions.some((tr) => tr.annotation(loading))) onChange(); }),
    EditorView.domEventHandlers({ blur: () => { onBlur(); return false; } }),
    // Links open in the browser with Ctrl+click.
    EditorView.domEventHandlers({
      click: (e, view) => {
        if (!e.ctrlKey) return false;
        const at = view.posAtCoords({ x: e.clientX, y: e.clientY });
        if (at == null) return false;
        const line = view.state.doc.lineAt(at);
        const url = /https?:\/\/[^\s)>\]]+/.exec(line.text);
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
export function MarkdownEditor({ source, placeholder, inputRef, viewRef, focus, className }: {
  source: MarkdownSource; placeholder: string; inputRef?: React.MutableRefObject<{ focus: () => void } | null>;
  viewRef?: React.MutableRefObject<EditorView | null>; focus?: boolean; className?: string;
}) {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<EditorView | null>(null);
  const saved = useRef("");
  const shown = useRef<MarkdownSource | null>(null);
  const timer = useRef(0);
  const version = useStore((s) => s.libraryVersion);

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
    v.setState(EditorState.create({ doc: value, extensions: extensions(placeholder, schedule, flush) }));
  };

  useEffect(() => {
    const v = new EditorView({ parent: host.current!, state: EditorState.create({ doc: "", extensions: extensions(placeholder, schedule, flush) }) });
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

  return <div ref={host} className={`md-editor${className ? " " + className : ""}`} onKeyDown={(e) => e.stopPropagation()} />;
}
