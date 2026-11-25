import { scaleOf } from "./prefs";
import { EditorSelection } from "@codemirror/state";
import { type EditorView, WidgetType } from "@codemirror/view";
import { redo, undo } from "@codemirror/commands";
import { t } from "../i18n";
import { call } from "../rpc";
import { openMenu, sep, type MenuEntry } from "../ui/menu";
import { structureOf, tableMarkdown, type Alignment, type TableData } from "./lines";
import { appendLine, deleteLines, selectBlock } from "./edit";

// A table of a document, written in where it stands (the Mac's MarkdownTableView): every cell is a small editor, columns
// and rows are added, moved and removed with the handles at its edges.

const escape = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

/** The text of a cell as it reads. */
export function inlineHTML(text: string): string {
  const kept: string[] = [];
  const keep = (html: string) => `\u0000${kept.push(html) - 1}\u0000`;
  let s = text.replace(/(`+)(?!`)(.+?)(?<!`)\1(?!`)/g, (_m, _t, code) => keep(`<span class="cm-md-code">${escape(code)}</span>`));
  s = s.replace(/!?\[([^\]\n]*)\]\(([^)\s]+)(?:\s+"[^"\n]*")?\)/g, (_m, label, url) => keep(`<span class="cm-md-link" data-url="${escape(url)}">${escape(label)}</span>`));
  s = s.replace(/https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"\]]/g, (url) => keep(`<span class="cm-md-link" data-url="${escape(url)}">${escape(url)}</span>`));
  s = escape(s)
    .replace(/\*\*\*(?=[^\s*])(.+?)(?<=[^\s*])\*\*\*/g, '<b class="cm-md-strong"><i>$1</i></b>')
    .replace(/(\*\*|__)(?=\S)(.+?)(?<=\S)\1/g, '<b class="cm-md-strong">$2</b>')
    .replace(/(?<!\*)\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?!\*)/g, "<i>$1</i>")
    .replace(/~~(?=\S)(.+?)(?<=\S)~~/g, '<span class="cm-md-strike">$1</span>')
    .replace(/==(?=\S)(.+?)(?<=\S)==/g, '<span class="cm-md-mark">$1</span>');
  return s.replace(/\u0000(\d+)\u0000/g, (_m, n) => kept[Number(n)]);
}

const clone = (d: TableData): TableData => ({ rows: d.rows.map((r) => [...r]), alignments: [...d.alignments] });
const same = (a: TableData, b: TableData) => JSON.stringify(a) === JSON.stringify(b);

class TableView {
  readonly dom = document.createElement("div");
  private box = document.createElement("div");
  private grid = document.createElement("table");
  private cells: HTMLElement[][] = [];
  private column = document.createElement("button");
  private row = document.createElement("button");
  private hovered = { row: 0, column: 0 };
  private selected: { rows: [number, number]; columns: [number, number] } | null = null;

  constructor(readonly view: EditorView, public data: TableData) {
    this.dom.className = "md-table";
    this.dom.contentEditable = "false";
    this.box.className = "md-table-box";
    this.box.append(this.grid);
    const button = (cls: string, title: string, el = document.createElement("button")) => {
      el.className = cls;
      el.title = title;
      el.setAttribute("aria-label", title);
      el.tabIndex = -1;
      el.addEventListener("mousedown", (e) => e.preventDefault());
      return el;
    };
    const plus = '<svg width="9" height="9" viewBox="0 0 9 9" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M4.5 1v7M1 4.5h7"/></svg>';
    const addColumn = button("md-table-add add-column", t("添加一列")), addRow = button("md-table-add add-row", t("添加一行"));
    addColumn.innerHTML = addRow.innerHTML = plus;
    button("md-table-handle of-column", t("这一列"), this.column).innerHTML = "<i></i><i></i><i></i>";
    button("md-table-handle of-row", t("这一行"), this.row).innerHTML = "<i></i><i></i><i></i>";
    addColumn.addEventListener("click", () => this.insertColumn(this.data.alignments.length));
    addRow.addEventListener("click", () => this.insertRow(this.data.rows.length));
    this.column.addEventListener("click", () => { const r = this.column.getBoundingClientRect(); openMenu(this.columnItems(this.hovered.column), r.left, r.bottom + 4); });
    this.row.addEventListener("click", () => { const r = this.row.getBoundingClientRect(); openMenu([...this.rowItems(this.hovered.row), this.removeItem()], r.right + 4, r.top); });
    this.dom.append(this.box, addColumn, addRow, this.column, this.row);
    this.dom.addEventListener("mousemove", (e) => this.hover(e));
    this.dom.addEventListener("mouseenter", (e) => this.hover(e));
    this.box.addEventListener("scroll", () => this.placeHandles());
    this.render();
  }

