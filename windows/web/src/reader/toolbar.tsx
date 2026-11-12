import { useRef, useState } from "react";
import { BookText, ChevronDown, Eraser, TextCursorInput, Columns2, GripVertical, Highlighter, MousePointer2, NotebookPen, PanelRight, PenLine, Printer, Search, StickyNote, Strikethrough, Type, Underline, ZoomIn, ZoomOut, MoveHorizontal, ChevronUp } from "lucide-react";
import { t } from "../i18n";
import { TranslateIcon } from "../ui/icons";
import { setSetting } from "../store";
import { Sheet } from "../ui/sheet";

/** What the reader's toolbar can hold. Tools sit together in one glass group. */
export const TOOLBAR_ITEMS: { id: string; title: string; icon: any; tool?: boolean }[] = [
  { id: "view", title: "显示", icon: ChevronDown },
  { id: "select", title: "选择", icon: MousePointer2, tool: true },
  { id: "highlight", title: "高亮", icon: Highlighter, tool: true },
  { id: "underline", title: "下划线", icon: Underline, tool: true },
  { id: "strike", title: "删除线", icon: Strikethrough, tool: true },
  { id: "note", title: "便签", icon: StickyNote, tool: true },
  { id: "textbox", title: "文本框", icon: Type, tool: true },
  { id: "ink", title: "手绘", icon: PenLine, tool: true },
  { id: "eraser", title: "橡皮擦", icon: Eraser, tool: true },
  { id: "color", title: "批注颜色", icon: null },
  { id: "translate", title: "翻译", icon: BookText },
  { id: "editText", title: "编辑 PDF", icon: TextCursorInput },
  { id: "selectionTranslate", title: "划词翻译", icon: TranslateIcon },
  { id: "search", title: "查找", icon: Search },
  { id: "zoomOut", title: "缩小", icon: ZoomOut },
  { id: "zoomIn", title: "放大", icon: ZoomIn },
  { id: "fitWidth", title: "适合页宽", icon: MoveHorizontal },
  { id: "previousPage", title: "上一页", icon: ChevronUp },
  { id: "nextPage", title: "下一页", icon: ChevronDown },
  { id: "parallel", title: "对照阅读", icon: Columns2 },
  { id: "addNote", title: "添加到笔记", icon: NotebookPen },
  { id: "notes", title: "笔记", icon: PanelRight },
  { id: "print", title: "打印", icon: Printer },
];

export const DEFAULT_TOOLBAR = ["view", "select", "highlight", "underline", "strike", "note", "textbox", "ink", "eraser", "color", "translate", "editText", "search"];

export function toolbarIds(stored: unknown): string[] {
  const known = new Set(TOOLBAR_ITEMS.map((i) => i.id));
  const list = Array.isArray(stored) ? (stored as string[]).filter((id) => known.has(id)) : [];
  return list.length ? list : DEFAULT_TOOLBAR;
}

/** 自定义工具栏: check what the toolbar shows and drag to put it in order. */
export function CustomizeToolbarSheet({ current, close }: { current: string[]; close: () => void }) {
  const [order, setOrder] = useState<string[]>(() => [...current, ...TOOLBAR_ITEMS.map((i) => i.id).filter((id) => !current.includes(id))]);
  const [shown, setShown] = useState<Set<string>>(() => new Set(current));
  const dragging = useRef<string | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const save = () => { setSetting("readerToolbar", order.filter((id) => shown.has(id))); close(); };
  const reset = () => { setOrder([...DEFAULT_TOOLBAR, ...TOOLBAR_ITEMS.map((i) => i.id).filter((id) => !DEFAULT_TOOLBAR.includes(id))]); setShown(new Set(DEFAULT_TOOLBAR)); };
  return (
    <Sheet title={t("自定义工具栏")} width={400} onEscape={close} actions={
      <>
        <button className="btn" style={{ marginRight: "auto" }} onClick={reset}>{t("恢复默认")}</button>
        <button className="btn" onClick={close}>{t("取消")}</button>
        <button className="btn primary" disabled={shown.size === 0} onClick={save}>{t("完成")}</button>
      </>}>
      <div className="toolbar-editor">
        {order.map((id) => {
          const item = TOOLBAR_ITEMS.find((i) => i.id === id)!;
          const Icon = item.icon;
          return (
            <label key={id} className={`te-row${over === id ? " over" : ""}`} draggable
              onDragStart={(e) => { dragging.current = id; e.dataTransfer.effectAllowed = "move"; }}
              onDragOver={(e) => { if (dragging.current && dragging.current !== id) { e.preventDefault(); setOver(id); } }}
              onDragLeave={() => setOver((o) => (o === id ? null : o))}
              onDrop={(e) => {
                e.preventDefault();
                const from = dragging.current;
                dragging.current = null; setOver(null);
                if (!from || from === id) return;
                setOrder((list) => { const next = list.filter((x) => x !== from); next.splice(next.indexOf(id), 0, from); return next; });
              }}
              onDragEnd={() => { dragging.current = null; setOver(null); }}>
              <GripVertical size={14} className="te-grip" />
              <input type="checkbox" checked={shown.has(id)} onChange={(e) => setShown((s) => { const n = new Set(s); if (e.target.checked) n.add(id); else n.delete(id); return n; })} />
              <span className="te-icon">{Icon ? <Icon size={15} strokeWidth={1.8} /> : <span className="color-dot" style={{ background: "#FFD933" }} />}</span>
              <span>{t(item.title)}</span>
            </label>
          );
        })}
      </div>
    </Sheet>
  );
}
