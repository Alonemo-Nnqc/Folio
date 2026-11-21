import { useEffect, useMemo, useRef, useState } from "react";
import type { EditorView } from "@codemirror/view";
import { Bold, Code, Heading, Italic, Link, List, ListOrdered, ListTodo, Minus, Quote, SquareCode, Strikethrough, Table } from "lucide-react";
import { call } from "../rpc";
import { t } from "../i18n";
import { useStore } from "../store";
import { TabBar, SettingsButton } from "../library/LibraryPage";
import { markdownSource } from "../library/Inspector";
import { openMenuAt } from "../ui/menu";
import { format, MarkdownEditor } from "./markdown";
import { ReturnToTabsButton } from "../ui/detach";

/** A document's name in its tab's title row, edited in place: Enter renames the file, Esc keeps the name. */
function FileName({ fileId, name }: { fileId: string; name: string }) {
  const [draft, setDraft] = useState(name);
  const editing = useRef(false);
  useEffect(() => { if (!editing.current) setDraft(name); }, [name]);
  const commit = () => {
    editing.current = false;
    const value = draft.trim();
    if (!value) setDraft(name);
    else if (value !== name) call("markdown.rename", { file: fileId, name: value });
  };
  return (
    <input className="doc-name" value={draft} spellCheck={false} aria-label={t("文件名")} size={Math.max(8, Math.min(40, draft.length + 1))}
      onFocus={(e) => { editing.current = true; e.currentTarget.select(); }}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={commit}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") e.currentTarget.blur();
        if (e.key === "Escape") { editing.current = false; setDraft(name); requestAnimationFrame(() => (e.target as HTMLInputElement).blur()); }
      }} />
  );
}

/** A Markdown document, or an item's note, in a tab of its own (MD-01): the name (editable for a document) and the
 *  formatting tools in the title row, the editor at a comfortable reading width below. */
export function MarkdownTab({ fileId, noteItemId, visible }: { fileId?: string; noteItemId?: string; visible: boolean }) {
  const file = useStore((s) => (fileId ? s.files.get(fileId) : undefined));
  const item = useStore((s) => s.items.get(noteItemId ?? file?.itemId ?? ""));
  const captionWidth = useStore((s) => s.captionWidth);
  const view = useRef<EditorView | null>(null);
  const source = useMemo(() => noteItemId
    ? { key: `note:${noteItemId}`, load: () => call<string>("note.get", { item: noteItemId }), save: (text: string) => { call("note.set", { item: noteItemId, text }); } }
    : markdownSource(fileId!), [fileId, noteItemId]);
  if (!noteItemId && !file) return null;
  const name = file ? file.fileName.replace(/\.(md|markdown)$/i, "") : "";
  const subtitle = noteItemId || item?.kind === "regular" ? item?.title ?? "" : "";
  const run = (f: (v: EditorView) => void) => (e: React.MouseEvent) => { e.preventDefault(); if (view.current) f(view.current); };
  const tool = (label: string, Icon: any, f: (v: EditorView) => void) =>
    <button title={label} aria-label={label} onMouseDown={run(f)}><Icon size={16} strokeWidth={1.75} /></button>;
  return (
    <div className="md-tab window" style={{ display: visible ? "flex" : "none" }}>
      <div className="titlebar-row drag" style={{ paddingLeft: 10, paddingRight: captionWidth + 8 }}>
        <SettingsButton />
        <ReturnToTabsButton tabKey={noteItemId ? `note:${noteItemId}` : fileId!} />
        <div className="list-title doc-title">
          {file ? <FileName fileId={file.id} name={name} /> : <div className="name ellipsis">{t("笔记")}</div>}
          {subtitle && <div className="count ellipsis" title={subtitle}>{subtitle}</div>}
        </div>
        <div className="md-tools">
          <div className="glass-group">
            <button title={t("标题")} aria-label={t("标题")} onMouseDown={(e) => {
              e.preventDefault();
              const v = view.current;
              if (!v) return;
              openMenuAt(e.currentTarget, [1, 2, 3, 0].map((level) => ({ label: level ? t("标题 %lld", level) : t("正文"), action: () => format.heading(v, level) })));
            }}><Heading size={16} strokeWidth={1.75} /></button>
          </div>
          <div className="glass-group">
            {tool(t("粗体（Ctrl+B）"), Bold, (v) => format.wrap(v, "**"))}
            {tool(t("斜体（Ctrl+I）"), Italic, (v) => format.wrap(v, "*"))}
            {tool(t("删除线"), Strikethrough, (v) => format.wrap(v, "~~"))}
            {tool(t("行内代码"), Code, (v) => format.wrap(v, "`"))}
            {tool(t("链接（Ctrl+K）"), Link, format.link)}
          </div>
          <div className="glass-group">
            {tool(t("项目列表"), List, (v) => format.lines(v, "bullet"))}
            {tool(t("编号列表"), ListOrdered, (v) => format.lines(v, "numbered"))}
            {tool(t("任务列表"), ListTodo, (v) => format.lines(v, "task"))}
          </div>
          <div className="glass-group">
            {tool(t("引用"), Quote, (v) => format.lines(v, "quote"))}
            {tool(t("代码块"), SquareCode, format.codeBlock)}
            {tool(t("表格"), Table, (v) => format.block(v, `| ${t("列 1")} | ${t("列 2")} |\n| --- | --- |\n|  |  |`, 2))}
            {tool(t("分隔线"), Minus, (v) => format.block(v, "---"))}
          </div>
        </div>
      </div>
      <TabBar />
      <div className="md-tab-body">
        <div className="md-tab-column">
          <MarkdownEditor source={source} viewRef={view} focus className="md-text" placeholder="" />
        </div>
      </div>
    </div>
  );
}
