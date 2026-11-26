import { EditorSelection, EditorState, type ChangeSpec, type Extension, type Text } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { deleteCharBackward, deleteCharForward, insertNewlineAndIndent } from "@codemirror/commands";
import { md } from "./prefs";
import { childIndent, codeAt, codeText, columns, infoAt, isEmpty, isList, levelOf, lineInfo, structureOf, tableAt, type Code, type LineInfo } from "./lines";

// Editing a document whose symbols are not shown, as on the Mac (MarkdownLiveEditor.swift).

// MARK: Where the caret can be

/** The symbols at the start of a line, the fences of a code block and a rule are not shown: the caret passes them. */
function snap(state: EditorState, proposed: number, old: number): number {
  let at = proposed;
  for (let k = 0; k < 4; k++) {
    const next = step(state, at, old);
    if (next === at) break;
    at = next;
  }
  return at;
}

function step(state: EditorState, at: number, old: number): number {
  const { doc } = state, forward = at >= old;
  const code = codeAt(state, at);
  if (code) {
    if (code.closeFrom == null) return at;
    const body = codeText(code, doc);
    if (at <= code.openTo) return !forward && code.from > 0 ? code.from - 1 : body.from;
    if (at >= code.closeFrom) return forward && code.to < doc.length && !(old >= code.closeFrom && old <= code.to) ? code.to + 1 : body.to;
    return at;
  }
  if (tableAt(state, at)) return at;
  const line = infoAt(doc, at);
  if (line.kind === "rule") {
    if (old >= line.from && old <= line.to) return at;
    if (forward && line.to < doc.length) return line.to + 1;
    return !forward && line.from > 0 ? line.from - 1 : at;
  }
  if (at >= line.textStart) return at;
  if (old === line.textStart && at === old - 1) return line.from > 0 ? line.from - 1 : line.textStart;
  return line.textStart;
}

/** A selection takes tables whole, and code blocks it does not lie inside of; made smaller, it leaves them whole. It never
 *  begins or ends among the symbols of a line. */
function wholeBlocks(state: EditorState, from: number, to: number, old: { from: number; to: number }): [number, number] {
  const shrinks = old.to - old.from > to - from && from >= old.from && to <= old.to, { codes, tables } = structureOf(state);
  const take = (a: number, b: number) => {
    if (from >= b || to <= a || (from <= a && to >= b)) return;
    if (shrinks && from < a) to = a;
    else if (shrinks && to > b) from = b;
    else { from = Math.min(from, a); to = Math.max(to, b); }
  };
  for (const t of tables) take(t.from, t.to);
  for (const c of codes) {
    if (c.closeFrom == null) continue;
    const body = codeText(c, state.doc);
    if (from >= body.from && to <= body.to) continue;
    take(c.from, c.to);
  }
  const symbols = (at: number) => {
    if (codeAt(state, at) || tableAt(state, at)) return null;
    const line = infoAt(state.doc, at);
    return at > line.from && at < line.textStart ? line : null;
  };
  const a = symbols(from), b = symbols(to);
  if (a) from = a.textStart;
  if (b) to = shrinks ? b.from : b.textStart;
  return [from, Math.max(from, to)];
}

function allowed(state: EditorState, range: { anchor: number; head: number; from: number; to: number; empty: boolean }, old: { head: number; from: number; to: number }) {
  if (range.empty) {
    const at = snap(state, range.head, old.head);
    return at === range.head ? null : EditorSelection.cursor(at);
  }
  const [from, to] = wholeBlocks(state, range.from, range.to, old);
  if (from === range.from && to === range.to) return null;
  return range.head < range.anchor ? EditorSelection.range(to, from) : EditorSelection.range(from, to);
}

/** The table or code block that is selected, and nothing else. */
export function selectedBlock(state: EditorState): { from: number; to: number } | null {
  const { from, to, empty } = state.selection.main, s = structureOf(state);
  if (empty) return null;
  return [...s.tables, ...s.codes.filter((c) => c.closeFrom != null)].find((b) => b.from === from && (b.to === to || b.to + 1 === to)) ?? null;
}

