import { useEffect, useLayoutEffect, useRef, useState, type ComponentProps, type MutableRefObject } from "react";
import { EditorSelection } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { Bold, ChevronDown, Code, Highlighter, AArrowUp, Ellipsis, Italic, Link, List, ListOrdered, ListTodo, ListTree, Plus, Quote, SquareCode, Strikethrough, Table, TextQuote } from "lucide-react";
import { t } from "../i18n";
import { openMenuAt, type MenuEntry } from "../ui/menu";
import { commandIcon } from "./BlockMenu";
import { commands, headings, insertTable, openSlashMenu, setStyle, styleAt, wordCount } from "./blocks";
import { format, MarkdownEditor } from "./markdown";
import { useStore } from "../store";
import { call } from "../rpc";
import { md, mdOf, setMd, setTextSize, stepZoom, textSize, zoomOf } from "./prefs";

export const FACES = () => [["system", t("系统默认")], ["serif", t("衬线")], ["rounded", t("圆体")], ["mono", t("等宽")]] as [string, string][];
export const WIDTHS = () => [[620, t("窄")], [760, t("标准")], [920, t("宽")], [1120, t("更宽")], [0, t("整个窗口")]] as [number, string][];

/** Sizes, spacing, typeface and width, as in 设置 ▸ Markdown. */
export function appearanceMenu(panel: boolean, view: EditorView | null): MenuEntry[] {
  const size = textSize(panel), near = (a: number, b: number) => Math.abs(a - b) < 0.01;
  return [
    { label: t("放大"), key: "Ctrl+=", action: () => view && stepZoom(view, 1, panel) },
    { label: t("缩小"), key: "Ctrl+-", action: () => view && stepZoom(view, -1, panel) },
    { label: t("实际大小（现为 %lld%%）", Math.round(zoomOf(panel) * 100)), key: "Ctrl+0", action: () => view && stepZoom(view, 0, panel) },
    { kind: "separator" },
    { label: t("字号"), submenu: [11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24].map((v) => ({ label: `${v} px`, checked: size === v, action: () => setTextSize(v, panel) })) },
    { label: t("行高"), submenu: [1.3, 1.45, 1.6, 1.75, 1.9, 2.1].map((v) => ({ label: v.toFixed(2), checked: near(md("markdownLineHeight"), v), action: () => setMd("markdownLineHeight", v) })) },
    { label: t("段落间距"), submenu: [0, 0.2, 0.4, 0.6, 0.8, 1].map((v) => ({ label: v.toFixed(1), checked: near(md("markdownParagraphSpacing"), v), action: () => setMd("markdownParagraphSpacing", v) })) },
    { label: t("字体"), submenu: FACES().map(([key, title]) => ({ label: title, checked: md("markdownTypeface") === key, action: () => setMd("markdownTypeface", key) })) },
    { label: t("文档宽度"), submenu: WIDTHS().map(([w, title]) => ({ label: title, checked: md("markdownReadableWidth") === w, action: () => setMd("markdownReadableWidth", w) })) },
    { kind: "separator" },
    { label: t("Markdown 设置…"), action: () => call("window.settings", { page: "markdown" }) },
  ];
}

/** The document's headings, to go to. */
function outlineMenu(v: EditorView): MenuEntry[] {
  const list = headings(v), top = Math.min(...list.map((h) => h.level));
  return list.length ? list.map((h): MenuEntry => ({ label: h.title, indent: Math.min(h.level - top, 5), action: () => {
    v.focus();
    v.dispatch({ selection: EditorSelection.cursor(v.state.doc.lineAt(h.from).to), effects: EditorView.scrollIntoView(h.from, { y: "start", yMargin: 16 }) });
  } })) : [{ label: t("没有标题"), disabled: true }];
}

function styleMenu(v: EditorView): MenuEntry[] {
  const entries: MenuEntry[] = [];
  commands.forEach((c, n) => {
    if (!c.style) return;
    if (n > 0 && commands[n - 1].section !== c.section) entries.push({ kind: "separator" });
    entries.push({ label: c.title(), icon: commandIcon(c.id), checked: styleAt(v, v.state.selection.main.head) === c.style, action: () => setStyle(v, c.style!) });
  });
  return entries;
}

interface Tool { label: string; Icon: typeof Bold; run?: (v: EditorView) => void; menu?: (v: EditorView) => MenuEntry[] }
type Viewed = MutableRefObject<EditorView | null>;

function ToolButton({ tool: { label, Icon, run, menu }, view }: { tool: Tool; view: Viewed }) {
  return <button title={label} aria-label={label} onMouseDown={(e) => {
    e.preventDefault();
    const v = view.current;
    if (!v) return;
    if (menu) openMenuAt(e.currentTarget, menu(v));
    else run?.(v);
  }}><Icon size={16} strokeWidth={1.75} /></button>;
}

/** Sizes and the outline: what is about the whole document. */
const documentTools = (panel: boolean): Tool[] => [
  { label: t("文字大小、行高和宽度"), Icon: AArrowUp, menu: (v) => appearanceMenu(panel, v) },
  { label: t("大纲"), Icon: ListTree, menu: outlineMenu },
];

export function DocumentTools({ panel, view }: { panel: boolean; view: Viewed }) {
  return <>{documentTools(panel).map((tool) => <ToolButton key={tool.label} tool={tool} view={view} />)}</>;
}