  // MARK: Showing

  update(data: TableData) {
    const before = this.data;
    this.data = data;
    if (data.rows.length !== this.cells.length || data.alignments.length !== (this.cells[0]?.length ?? 0)) return this.render();
    data.rows.forEach((row, r) => row.forEach((text, c) => {
      const cell = this.cells[r][c];
      cell.style.textAlign = data.alignments[c] === "none" ? "" : data.alignments[c];
      if (cell === document.activeElement) { if (this.read(cell).trim() !== text) { cell.textContent = text; caretIn(cell, text.length); } }
      else if (before.rows[r]?.[c] !== text || cell.dataset.text !== text) this.paint(cell, text);
    }));
  }

  private paint(cell: HTMLElement, text: string) {
    cell.dataset.text = text;
    cell.innerHTML = inlineHTML(text);
  }

  private read(cell: HTMLElement) { return cell.innerText.replace(/\u00a0/g, " ").replace(/\n$/, ""); }

  private render() {
    this.grid.replaceChildren();
    this.cells = this.data.rows.map((row, r) => {
      const tr = this.grid.insertRow();
      return row.map((text, c) => {
        const td = document.createElement(r === 0 ? "th" : "td"), cell = document.createElement("div");
        cell.className = "md-cell";
        cell.contentEditable = "plaintext-only";
        cell.spellcheck = false;
        cell.style.textAlign = this.data.alignments[c] === "none" ? "" : this.data.alignments[c];
        this.paint(cell, text);
        this.listen(cell, r, c);
        td.append(cell);
        tr.append(td);
        return cell;
      });
    });
  }

  private hover(e: MouseEvent) {
    const row = this.cells.findIndex((line) => e.clientY <= line[0].parentElement!.getBoundingClientRect().bottom);
    const line = this.cells[0] ?? [];
    const column = line.findIndex((cell) => e.clientX <= cell.parentElement!.getBoundingClientRect().right);
    this.hovered = { row: row < 0 ? this.cells.length - 1 : row, column: column < 0 ? line.length - 1 : column };
    this.placeHandles();
  }

  private placeHandles() {
    const cell = this.cells[this.hovered.row]?.[this.hovered.column];
    if (!cell) return;
    const r = cell.parentElement!.getBoundingClientRect(), box = this.dom.getBoundingClientRect(), view = this.box.getBoundingClientRect();
    const scale = scaleOf(this.dom);
    this.column.style.left = `${(Math.min(Math.max((r.left + r.right) / 2, view.left + 14 * scale), view.right - 14 * scale) - box.left) / scale - 14}px`;
    this.row.style.top = `${((r.top + r.bottom) / 2 - box.top) / scale - 11}px`;
  }

  // MARK: The keyboard