/** Selects a table or code block, to be deleted, copied or moved as one. */
export function selectBlock(view: EditorView, block: { from: number; to: number }) {
  view.focus();
  view.dispatch({ selection: EditorSelection.range(block.from, block.to), scrollIntoView: true, userEvent: "select" });
}

/** Takes the lines from…to out, with one of two empty lines left around them. */
export function deleteLines(view: EditorView, from: number, to: number) {
  const { doc } = view.state;
  let a = doc.lineAt(from).from, b = Math.min(doc.lineAt(to).to + 1, doc.length);
  const blank = (at: number) => !codeAt(view.state, at) && !doc.lineAt(at).text.trim();
  const last = doc.lineAt(to).to >= doc.length;
  if (a < doc.lineAt(to).to && !last && (a === 0 || blank(a - 1)) && blank(b)) b = Math.min(doc.lineAt(b).to + 1, doc.length);
  // The last line takes the line break before it along.
  const end = b >= doc.length && (last || doc.lineAt(doc.length).from < b);
  if (end && a > 0 && doc.sliceString(b - 1, b) !== "\n") a--;
  const caret = Math.min(a, doc.length - (b - a));
  view.dispatch({ changes: { from: a, to: b }, selection: EditorSelection.cursor(caret), scrollIntoView: true, userEvent: "delete" });
  renumber(view);
  view.focus();
}

export const caretRules: Extension = [
  EditorState.transactionFilter.of((tr) => {
    if (!tr.selection || tr.docChanged || tr.isUserEvent("select.search") || tr.selection.ranges.length > 1) return tr;
    let main = tr.selection.main;
    // Dragged onto a table the pointer is at its edge, whatever row it is on.
    if (tr.isUserEvent("select.pointer") && !main.empty) {
      const table = structureOf(tr.startState).tables.find((t) => (main.head === t.from && main.anchor < t.from) || (main.head === t.to && main.anchor > t.to));
      if (table) main = EditorSelection.range(main.anchor, main.head === table.from ? table.to : table.from);
    }
    const fixed = allowed(tr.startState, main, tr.startState.selection.main) ?? (main === tr.selection.main ? null : main);
    return fixed ? [tr, { selection: fixed, sequential: true }] : tr;
  }),
  // After an edit (and undo) the caret may be among symbols that were just completed: on to where it can be.
  EditorView.updateListener.of((u) => {
    if (!u.docChanged || u.view.composing) return;
    const { view } = u;
    queueMicrotask(() => settle(view, u.transactions.some((tr) => tr.isUserEvent("undo") || tr.isUserEvent("redo"))));
  }),
];

function settle(view: EditorView, replayed: boolean) {
  const { state } = view, main = state.selection.main;
  if (view.composing || state.selection.ranges.length > 1) return;
  if (main.empty && !replayed) {
    // The fence just typed closed a block: on to the line after it.
    const code = structureOf(state).codes.find((c) => c.closeFrom != null && main.head > c.closeFrom && main.head <= c.to);
    if (code) {
      if (code.to < state.doc.length) view.dispatch({ selection: EditorSelection.cursor(code.to + 1) });
      else view.dispatch({ changes: { from: code.to, insert: "\n" }, selection: EditorSelection.cursor(code.to + 1) });
      return;
    }
  }
  const fixed = allowed(state, main, { head: main.head, from: main.from, to: main.from });
  if (fixed) view.dispatch({ selection: fixed });
}

// MARK: Lists

function change(view: EditorView, changes: ChangeSpec, caret?: number, event = "input") {
  view.dispatch({ changes, ...(caret != null ? { selection: EditorSelection.cursor(caret) } : {}), scrollIntoView: true, userEvent: event });
}

/** The lines of the list around line n. */
function listAround(doc: Text, n: number): [number, number] {
  const belongs = (k: number) => { const i = lineInfo(doc, k); return isList(i) || i.kind === "continuation"; };
  if (!belongs(n)) return [n, n - 1];
  let a = n, b = n;
  while (a > 1 && belongs(a - 1)) a--;
  while (b < doc.lines && belongs(b + 1)) b++;
  return [a, b];
}

