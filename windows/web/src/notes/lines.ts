import type { EditorState, Text } from "@codemirror/state";
import { StateField } from "@codemirror/state";
import { codeTools } from "./code";

// What the lines of a document are, as on the Mac (MarkdownLine.swift): the symbols at a line's start are never shown (a
// bullet, a number, a box, a bar, a larger font stand for them); code blocks and tables span lines.

export type LineKind = "text" | "heading" | "bullet" | "numbered" | "task" | "rule" | "continuation";

export interface LineInfo {
  kind: LineKind;
  from: number; to: number;
  /** A heading's level, a number's value. */
  value: number;
  done: boolean;
  quoteDepth: number; quoteLength: number;
  /** Columns before the list marker. */
  indent: number;
  markerFrom: number; markerTo: number;
  /** Where the text begins. */
  textStart: number;
}

export const isList = (l: LineInfo) => l.kind === "bullet" || l.kind === "numbered" || l.kind === "task";
export const isEmpty = (l: LineInfo) => l.textStart >= l.to;
/** Columns what is nested under this item is indented by. */
export const childIndent = (l: LineInfo) => l.indent + (l.kind === "numbered" ? String(l.value).length + 2 : 2);
export const columns = (s: string) => [...s].reduce((n, c) => n + (c === "\t" ? 4 : 1), 0);

const RULE = /^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$/;
const QUOTE = /^[ \t]{0,3}(?:>[ \t]?)+/;
const HEADING = /^(#{1,6})[ \t]+/;
const TASK = /^([ \t]*)([-*+])[ \t]+\[([ xX])\](?:[ \t]+|$)/;
const BULLET = /^([ \t]*)([-*+])[ \t]+/;
const ORDERED = /^([ \t]*)((\d{1,9})[.)])[ \t]+/;

function parse(text: string, from: number): LineInfo {
  const info: LineInfo = { kind: "text", from, to: from + text.length, value: 0, done: false, quoteDepth: 0, quoteLength: 0, indent: 0, markerFrom: from, markerTo: from, textStart: from };
  if (RULE.test(text)) { info.kind = "rule"; return info; }
  const quote = QUOTE.exec(text)?.[0] ?? "";
  info.quoteLength = quote.length;
  info.quoteDepth = quote.split(">").length - 1;
  const rest = text.slice(quote.length), start = from + quote.length;
  info.textStart = start;
  let m: RegExpExecArray | null;
  const marker = (kind: LineKind) => {
    info.kind = kind;
    info.indent = columns(m![1]);
    info.markerFrom = start + m![1].length;
    info.markerTo = info.markerFrom + m![2].length;
    info.textStart = start + m![0].length;
  };
  if ((m = HEADING.exec(rest))) { info.kind = "heading"; info.value = m[1].length; info.textStart = start + m[0].length; }
  else if ((m = TASK.exec(rest))) { marker("task"); info.done = m[3] !== " "; }
  else if ((m = BULLET.exec(rest))) marker("bullet");
  else if ((m = ORDERED.exec(rest))) { marker("numbered"); info.value = Number(m[3]); }
  else info.indent = columns(/^[ \t]*/.exec(rest)![0]);
  return info;
}

/** The item a line indented by `cols` belongs to. */
function itemAbove(doc: Text, n: number, cols: number, depth: number): LineInfo | null {
  for (let k = n - 1; k >= 1 && k > n - 200; k--) {
    const line = doc.line(k);
    if (!line.text.trim() || line.text.trim().startsWith("#")) return null;
    const info = parse(line.text, line.from);
    if (info.quoteDepth !== depth) return null;
    if (isList(info) && info.indent < cols) return info;
    if (!isList(info) && info.indent < 2) return null;
  }
  return null;
}

/** Line number n. */
export function lineInfo(doc: Text, n: number): LineInfo {
  const line = doc.line(n);
  const info = parse(line.text, line.from);
  if (info.kind !== "text") return info;
  const rest = line.text.slice(info.quoteLength), white = /^[ \t]*/.exec(rest)![0], cols = columns(white);
  info.indent = 0;
  // A line that is only indented so far is one too, where what is written on it will be: as deep as the item's text.
  if (cols >= 2) {
    const above = itemAbove(doc, n, cols, info.quoteDepth);
    if (above && (rest.trim() || cols === childIndent(above))) { info.kind = "continuation"; info.indent = above.indent; info.markerFrom = above.markerFrom; info.markerTo = above.markerTo; info.textStart += white.length; }
  }
  return info;
}

export const infoAt = (doc: Text, pos: number) => lineInfo(doc, doc.lineAt(pos).number);

/** How deep an item is nested. */
export function levelOf(doc: Text, item: LineInfo): number {
  let level = 0, current = item.indent, blanks = 0;
  for (let k = doc.lineAt(item.from).number - 1; k >= 1 && current > 0; k--) {
    const line = doc.line(k);
    if (!line.text.trim()) { if (++blanks > 1) break; continue; }
    blanks = 0;
    const above = parse(line.text, line.from);
    if (above.quoteDepth !== item.quoteDepth) break;
    if (isList(above)) { if (above.indent < current) { level++; current = above.indent; } } else if (above.indent < 2) break;
  }
  return level;
}

