import { useMemo, useRef } from "react";
import type { EditorView } from "@codemirror/view";
import { Bold, ChevronDown, Code, Heading, Italic, Link, List, ListOrdered, ListTodo, Minus, PanelTop, Quote, SquareCode, Strikethrough, Table } from "lucide-react";
import { call } from "../rpc";
import { t } from "../i18n";
import { setSetting, useStore } from "../store";
import { TabBar, SettingsButton } from "../library/LibraryPage";
import { markdownSource } from "../library/Inspector";
import { openMenuAt } from "../ui/menu";
import { format, MarkdownEditor } from "./markdown";
import { ReturnToTabsButton } from "../ui/detach";

/** A Markdown document, or an item's note, in a tab of its own (MD-01): the editor at a comfortable reading width under
 *  a row of the usual formatting tools (设置 ▸ 通用 ▸ 显示 Markdown 文档工具栏, or the button beside the title). */
export function MarkdownTab({ fileId, noteItemId, visible }: { fileId?: string; noteItemId?: string; visible: boolean }) {
  const file = useStore((s) => (fileId ? s.files.get(fileId) : undefined));
  const item = useStore((s) => s.items.get(noteItemId ?? file?.itemId ?? ""));
  const captionWidth = useStore((s) => s.captionWidth);
  const toolbar = useStore((s) => s.settings.markdownToolbar !== false);
  const view = useRef<EditorView | null>(null);
  const source = useMemo(() => noteItemId
    ? { key: `note:${noteItemId}`, load: () => call<string>("note.get", { item: noteItemId }), save: (text: string) => { call("note.set", { item: noteItemId, text }); } }
    : markdownSource(fileId!), [fileId, noteItemId]);
  if (!noteItemId && !file) return null;
  const title = noteItemId ? t("笔记") : item?.kind === "standalone" ? item.title : file!.fileName;
  const subtitle = noteItemId ? item?.title ?? "" : item?.kind === "regular" ? item.title : "";
  const run = (f: (v: EditorView) => void) => (e: React.MouseEvent) => { e.preventDefault(); if (view.current) f(view.current); };
  const tool = (label: string, Icon: any, f: (v: EditorView) => void) =>
    <button title={label} aria-label={label} onMouseDown={run(f)}><Icon size={16} strokeWidth={1.8} /></button>;
  return (
    <div className="md-tab window" style={{ display: visible ? "flex" : "none" }}>
      <div className="titlebar-row drag" style={{ paddingLeft: 10, paddingRight: captionWidth + 8 }}>
        <SettingsButton />
        <ReturnToTabsButton />
        <div className="list-title">
          <div className="name ellipsis" title={title}>{title}</div>
          {subtitle && <div className="count ellipsis" title={subtitle}>{subtitle}</div>}
        </div>
        <button className={`glass-button${toolbar ? " on" : ""}`} title={toolbar ? t("隐藏工具栏") : t("显示工具栏")} aria-pressed={toolbar}
          onClick={() => setSetting("markdownToolbar", !toolbar)}><PanelTop size={16} strokeWidth={1.7} /></button>
      </div>
      <TabBar />
      {toolbar && (
        <div className="md-toolbar">
          <div className="glass-group">
            <button className="with-chevron" title={t("标题")} aria-label={t("标题")} onMouseDown={(e) => {
              e.preventDefault();
              const v = view.current;
              if (!v) return;
              openMenuAt(e.currentTarget, [1, 2, 3, 0].map((level) => ({ label: level ? t("标题 %lld", level) : t("正文"), action: () => format.heading(v, level) })));
            }}><Heading size={16} strokeWidth={1.8} /><ChevronDown size={10} /></button>
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
      )}
      <div className="md-tab-body">
        <div className="md-tab-column">
          <MarkdownEditor source={source} viewRef={view} className="md-text" placeholder={noteItemId ? t("记下想法、摘录与待办… 支持 Markdown") : t("开始书写… 支持 Markdown")} />
        </div>
      </div>
    </div>
  );
}
