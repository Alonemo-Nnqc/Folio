import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { ArrowDown, ArrowDownToLine, ArrowUp, ArrowUpToLine, Calendar, Copy, CopyPlus, Link, List, ListOrdered, ListTodo, Minus, Quote, SquareCode, Table, TextQuote, Trash2 } from "lucide-react";
import { t } from "../i18n";

export interface MenuItem { kind: "command" | "reference"; id: string; title: string; detail: string; section?: string; markdown?: string }

/** A tool's picture: the letters that stand for a heading, or its symbol. */
export function commandIcon(id: string): ReactNode {
  const letters = { text: "T", h1: "H1", h2: "H2", h3: "H3" } as Record<string, string>;
  if (letters[id]) return <span className="md-letter">{letters[id]}</span>;
  const Icon = ({ bullet: List, numbered: ListOrdered, task: ListTodo, quote: TextQuote, code: SquareCode, table: Table, rule: Minus, cite: Quote, link: Link, date: Calendar,
    above: ArrowUpToLine, below: ArrowDownToLine, up: ArrowUp, down: ArrowDown, duplicate: CopyPlus, copy: Copy, delete: Trash2 } as Record<string, any>)[id];
  return Icon ? <Icon size={15} strokeWidth={1.75} /> : null;
}

const SECTIONS: Record<string, string> = { style: "文字", list: "列表", block: "区块", insert: "插入" };

/** The menu "/" opens: one quiet column, the tool's symbol, its name and the Markdown it stands for; or the papers to cite. */
export function BlockMenu({ items, selected, citing, x, top, bottom, onPick, onHover }: {
  items: MenuItem[]; selected: number; citing: boolean; x: number; top: number; bottom: number; onPick: (n: number) => void; onHover: (n: number) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);
  useLayoutEffect(() => {
    const el = ref.current!;
    const h = el.offsetHeight, w = el.offsetWidth;
    const below = bottom + 4;
    setPos({ left: Math.max(6, Math.min(x, innerWidth - w - 6)), top: below + h <= innerHeight - 6 ? below : Math.max(6, top - h - 4) });
  }, [x, top, bottom, items.length, citing]);
  useLayoutEffect(() => { ref.current?.querySelector(".on")?.scrollIntoView({ block: "nearest" }); }, [selected, items]);
  return createPortal(
    <div ref={ref} className={`menu md-slash${citing ? " citing" : ""}`} style={pos ? pos : { left: x, top: bottom, visibility: "hidden" }} onMouseDown={(e) => e.preventDefault()}>
      {citing && <div className="menu-title">{items.length ? t("输入标题、作者或年份") : t("没有找到文献")}</div>}
      {items.map((item, n) => (
        <div key={item.id}>
          {item.section && items[n - 1]?.section !== item.section && <div className="menu-title">{t(SECTIONS[item.section])}</div>}
          <div className={`md-slash-row${n === selected ? " on" : ""}`} onMouseMove={() => onHover(n)} onClick={() => onPick(n)}>
            {item.kind === "command" ? <>
              <span className="icon">{commandIcon(item.id)}</span>
              <span className="name">{item.title}</span>
              <span className="hint">{item.detail}</span>
            </> : <span className="paper"><span className="ellipsis">{item.title}</span><span className="sub ellipsis">{item.detail}</span></span>}
          </div>
        </div>
      ))}
    </div>, document.body);
}