/** Numbers the list around pos again: each level from its first item's number, one by one. */
export function renumber(view: EditorView, pos = view.state.selection.main.head) {
  const { state } = view, { doc } = state;
  pos = Math.min(pos, doc.length);
  if (codeAt(state, pos)) return;
  const [a, b] = listAround(doc, doc.lineAt(pos).number);
  const counts: { indent: number; next: number }[] = [], changes: ChangeSpec[] = [];
  const top = () => counts[counts.length - 1];
  for (let n = a; n <= b; n++) {
    const line = lineInfo(doc, n);
    if (!isList(line)) continue;
    while (top() && top().indent > line.indent) counts.pop();
    if (line.kind === "numbered") {
      const follows = top() && top().indent === line.indent && top().next > 0;
      // A nested list begins with 1.
      if (!follows && counts.length && top().indent !== line.indent) counts.push({ indent: line.indent, next: 1 });
      if (top() && top().indent === line.indent && top().next > 0) {
        if (line.value !== top().next) changes.push({ from: line.markerFrom, to: line.markerTo - 1, insert: String(top().next) });
        top().next++;
      } else {
        if (top()?.indent === line.indent) counts.pop();
        counts.push({ indent: line.indent, next: line.value + 1 });
      }
    } else if (top()?.indent === line.indent) top().next = 0;
    else counts.push({ indent: line.indent, next: 0 });
  }
  if (changes.length) view.dispatch({ changes, userEvent: "input.renumber" });
}

/** Nests (or un-nests) the list items the selection touches, with what is under them. False when it touches none. */
function indentList(view: EditorView, dir: 1 | -1): boolean {
  const { state } = view, { doc } = state, sel = state.selection.main;
  const a = doc.lineAt(sel.from).number;
  let b = doc.lineAt(sel.to).number;
  for (let n = a; n <= b; n++) { const i = lineInfo(doc, n); if (!isList(i) && i.kind !== "continuation") return false; }
  const first = lineInfo(doc, a);
  if (!isList(first)) return true;
  let target = 0;
  if (dir > 0) {
    let above: LineInfo | null = null;
    for (let n = a - 1; n >= 1; n--) {
      const i = lineInfo(doc, n);
      if ((!isList(i) && i.kind !== "continuation") || i.quoteDepth !== first.quoteDepth) break;
      if (isList(i) && i.indent <= first.indent) { above = i; break; }
    }
    if (!above || (above.indent !== first.indent && childIndent(above) <= first.indent)) return true;
    target = childIndent(above);
  } else {
    if (first.indent === 0) return true;
    for (let n = a - 1; n >= 1; n--) {
      const i = lineInfo(doc, n);
      if (!isList(i) && i.kind !== "continuation") break;
      if (isList(i) && i.indent < first.indent) { target = i.indent; break; }
    }
  }
  const by = target - first.indent;
  if (!by) return true;
  const last = lineInfo(doc, b).indent;
  while (b < doc.lines) { const i = lineInfo(doc, b + 1); if (!(isList(i) && i.indent > last) && i.kind !== "continuation") break; b++; }
  const changes: ChangeSpec[] = [];
  for (let n = a; n <= b; n++) {
    const i = lineInfo(doc, n), start = i.from + i.quoteLength;
    const white = /^[ \t]*/.exec(doc.sliceString(start, i.to))![0];
    changes.push({ from: start, to: start + white.length, insert: " ".repeat(Math.max(columns(white) + by, 0)) });
  }
  view.dispatch({ changes, userEvent: "input.indent", scrollIntoView: true });
  renumber(view);
  return true;
}

/** Takes a line one step towards plain text: out one level of its list, out of the list, out of the quote. */
function leave(view: EditorView, line: LineInfo) {
  const { doc } = view.state, start = line.from + line.quoteLength;
  if (isList(line) && line.indent > 0 && levelOf(doc, line) > 0) { indentList(view, -1); return; }
  if (line.kind !== "text" && line.kind !== "rule") {
    change(view, { from: start, to: line.textStart }, start, "delete");
    const next = view.state.doc.lineAt(start);
    if (next.to < view.state.doc.length) renumber(view, next.to + 1);
    return;
  }
  if (!line.quoteDepth) return;
  let quote = doc.sliceString(line.from, start);
  quote = quote.slice(0, quote.lastIndexOf(">"));
  // The line itself becomes text: a quote ends where its symbol does, no empty line is put between.
  change(view, { from: line.from, to: start, insert: quote }, line.from + quote.length, "delete");
}