  private listen(cell: HTMLElement, r: number, c: number) {
    cell.addEventListener("focus", () => {
      const text = this.data.rows[r]?.[c] ?? "";
      if (cell.textContent !== text) { cell.textContent = text; caretIn(cell, text.length); }
    });
    cell.addEventListener("blur", () => this.setSelected(null));
    cell.addEventListener("blur", () => this.paint(cell, this.data.rows[r]?.[c] ?? ""));
    const changed = (e: Event) => { if (!(e as InputEvent).isComposing) this.typed(r, c, this.read(cell)); };
    cell.addEventListener("input", changed);
    cell.addEventListener("compositionend", () => this.typed(r, c, this.read(cell)));
    cell.addEventListener("copy", (e) => {
      e.stopPropagation();
      if (!this.selected) return;
      e.preventDefault();
      e.clipboardData?.setData("text/plain", this.selectedText());
    });
    cell.addEventListener("cut", (e) => {
      e.stopPropagation();
      if (!this.selected) return;
      e.preventDefault();
      e.clipboardData?.setData("text/plain", this.selectedText());
      this.deleteSelected();
    });
    cell.addEventListener("mousedown", (e) => {
      e.stopPropagation();
      this.drag(e, r, c);
      const url = (e.target as HTMLElement).closest<HTMLElement>("[data-url]")?.dataset.url;
      if (e.ctrlKey && url) { e.preventDefault(); call("shell.open", { target: url }); }
    });
    cell.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      e.stopPropagation();
      openMenu([{ label: t("行"), submenu: this.rowItems(r) }, { label: t("列"), submenu: this.columnItems(c) }, sep, this.removeItem()], e.clientX, e.clientY);
    });
    cell.addEventListener("paste", (e) => {
      const text = e.clipboardData?.getData("text/plain").replace(/\r\n/g, "\n").replace(/\n+$/, "") ?? "";
      e.stopPropagation();
      if (!text.includes("\t")) return;
      e.preventDefault();
      this.paste(text.split("\n").map((l) => l.split("\t")), r, c);
    });
    cell.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.isComposing) return;
      const at = caretOffset(cell), end = this.read(cell).length, mod = e.ctrlKey || e.metaKey;
      const take = (run: () => void) => { e.preventDefault(); run(); };
      if (mod && e.key.toLowerCase() === "z") return take(() => (e.shiftKey ? redo : undo)(this.view));
      if (mod && e.key.toLowerCase() === "y") return take(() => redo(this.view));
      if (mod && e.key.toLowerCase() === "b") return take(() => wrapIn(cell, "**"));
      if (mod && e.key.toLowerCase() === "i") return take(() => wrapIn(cell, "*"));
      const index = r * this.data.alignments.length + c;
      if (mod && e.key.toLowerCase() === "a") {
        const s = getSelection()?.toString() ?? "";
        if (!end || s.length >= end) return take(() => this.selectAll());
        return;
      }
      if (e.key === "Backspace" || e.key === "Delete") {
        if (this.selected) return take(() => { this.deleteSelected(); });
        // Nothing left in it: the table is selected, and goes with the next one.
        if (!end && this.data.rows.every((row) => row.every((x) => !x.trim()))) return take(() => this.selectAll());
        return;
      }
      if (this.selected && !mod && e.key !== "Shift") { this.setSelected(null); if (e.key === "Escape") return take(() => {}); }
      if (e.key === "Tab") return take(() => this.step(index + (e.shiftKey ? -1 : 1), true));
      if (e.key === "Enter" && e.shiftKey) return take(() => document.execCommand("insertText", false, "\n"));
      if (e.key === "Enter") return take(() => (r + 1 < this.cells.length ? this.focusCell(r + 1, c) : this.insertRow(this.data.rows.length, c)));
      if (e.key === "Escape") return take(() => this.selectAll());
      if (e.key === "ArrowUp" && onEdge(cell, "top")) return take(() => (r > 0 ? this.focusCell(r - 1, c) : this.leave(-1)));
      if (e.key === "ArrowDown" && onEdge(cell, "bottom")) return take(() => (r + 1 < this.cells.length ? this.focusCell(r + 1, c) : this.leave(1)));
      if (e.key === "ArrowLeft" && !e.shiftKey && at === 0) return take(() => this.step(index - 1));
      if (e.key === "ArrowRight" && !e.shiftKey && at === end) return take(() => this.step(index + 1, false, 0));
    });
  }

  private step(index: number, selecting = false, caret?: number) {
    const columns = this.data.alignments.length;
    if (index < 0) return this.leave(-1);
    if (index >= this.cells.length * columns) { if (selecting) this.insertRow(this.data.rows.length); else this.leave(1); return; }
    this.focusCell(Math.floor(index / columns), index % columns, selecting, caret);
  }

  focusCell(r: number, c: number, selecting = false, caret?: number) {
    const cell = this.cells[r]?.[c];
    if (!cell) return;
    cell.focus();
    const length = (this.data.rows[r]?.[c] ?? "").length;
    caretIn(cell, caret ?? length, selecting ? 0 : undefined);
    cell.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  focus(end: boolean, selecting = false) {
    const r = end ? this.cells.length - 1 : 0;
    this.focusCell(r, end ? this.data.alignments.length - 1 : 0, selecting);
  }

  private place() {
    const from = this.view.posAtDOM(this.dom);
    return structureOf(this.view.state).tables.find((x) => from >= x.from && from <= x.to);
  }

  leave(dir: 1 | -1) {
    const at = this.place(), { view } = this;
    if (!at) return;
    view.focus();
    if (dir < 0) {
      if (at.from === 0) view.dispatch({ changes: { from: 0, insert: "\n" }, selection: EditorSelection.cursor(0), userEvent: "input" });
      else view.dispatch({ selection: EditorSelection.cursor(at.from - 1), scrollIntoView: true });
    } else if (at.to >= view.state.doc.length) appendLine(view);
    else view.dispatch({ selection: EditorSelection.cursor(at.to + 1), scrollIntoView: true });
  }

  // MARK: Editing

  private typed(r: number, c: number, text: string) {
    if (!this.data.rows[r] || this.data.rows[r][c] === text.trim()) return;
    const next = clone(this.data);
    next.rows[r][c] = text;
    this.write(next, "input.type");
  }

  /** Only what differs is changed, so that typing is undone as typing. */
  private write(next: TableData, event = "input") {
    const at = this.place();
    if (!at) return;
    const { view } = this, before = view.state.doc.sliceString(at.from, at.to), after = tableMarkdown(next);
    if (before === after) return;
    let a = 0, b = 0;
    while (a < before.length && a < after.length && before[a] === after[a]) a++;
    while (b < before.length - a && b < after.length - a && before[before.length - 1 - b] === after[after.length - 1 - b]) b++;
    view.dispatch({ changes: { from: at.from + a, to: at.to - b, insert: after.slice(a, after.length - b) }, userEvent: event });
  }

  private restructure(next: TableData, r: number, c: number) {
    this.write(next);
    this.update(next);
    this.focusCell(r, c);
  }

  insertRow(at: number, c = 0) {
    const next = clone(this.data);
    at = Math.min(Math.max(at, 1), next.rows.length);
    next.rows.splice(at, 0, next.alignments.map(() => ""));
    this.restructure(next, at, c);
  }

  insertColumn(at: number) {
    const next = clone(this.data);
    next.rows.forEach((row) => row.splice(at, 0, ""));
    next.alignments.splice(at, 0, "none");
    this.restructure(next, 0, at);
  }

  private swapRows(r: number, dir: number) { const n = clone(this.data); [n.rows[r], n.rows[r + dir]] = [n.rows[r + dir], n.rows[r]]; this.restructure(n, r + dir, 0); }
  private swapColumns(c: number, dir: number) {
    const n = clone(this.data);
    n.rows.forEach((row) => { [row[c], row[c + dir]] = [row[c + dir], row[c]]; });
    [n.alignments[c], n.alignments[c + dir]] = [n.alignments[c + dir], n.alignments[c]];
    this.restructure(n, 0, c + dir);
  }

  private removeRow(r: number) {
    if (this.data.rows.length <= 1) return this.remove();
    const n = clone(this.data);
    n.rows.splice(r, 1);
    this.restructure(n, Math.min(r, n.rows.length - 1), 0);
  }

  private removeColumn(c: number) {
    if (this.data.alignments.length <= 1) return this.remove();
    const n = clone(this.data);
    n.rows.forEach((row) => row.splice(c, 1));
    n.alignments.splice(c, 1);
    this.restructure(n, 0, Math.min(c, n.alignments.length - 1));
  }

  private align(c: number, to: Alignment) { const n = clone(this.data); n.alignments[c] = to; this.write(n); this.update(n); }

  remove() {
    const at = this.place();
    if (!at) return;
    deleteLines(this.view, at.from, at.to);
  }

  /** The whole table selected, to be deleted or copied as one. */
  selectAll() { const at = this.place(); if (at) { this.setSelected(null); selectBlock(this.view, at); } }

  // MARK: Cells selected together

  private setSelected(area: { rows: [number, number]; columns: [number, number] } | null) {
    this.selected = area;
    this.cells.forEach((row, r) => row.forEach((cell, c) =>
      cell.parentElement!.classList.toggle("on", !!area && r >= area.rows[0] && r <= area.rows[1] && c >= area.columns[0] && c <= area.columns[1])));
    this.dom.classList.toggle("cells", !!area);
  }

  /** Dragged from a cell: the cells between it and the pointer. */
  private drag(e: MouseEvent, r: number, c: number) {
    this.setSelected(null);
    if (e.button !== 0 || e.shiftKey) return;
    const move = (m: MouseEvent) => {
      if (!(m.buttons & 1)) return up();
      const near = (cells: HTMLElement[], at: number, a: "left" | "top", b: "right" | "bottom") => {
        const n = cells.findIndex((cell) => at < cell.parentElement!.getBoundingClientRect()[b]);
        return n < 0 ? cells.length - 1 : n;
      };
      const row = near(this.cells.map((line) => line[0]), m.clientY, "top", "bottom"), column = near(this.cells[0], m.clientX, "left", "right");
      if (row === r && column === c) { if (this.selected) this.setSelected(null); return; }
      m.preventDefault();
      getSelection()?.collapseToStart();
      this.setSelected({ rows: [Math.min(row, r), Math.max(row, r)], columns: [Math.min(column, c), Math.max(column, c)] });
    };
    const up = () => { removeEventListener("mousemove", move, true); removeEventListener("mouseup", up, true); };
    addEventListener("mousemove", move, true);
    addEventListener("mouseup", up, true);
  }

  /** Delete on cells selected together: all of them, the table goes; whole rows or columns go; others are emptied. */
  private deleteSelected(): boolean {
    const area = this.selected;
    if (!area) return false;
    this.setSelected(null);
    const rows = area.rows[1] - area.rows[0] + 1, columns = area.columns[1] - area.columns[0] + 1;
    const allRows = rows === this.data.rows.length, allColumns = columns === this.data.alignments.length, n = clone(this.data);
    if (allRows && allColumns) { this.remove(); return true; }
    if (allColumns && area.rows[0] > 0) { n.rows.splice(area.rows[0], rows); this.restructure(n, Math.min(area.rows[0], n.rows.length - 1), 0); }
    else if (allRows) { n.rows.forEach((row) => row.splice(area.columns[0], columns)); n.alignments.splice(area.columns[0], columns); this.restructure(n, 0, Math.min(area.columns[0], n.alignments.length - 1)); }
    else {
      for (let r = area.rows[0]; r <= area.rows[1]; r++) for (let c = area.columns[0]; c <= area.columns[1]; c++) n.rows[r][c] = "";
      this.restructure(n, area.rows[0], area.columns[0]);
    }
    return true;
  }

  private selectedText() {
    const a = this.selected!;
    return this.data.rows.slice(a.rows[0], a.rows[1] + 1).map((row) => row.slice(a.columns[0], a.columns[1] + 1).join("\t")).join("\n");
  }

  private paste(grid: string[][], r: number, c: number) {
    const n = clone(this.data), width = c + Math.max(...grid.map((g) => g.length));
    while (n.alignments.length < width) { n.rows.forEach((row) => row.push("")); n.alignments.push("none"); }
    grid.forEach((values, i) => {
      if (r + i >= n.rows.length) n.rows.push(n.alignments.map(() => ""));
      values.forEach((v, j) => { n.rows[r + i][c + j] = v.trim(); });
    });
    this.restructure(n, r, c);
  }

  // MARK: Menus

  private removeItem(): MenuEntry { return { label: t("删除表格"), action: () => this.remove() }; }

  private columnItems(c: number): MenuEntry[] {
    const a = this.data.alignments[c], last = this.data.alignments.length - 1;
    return [
      { label: t("左对齐"), checked: a === "left" || a === "none", action: () => this.align(c, "left") },
      { label: t("居中"), checked: a === "center", action: () => this.align(c, "center") },
      { label: t("右对齐"), checked: a === "right", action: () => this.align(c, "right") },
      sep,
      { label: t("在左侧插入列"), action: () => this.insertColumn(c) },
      { label: t("在右侧插入列"), action: () => this.insertColumn(c + 1) },
      { label: t("左移"), disabled: c === 0, action: () => this.swapColumns(c, -1) },
      { label: t("右移"), disabled: c >= last, action: () => this.swapColumns(c, 1) },
      sep,
      { label: t("删除列"), action: () => this.removeColumn(c) },
    ];
  }

  private rowItems(r: number): MenuEntry[] {
    const last = this.data.rows.length - 1;
    return [
      { label: t("在上方插入行"), disabled: r === 0, action: () => this.insertRow(r) },
      { label: t("在下方插入行"), action: () => this.insertRow(r + 1) },
      { label: t("上移"), disabled: r < 2, action: () => this.swapRows(r, -1) },
      { label: t("下移"), disabled: r === 0 || r >= last, action: () => this.swapRows(r, 1) },
      sep,
      { label: t("删除行"), disabled: r === 0 && last > 0, action: () => this.removeRow(r) },
    ];
  }
}

