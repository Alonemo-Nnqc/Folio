import { Fragment, useEffect, useRef, useState, type ReactNode } from "react";
import { call } from "../rpc";
import { t } from "../i18n";
import { useStore } from "../store";

// Markdown for notes and documents (MD-01): the editing keys of the macOS editor (a list or quote goes on at Return, Tab
// and Shift+Tab nest list items, Ctrl+B / Ctrl+I / Ctrl+K wrap the selection) on a plain text box, and a rendered view
// whose task boxes can be ticked.

// MARK: Editing keys

const LIST = /^([ \t]*(?:>[ \t]?)*[ \t]*)(?:([-*+])([ \t]+\[[ xX]\])?|(\d{1,9})([.)]))([ \t]+)/;
const QUOTE = /^([ \t]*(?:>[ \t]?)+)/;

/** Replaces [start, end) with text as if typed: the text box keeps it in its own undo. */
function replace(box: HTMLTextAreaElement, start: number, end: number, text: string) {
  box.focus();
  box.setSelectionRange(start, end);
  if (!document.execCommand("insertText", false, text)) {
    box.setRangeText(text, start, end, "end");
    box.dispatchEvent(new Event("input", { bubbles: true }));
  }
}

function lineStart(text: string, at: number) { return text.lastIndexOf("\n", at - 1) + 1; }
function lineEnd(text: string, at: number) { const n = text.indexOf("\n", at); return n < 0 ? text.length : n; }

