import { useEffect, useMemo, useRef, useState } from "react";
import type { EditorView } from "@codemirror/view";
import { FileText } from "lucide-react";
import { call } from "../rpc";
import { t } from "../i18n";
import { docName, setState, useStore } from "../store";
import { TabBar, SettingsButton } from "../library/LibraryPage";
import { markdownSource } from "../library/Inspector";
import { openItems } from "../commands";
import { styleAt, wordCount } from "./blocks";
import { MarkdownEditor } from "./markdown";
import { DocumentTools, MarkdownTools } from "./MarkdownTools";
import { mdOf } from "./prefs";
import { ReturnToTabsButton } from "../ui/detach";

/** A document's name in its tab's title row, edited in place: Enter renames the file, Esc keeps the name. */
function FileName({ fileId, name }: { fileId: string; name: string }) {
  const [draft, setDraft] = useState(name);
  const editing = useRef(false);
  const field = useRef<HTMLInputElement>(null);
  // A new document: its name is selected, to be typed over; Enter goes on to the text.
  const naming = useStore((s) => s.naming === fileId);
  useEffect(() => {
    if (!naming) return;
    const timer = setTimeout(() => { field.current?.focus(); field.current?.select(); setState({ naming: null }); }, 120);
    return () => clearTimeout(timer);
  }, [naming]);
  useEffect(() => { if (!editing.current) setDraft(name); }, [name]);
  const commit = () => {
    editing.current = false;
    const value = draft.trim();
    if (!value) setDraft(name);
    else if (value !== name) call("markdown.rename", { file: fileId, name: value });
  };
  return (
    <input ref={field} className="doc-name" value={draft} spellCheck={false} aria-label={t("文件名")} size={Math.max(8, Math.min(40, draft.length + 1))}
      onFocus={(e) => { editing.current = true; e.currentTarget.select(); }}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={commit}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") { e.currentTarget.closest(".md-tab")?.querySelector<HTMLElement>(".cm-content")?.focus(); e.currentTarget.blur(); }
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
  const tools = useStore((s) => mdOf(s.settings, "markdownToolbar"));
  const counts = useStore((s) => mdOf(s.settings, "markdownShowsWordCount"));
  const view = useRef<EditorView | null>(null);
  const [style, setStyleName] = useState("text");
  const [count, setCount] = useState(0);
  const countTimer = useRef(0);
  const onUpdate = (v: EditorView) => {
    setStyleName(styleAt(v, v.state.selection.main.head));
    clearTimeout(countTimer.current);
    countTimer.current = window.setTimeout(() => setCount(wordCount(v.state.doc.toString())), 200);
  };
  const hasPaper = !!item && item.kind === "regular" && !!item.defaultFileId;
  const source = useMemo(() => noteItemId
    ? { key: `note:${noteItemId}`, load: () => call<string>("note.get", { item: noteItemId }), save: (text: string) => { call("note.set", { item: noteItemId, text }); } }
    : markdownSource(fileId!), [fileId, noteItemId]);
  if (!noteItemId && !file) return null;
  const name = file ? docName(file) : "";
  const subtitle = noteItemId || item?.kind === "regular" ? item?.title ?? "" : "";
  return (
    <div className="md-tab window" style={{ display: visible ? "flex" : "none" }}>
      <div className="titlebar-row drag" style={{ paddingLeft: 10, paddingRight: captionWidth + 8 }}>
        <SettingsButton />
        <ReturnToTabsButton tabKey={noteItemId ? `note:${noteItemId}` : fileId!} />
        <div className="list-title doc-title">
          {file ? <FileName fileId={file.id} name={name} /> : <div className="name ellipsis">{t("笔记")}</div>}
          {subtitle && <div className="count ellipsis" title={subtitle}>{subtitle}</div>}
        </div>
        {tools && <div className="md-tools"><MarkdownTools view={view} style={style} /></div>}
        <div className="md-tools end">
          <div className="glass-group">
            {hasPaper && <button title={t("打开论文")} aria-label={t("打开论文")} onClick={() => openItems([item!.id])}><FileText size={16} strokeWidth={1.75} /></button>}
            <DocumentTools panel={false} view={view} />
          </div>
        </div>
      </div>
      <TabBar />
      <div className="md-tab-body">
        <div className="md-tab-column">
          <MarkdownEditor source={source} viewRef={view} focus gutter onUpdate={onUpdate} className="md-text" placeholder="" />
        </div>
        {counts && count > 0 && <div className="md-count tabular">{t("%lld 字", count)}</div>}
      </div>
    </div>
  );
}