// MARK: Code blocks

export interface Code { from: number; to: number; openTo: number; closeFrom: number | null; first: number; last: number; info: string }
/** The code's own characters. */
export const codeText = (c: Code, doc: Text) => {
  const from = Math.min(c.openTo + 1, c.to);
  return { from, to: Math.max(from, c.closeFrom != null ? c.closeFrom - 1 : doc.length) };
};

export function findCodes(doc: Text): Code[] {
  const out: Code[] = [];
  let open: { n: number; from: number; to: number } | null = null, fence = "", info = "";
  let n = 0, pos = 0;
  for (let it = doc.iterLines(); !it.next().done;) {
    n++;
    const raw = it.value, text = raw.trim(), from = pos, to = pos + raw.length;
    pos = to + 1;
    if (open) {
      if (text.startsWith(fence) && [...text].every((c) => c === fence[0])) { out.push({ from: open.from, to, openTo: open.to, closeFrom: from, first: open.n, last: n, info }); open = null; }
    } else {
      const m = /^(`{3,}|~{3,})(.*)$/.exec(text);
      if (m && !m[2].includes("`")) { open = { n, from, to }; fence = m[1]; info = m[2].trim(); }
    }
  }
  if (open) out.push({ from: open.from, to: doc.length, openTo: open.to, closeFrom: null, first: open.n, last: doc.lines, info });
  return out;
}

export function codeLanguage(code: Code, doc: Text): { id: string | null; detected: boolean } {
  if (code.info) return { id: codeTools.resolve(code.info), detected: false };
  const { from, to } = codeText(code, doc);
  return { id: codeTools.detect(doc.sliceString(from, to)), detected: true };
}

// MARK: Tables

export type Alignment = "none" | "left" | "center" | "right";
export interface TableData { rows: string[][]; alignments: Alignment[] }
export interface Table { from: number; to: number; first: number; last: number; data: TableData }

const DELIMITER = /^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/;

/** The cells of a line, as they read ("\|" a bar, <br> a line break). */
export function tableCells(line: string): string[] {
  let text = line.trim();
  if (text.startsWith("|")) text = text.slice(1);
  if (text.endsWith("|") && !text.endsWith("\\|")) text = text.slice(0, -1);
  const cells = [""];
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "\\" && text[i + 1] === "|") { cells[cells.length - 1] += "|"; i++; }
    else if (text[i] === "|") cells.push("");
    else cells[cells.length - 1] += text[i];
  }
  return cells.map((c) => c.trim().replace(/<br\s*\/?>/gi, "\n"));
}

export function tableMarkdown(table: TableData): string {
  const cell = (c: string) => c.trim().replace(/\|/g, "\\|").replace(/\n/g, "<br>");
  const line = (cells: string[]) => "| " + cells.join(" | ") + " |";
  const marks = { none: "---", left: ":---", center: ":---:", right: "---:" };
  const lines = table.rows.map((r) => line(r.map(cell)));
  lines.splice(1, 0, line(table.alignments.map((a) => marks[a])));
  return lines.join("\n");
}

function findTables(doc: Text, codes: Code[]): Table[] {
  const out: Table[] = [];
  const inCode = (n: number) => codes.some((c) => n >= c.first && n <= c.last);
  for (let n = 1; n < doc.lines; n++) {
    const head = doc.line(n);
    if (!head.text.includes("|") || inCode(n)) continue;
    const rule = doc.line(n + 1);
    if (!rule.text.includes("|") || !DELIMITER.test(rule.text)) continue;
    const plain = (k: number) => { const i = lineInfo(doc, k); return i.textStart === i.from; };
    const cells = tableCells(head.text), marks = tableCells(rule.text);
    if (!plain(n) || cells.length !== marks.length) continue;
    const rows = [cells];
    let last = n + 1;
    while (last < doc.lines && doc.line(last + 1).text.includes("|") && !inCode(last + 1) && plain(last + 1)) {
      last++;
      const row = tableCells(doc.line(last).text).slice(0, cells.length);
      while (row.length < cells.length) row.push("");
      rows.push(row);
    }
    const alignments = marks.map((m): Alignment => m.startsWith(":") ? (m.endsWith(":") ? "center" : "left") : m.endsWith(":") ? "right" : "none");
    out.push({ from: head.from, to: doc.line(last).to, first: n, last, data: { rows, alignments } });
    n = last;
  }
  return out;
}

export interface Structure { codes: Code[]; tables: Table[] }
export const readStructure = (doc: Text): Structure => { const codes = findCodes(doc); return { codes, tables: findTables(doc, codes) }; };

/** What spans lines, kept with the document. */
export const structureField = StateField.define<Structure>({
  create: (state) => readStructure(state.doc),
  update: (value, tr) => (tr.docChanged ? readStructure(tr.state.doc) : value),
});
export const structureOf = (state: EditorState) => state.field(structureField, false) ?? readStructure(state.doc);
export const codeAt = (state: EditorState, pos: number) => structureOf(state).codes.find((c) => pos >= c.from && pos <= c.to);
export const tableAt = (state: EditorState, pos: number) => structureOf(state).tables.find((t) => pos >= t.from && pos <= t.to);