/** Inside a fenced code block: Return keeps the indentation and nothing else. */
function inCodeBlock(text: string, at: number) {
  let open = false;
  for (const line of text.slice(0, lineStart(text, at)).split("\n")) if (/^\s*(```|~~~)/.test(line)) open = !open;
  return open;
}

function newline(box: HTMLTextAreaElement): boolean {
  const text = box.value;
  const caret = box.selectionStart;
  if (caret !== box.selectionEnd) return false;
  const start = lineStart(text, caret), end = lineEnd(text, caret);
  const line = text.slice(start, end);
  if (inCodeBlock(text, caret)) {
    replace(box, caret, caret, "\n" + (line.match(/^[ \t]*/)?.[0] ?? ""));
    return true;
  }
  if (caret === start) return false;
  const list = LIST.exec(line);
  if (list) {
    const marker = list[0].length;
    // An empty item ends the list (Return on "- " leaves an empty line).
    if (marker >= line.length) { replace(box, start, start + marker, ""); return true; }
    if (caret < start + marker) return false;
    const next = list[2] !== undefined
      ? list[1] + list[2] + (list[3] !== undefined ? " [ ]" : "") + list[6]
      : list[1] + (Number(list[4]) + 1) + list[5] + list[6];
    replace(box, caret, caret, "\n" + next);
    return true;
  }
  const quote = QUOTE.exec(line);
  if (quote) {
    if (quote[0].length >= line.length) { replace(box, start, start + quote[0].length, ""); return true; }
    replace(box, caret, caret, "\n" + quote[0]);
    return true;
  }
  return false;
}

/** Nests (or un-nests) the list items the selection touches. False when it touches none. */
function indent(box: HTMLTextAreaElement, step: 1 | -1): boolean {
  const text = box.value;
  const from = lineStart(text, box.selectionStart), to = lineEnd(text, box.selectionEnd);
  const lines = text.slice(from, to).split("\n");
  if (!lines.every((l) => LIST.test(l))) return false;
  const changed = lines.map((l) => (step > 0 ? "  " + l : l.replace(/^ {1,2}/, "")));
  const selStart = box.selectionStart, selEnd = box.selectionEnd;
  const firstShift = changed[0].length - lines[0].length;
  const total = changed.join("\n").length - (to - from);
  replace(box, from, to, changed.join("\n"));
  box.setSelectionRange(Math.max(from, selStart + firstShift), Math.max(from, selEnd + total));
  return true;
}

/** Wraps the selection in marker (or unwraps it); with nothing selected, puts the caret between a pair. */
function wrap(box: HTMLTextAreaElement, marker: string) {
  const text = box.value;
  const a = box.selectionStart, b = box.selectionEnd, m = marker.length;
  const selected = text.slice(a, b);
  if (selected.length >= 2 * m && selected.startsWith(marker) && selected.endsWith(marker)) {
    replace(box, a, b, selected.slice(m, -m));
    box.setSelectionRange(a, b - 2 * m);
  } else if (a >= m && text.slice(a - m, a) === marker && text.slice(b, b + m) === marker) {
    replace(box, a - m, b + m, selected);
    box.setSelectionRange(a - m, b - m);
  } else {
    replace(box, a, b, marker + selected + marker);
    box.setSelectionRange(a + m, b + m);
  }
}

function link(box: HTMLTextAreaElement) {
  const a = box.selectionStart, b = box.selectionEnd;
  const selected = box.value.slice(a, b);
  replace(box, a, b, `[${selected}](https://)`);
  if (selected) box.setSelectionRange(a + selected.length + 3, a + selected.length + 11);
  else box.setSelectionRange(a + 1, a + 1);
}

/** The editor's own keys; true when the key was used. */
export function markdownKeyDown(e: React.KeyboardEvent<HTMLTextAreaElement>): boolean {
  const box = e.currentTarget;
  if (e.nativeEvent.isComposing || e.keyCode === 229) return false;
  let used = false;
  if (e.key === "Enter" && !e.shiftKey && !e.ctrlKey && !e.altKey) used = newline(box);
  else if (e.key === "Tab" && !e.ctrlKey && !e.altKey) used = indent(box, e.shiftKey ? -1 : 1);
  else if (e.ctrlKey && !e.altKey && !e.shiftKey) {
    if (e.code === "KeyB") { wrap(box, "**"); used = true; }
    else if (e.code === "KeyI") { wrap(box, "*"); used = true; }
    else if (e.code === "KeyK") { link(box); used = true; }
  }
  if (used) e.preventDefault();
  return used;
}

/** Ticks or unticks the task on the given line (0-based) of text. */
export function toggleTask(text: string, line: number): string {
  const lines = text.split("\n");
  const match = /^([ \t]*(?:>[ \t]?)*[ \t]*[-*+][ \t]+\[)([ xX])(\])/.exec(lines[line] ?? "");
  if (!match) return text;
  lines[line] = match[1] + (match[2] === " " ? "x" : " ") + match[3] + lines[line].slice(match[0].length);
  return lines.join("\n");
}

// MARK: Rendering

function inline(text: string, key: string): ReactNode[] {
  const out: ReactNode[] = [];
  const pattern = /(`+)([^`]+?)\1|\*\*([^*]+?)\*\*|__([^_]+?)__|\*([^*\s][^*]*?)\*|_([^_\s][^_]*?)_|~~([^~]+?)~~|!\[([^\]]*)\]\(([^)\s]+)[^)]*\)|\[([^\]]+)\]\(([^)\s]+)[^)]*\)|(https?:\/\/[^\s<>()]+)/g;
  let last = 0, k = 0, m: RegExpExecArray | null;
  while ((m = pattern.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const id = `${key}-${k++}`;
    if (m[2] !== undefined) out.push(<code key={id}>{m[2]}</code>);
    else if (m[3] !== undefined || m[4] !== undefined) out.push(<strong key={id}>{inline(m[3] ?? m[4], id)}</strong>);
    else if (m[5] !== undefined || m[6] !== undefined) out.push(<em key={id}>{inline(m[5] ?? m[6], id)}</em>);
    else if (m[7] !== undefined) out.push(<del key={id}>{inline(m[7], id)}</del>);
    else if (m[9] !== undefined) out.push(<span key={id} className="md-image" title={m[9]}>🖼 {m[8] || m[9]}</span>);
    else {
      const target = m[11] ?? m[12];
      const label = m[10] !== undefined ? inline(m[10], id) : target;
      out.push(<a key={id} href={target} onClick={(e) => { e.preventDefault(); e.stopPropagation(); if (/^https?:/i.test(target)) call("shell.open", { target }); }}>{label}</a>);
    }
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

/** The text as it reads: headings, emphasis, code, links, quotes, lists and tasks (clickable), tables, rules. */
export function MarkdownView({ text, onToggleTask }: { text: string; onToggleTask?: (line: number) => void }) {
  const lines = text.split("\n");
  const blocks: ReactNode[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const key = `b${i}`;
    const fence = /^\s*(```|~~~)/.exec(line);
    if (fence) {
      const body: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith(fence[1])) body.push(lines[i++]);
      i++;
      blocks.push(<pre key={key}><code>{body.join("\n")}</code></pre>);
      continue;
    }
    const heading = /^(#{1,6})[ \t]+(.*)$/.exec(line);
    if (heading) {
      const H = `h${heading[1].length}` as "h1";
      blocks.push(<H key={key}>{inline(heading[2].replace(/[ \t]#+[ \t]*$/, ""), key)}</H>);
      i++;
      continue;
    }
    if (/^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$/.test(line)) { blocks.push(<hr key={key} />); i++; continue; }
    if (/^[ \t]*\|.*\|[ \t]*$/.test(line) && i + 1 < lines.length && /^[ \t]*\|?[ \t:|-]+\|[ \t:|-]*$/.test(lines[i + 1]) && lines[i + 1].includes("-")) {
      const cells = (l: string) => l.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
      const head = cells(line);
      const rows: string[][] = [];
      i += 2;
      while (i < lines.length && /^[ \t]*\|.*\|[ \t]*$/.test(lines[i])) rows.push(cells(lines[i++]));
      blocks.push(
        <table key={key}><thead><tr>{head.map((c, k) => <th key={k}>{inline(c, `${key}h${k}`)}</th>)}</tr></thead>
          <tbody>{rows.map((r, n) => <tr key={n}>{r.map((c, k) => <td key={k}>{inline(c, `${key}r${n}c${k}`)}</td>)}</tr>)}</tbody></table>);
      continue;
    }
    if (/^[ \t]*>/.test(line)) {
      const body: string[] = [];
      while (i < lines.length && /^[ \t]*>/.test(lines[i])) body.push(lines[i++].replace(/^[ \t]*>[ \t]?/, ""));
      blocks.push(<blockquote key={key}><MarkdownView text={body.join("\n")} /></blockquote>);
      continue;
    }
    const item = /^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$/.exec(line);
    if (item) {
      const items: ReactNode[] = [];
      const ordered = /\d/.test(item[2]);
      while (i < lines.length) {
        const m = /^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$/.exec(lines[i]);
        if (!m || /\d/.test(m[2]) !== ordered) break;
        const depth = Math.floor(m[1].replace(/\t/g, "    ").length / 2);
        const task = /^\[([ xX])\][ \t]+(.*)$/.exec(m[3]);
        const at = i;
        items.push(
          <li key={at} style={depth ? { marginLeft: depth * 18 } : undefined} className={task ? "md-task" : undefined}>
            {task ? (
              <>
                <input type="checkbox" checked={task[1] !== " "} readOnly={!onToggleTask} onChange={() => onToggleTask?.(at)} onClick={(e) => e.stopPropagation()} />
                <span className={task[1] !== " " ? "done" : undefined}>{inline(task[2], `${key}t${at}`)}</span>
              </>
            ) : inline(m[3], `${key}i${at}`)}
          </li>);
        i++;
      }
      blocks.push(ordered ? <ol key={key} start={Number(item[2].replace(/\D/g, "")) || 1}>{items}</ol> : <ul key={key}>{items}</ul>);
      continue;
    }
    if (!line.trim()) { i++; continue; }
    const para: string[] = [];
    while (i < lines.length && lines[i].trim() && !/^(#{1,6})[ \t]|^\s*(```|~~~)|^[ \t]*>|^[ \t]*([-*+]|\d{1,9}[.)])[ \t]|^[ \t]*\|.*\|[ \t]*$/.test(lines[i])) para.push(lines[i++]);
    if (para.length === 0) { blocks.push(<p key={key}>{inline(line, key)}</p>); i++; continue; }
    blocks.push(<p key={key}>{para.map((l, k) => <Fragment key={k}>{k > 0 && <br />}{inline(l, `${key}p${k}`)}</Fragment>)}</p>);
  }
  return <div className="md-view selectable">{blocks}</div>;
}