function caretOffset(cell: HTMLElement): number {
  const s = getSelection();
  if (!s || !s.rangeCount || !s.isCollapsed || !cell.contains(s.anchorNode)) return -1;
  const range = document.createRange();
  range.selectNodeContents(cell);
  range.setEnd(s.anchorNode!, s.anchorOffset);
  return range.toString().length;
}

/** The caret at `to` in a cell's text, or the text from `from` selected. */
function caretIn(cell: HTMLElement, to: number, from?: number) {
  const node = cell.firstChild, range = document.createRange();
  if (!node) range.selectNodeContents(cell);
  else if (node.nodeType === 3) { const n = node.textContent!.length; range.setStart(node, Math.min(from ?? to, n)); range.setEnd(node, Math.min(to, n)); }
  else range.selectNodeContents(cell);
  const s = getSelection();
  s?.removeAllRanges();
  s?.addRange(range);
}

function onEdge(cell: HTMLElement, edge: "top" | "bottom"): boolean {
  const s = getSelection();
  if (!s?.rangeCount || !s.isCollapsed) return false;
  const rects = s.getRangeAt(0).getClientRects(), box = cell.getBoundingClientRect();
  if (!rects.length) return true;
  return edge === "top" ? rects[0].top - box.top < 18 : box.bottom - rects[0].bottom < 18;
}