/** The formatting tools; rank: which go first when there is no room (the highest). */
const toolGroups = (): { tools: Tool[]; rank: number }[] => [
  { rank: 1, tools: [{ label: t("粗体（Ctrl+B）"), Icon: Bold, run: (v) => format.wrap(v, "**") }, { label: t("斜体（Ctrl+I）"), Icon: Italic, run: (v) => format.wrap(v, "*") },
    { label: t("删除线"), Icon: Strikethrough, run: (v) => format.wrap(v, "~~") }, { label: t("高亮"), Icon: Highlighter, run: (v) => format.wrap(v, "==") }, { label: t("行内代码"), Icon: Code, run: (v) => format.wrap(v, "`") }] },
  { rank: 3, tools: [{ label: t("项目列表"), Icon: List, run: (v) => format.lines(v, "bullet") }, { label: t("编号列表"), Icon: ListOrdered, run: (v) => format.lines(v, "numbered") }, { label: t("任务列表"), Icon: ListTodo, run: (v) => format.lines(v, "task") }] },
  { rank: 4, tools: [{ label: t("引用块"), Icon: TextQuote, run: (v) => format.lines(v, "quote") }, { label: t("代码块"), Icon: SquareCode, run: format.codeBlock }, { label: t("表格"), Icon: Table, run: insertTable }] },
  { rank: 2, tools: [{ label: t("链接（Ctrl+K）"), Icon: Link, run: format.link }, { label: t("引用文献"), Icon: Quote, run: (v) => openSlashMenu(v, true) }, { label: t("插入（/）"), Icon: Plus, run: (v) => openSlashMenu(v) }] },
];

function StyleButton({ view, style }: { view: Viewed; style: string }) {
  return (
    <button className="md-style" title={t("段落样式")} aria-label={t("段落样式")} onMouseDown={(e) => {
      e.preventDefault();
      if (view.current) openMenuAt(e.currentTarget, styleMenu(view.current));
    }}><span>{styleTitle(style)}</span><ChevronDown size={12} strokeWidth={2} /></button>
  );
}

const styleTitle = (style: string) => commands.find((c) => c.style === style)?.title() ?? "";

/** The formatting tools of a document's tab. */
export function MarkdownTools({ view, style }: { view: Viewed; style: string }) {
  return <>
    <div className="glass-group"><StyleButton view={view} style={style} /></div>
    {toolGroups().map((g, n) => <div key={n} className="glass-group">{g.tools.map((tool) => <ToolButton key={tool.label} tool={tool} view={view} />)}</div>)}
  </>;
}

let ruler: CanvasRenderingContext2D | null = null;
function textWidth(text: string) {
  ruler ??= document.createElement("canvas").getContext("2d")!;
  ruler.font = `12.5px ${getComputedStyle(document.body).fontFamily}`;
  return ruler.measureText(text).width;
}

/** The tools of a side panel: those there is room for, in its middle; the rest are in the menu at their end. */
function PanelTools({ view, style, width }: { view: Viewed; style: string; width: number }) {
  const all = [...toolGroups(), { tools: documentTools(true), rank: 5 }];
  const gap = 6, group = (buttons: number) => buttons * 28 + 4;
  const room = width - 12 - (textWidth(styleTitle(style)) + 41);
  const shown = new Set(all);
  const wide = () => [...shown].reduce((sum, g) => sum + group(g.tools.length) + gap, 0) + (shown.size < all.length ? group(1) + gap : 0);
  while (shown.size && wide() > room) shown.delete([...shown].reduce((a, b) => (a.rank > b.rank ? a : b)));
  const rest = all.filter((g) => !shown.has(g));
  const more: Tool = { label: t("更多工具"), Icon: Ellipsis, menu: (v) => rest.flatMap((g, n): MenuEntry[] => [...(n ? [{ kind: "separator" } as MenuEntry] : []), ...g.tools.map(({ label, Icon, run, menu }): MenuEntry =>
    ({ label, icon: <Icon size={14} />, ...(menu ? { submenu: menu(v) } : { action: () => run!(v) }) }))]) };
  return (
    <div className="md-tools md-panel-tools">
      <div className="glass-group"><StyleButton view={view} style={style} /></div>
      {all.map((g, n) => shown.has(g) && <div key={n} className="glass-group">{g.tools.map((tool) => <ToolButton key={tool.label} tool={tool} view={view} />)}</div>)}
      {rest.length > 0 && <div className="glass-group"><ToolButton tool={more} view={view} /></div>}
    </div>
  );
}

/** A Markdown editor in a side panel: what a document's tab is — the handles beside the lines, the tools in the middle above, the
 *  number of words — as wide as the panel. */
export function MarkdownPanel(props: ComponentProps<typeof MarkdownEditor>) {
  const box = useRef<HTMLDivElement>(null);
  const own = useRef<EditorView | null>(null);
  const view = props.viewRef ?? own;
  const [width, setWidth] = useState(0);
  const [style, setStyleName] = useState("text");
  const [count, setCount] = useState(0);
  const countTimer = useRef(0);
  useEffect(() => () => clearTimeout(countTimer.current), []);
  useLayoutEffect(() => {
    const observer = new ResizeObserver(([entry]) => setWidth(Math.round(entry.contentRect.width)));
    observer.observe(box.current!);
    return () => observer.disconnect();
  }, []);
  const tools = useStore((s) => mdOf(s.settings, "markdownToolbar"));
  const counts = useStore((s) => mdOf(s.settings, "markdownShowsWordCount"));
  return (
    <div className="md-panel" ref={box}>
      {tools && width > 0 && <PanelTools view={view} style={style} width={width} />}
      <MarkdownEditor {...props} viewRef={view} gutter panel onUpdate={(v) => {
        setStyleName(styleAt(v, v.state.selection.main.head));
        clearTimeout(countTimer.current);
        countTimer.current = window.setTimeout(() => setCount(wordCount(v.state.doc.toString())), 200);
      }} />
      {counts && count > 0 && <div className="md-count tabular">{t("%lld 字", count)}</div>}
    </div>
  );
}