// MARK: Editor

export interface MarkdownSource {
  /** What is being edited ("note:<item>", "file:<file>"): another key loads afresh. */
  key: string | null;
  load: () => Promise<string>;
  save: (text: string) => void;
}

/** A Markdown text: typed in a plain box with the Markdown keys, or read rendered (预览). Saved a moment after typing
 *  stops; when someone else (another tab, an agent) changes it, what is being typed is not overwritten. */
export function MarkdownEditor({ source, placeholder, inputRef, focus, preview, className }: {
  source: MarkdownSource; placeholder: string; inputRef?: React.MutableRefObject<HTMLTextAreaElement | null>; focus?: boolean;
  preview?: boolean; className?: string;
}) {
  const [text, setText] = useState("");
  const saved = useRef("");
  const shown = useRef<MarkdownSource | null>(null);
  const timer = useRef(0);
  const box = useRef<HTMLTextAreaElement | null>(null);
  const version = useStore((s) => s.libraryVersion);
  const composing = useRef(false);

  const flush = () => {
    clearTimeout(timer.current);
    const value = box.current?.value;
    const current = shown.current;
    if (current?.key && value !== undefined && value !== saved.current) {
      saved.current = value;
      current.save(value);
    }
  };

  useEffect(() => {
    flush();
    shown.current = source;
    if (!source.key) { setText(""); saved.current = ""; return; }
    let live = true;
    source.load().then((value) => {
      if (!live) return;
      saved.current = value;
      setText(value);
      if (focus) requestAnimationFrame(() => { box.current?.focus(); box.current?.setSelectionRange(value.length, value.length); });
    });
    return () => { live = false; };
  }, [source.key]);

  // Someone else changed it: what is being typed here is not overwritten.
  useEffect(() => {
    if (!source.key || document.activeElement === box.current || box.current?.value !== saved.current) return;
    source.load().then((value) => {
      if (value !== saved.current && document.activeElement !== box.current) { saved.current = value; setText(value); }
    });
  }, [version]);

  useEffect(() => flush, []);

  const changed = (value: string) => {
    setText(value);
    clearTimeout(timer.current);
    // Not while a word is being composed (IME): the box would be rewritten under it.
    timer.current = window.setTimeout(() => { if (!composing.current) flush(); }, 700);
  };

  if (preview) {
    return (
      <div className={`md-preview ${className ?? ""}`}>
        {text.trim() ? <MarkdownView text={text} onToggleTask={(line) => { const next = toggleTask(text, line); changed(next); saved.current = next; source.save(next); }} />
          : <div className="secondary">{placeholder}</div>}
      </div>
    );
  }
  return (
    <textarea ref={(el) => { box.current = el; if (inputRef) inputRef.current = el; }} className={className} disabled={!source.key} value={text} spellCheck={false}
      placeholder={placeholder}
      onChange={(e) => changed(e.target.value)}
      onCompositionStart={() => { composing.current = true; }}
      onCompositionEnd={() => { composing.current = false; }}
      onBlur={flush}
      onKeyDown={(e) => { e.stopPropagation(); markdownKeyDown(e); }} />
  );
}

/** "编辑" and "预览" side by side. */
export function PreviewToggle({ preview, onChange }: { preview: boolean; onChange: (preview: boolean) => void }) {
  return (
    <div className="md-toggle" role="group">
      <button className={!preview ? "on" : ""} onClick={() => onChange(false)}>{t("编辑")}</button>
      <button className={preview ? "on" : ""} onClick={() => onChange(true)}>{t("预览")}</button>
    </div>
  );
}