// MARK: Keys

export function enter(view: EditorView): boolean {
  const { state } = view, { doc } = state, sel = state.selection.main;
  if (!sel.empty) return false;
  const at = sel.head, code = codeAt(state, at);
  if (code) {
    if (code.closeFrom == null && at === code.openTo) {
      // The fence just typed becomes a block, its end with it.
      const fence = /^\s*(`{3,}|~{3,})/.exec(doc.sliceString(code.from, code.openTo))![1];
      change(view, { from: at, insert: "\n\n" + fence + (code.openTo >= doc.length ? "\n" : "") }, at + 1);
      return true;
    }
    const before = doc.sliceString(doc.lineAt(at).from, at);
    const indent = /^[ \t]*/.exec(before)![0], unit = indent.includes("\t") ? "\t" : codeStep();
    const last = before.trim().slice(-1), next = doc.sliceString(at, at + 1);
    const inner = indent + ("{[(:".includes(last) && last ? unit : "");
    const pair = (last === "{" && next === "}") || (last === "[" && next === "]") || (last === "(" && next === ")");
    change(view, { from: at, insert: "\n" + inner + (pair ? "\n" + indent : "") }, at + 1 + inner.length);
    return true;
  }
  const line = infoAt(doc, at);
  // What a Chinese keyboard types for a fence.
  if (doc.sliceString(line.from, line.to) === "···") {
    change(view, { from: line.from, to: line.to, insert: "```\n\n```\n" }, line.from + 4);
    return true;
  }
  const quote = doc.sliceString(line.from, line.from + line.quoteLength);
  // 回车延续列表和引用 is off: an empty item or quote still ends with Enter.
  if (!md("markdownContinuesLists") && (isList(line) || line.quoteDepth) && !isEmpty(line)) { change(view, { from: at, insert: "\n" }, at + 1); return true; }
  if (isList(line)) {
    if (isEmpty(line)) { leave(view, line); return true; }
    const marker = doc.sliceString(line.markerFrom, line.markerTo);
    const next = quote + " ".repeat(line.indent) + (line.kind === "numbered" ? `${line.value + 1}${marker.slice(-1)} ` : line.kind === "task" ? `${marker} [ ] ` : `${marker} `);
    change(view, { from: at, insert: "\n" + next }, at + 1 + next.length);
    renumber(view);
    return true;
  }
  if (line.kind === "heading" && isEmpty(line)) { leave(view, line); return true; }
  if (line.kind === "heading" && at === line.textStart) { change(view, { from: line.from, insert: "\n" }, at + 1); return true; }
  if (line.quoteDepth) {
    if (isEmpty(line)) { leave(view, line); return true; }
    change(view, { from: at, insert: "\n" + quote }, at + 1 + quote.length);
    return true;
  }
  return insertNewlineAndIndent(view) || true;
}

/** Shift+Enter: a line of the same item or quote. */
export function lineBreak(view: EditorView): boolean {
  const { state } = view, at = state.selection.main.head;
  if (!state.selection.main.empty || codeAt(state, at)) return enter(view);
  const line = infoAt(state.doc, at), quote = state.doc.sliceString(line.from, line.from + line.quoteLength);
  const lead = isList(line) ? quote + " ".repeat(childIndent(line)) : line.kind === "continuation" ? state.doc.sliceString(line.from, line.textStart) : quote;
  change(view, { from: at, insert: "\n" + lead }, at + 1 + lead.length);
  return true;
}

export function backspace(view: EditorView): boolean {
  const { state } = view, { doc } = state, sel = state.selection.main, whole = selectedBlock(state);
  if (whole) { deleteLines(view, whole.from, whole.to); return true; }
  if (!sel.empty) { deleteCharBackward(view); renumber(view); return true; }
  const at = sel.head, code = codeAt(state, at);
  if (code && code.closeFrom != null) {
    const body = codeText(code, doc);
    if (at === body.from) {
      if (body.to === body.from) change(view, { from: code.from, to: code.to }, code.from, "delete");
      return true;
    }
    const before = doc.sliceString(doc.lineAt(at).from, at);
    if (before && /^ +$/.test(before)) { change(view, { from: at - ((before.length - 1) % codeStep().length + 1), to: at }, undefined, "delete.backward"); return true; }
    return deleteCharBackward(view);
  }
  const line = infoAt(doc, at);
  if (line.textStart > line.from && line.kind !== "rule" && at === line.textStart) {
    if (line.kind === "continuation") change(view, { from: line.from - 1, to: line.textStart }, line.from - 1, "delete");
    else leave(view, line);
    return true;
  }
  if (at === line.from && at > 0) {
    const s = structureOf(state), above = s.codes.find((c) => c.closeFrom != null && c.to === at - 1), table = s.tables.find((t) => t.to === at - 1);
    // After a table or a code block: first it is selected, then (Backspace again) it goes.
    if (above || table) { selectBlock(view, (above ?? table)!); return true; }
    const before = infoAt(doc, at - 1);
    if (before.kind === "rule") { change(view, { from: before.from, to: at }, before.from, "delete"); return true; }
  }
  deleteCharBackward(view);
  renumber(view);
  return true;
}

export function deleteForward(view: EditorView): boolean {
  const { state } = view, { doc } = state, sel = state.selection.main, at = sel.head, whole = selectedBlock(state);
  if (whole) { deleteLines(view, whole.from, whole.to); return true; }
  if (!sel.empty || at >= doc.length || doc.lineAt(at).to !== at) return deleteCharForward(view);
  const below = at + 1, code = codeAt(state, at);
  if (code?.closeFrom === below) return true;
  const block = tableAt(state, below) ?? structureOf(state).codes.find((c) => c.from === below && c.closeFrom != null);
  if (block) { selectBlock(view, block); return true; }
  const line = infoAt(doc, below);
  change(view, { from: at, to: line.kind === "rule" ? line.to : code ? below : line.textStart }, at, "delete");
  renumber(view);
  return true;
}

const codeStep = () => " ".repeat(md("markdownCodeIndent"));

function indentCode(view: EditorView, code: Code, dir: 1 | -1): boolean {
  const { state } = view, sel = state.selection.main, { doc } = state;
  const step = codeStep();
  if (dir > 0 && sel.empty) { change(view, { from: sel.head, insert: step }, sel.head + step.length); return true; }
  const body = codeText(code, doc), changes: ChangeSpec[] = [];
  for (let n = doc.lineAt(Math.max(sel.from, body.from)).number; n <= doc.lineAt(Math.min(sel.to, body.to)).number; n++) {
    const line = doc.line(n);
    if (dir > 0) { if (line.length) changes.push({ from: line.from, insert: step }); }
    else { const m = new RegExp(`^(\\t| {1,${step.length}})`).exec(line.text); if (m) changes.push({ from: line.from, to: line.from + m[0].length }); }
  }
  if (changes.length) view.dispatch({ changes, userEvent: "input.indent" });
  return true;
}

export const tab = (dir: 1 | -1) => (view: EditorView): boolean => {
  const { state } = view, sel = state.selection.main, code = codeAt(state, sel.head);
  if (code) return indentCode(view, code, dir);
  if (indentList(view, dir)) return true;
  // A tab at the start of a line would make it code.
  if (dir > 0 && sel.empty && sel.head > infoAt(state.doc, sel.head).textStart) view.dispatch(state.replaceSelection("\t"), { userEvent: "input" });
  return true;
};

/** Ctrl+Enter: done or not, in a task; on to a line below, in a code block. */
export function ctrlEnter(view: EditorView): boolean {
  const { state } = view, at = state.selection.main.head, code = codeAt(state, at);
  if (code && code.closeFrom != null) {
    if (code.to >= state.doc.length) appendLine(view);
    else view.dispatch({ selection: EditorSelection.cursor(code.to + 1), scrollIntoView: true });
    return true;
  }
  const line = infoAt(state.doc, at);
  if (line.kind !== "task") return false;
  toggleTask(view, line);
  return true;
}

export function toggleTask(view: EditorView, line: LineInfo) {
  const mark = /\[([ xX])\]/.exec(view.state.doc.sliceString(line.markerTo, line.textStart));
  if (!mark) return;
  const pos = line.markerTo + mark.index + 1;
  view.dispatch({ changes: { from: pos, to: pos + 1, insert: mark[1] === " " ? "x" : " " }, userEvent: "input" });
}

/** An empty line at the end, the caret on it. */
export function appendLine(view: EditorView) {
  const end = view.state.doc.length;
  view.dispatch({ changes: { from: end, insert: "\n" }, selection: EditorSelection.cursor(end + 1), scrollIntoView: true, userEvent: "input" });
  view.focus();
}

/** The last thing is a code block or a table, without a line after it. */
export function endsInBlock(state: EditorState) {
  const s = structureOf(state), end = state.doc.length;
  return s.codes.some((c) => c.closeFrom != null && c.to === end) || s.tables.some((t) => t.to === end);
}

/** Down out of a code block that ends the document. */
export function down(view: EditorView): boolean {
  const { state } = view, sel = state.selection.main, code = codeAt(state, sel.head);
  if (!sel.empty || !code || code.closeFrom == null || code.to !== state.doc.length) return false;
  if (state.doc.lineAt(sel.head).to !== codeText(code, state.doc).to) return false;
  const below = view.moveVertically(sel, true);
  if (below.head <= codeText(code, state.doc).to && below.head !== sel.head && state.doc.lineAt(below.head).number === state.doc.lineAt(sel.head).number && view.coordsAtPos(below.head)?.top !== view.coordsAtPos(sel.head)?.top) return false;
  appendLine(view);
  return true;
}

/** Ctrl+A in a code block: its code first, then everything. */
export function selectAll(view: EditorView): boolean {
  const { state } = view, sel = state.selection.main, code = codeAt(state, sel.head);
  if (!code || code.closeFrom == null) return false;
  const body = codeText(code, state.doc);
  if (body.to === body.from || (sel.from === body.from && sel.to === body.to)) return false;
  view.dispatch({ selection: EditorSelection.range(body.from, body.to), userEvent: "select" });
  return true;
}

const SYMBOLS: Record<string, string> = { "》 ": "> ", "》　": "> ", "【】 ": "- [ ] ", "[] ": "- [ ] ", "[ ] ": "- [ ] ", "・ ": "- ", "· ": "- " };

/** What typing a space completes: the symbols a Chinese keyboard types for Markdown's, and a task without its dash. */
export function completeSymbols(view: EditorView) {
  const { state } = view, at = state.selection.main.head;
  if (codeAt(state, at) || !md("markdownCompletesSymbols")) return;
  const line = infoAt(state.doc, at);
  if (line.kind !== "text" && line.kind !== "bullet") return;
  const markdown = SYMBOLS[state.doc.sliceString(line.textStart, at)];
  if (!markdown || (line.kind === "bullet" && markdown !== "- [ ] ")) return;
  const from = line.kind === "bullet" ? line.markerFrom : line.textStart;
  change(view, { from, to: at, insert: markdown }, from + markdown.length);
}

/** An address pasted over text makes it a link. */
export function pasteLink(e: ClipboardEvent, view: EditorView): boolean {
  const text = e.clipboardData?.getData("text/plain").trim() ?? "", sel = view.state.selection.main;
  if (!md("markdownPastesLinks") || sel.empty || !/^https?:\/\/\S+$/.test(text) || codeAt(view.state, sel.from)) return false;
  const shown = view.state.doc.sliceString(sel.from, sel.to);
  if (shown.includes("\n")) return false;
  e.preventDefault();
  const link = `[${shown}](${text})`;
  change(view, { from: sel.from, to: sel.to, insert: link }, sel.from + link.length, "input.paste");
  return true;
}