/** Wraps what is selected in a cell in marker (or unwraps it). */
function wrapIn(cell: HTMLElement, marker: string) {
  const s = getSelection();
  if (!s?.rangeCount || !cell.contains(s.anchorNode)) return;
  const from = Math.min(s.anchorOffset, s.focusOffset), to = Math.max(s.anchorOffset, s.focusOffset), text = cell.textContent ?? "", m = marker.length;
  if (text.slice(from - m, from) === marker && text.slice(to, to + m) === marker && from >= m) {
    caretIn(cell, to + m, from - m);
    document.execCommand("insertText", false, text.slice(from, to));
    caretIn(cell, to - m, from - m);
  } else {
    document.execCommand("insertText", false, marker + text.slice(from, to) + marker);
    caretIn(cell, to + m, from + m);
  }
}

/** Wraps the text of the cell being written in. False when there is none. */
export function wrapCell(view: EditorView, marker: string): boolean {
  const cell = document.activeElement as HTMLElement | null;
  if (!cell?.classList.contains("md-cell") || !view.dom.contains(cell)) return false;
  wrapIn(cell, marker);
  return true;
}

const views = new WeakMap<HTMLElement, TableView>();

export class TableWidget extends WidgetType {
  constructor(readonly data: TableData) { super(); }
  eq(other: TableWidget) { return same(this.data, other.data); }
  get estimatedHeight() { return this.data.rows.length * 36 + 24; }
  toDOM(view: EditorView) {
    const made = new TableView(view, this.data);
    views.set(made.dom, made);
    return made.dom;
  }
  updateDOM(dom: HTMLElement, view: EditorView) {
    const shown = views.get(dom);
    if (!shown || shown.view !== view) return false;
    shown.update(this.data);
    view.requestMeasure();
    return true;
  }
  ignoreEvent() { return true; }
}

/** Puts the keyboard into the table at pos (its first cell, or its last). */
export function focusTable(view: EditorView, pos: number, end = false, selecting = false) {
  const table = structureOf(view.state).tables.find((x) => pos >= x.from && pos <= x.to);
  if (!table) return;
  for (const dom of view.contentDOM.querySelectorAll<HTMLElement>(".md-table")) {
    if (view.posAtDOM(dom) === table.from) { views.get(dom)?.focus(end, selecting); return; }
  }
}

/** Tables the selection covers show it. */
export function markSelected(view: EditorView) {
  const { from, to, empty } = view.state.selection.main, { tables } = structureOf(view.state);
  for (const dom of view.contentDOM.querySelectorAll<HTMLElement>(".md-table")) {
    const at = view.posAtDOM(dom), table = tables.find((x) => x.from === at);
    dom.classList.toggle("selected", !empty && !!table && from <= table.from && to >= table.to);
  }
}

export function tableViewAt(view: EditorView, pos: number): TableView | undefined {
  for (const dom of view.contentDOM.querySelectorAll<HTMLElement>(".md-table")) {
    const from = view.posAtDOM(dom), table = structureOf(view.state).tables.find((x) => from >= x.from && from <= x.to);
    if (table && pos >= table.from && pos <= table.to) return views.get(dom);
  }
}
